require('../config/env');
const { PublicKey }                                     = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress }   = require('@solana/spl-token');
const {
  getProgram, getKeypair,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
} = require('../config/anchor');
const { supabase } = require('../config/supabase');

// ── releaseMerchant ───────────────────────────────────────
// Calls the on-chain release() instruction for one merchant.
// gross → fee (1.5%) + net → merchant wallet
async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);

  // Fetch on-chain state to get wallet addresses
  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const merchantAccount = await program.account.merchantAccount.fetch(merchantPDA);
  const configAccount   = await program.account.settlConfig.fetch(configPDA);

  const merchantWallet  = merchantAccount.wallet;
  const treasuryWallet  = configAccount.treasuryWallet;

  // Derive ATAs (associated token accounts) for merchant and treasury
  const merchantAta = await getAssociatedTokenAddress(auddMint, merchantWallet);
  const treasuryAta = await getAssociatedTokenAddress(auddMint, treasuryWallet);

  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config:      configPDA,
      merchant:    merchantPDA,
      escrow:      escrowPDA,
      vault:       vaultPDA,
      merchantAta,
      treasuryAta,
      authority:   authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority])
    .rpc();

  console.log(`[release] ${merchantId} → tx: ${tx}`);
  return { tx, merchantId };
}

// ── releaseAllMerchants ───────────────────────────────────
// Loops all active merchants, calls release() on each,
// logs results to Supabase release_logs table.
async function releaseAllMerchants() {
  const { getProgram, getEscrowPDA } = require('../config/anchor');
  const program = getProgram();

  console.log('[cron] Starting daily release run…');

  const { data: merchants, error } = await supabase
    .from('merchants')
    .select('merchant_id')
    .eq('is_active', true);

  if (error) throw new Error('Failed to fetch merchants: ' + error.message);
  if (!merchants.length) { console.log('[cron] No active merchants to release.'); return; }

  const results = { success: 0, skipped: 0, failed: 0, txs: [] };

  for (const { merchant_id } of merchants) {
    let logRecord = {
      merchant_id,
      status:     'pending',
      released_at: new Date().toISOString(),
    };

    try {
      // Check on-chain balance before calling release
      const [escrowPDA] = getEscrowPDA(merchant_id);
      const escrow      = await program.account.escrowAccount.fetch(escrowPDA).catch(() => null);

      if (!escrow || escrow.pendingBalance.toNumber() === 0) {
        logRecord.status = 'skipped';
        logRecord.error  = 'Zero balance';
        results.skipped++;
      } else {
        const gross = escrow.pendingBalance.toNumber();
        const fee   = Math.floor(gross * 150 / 10_000);  // 1.5%
        const net   = gross - fee;

        const { tx } = await releaseMerchant(merchant_id);

        logRecord = {
          ...logRecord,
          gross,
          fee,
          net,
          tx_signature: tx,
          status:       'success',
        };
        results.success++;
        results.txs.push({ merchant_id, tx });

        // Update escrow DB snapshot
        await supabase
          .from('escrows')
          .update({ pending_balance: 0, last_released_at: new Date().toISOString() })
          .eq('merchant_id', merchant_id);

        // Record transaction in DB
        await supabase.from('transactions').insert({
          merchant_id,
          type:         'release',
          amount:       gross,
          fee,
          net,
          tx_signature: tx,
          status:       'confirmed',
        });
      }
    } catch (err) {
      console.error(`[release] Failed for ${merchant_id}:`, err.message);
      logRecord.status = 'failed';
      logRecord.error  = err.message;
      results.failed++;
    }

    // Log every merchant result to Supabase
    await supabase.from('release_logs').insert(logRecord);
  }

  console.log(`[cron] Release run complete — success:${results.success} skipped:${results.skipped} failed:${results.failed}`);
  return results;
}

module.exports = { releaseMerchant, releaseAllMerchants };
