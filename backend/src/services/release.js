const { supabase }  = require('../config/supabase');
const contract      = require('./contract');

const FEE_BPS = 150;

async function releaseMerchant(merchantId) {
  const escrowChain = await contract.fetchEscrowOnChain(merchantId);
  if (!escrowChain || escrowChain.pendingBalance === 0) {
    return { skipped: true, merchantId, reason: 'zero balance' };
  }

  const gross = escrowChain.pendingBalance;
  const fee   = Math.floor(gross * FEE_BPS / 10_000);
  const net   = gross - fee;

  const tx  = await contract.releaseMerchant(merchantId);
  const now = new Date().toISOString();

  await supabase.from('release_logs').insert({
    merchant_id: merchantId,
    gross: gross / 1_000_000, fee: fee / 1_000_000, net: net / 1_000_000,
    tx_signature: tx, status: 'success', released_at: now,
  });

  await supabase.from('transactions').insert([
    { merchant_id: merchantId, type: 'release', amount: gross/1_000_000, fee: fee/1_000_000, net: net/1_000_000, tx_signature: tx, status: 'confirmed' },
    { merchant_id: merchantId, type: 'fee',     amount: fee/1_000_000,   tx_signature: tx, status: 'confirmed' },
  ]);

  await supabase.from('escrows')
    .update({ pending_balance: 0, last_released_at: now })
    .eq('merchant_id', merchantId);

  console.log(`[release] ${merchantId} gross:${gross} fee:${fee} net:${net} tx:${tx}`);
  return { skipped: false, merchantId, gross, fee, net, tx };
}

async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase.from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running', started_at: new Date().toISOString() })
    .select().single();
  const runId = run?.id;

  const { data: merchants } = await supabase.from('merchants').select('merchant_id').eq('is_active', true);
  if (!merchants?.length) {
    await supabase.from('cron_logs').update({ status: 'skipped', finished_at: new Date().toISOString(), summary: 'No active merchants' }).eq('id', runId);
    return { total: 0, released: 0, skipped: 0, failed: 0, results: [] };
  }

  const results = []; let released = 0, skipped = 0, failed = 0;

  for (const { merchant_id } of merchants) {
    try {
      const r = await releaseMerchant(merchant_id);
      results.push(r);
      r.skipped ? skipped++ : released++;
    } catch (err) {
      console.error(`[releaseAll] ${merchant_id}:`, err.message);
      results.push({ merchantId: merchant_id, error: err.message });
      failed++;
      await supabase.from('release_logs').insert({ merchant_id, status: 'failed', error: err.message });
    }
  }

  const summary = `${released} released, ${skipped} skipped, ${failed} failed`;
  await supabase.from('cron_logs').update({
    status: failed > 0 ? 'partial' : 'success',
    finished_at: new Date().toISOString(), summary,
    total_merchants: merchants.length, released, skipped, failed,
  }).eq('id', runId);

  return { total: merchants.length, released, skipped, failed, results };
}

module.exports = { releaseMerchant, releaseAll };
