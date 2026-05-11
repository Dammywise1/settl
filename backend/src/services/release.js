const { PublicKey } = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } = require('@solana/spl-token');
const { supabase } = require('../config/supabase');
const {
  getProgram, getKeypair,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
  getVaultTokenBalance,
} = require('../config/anchor');

const FEE_BPS = 150; // 1.5%

// ── releaseMerchant ───────────────────────────────────────
// Now works with updated contract that reads vault.amount directly
async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);
  const treasury  = new PublicKey(process.env.TREASURY_WALLET);

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  // ── Read gross from vault token balance ──────────────────
  // Contract now uses vault.amount directly, so no need for pending_balance sync
  const vaultAddress = vaultPDA.toBase58();
  const vaultBal = await getVaultTokenBalance(vaultAddress);
  const grossAudd = vaultBal.uiAmount || 0;

  if (grossAudd === 0) {
    console.log(`[release] ${merchantId} - zero balance, skipping`);
    return { skipped: true, merchantId, reason: 'zero balance in vault' };
  }

  // Convert to raw lamports (6 decimals for AUDD)
  const gross = Math.floor(grossAudd * 1_000_000);
  const fee   = Math.floor(gross * FEE_BPS / 10_000);
  const net   = gross - fee;

  console.log(`[release] ${merchantId} gross:${grossAudd} AUDD (fee:${fee/1_000_000} net:${net/1_000_000})`);

  // ── Verify escrow exists on-chain ────────────────────────
  try {
    await program.account.escrowAccount.fetch(escrowPDA);
  } catch (err) {
    if (err.message?.includes('Account does not exist') || err.message?.includes('has no data')) {
      console.log(`[release] ${merchantId} - escrow not initialized, cannot release`);
      return { skipped: true, merchantId, reason: 'escrow not initialized' };
    }
    throw err;
  }

  // ── Get merchant wallet and ATAs ─────────────────────────
  const merchantAccount = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, merchantAccount.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  // ── Call contract's release() ────────────────────────────
  // Contract now uses vault.amount directly, so works with Solana Pay transfers
  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config:       configPDA,
      merchant:     merchantPDA,
      escrow:       escrowPDA,
      vault:        vaultPDA,
      merchantAta:  merchantATA,
      treasuryAta:  treasuryATA,
      authority:    authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority])
    .rpc();

  console.log(`[release] ${merchantId} - SUCCESS! tx: ${tx}`);
  
  return await recordRelease(merchantId, gross, fee, net, tx);
}

// ── recordRelease ─────────────────────────────────────────
// Writes release to DB and fires webhook + email.
async function recordRelease(merchantId, gross, fee, net, txSignature) {
  const now       = new Date().toISOString();
  const grossAudd = gross / 1_000_000;
  const feeAudd   = fee   / 1_000_000;
  const netAudd   = net   / 1_000_000;

  // Insert release log
  await supabase.from('release_logs').insert({
    merchant_id:  merchantId,
    gross:        grossAudd,
    fee:          feeAudd,
    net:          netAudd,
    tx_signature: txSignature,
    status:       'success',
    released_at:  now,
  });

  // Insert transactions
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
        gross: grossAudd, 
        fee: feeAudd, 
        net: netAudd,
        tx_signature: txSignature, 
        released_at: now,
      });
    } catch (e) { 
      console.warn('[release] webhook error:', e.message); 
    }

    try {
      const emailSvc = require('./email');
      const { data: merchant } = await supabase
        .from('merchants')
        .select('user_id, name')
        .eq('merchant_id', merchantId)
        .maybeSingle();
      
      if (merchant?.user_id) {
        const { data: user } = await supabase
          .from('users')
          .select('email')
          .eq('id', merchant.user_id)
          .maybeSingle();
        
        if (user?.email) {
          const { data: already } = await supabase
            .from('notification_log')
            .select('id')
            .eq('ref', txSignature)
            .eq('type', 'release.completed')
            .maybeSingle();
          
          if (!already) {
            await emailSvc.sendReleaseCompleted({
              email: user.email, 
              merchantName: merchant.name,
              gross: grossAudd, 
              fee: feeAudd, 
              net: netAudd, 
              txSignature,
            });
            await supabase.from('notification_log').insert({
              merchant_id: merchantId, 
              type: 'release.completed', 
              ref: txSignature,
            });
          }
        }
      }
    } catch (e) { 
      console.warn('[release] email error:', e.message); 
    }
  });

  return { 
    skipped: false, 
    merchantId, 
    gross: grossAudd, 
    fee: feeAudd, 
    net: netAudd, 
    tx: txSignature 
  };
}

// ── releaseAll ────────────────────────────────────────────
async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase
    .from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running' })
    .select()
    .single();
  
  const runId = run?.id;

  const { data: merchants } = await supabase
    .from('merchants')
    .select('merchant_id')
    .eq('is_active', true);

  if (!merchants?.length) {
    await supabase
      .from('cron_logs')
      .update({
        status: 'skipped', 
        finished_at: new Date().toISOString(),
        summary: 'No active merchants',
      })
      .eq('id', runId);
    
    return { 
      total: 0, 
      released: 0, 
      skipped: 0, 
      failed: 0, 
      results: [], 
      summary: 'No active merchants' 
    };
  }

  let released = 0, skipped = 0, failed = 0;
  const results = [];

  for (const { merchant_id } of merchants) {
    try {
      const r = await releaseMerchant(merchant_id);
      results.push(r);
      if (r.skipped) {
        skipped++;
      } else {
        released++;
      }
    } catch (err) {
      console.error(`[releaseAll] ${merchant_id}:`, err.message);
      results.push({ merchantId: merchant_id, error: err.message });
      failed++;
      
      await supabase.from('release_logs').insert({
        merchant_id, 
        status: 'failed', 
        error: err.message,
      });
    }
  }

  const summary = `${released} released, ${skipped} skipped, ${failed} failed`;
  
  await supabase
    .from('cron_logs')
    .update({
      status: failed > 0 ? 'partial' : 'success',
      finished_at: new Date().toISOString(),
      summary,
      total_merchants: merchants.length,
      released, 
      skipped, 
      failed,
    })
    .eq('id', runId);

  return { 
    total: merchants.length, 
    released, 
    skipped, 
    failed, 
    results, 
    summary 
  };
}

module.exports = { releaseMerchant, releaseAll };