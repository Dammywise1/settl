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
// Creates a one-time payment session.
// Called by the dashboard paylink page and the API key endpoint.
async function createPaymentSession({
  merchantId, amountAudd, message, memo,
  expiryMinutes,   // null = default 30min
  successUrl,      // override merchant default
  paymentLinkId,   // if created from a reusable link
}, reqHost) {

  const { data: merchant } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address, name, brand_name, brand_logo_url, success_url, is_active, registration_status')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchant)               throw new Error('Merchant not found');
  if (!merchant.is_active)     throw new Error(`Merchant not active (${merchant.registration_status}). Try again in a moment.`);
  if (!merchant.vault_address) throw new Error('Vault not ready — registration still processing. Try again shortly.');

  const referenceKp = Keypair.generate();
  const reference   = referenceKp.publicKey;
  const recipient   = new PublicKey(merchant.vault_address);
  const splToken    = new PublicKey(process.env.AUDD_MINT);
  const label       = merchant.brand_name || merchant.name || merchantId;
  const msgText     = message || `Payment to ${label}`;
  const amount      = amountAudd ? new BigNumber(amountAudd) : undefined;

  const { encodeURL } = sp();
  const urlFields = {
    recipient, splToken, reference: [reference], label, message: msgText,
    ...(memo   ? { memo }   : {}),
    ...(amount ? { amount } : {}),
  };

  const solanaUrl   = encodeURL(urlFields).toString();
  const baseUrl     = getBaseUrl(reqHost);
  const checkoutUrl = `${baseUrl}/pages/checkout.html?ref=${reference.toBase58()}`;

  // Expiry: default 30min, or merchant-specified, or null (never)
  let expiresAt = null;
  const mins = expiryMinutes !== undefined ? expiryMinutes : 30;
  if (mins && mins > 0) {
    expiresAt = new Date(Date.now() + mins * 60_000).toISOString();
  }

  // Success URL: session override → merchant default → null
  const resolvedSuccessUrl = successUrl || merchant.success_url || null;

  const { data: session } = await supabase
    .from('payment_sessions')
    .insert({
      merchant_id:     merchantId,
      amount:          amountAudd || null,
      reference_key:   reference.toBase58(),
      label,
      message:         msgText,
      memo:            memo || null,
      status:          'pending',
      expires_at:      expiresAt,
      success_url:     resolvedSuccessUrl,
      payment_link_id: paymentLinkId || null,
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
    merchant_name: label,
    brand_logo:    merchant.brand_logo_url || null,
    success_url:   resolvedSuccessUrl,
    checkout_url:  checkoutUrl,
    expires_at:    expiresAt,
  };
}

// ── createSessionFromLink ─────────────────────────────────
// Called when a customer opens a reusable payment link.
// Creates a fresh session each time.
async function createSessionFromLink(slug, reqHost) {
  const { data: link } = await supabase
    .from('payment_links')
    .select('*, merchants(merchant_id, vault_address, name, brand_name, brand_logo_url, success_url, is_active)')
    .eq('slug', slug)
    .eq('is_active', true)
    .maybeSingle();

  if (!link)                      throw new Error('Payment link not found or inactive');
  if (!link.merchants.is_active)  throw new Error('Merchant is not active');

  const session = await createPaymentSession({
    merchantId:     link.merchant_id,
    amountAudd:     link.amount || null,
    message:        link.title,
    expiryMinutes:  link.is_reusable ? null : (link.expiry_minutes || 30),
    successUrl:     link.success_url,
    paymentLinkId:  link.id,
  }, reqHost);

  // Update link usage counter
  await supabase
    .from('payment_links')
    .update({ total_uses: (link.total_uses || 0) + 1 })
    .eq('id', link.id);

  return {
    ...session,
    link: {
      slug:        link.slug,
      title:       link.title,
      description: link.description,
      is_reusable: link.is_reusable,
    },
  };
}

// ── pollPaymentSession ────────────────────────────────────
async function pollPaymentSession(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(vault_address, name, brand_name, brand_logo_url, wallet_address, success_url)')
    .eq('reference_key', referenceKey)
    .maybeSingle();

  if (!session) return { status: 'not_found' };
  if (session.status === 'confirmed') return {
    status:      'confirmed',
    tx:          session.tx_signature,
    success_url: session.success_url,
    is_overpaid: session.is_overpaid,
    is_underpaid: session.is_underpaid,
    amount_received: session.amount_received,
  };
  if (session.status === 'expired') return { status: 'expired' };
  if (session.status === 'failed')  return { status: 'failed' };

  // Check expiry
  if (session.expires_at && new Date(session.expires_at) < new Date()) {
    await supabase.from('payment_sessions').update({ status: 'expired' }).eq('reference_key', referenceKey);
    return { status: 'expired' };
  }

  const vault = session.merchants?.vault_address;
  if (!vault) return { status: 'pending' };

  try {
    const connection   = getConnection();
    const vaultPubkey  = new PublicKey(vault);
    const splToken     = new PublicKey(process.env.AUDD_MINT);
    const sessionStart = new Date(session.created_at).getTime() / 1000;

    // Method 1: findReference
    try {
      const { findReference, validateTransfer } = sp();
      const reference = new PublicKey(referenceKey);
      const sigInfo   = await findReference(connection, reference, { finality: 'confirmed' });
      if (sigInfo) {
        const received = await getReceivedAmount(connection, sigInfo.signature, splToken);
        return await confirmSession(session, sigInfo.signature, referenceKey, received);
      }
    } catch (e) {
      if (!e.name?.includes('FindReference') && !e.message?.includes('not found')) {
        console.warn('[poll] findReference:', e.message);
      }
    }

    // Method 2: vault signature scan
    const signatures = await connection.getSignaturesForAddress(vaultPubkey, {
      limit: 10, commitment: 'confirmed',
    });

    for (const sig of signatures) {
      if (sig.blockTime && sig.blockTime < sessionStart - 5) continue;
      if (sig.err) continue;

      const { data: existing } = await supabase
        .from('payment_sessions')
        .select('id').eq('tx_signature', sig.signature).maybeSingle();
      if (existing && existing.id !== session.id) continue;

      const tx = await connection.getParsedTransaction(sig.signature, {
        commitment: 'confirmed', maxSupportedTransactionVersion: 0,
      });
      if (!tx?.meta) continue;

      const received = getReceivedFromMeta(tx.meta, splToken.toBase58());
      if (received <= 0) continue;

      console.log(`[poll] Confirmed via vault scan: ${sig.signature}, received: ${received} AUDD`);
      return await confirmSession(session, sig.signature, referenceKey, received);
    }

    return { status: 'pending' };
  } catch (err) {
    console.error('[poll]', err.message);
    return { status: 'pending' };
  }
}

// ── getReceivedAmount ─────────────────────────────────────
// Parse how much was actually received from a tx signature
async function getReceivedAmount(connection, signature, splToken) {
  try {
    const tx = await connection.getParsedTransaction(signature, {
      commitment: 'confirmed', maxSupportedTransactionVersion: 0,
    });
    if (!tx?.meta) return 0;
    return getReceivedFromMeta(tx.meta, splToken.toBase58());
  } catch { return 0; }
}

function getReceivedFromMeta(meta, splTokenMint) {
  const pre  = meta.preTokenBalances  || [];
  const post = meta.postTokenBalances || [];
  const vaultPost = post.find(b => b.mint === splTokenMint);
  const vaultPre  = pre.find(b =>
    b.mint === splTokenMint && vaultPost && b.accountIndex === vaultPost.accountIndex
  );
  const postAmt = parseFloat(vaultPost?.uiTokenAmount?.uiAmountString || '0');
  const preAmt  = parseFloat(vaultPre?.uiTokenAmount?.uiAmountString  || '0');
  return Math.max(0, postAmt - preAmt);
}

// ── confirmSession ────────────────────────────────────────
// Handles exact, partial, and over payments
async function confirmSession(session, txSignature, referenceKey, amountReceived) {
  const now = new Date().toISOString();

  const expectedAmount = session.amount ? parseFloat(session.amount) : null;
  const TOLERANCE = 0.001; // 0.001 AUDD tolerance for rounding

  let isOverpaid  = false;
  let isUnderpaid = false;
  let overpayAmt  = 0;
  let underpayAmt = 0;

  if (expectedAmount !== null && amountReceived > 0) {
    const diff = amountReceived - expectedAmount;
    if (diff > TOLERANCE) {
      isOverpaid = true;
      overpayAmt = diff;
      console.log(`[confirm] Overpayment: received ${amountReceived}, expected ${expectedAmount}, over by ${overpayAmt}`);
    } else if (diff < -TOLERANCE) {
      isUnderpaid = true;
      underpayAmt = Math.abs(diff);
      console.log(`[confirm] Underpayment: received ${amountReceived}, expected ${expectedAmount}, short by ${underpayAmt}`);
      // For underpayment: still confirm but flag it
      // Merchant sees the shortfall in dashboard
    }
  }

  // Mark session confirmed regardless (merchant decides how to handle underpayment)
  await supabase.from('payment_sessions').update({
    status:          'confirmed',
    tx_signature:    txSignature,
    confirmed_at:    now,
    amount_received: amountReceived || null,
    is_overpaid:     isOverpaid,
    is_underpaid:    isUnderpaid,
    overpay_amount:  isOverpaid  ? overpayAmt  : null,
    underpay_amount: isUnderpaid ? underpayAmt : null,
  }).eq('reference_key', referenceKey);

  // Record transaction
  await supabase.from('transactions').insert({
    merchant_id:     session.merchant_id,
    type:            'deposit',
    amount:          session.amount || amountReceived || 0,
    tx_signature:    txSignature,
    reference_key:   referenceKey,
    status:          'confirmed',
    customer_note:   session.customer_note || null,
    amount_received: amountReceived || null,
    is_overpaid:     isOverpaid,
    is_underpaid:    isUnderpaid,
  }).then(() => {}).catch(e => console.warn('[confirm] tx insert:', e.message));

  // Sync vault balance to DB
  const { data: merchant } = await supabase
    .from('merchants').select('vault_address').eq('merchant_id', session.merchant_id).maybeSingle();

  if (merchant?.vault_address) {
    const vaultBalance = await getVaultTokenBalance(merchant.vault_address);
    const { count } = await supabase
      .from('payment_sessions')
      .select('id', { count: 'exact', head: true })
      .eq('merchant_id', session.merchant_id)
      .eq('status', 'confirmed');

    await supabase.from('escrows').update({
      pending_balance: vaultBalance.uiAmount || 0,
      total_payments:  count || 0,
    }).eq('merchant_id', session.merchant_id);

    // Update payment link volume if applicable
    if (session.payment_link_id) {
      await supabase.rpc('increment_link_volume', {
        link_id: session.payment_link_id,
        amount:  amountReceived || 0,
      }).catch(() => {
        // RPC may not exist yet — do a manual update
        supabase.from('payment_links')
          .update({ total_volume: (amountReceived || 0) })
          .eq('id', session.payment_link_id)
          .then(() => {}).catch(() => {});
      });
    }
  }

  // Fire webhook + email (non-blocking)
  setImmediate(async () => {
    try {
      const { dispatch } = require('./webhook');
      await dispatch(session.merchant_id, 'deposit.confirmed', {
        reference_key:   referenceKey,
        amount:          session.amount || 0,
        amount_received: amountReceived || 0,
        tx_signature:    txSignature,
        confirmed_at:    now,
        is_overpaid:     isOverpaid,
        is_underpaid:    isUnderpaid,
        overpay_amount:  overpayAmt  || null,
        underpay_amount: underpayAmt || null,
        customer_note:   session.customer_note || null,
      });
    } catch (e) { console.warn('[confirm] webhook:', e.message); }

    try {
      const emailSvc = require('./email');
      const { data: m } = await supabase
        .from('merchants').select('user_id, name').eq('merchant_id', session.merchant_id).maybeSingle();
      if (m?.user_id) {
        const { data: u } = await supabase.from('users').select('email').eq('id', m.user_id).maybeSingle();
        if (u?.email) {
          const { data: already } = await supabase.from('notification_log')
            .select('id').eq('ref', referenceKey).eq('type', 'deposit.confirmed').maybeSingle();
          if (!already) {
            await emailSvc.sendDepositConfirmed({
              email: u.email, merchantName: m.name,
              amount: amountReceived || session.amount || 0,
              txSignature, reference: referenceKey,
            });
            await supabase.from('notification_log').insert({
              merchant_id: session.merchant_id, type: 'deposit.confirmed', ref: referenceKey,
            });
          }
        }
      }
    } catch (e) { console.warn('[confirm] email:', e.message); }
  });

  return {
    status:          'confirmed',
    tx:              txSignature,
    success_url:     session.success_url,
    is_overpaid:     isOverpaid,
    is_underpaid:    isUnderpaid,
    amount_received: amountReceived,
    overpay_amount:  overpayAmt  || null,
    underpay_amount: underpayAmt || null,
  };
}

// ── getSessionByRef ───────────────────────────────────────
async function getSessionByRef(referenceKey) {
  const { data } = await supabase
    .from('payment_sessions')
    .select('*, merchants(name, brand_name, brand_logo_url, vault_address, wallet_address, success_url)')
    .eq('reference_key', referenceKey)
    .maybeSingle();
  return data;
}

module.exports = {
  createPaymentSession,
  createSessionFromLink,
  pollPaymentSession,
  getSessionByRef,
};
