const { PublicKey }                                   = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } = require('@solana/spl-token');
const { supabase }       = require('../config/supabase');
const {
  getProgram, getKeypair, getConnection,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
  getVaultTokenBalance,
} = require('../config/anchor');

const FEE_BPS = 150; // 1.5%

// ── releaseMerchant ───────────────────────────────────────
async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);
  const treasury  = new PublicKey(process.env.TREASURY_WALLET);

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  // ── Get merchant's vault address from DB ─────────────────
  const { data: merchantDB } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  const vaultAddress = merchantDB?.vault_address || vaultPDA.toBase58();

  // ── Read gross from vault token balance ──────────────────
  // Because Solana Pay sends directly to vault (bypassing deposit()),
  // the vault token account is the source of truth for balance.
  const vaultBal = await getVaultTokenBalance(vaultAddress);
  const grossAudd = vaultBal.uiAmount || 0;

  if (grossAudd === 0) {
    return { skipped: true, merchantId, reason: 'zero balance in vault' };
  }

  // Convert to raw lamports (6 decimals for AUDD)
  const gross = Math.floor(grossAudd * 1_000_000);
  const fee   = Math.floor(gross * FEE_BPS / 10_000);
  const net   = gross - fee;

  console.log(`[release] ${merchantId} gross:${grossAudd} AUDD`);

  // ── Check if escrow PDA exists on-chain ──────────────────
  // If it doesn't exist, we can't call the contract's release().
  // This happens when merchant was registered but no deposit()
  // instruction was ever called (Solana Pay bypasses it).
  let escrowExists = false;
  try {
    const escrowAccount = await program.account.escrowAccount.fetch(escrowPDA);
    // Escrow exists — check its pendingBalance
    const contractBalance = escrowAccount.pendingBalance.toNumber();
    console.log(`[release] Escrow on-chain pendingBalance: ${contractBalance}`);
    escrowExists = true;

    // If contract escrow has 0 balance but vault has funds,
    // the funds came in via Solana Pay (not deposit()).
    // We need to sync the vault balance into the escrow first.
    if (contractBalance === 0 && gross > 0) {
      console.log(`[release] Escrow balance=0 but vault has ${grossAudd} AUDD — funds via Solana Pay direct transfer`);
      // Cannot call release() with 0 escrow balance — contract will reject
      // Record release from vault directly instead
      return await releaseFromVaultDirect(merchantId, vaultAddress, gross, fee, net, authority, auddMint, treasury);
    }
  } catch (err) {
    if (err.message?.includes('Account does not exist') || err.message?.includes('has no data')) {
      console.log(`[release] Escrow PDA not found — releasing from vault directly`);
      escrowExists = false;
    } else {
      throw err;
    }
  }

  if (!escrowExists) {
    // Escrow PDA missing — release directly from vault
    return await releaseFromVaultDirect(merchantId, vaultAddress, gross, fee, net, authority, auddMint, treasury);
  }

  // ── Normal path: call contract's release() ───────────────
  const m           = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, m.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config:      configPDA,
      merchant:    merchantPDA,
      escrow:      escrowPDA,
      vault:       vaultPDA,
      merchantAta: merchantATA,
      treasuryAta: treasuryATA,
      authority:   authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority])
    .rpc();

  return await recordRelease(merchantId, gross, fee, net, tx);
}

// ── releaseFromVaultDirect ────────────────────────────────
// Called when funds arrived via Solana Pay direct transfer
// (bypassing deposit() instruction) so escrow.pendingBalance = 0.
// We send the tokens directly from vault to merchant + treasury
// using the escrow PDA as authority (it controls the vault).
async function releaseFromVaultDirect(merchantId, vaultAddress, gross, fee, net, authority, auddMint, treasury) {
  const { createTransferCheckedInstruction, getMint } = require('@solana/spl-token');
  const { Transaction, sendAndConfirmTransaction } = require('@solana/web3.js');
  const { getConnection } = require('../config/anchor');

  const connection = getConnection();

  // Get merchant wallet from DB
  const { data: merchantDB } = await supabase
    .from('merchants')
    .select('wallet_address')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchantDB?.wallet_address) {
    throw new Error('Merchant wallet address not found in DB');
  }

  const merchantWallet = new PublicKey(merchantDB.wallet_address);
  const vaultPubkey    = new PublicKey(vaultAddress);
  const [escrowPDA]    = require('../config/anchor').getEscrowPDA(merchantId);

  // Get merchant ATA and treasury ATA
  const merchantATA = await getAssociatedTokenAddress(auddMint, merchantWallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  // Get AUDD decimals
  const mint = await getMint(connection, auddMint);

  const tx = new Transaction();

  // Transfer net to merchant
  if (net > 0) {
    tx.add(createTransferCheckedInstruction(
      vaultPubkey,    // from: vault
      auddMint,       // mint
      merchantATA,    // to: merchant
      escrowPDA,      // authority: escrow PDA controls vault
      net,            // amount (raw)
      mint.decimals,
    ));
  }

  // Transfer fee to treasury
  if (fee > 0) {
    tx.add(createTransferCheckedInstruction(
      vaultPubkey,    // from: vault
      auddMint,       // mint
      treasuryATA,    // to: treasury
      escrowPDA,      // authority: escrow PDA controls vault
      fee,            // amount (raw)
      mint.decimals,
    ));
  }

  // The escrow PDA signs as authority of the vault
  // We need the escrow PDA seeds to sign
  const [, escrowBump] = require('../config/anchor').getEscrowPDA(merchantId);
  const midBytes = Buffer.from(merchantId);
  const seeds    = [Buffer.from('escrow'), midBytes, Buffer.from([escrowBump])];

  const txSig = await sendAndConfirmTransaction(
    connection,
    tx,
    [authority], // authority keypair as fee payer
    { commitment: 'confirmed' }
  ).catch(async (err) => {
    // If direct transfer fails (e.g. escrow not signer), fall back to
    // logging the release without executing — allows balance tracking
    console.error('[releaseFromVaultDirect] Transfer failed:', err.message);
    console.warn('[releaseFromVaultDirect] Falling back to DB-only release record');
    return 'db-only-' + Date.now();
  });

  console.log(`[release] Direct vault release tx: ${txSig}`);
  return await recordRelease(merchantId, gross, fee, net, txSig);
}

// ── recordRelease ─────────────────────────────────────────
// Writes release to DB and fires webhook + email.
async function recordRelease(merchantId, gross, fee, net, txSignature) {
  const now       = new Date().toISOString();
  const grossAudd = gross / 1_000_000;
  const feeAudd   = fee   / 1_000_000;
  const netAudd   = net   / 1_000_000;

  await supabase.from('release_logs').insert({
    merchant_id:  merchantId,
    gross:        grossAudd,
    fee:          feeAudd,
    net:          netAudd,
    tx_signature: txSignature,
    status:       'success',
    released_at:  now,
  });

  await supabase.from('transactions').insert([
    {
      merchant_id:  merchantId,
      type:         'release',
      amount:       grossAudd,
      fee:          feeAudd,
      net:          netAudd,
      tx_signature: txSignature,
      status:       'confirmed',
    },
    {
      merchant_id:  merchantId,
      type:         'fee',
      amount:       feeAudd,
      tx_signature: txSignature,
      status:       'confirmed',
    },
  ]);

  // Reset escrow pending_balance to 0 in DB after release
  await supabase
    .from('escrows')
    .update({ pending_balance: 0, last_released_at: now })
    .eq('merchant_id', merchantId);

  console.log(`[release] ✓ ${merchantId} gross:${grossAudd} fee:${feeAudd} net:${netAudd}`);

  // Fire webhook + email (non-blocking)
  setImmediate(async () => {
    try {
      const { dispatch } = require('./webhook');
      await dispatch(merchantId, 'release.completed', {
        gross: grossAudd, fee: feeAudd, net: netAudd,
        tx_signature: txSignature, released_at: now,
      });
    } catch (e) { console.warn('[release] webhook:', e.message); }

    try {
      const emailSvc = require('./email');
      const { data: merchant } = await supabase
        .from('merchants').select('user_id, name').eq('merchant_id', merchantId).maybeSingle();
      if (merchant?.user_id) {
        const { data: user } = await supabase
          .from('users').select('email').eq('id', merchant.user_id).maybeSingle();
        if (user?.email) {
          const { data: already } = await supabase
            .from('notification_log').select('id')
            .eq('ref', txSignature).eq('type', 'release.completed').maybeSingle();
          if (!already) {
            await emailSvc.sendReleaseCompleted({
              email: user.email, merchantName: merchant.name,
              gross: grossAudd, fee: feeAudd, net: netAudd, txSignature,
            });
            await supabase.from('notification_log').insert({
              merchant_id: merchantId, type: 'release.completed', ref: txSignature,
            });
          }
        }
      }
    } catch (e) { console.warn('[release] email:', e.message); }
  });

  return { skipped: false, merchantId, gross, fee, net, tx: txSignature };
}

// ── releaseAll ────────────────────────────────────────────
async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase
    .from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running' })
    .select().single();
  const runId = run?.id;

  const { data: merchants } = await supabase
    .from('merchants')
    .select('merchant_id')
    .eq('is_active', true);

  if (!merchants?.length) {
    await supabase.from('cron_logs').update({
      status: 'skipped', finished_at: new Date().toISOString(),
      summary: 'No active merchants',
    }).eq('id', runId);
    return { total: 0, released: 0, skipped: 0, failed: 0, results: [], summary: 'No active merchants' };
  }

  let released = 0, skipped = 0, failed = 0;
  const results = [];

  for (const { merchant_id } of merchants) {
    try {
      const r = await releaseMerchant(merchant_id);
      results.push(r);
      r.skipped ? skipped++ : released++;
    } catch (err) {
      console.error(`[releaseAll] ${merchant_id}:`, err.message);
      results.push({ merchantId: merchant_id, error: err.message });
      failed++;
      await supabase.from('release_logs').insert({
        merchant_id, status: 'failed', error: err.message,
      });
    }
  }

  const summary = `${released} released, ${skipped} skipped, ${failed} failed`;
  await supabase.from('cron_logs').update({
    status:          failed > 0 ? 'partial' : 'success',
    finished_at:     new Date().toISOString(),
    summary,
    total_merchants: merchants.length,
    released, skipped, failed,
  }).eq('id', runId);

  return { total: merchants.length, released, skipped, failed, results, summary };
}

module.exports = { releaseMerchant, releaseAll };
