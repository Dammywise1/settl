const { PublicKey }                               = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } = require('@solana/spl-token');
const { supabase }   = require('../config/supabase');
const { getProgram, getKeypair, getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA } = require('../config/anchor');

const FEE_BPS = 150;

async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);
  const treasury  = new PublicKey(process.env.TREASURY_WALLET);

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const escrowBefore = await program.account.escrowAccount.fetch(escrowPDA);
  const gross        = escrowBefore.pendingBalance.toNumber();
  if (gross === 0) return { skipped: true, merchantId, reason: 'zero balance' };

  const fee = Math.floor(gross * FEE_BPS / 10_000);
  const net = gross - fee;

  const m = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, m.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  const tx = await program.methods.release(merchantId)
    .accounts({
      config: configPDA, merchant: merchantPDA, escrow: escrowPDA,
      vault: vaultPDA, merchantAta: merchantATA, treasuryAta: treasuryATA,
      authority: authority.publicKey, tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority]).rpc();

  const now = new Date().toISOString();
  await supabase.from('release_logs').insert({ merchant_id: merchantId, gross: gross/1e6, fee: fee/1e6, net: net/1e6, tx_signature: tx, status: 'success', released_at: now });
  await supabase.from('transactions').insert([
    { merchant_id: merchantId, type: 'release', amount: gross/1e6, fee: fee/1e6, net: net/1e6, tx_signature: tx, status: 'confirmed' },
    { merchant_id: merchantId, type: 'fee',     amount: fee/1e6,   tx_signature: tx, status: 'confirmed' },
  ]);
  await supabase.from('escrows').update({ pending_balance: 0, last_released_at: now }).eq('merchant_id', merchantId);
  console.log(`[release] ${merchantId} gross:${gross} fee:${fee} net:${net} tx:${tx}`);
  return { skipped: false, merchantId, gross, fee, net, tx };
}

async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase.from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running' }).select().single();
  const runId = run?.id;
  const { data: merchants } = await supabase.from('merchants').select('merchant_id').eq('is_active', true);
  if (!merchants?.length) {
    await supabase.from('cron_logs').update({ status: 'skipped', finished_at: new Date().toISOString(), summary: 'No active merchants' }).eq('id', runId);
    return { total: 0, released: 0, skipped: 0, failed: 0, results: [] };
  }
  let released=0, skipped=0, failed=0; const results=[];
  for (const { merchant_id } of merchants) {
    try { const r=await releaseMerchant(merchant_id); results.push(r); r.skipped?skipped++:released++; }
    catch(err) {
      console.error(`[releaseAll] ${merchant_id}:`, err.message);
      results.push({ merchantId: merchant_id, error: err.message });
      failed++;
      await supabase.from('release_logs').insert({ merchant_id, status: 'failed', error: err.message });
    }
  }
  const summary = `${released} released, ${skipped} skipped, ${failed} failed`;
  await supabase.from('cron_logs').update({ status: failed>0?'partial':'success', finished_at: new Date().toISOString(), summary, total_merchants: merchants.length, released, skipped, failed }).eq('id', runId);
  return { total: merchants.length, released, skipped, failed, results };
}

module.exports = { releaseMerchant, releaseAll };
