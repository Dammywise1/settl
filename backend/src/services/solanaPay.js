const { PublicKey, Keypair } = require('@solana/web3.js');
const BigNumber  = require('bignumber.js');
const { supabase } = require('../config/supabase');
const {
  getConnection, getEscrowPDA, getProgram,
  getVaultTokenBalance,
} = require('../config/anchor');

let _sp;
function sp() { if (!_sp) _sp = require('@solana/pay'); return _sp; }

function getBaseUrl(reqHost) {
  return reqHost || process.env.APP_URL || 'http://localhost:3000';
}

// ── createPaymentSession ──────────────────────────────────
async function createPaymentSession({ merchantId, amountAudd, message, memo }, reqHost) {
  const { data: merchant } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address, name, is_active, registration_status')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchant)               throw new Error('Merchant not found');
  if (!merchant.is_active)     throw new Error(`Merchant not active yet (${merchant.registration_status}). Try again in a moment.`);
  if (!merchant.vault_address) throw new Error('Vault not ready yet — registration still processing. Try again in a moment.');

  const referenceKp = Keypair.generate();
  const reference   = referenceKp.publicKey;
  const recipient   = new PublicKey(merchant.vault_address);
  const splToken    = new PublicKey(process.env.AUDD_MINT);
  const label       = merchant.name || merchantId;
  const msgText     = message || `Payment to ${label}`;
  const amount      = amountAudd ? new BigNumber(amountAudd) : undefined;

  const { encodeURL } = sp();
  const urlFields = {
    recipient, splToken, reference: [reference], label, message: msgText,
    ...(memo ? { memo } : {}), ...(amount ? { amount } : {}),
  };

  const solanaUrl   = encodeURL(urlFields).toString();
  const baseUrl     = getBaseUrl(reqHost);
  const checkoutUrl = `${baseUrl}/pages/checkout.html?ref=${reference.toBase58()}`;

  const { data: session } = await supabase
    .from('payment_sessions')
    .insert({
      merchant_id:   merchantId,
      amount:        amountAudd || null,
      reference_key: reference.toBase58(),
      label,
      message:       msgText,
      memo:          memo || null,
      status:        'pending',
    })
    .select()
    .single();

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
    checkout_url:  checkoutUrl,
  };
}

// ── pollPaymentSession ────────────────────────────────────
async function pollPaymentSession(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(vault_address, name, wallet_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();

  if (!session) return { status: 'not_found' };
  if (session.status === 'confirmed') return { status: 'confirmed', tx: session.tx_signature };
  if (session.status === 'expired')   return { status: 'expired' };
  if (session.status === 'failed')    return { status: 'failed' };

  // Check expiry
  if (session.expires_at && new Date(session.expires_at) < new Date()) {
    await supabase
      .from('payment_sessions')
      .update({ status: 'expired' })
      .eq('reference_key', referenceKey);
    return { status: 'expired' };
  }

  const vault = session.merchants?.vault_address;
  if (!vault) return { status: 'pending' };

  try {
    const connection   = getConnection();
    const vaultPubkey  = new PublicKey(vault);
    const splToken     = new PublicKey(process.env.AUDD_MINT);
    const sessionStart = new Date(session.created_at).getTime() / 1000;

    // Method 1: findReference (works if wallet includes reference key)
    try {
      const { findReference, validateTransfer } = sp();
      const reference = new PublicKey(referenceKey);
      const sigInfo   = await findReference(connection, reference, { finality: 'confirmed' });
      if (sigInfo) {
        if (session.amount) {
          try {
            await validateTransfer(connection, sigInfo.signature, {
              recipient: vaultPubkey,
              amount:    new BigNumber(session.amount),
              splToken,
            });
          } catch { /* fall through to vault scan */ }
        }
        return await confirmSession(session, sigInfo.signature, referenceKey);
      }
    } catch (e) {
      if (!e.name?.includes('FindReference') && !e.message?.includes('not found')) {
        console.warn('[poll] findReference:', e.message);
      }
    }

    // Method 2: Watch vault's recent signatures directly
    const signatures = await connection.getSignaturesForAddress(vaultPubkey, {
      limit: 10, commitment: 'confirmed',
    });

    for (const sig of signatures) {
      if (sig.blockTime && sig.blockTime < sessionStart - 5) continue;
      if (sig.err) continue;

      // Skip if another session already claimed this tx
      const { data: existing } = await supabase
        .from('payment_sessions')
        .select('id')
        .eq('tx_signature', sig.signature)
        .maybeSingle();
      if (existing && existing.id !== session.id) continue;

      const tx = await connection.getParsedTransaction(sig.signature, {
        commitment: 'confirmed', maxSupportedTransactionVersion: 0,
      });
      if (!tx?.meta) continue;

      const pre  = tx.meta.preTokenBalances  || [];
      const post = tx.meta.postTokenBalances || [];

      const vaultPost = post.find(b => b.mint === splToken.toBase58());
      const vaultPre  = pre.find(b =>
        b.mint === splToken.toBase58() &&
        vaultPost && b.accountIndex === vaultPost.accountIndex
      );

      const postAmt  = parseFloat(vaultPost?.uiTokenAmount?.uiAmountString || '0');
      const preAmt   = parseFloat(vaultPre?.uiTokenAmount?.uiAmountString  || '0');
      const received = postAmt - preAmt;

      if (received <= 0) continue;

      if (session.amount !== null && session.amount !== undefined) {
        if (Math.abs(received - parseFloat(session.amount)) > 0.001) continue;
      }

      console.log(`[poll] Confirmed via vault scan: ${sig.signature}, received: ${received} AUDD`);
      return await confirmSession(session, sig.signature, referenceKey);
    }

    return { status: 'pending' };

  } catch (err) {
    console.error('[poll]', err.message);
    return { status: 'pending' };
  }
}

// ── confirmSession ────────────────────────────────────────
// Called when a payment is detected on-chain.
// Key fix: reads vault token account balance (real AUDD)
// and writes it to DB escrows.pending_balance so dashboard
// shows the correct amount immediately.
async function confirmSession(session, txSignature, referenceKey) {
  const now = new Date().toISOString();

  // Mark session confirmed
  await supabase
    .from('payment_sessions')
    .update({ status: 'confirmed', tx_signature: txSignature, confirmed_at: now })
    .eq('reference_key', referenceKey);

  // Record transaction
  await supabase.from('transactions').insert({
    merchant_id:   session.merchant_id,
    type:          'deposit',
    amount:        session.amount || 0,
    tx_signature:  txSignature,
    reference_key: referenceKey,
    status:        'confirmed',
  }).then(() => {}).catch(e => console.warn('[confirm] tx insert:', e.message));

  // ── BALANCE SYNC ──────────────────────────────────────────
  // Get the merchant's vault address
  const { data: merchant } = await supabase
    .from('merchants')
    .select('vault_address')
    .eq('merchant_id', session.merchant_id)
    .maybeSingle();

  if (merchant?.vault_address) {
    // Read vault token account balance — this is the real AUDD held
    const vaultBalance = await getVaultTokenBalance(merchant.vault_address);
    const pendingAudd  = vaultBalance.uiAmount || 0;

    console.log(`[confirm] Vault balance: ${pendingAudd} AUDD for ${session.merchant_id}`);

    // Count total confirmed payments for this merchant
    const { count } = await supabase
      .from('payment_sessions')
      .select('id', { count: 'exact', head: true })
      .eq('merchant_id', session.merchant_id)
      .eq('status', 'confirmed');

    // Update DB escrow with real vault balance
    await supabase
      .from('escrows')
      .update({
        pending_balance: pendingAudd,
        total_payments:  count || 0,
      })
      .eq('merchant_id', session.merchant_id);

    console.log(`[confirm] Escrow synced: ${pendingAudd} AUDD, ${count} payments`);
  }

  // Fire webhook + email (non-blocking)
  setImmediate(async () => {
    try {
      const { dispatch } = require('./webhook');
      await dispatch(session.merchant_id, 'deposit.confirmed', {
        reference_key: referenceKey,
        amount:        session.amount || 0,
        tx_signature:  txSignature,
        confirmed_at:  now,
      });
    } catch (e) { console.warn('[confirm] webhook:', e.message); }

    try {
      const emailSvc = require('./email');
      const { data: merchantData } = await supabase
        .from('merchants')
        .select('user_id, name')
        .eq('merchant_id', session.merchant_id)
        .maybeSingle();

      if (merchantData?.user_id) {
        const { data: user } = await supabase
          .from('users')
          .select('email')
          .eq('id', merchantData.user_id)
          .maybeSingle();

        if (user?.email) {
          const { data: already } = await supabase
            .from('notification_log')
            .select('id')
            .eq('ref', referenceKey)
            .eq('type', 'deposit.confirmed')
            .maybeSingle();

          if (!already) {
            await emailSvc.sendDepositConfirmed({
              email:        user.email,
              merchantName: merchantData.name || session.merchant_id,
              amount:       session.amount || 0,
              txSignature,
              reference:    referenceKey,
            });
            await supabase.from('notification_log').insert({
              merchant_id: session.merchant_id,
              type:        'deposit.confirmed',
              ref:         referenceKey,
            });
          }
        }
      }
    } catch (e) { console.warn('[confirm] email:', e.message); }
  });

  return { status: 'confirmed', tx: txSignature };
}

// ── getSessionByRef ───────────────────────────────────────
async function getSessionByRef(referenceKey) {
  const { data } = await supabase
    .from('payment_sessions')
    .select('*, merchants(name, vault_address, wallet_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();
  return data;
}

module.exports = { createPaymentSession, pollPaymentSession, getSessionByRef };
