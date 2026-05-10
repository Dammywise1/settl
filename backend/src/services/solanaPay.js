const { PublicKey, Keypair } = require('@solana/web3.js');
const BigNumber  = require('bignumber.js');
const { supabase }    = require('../config/supabase');
const { getConnection, getVaultPDA } = require('../config/anchor');

// Lazy-load @solana/pay to avoid startup crash if not yet installed
let solanaPay;
function getSolanaPay() {
  if (!solanaPay) solanaPay = require('@solana/pay');
  return solanaPay;
}

// ── createPaymentSession ──────────────────────────────────
// The vault PDA = [b"vault", merchant_id] is a SPL token account
// that holds AUDD on behalf of the escrow.
//
// Solana Pay transfer request:
//   recipient  = vault PDA address (the token account)
//   spl-token  = AUDD mint
//   reference  = unique keypair pubkey for tracking
//
// This means: send AUDD to the vault directly.
// The escrow program already controls that vault PDA.
async function createPaymentSession({ merchantId, amountAudd, message, memo }) {
  // Get vault_address from DB (set during signup registration)
  const { data: merchant, error } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address, name, is_active, registration_status')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchant)                           throw new Error('Merchant not found');
  if (!merchant.is_active)                 throw new Error('Merchant is not active yet. Registration may still be processing.');
  if (!merchant.vault_address)             throw new Error('Vault not initialised for this merchant. Try again in a moment.');

  // vault_address is the SPL token account — use as recipient directly
  const recipient = new PublicKey(merchant.vault_address);
  const splToken  = new PublicKey(process.env.AUDD_MINT);

  // Unique reference keypair for this session
  const referenceKeypair = Keypair.generate();
  const reference        = referenceKeypair.publicKey;

  const label    = merchant.name || merchantId;
  const msgText  = message || `Payment to ${label}`;
  const amount   = amountAudd ? new BigNumber(amountAudd) : undefined;

  const { encodeURL } = getSolanaPay();

  const urlFields = {
    recipient,
    splToken,
    reference:  [reference],
    label,
    message:    msgText,
    ...(memo   ? { memo }   : {}),
    ...(amount ? { amount } : {}),
  };

  const solanaUrl = encodeURL(urlFields).toString();

  // Persist session
  const { data: session } = await supabase.from('payment_sessions').insert({
    merchant_id:   merchantId,
    amount:        amountAudd || null,
    reference_key: reference.toBase58(),
    label,
    message:       msgText,
    memo:          memo || null,
    status:        'pending',
  }).select().single();

  return {
    session_id:    session.id,
    url:           solanaUrl,
    reference:     reference.toBase58(),
    recipient:     merchant.vault_address,
    spl_token:     process.env.AUDD_MINT,
    amount:        amountAudd || null,
    label,
    message:       msgText,
    merchant_name: merchant.name || merchantId,
    // Shareable checkout link — works for anyone, no login
    checkout_url:  `${process.env.APP_URL || 'http://localhost:3000'}/pages/checkout.html?ref=${reference.toBase58()}`,
  };
}

// ── pollPaymentSession ────────────────────────────────────
// Checks on-chain whether the reference has appeared.
// Called by both the merchant dashboard AND the checkout page.
async function pollPaymentSession(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(wallet_address, name, vault_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();

  if (!session) throw new Error('Payment session not found');
  if (session.status === 'confirmed') return { status: 'confirmed', tx: session.tx_signature, session };
  if (session.status === 'expired')   return { status: 'expired',   session };

  // Check expiry
  if (session.expires_at && new Date(session.expires_at) < new Date()) {
    await supabase.from('payment_sessions').update({ status: 'expired' }).eq('reference_key', referenceKey);
    return { status: 'expired', session };
  }

  const { findReference, validateTransfer, FindReferenceError } = getSolanaPay();
  const connection  = getConnection();
  const reference   = new PublicKey(referenceKey);
  const recipient   = new PublicKey(session.merchants.vault_address);
  const splToken    = new PublicKey(process.env.AUDD_MINT);
  const amount      = session.amount ? new BigNumber(session.amount) : undefined;

  try {
    const sigInfo = await findReference(connection, reference, { finality: 'confirmed' });

    // Validate the transfer matches what we asked for
    if (amount) {
      await validateTransfer(connection, sigInfo.signature, { recipient, amount, splToken });
    }

    const now = new Date().toISOString();
    await supabase.from('payment_sessions').update({
      status: 'confirmed', tx_signature: sigInfo.signature, confirmed_at: now,
    }).eq('reference_key', referenceKey);

    // Record deposit transaction
    await supabase.from('transactions').insert({
      merchant_id:   session.merchant_id,
      type:          'deposit',
      amount:        session.amount || 0,
      tx_signature:  sigInfo.signature,
      reference_key: referenceKey,
      status:        'confirmed',
    });

    // Sync escrow balance from chain
    try {
      const { getProgram, getEscrowPDA } = require('../config/anchor');
      const program     = getProgram();
      const [escrowPDA] = getEscrowPDA(session.merchant_id);
      const escrowAcc   = await program.account.escrowAccount.fetch(escrowPDA);
      await supabase.from('escrows').update({
        pending_balance: escrowAcc.pendingBalance.toNumber() / 1_000_000,
        total_payments:  escrowAcc.totalPayments.toNumber(),
      }).eq('merchant_id', session.merchant_id);
    } catch (e) {
      console.warn('[poll] Escrow sync failed:', e.message);
    }

    return { status: 'confirmed', tx: sigInfo.signature, session };

  } catch (err) {
    if (err.name === 'FindReferenceError' || err.message?.includes('not found')) {
      return { status: 'pending', session };
    }
    console.error('[poll] validateTransfer failed:', err.message);
    await supabase.from('payment_sessions').update({ status: 'failed' }).eq('reference_key', referenceKey);
    return { status: 'failed', error: err.message, session };
  }
}

// ── getSessionByRef ───────────────────────────────────────
// Used by the public checkout page to load session info
async function getSessionByRef(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(name, wallet_address, vault_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();
  return session;
}

module.exports = { createPaymentSession, pollPaymentSession, getSessionByRef };
