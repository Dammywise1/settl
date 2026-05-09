const { supabase }  = require('../config/supabase');
const contract      = require('./contract');
const { PublicKey } = require('@solana/web3.js');

// Validate a Solana base58 public key — lenient check
function isValidSolanaAddress(address) {
  try {
    if (!address || typeof address !== 'string') return false;
    if (address.length < 32 || address.length > 44) return false;
    new PublicKey(address); // throws if invalid
    return true;
  } catch { return false; }
}

// Full flow: on-chain register → escrow init → DB save
async function createMerchant({ merchantId, walletAddress, name, email, createdBy }) {
  if (!isValidSolanaAddress(walletAddress)) {
    throw new Error('Invalid Solana wallet address. Must be a valid base58 public key (32–44 characters).');
  }
  if (!merchantId || merchantId.length > 64) {
    throw new Error('Merchant ID must be 1–64 characters');
  }

  const { tx: registerTx, merchantPDA } = await contract.registerMerchant(merchantId, walletAddress);
  const { tx: escrowTx, escrowPDA, vaultPDA } = await contract.initializeMerchantEscrow(merchantId);

  const { data: merchant, error } = await supabase.from('merchants')
    .upsert({
      merchant_id: merchantId, wallet_address: walletAddress,
      name: name || merchantId, email: email || null,
      is_active: true, registered_at: new Date().toISOString(),
      on_chain_tx: registerTx, escrow_tx: escrowTx,
      merchant_pda: merchantPDA, escrow_pda: escrowPDA, vault_address: vaultPDA,
      created_by: createdBy,
    }, { onConflict: 'merchant_id' })
    .select().single();

  if (error) throw new Error('DB save failed: ' + error.message);

  await supabase.from('escrows').upsert({
    merchant_id: merchantId, pending_balance: 0, total_payments: 0, vault_address: vaultPDA,
  }, { onConflict: 'merchant_id' });

  return { merchant, registerTx, escrowTx, merchantPDA, escrowPDA, vaultPDA };
}

module.exports = { createMerchant, isValidSolanaAddress };
