const { PublicKey, Keypair } = require('@solana/web3.js');
const { encodeURL, findReference, validateTransfer, FindReferenceError } = require('@solana/pay');
const BigNumber = require('bignumber.js');
const { supabase }    = require('../config/supabase');
const { getConnection } = require('../config/anchor');
const contract        = require('./contract');

// ── createPaymentSession ──────────────────────────────────
// Creates a Solana Pay URL + stores session in DB.
// recipient = merchant vault PDA (AUDD token account)
// spl-token = AUDD mint
async function createPaymentSession({ merchantId, amountAudd, label, message, memo }) {
  // Get vault address from DB
  const { data: escrow } = await supabase
    .from('escrows').select('vault_address').eq('merchant_id', merchantId).single();
  if (!escrow?.vault_address) throw new Error('Escrow vault not found for merchant');

  const { data: merchant } = await supabase
    .from('merchants').select('wallet_address, name').eq('merchant_id', merchantId).single();
  if (!merchant) throw new Error('Merchant not found');

  // Generate a unique reference keypair for this session
  const referenceKeypair = Keypair.generate();
  const reference        = referenceKeypair.publicKey;

  // recipient = the merchant's wallet (AUDD will go to their ATA)
  const recipient  = new PublicKey(merchant.wallet_address);
  const splToken   = contract.AUDD_MINT();
  const amount     = amountAudd ? new BigNumber(amountAudd) : undefined;

  const urlFields = {
    recipient,
    splToken,
    reference: [reference],
    label:   label   || merchant.name || merchantId,
    message: message || `Payment to ${merchant.name || merchantId}`,
    ...(memo   ? { memo } : {}),
    ...(amount ? { amount } : {}),
  };

  const solanaPayUrl = encodeURL(urlFields);

  // Store session
  await supabase.from('payment_sessions').insert({
    merchant_id:   merchantId,
    amount:        amountAudd || null,
    reference_key: reference.toBase58(),
    label:   urlFields.label,
    message: urlFields.message,
    memo:    memo || null,
    status:  'pending',
  });

  return {
    url:          solanaPayUrl.toString(),
    reference:    reference.toBase58(),
    recipient:    recipient.toBase58(),
    splToken:     splToken.toBase58(),
    amount:       amountAudd || null,
    label:        urlFields.label,
    message:      urlFields.message,
  };
}

// ── pollPaymentSession ────────────────────────────────────
// Called by frontend polling. Checks if the reference has been
// seen on-chain, then validates the transfer.
async function pollPaymentSession(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(wallet_address, name)')
    .eq('reference_key', referenceKey)
    .single();

  if (!session) throw new Error('Session not found');
  if (session.status === 'confirmed') {
    return { status: 'confirmed', tx: session.tx_signature };
  }
  if (session.status === 'expired') {
    return { status: 'expired' };
  }

  const connection  = getConnection();
  const reference   = new PublicKey(referenceKey);
  const recipient   = new PublicKey(session.merchants.wallet_address);
  const splToken    = contract.AUDD_MINT();
  const amount      = session.amount ? new BigNumber(session.amount) : undefined;

  try {
    const signatureInfo = await findReference(connection, reference, { finality: 'confirmed' });

    // Validate that the transfer matches what we expected
    if (amount) {
      await validateTransfer(connection, signatureInfo.signature, {
        recipient, amount, splToken,
      });
    }

    const now = new Date().toISOString();

    // Mark confirmed in DB
    await supabase.from('payment_sessions').update({
      status: 'confirmed', tx_signature: signatureInfo.signature, confirmed_at: now,
    }).eq('reference_key', referenceKey);

    // Record transaction
    await supabase.from('transactions').insert({
      merchant_id:    session.merchant_id,
      type:           'deposit',
      amount:         session.amount || 0,
      tx_signature:   signatureInfo.signature,
      reference_key:  referenceKey,
      status:         'confirmed',
    });

    // Sync escrow balance
    const escrowChain = await contract.fetchEscrowOnChain(session.merchant_id).catch(() => null);
    if (escrowChain) {
      await supabase.from('escrows').update({
        pending_balance: escrowChain.pendingBalance / 1_000_000,
        total_payments:  escrowChain.totalPayments,
      }).eq('merchant_id', session.merchant_id);
    }

    return { status: 'confirmed', tx: signatureInfo.signature };

  } catch (err) {
    if (err instanceof FindReferenceError) {
      // Not found yet — still pending
      return { status: 'pending' };
    }
    // Validation failed
    console.error('[solanaPay] validateTransfer failed:', err.message);
    await supabase.from('payment_sessions').update({ status: 'failed' }).eq('reference_key', referenceKey);
    return { status: 'failed', error: err.message };
  }
}

module.exports = { createPaymentSession, pollPaymentSession };
