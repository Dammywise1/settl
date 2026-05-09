const { supabase } = require('../config/supabase');
const contract     = require('./contract');

// ── createMerchant ────────────────────────────────────────
// Full flow: on-chain register → escrow init → DB record
async function createMerchant({ merchantId, walletAddress, name, email, createdBy }) {
  // 1. Register on-chain
  const { tx: registerTx, merchantPDA } = await contract.registerMerchant(merchantId, walletAddress);

  // 2. Initialize escrow vault
  const { tx: escrowTx, escrowPDA, vaultPDA } = await contract.initializeMerchantEscrow(merchantId);

  // 3. Persist to Supabase — merchants table
  const { data: merchant, error: mErr } = await supabase
    .from('merchants')
    .upsert({
      merchant_id:    merchantId,
      wallet_address: walletAddress,
      name:           name || merchantId,
      email:          email || null,
      is_active:      true,
      registered_at:  new Date().toISOString(),
      on_chain_tx:    registerTx,
      created_by:     createdBy,
    }, { onConflict: 'merchant_id' })
    .select()
    .single();

  if (mErr) throw new Error('DB merchant insert failed: ' + mErr.message);

  // 4. Persist escrow record
  const { error: eErr } = await supabase
    .from('escrows')
    .upsert({
      merchant_id:     merchantId,
      pending_balance: 0,
      total_payments:  0,
      vault_address:   vaultPDA,
    }, { onConflict: 'merchant_id' });

  if (eErr) throw new Error('DB escrow insert failed: ' + eErr.message);

  return { merchant, registerTx, escrowTx, escrowPDA, vaultPDA };
}

// ── getMerchantWithChainState ─────────────────────────────
// Merges DB record + live on-chain state
async function getMerchantWithChainState(merchantId) {
  const { data: dbRecord, error } = await supabase
    .from('merchants')
    .select('*, escrows(*)')
    .eq('merchant_id', merchantId)
    .single();

  if (error || !dbRecord) throw new Error('Merchant not found');

  const [onChain, escrowChain] = await Promise.all([
    contract.fetchMerchantOnChain(merchantId),
    contract.fetchEscrowOnChain(merchantId),
  ]);

  return { db: dbRecord, onChain, escrowChain };
}

// ── syncMerchantFromChain ─────────────────────────────────
// Updates DB to match on-chain state (called after wallet updates)
async function syncMerchantFromChain(merchantId) {
  const onChain = await contract.fetchMerchantOnChain(merchantId);
  if (!onChain) throw new Error('Merchant not found on-chain');

  await supabase
    .from('merchants')
    .update({
      wallet_address: onChain.wallet,
      is_active:      onChain.isActive,
    })
    .eq('merchant_id', merchantId);

  return onChain;
}

// ── requestWalletUpdate ───────────────────────────────────
async function requestWalletUpdate(merchantId, newWallet) {
  const result = await contract.requestWalletUpdate(merchantId, newWallet);

  // Record in DB for audit
  await supabase.from('wallet_update_requests').upsert({
    merchant_id:  merchantId,
    new_wallet:   newWallet,
    tx_signature: result.tx,
    unlocks_at:   new Date(Date.now() + 86_400_000).toISOString(),
    status:       'pending',
  }, { onConflict: 'merchant_id' });

  return result;
}

// ── confirmWalletUpdate ───────────────────────────────────
async function confirmWalletUpdate(merchantId) {
  const result = await contract.confirmWalletUpdate(merchantId);
  await contract.updateEscrowWallet(merchantId);
  await syncMerchantFromChain(merchantId);

  await supabase
    .from('wallet_update_requests')
    .update({ status: 'confirmed', confirmed_at: new Date().toISOString() })
    .eq('merchant_id', merchantId);

  return result;
}

// ── deactivateMerchant ────────────────────────────────────
async function deactivateMerchant(merchantId) {
  const result = await contract.deactivateMerchant(merchantId);

  await supabase
    .from('merchants')
    .update({ is_active: false })
    .eq('merchant_id', merchantId);

  return result;
}

module.exports = {
  createMerchant,
  getMerchantWithChainState,
  syncMerchantFromChain,
  requestWalletUpdate,
  confirmWalletUpdate,
  deactivateMerchant,
};
