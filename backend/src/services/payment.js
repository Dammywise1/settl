require('../config/env');
const { v4: uuidv4 }   = require('uuid');
const { supabase }     = require('../config/supabase');

// ── createPaymentLink ─────────────────────────────────────
// Generates a shareable payment token for a merchant.
// Customer opens /pay/{token} and their wallet handles deposit.
async function createPaymentLink({ merchantId, amount, description, expiresInHours = 24 }) {
  // Verify merchant exists and is active
  const { data: merchant, error } = await supabase
    .from('merchants')
    .select('id, merchant_id, wallet_address, is_active, name')
    .eq('merchant_id', merchantId)
    .single();

  if (error || !merchant) throw new Error('Merchant not found');
  if (!merchant.is_active) throw new Error('Merchant is inactive');

  const token     = uuidv4();
  const expiresAt = new Date(Date.now() + expiresInHours * 3_600_000);

  const { data: link, error: linkErr } = await supabase
    .from('payment_links')
    .insert({
      token,
      merchant_id:  merchantId,
      amount:       amount || null,   // null = open amount
      description:  description || null,
      expires_at:   expiresAt.toISOString(),
      status:       'active',
    })
    .select()
    .single();

  if (linkErr) throw new Error('Failed to create payment link: ' + linkErr.message);

  return {
    token,
    link:       `${process.env.FRONTEND_URL || 'http://localhost:3000'}/pages/pay.html?token=${token}`,
    expiresAt:  expiresAt.toISOString(),
    merchant:   { id: merchantId, name: merchant.name, wallet: merchant.wallet_address },
    amount,
  };
}

// ── getPaymentLink ────────────────────────────────────────
async function getPaymentLink(token) {
  const { data, error } = await supabase
    .from('payment_links')
    .select('*, merchants(merchant_id, name, wallet_address, is_active)')
    .eq('token', token)
    .single();

  if (error || !data) throw new Error('Payment link not found or expired');
  if (data.status !== 'active') throw new Error('Payment link is no longer active');
  if (new Date(data.expires_at) < new Date()) {
    await supabase.from('payment_links').update({ status: 'expired' }).eq('token', token);
    throw new Error('Payment link has expired');
  }

  return data;
}

// ── confirmDeposit ────────────────────────────────────────
// Called after customer's wallet completes the on-chain deposit.
// Records the transaction and marks payment link as used.
async function confirmDeposit({ token, txSignature, amount, customerWallet }) {
  const link = await getPaymentLink(token);

  // Record transaction
  const { data: tx, error: txErr } = await supabase
    .from('transactions')
    .insert({
      merchant_id:     link.merchant_id,
      type:            'deposit',
      amount,
      customer_wallet: customerWallet || null,
      tx_signature:    txSignature,
      status:          'confirmed',
    })
    .select()
    .single();

  if (txErr) throw new Error('Failed to record transaction: ' + txErr.message);

  // Mark link as used (one-time use)
  await supabase
    .from('payment_links')
    .update({ status: 'used', used_at: new Date().toISOString() })
    .eq('token', token);

  // Update escrow snapshot in DB
  const { data: escrow } = await supabase
    .from('escrows')
    .select('pending_balance, total_payments')
    .eq('merchant_id', link.merchant_id)
    .single();

  if (escrow) {
    await supabase
      .from('escrows')
      .update({
        pending_balance: (escrow.pending_balance || 0) + amount,
        total_payments:  (escrow.total_payments  || 0) + 1,
      })
      .eq('merchant_id', link.merchant_id);
  }

  return tx;
}

module.exports = { createPaymentLink, getPaymentLink, confirmDeposit };
