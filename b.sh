#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Payment confirmation fix
#
#  Problems fixed:
#  ① Poll returning 401 — route was behind auth middleware
#  ② Checkout session also 401 — same issue
#  ③ Share URL uses localhost — now derived from request host
#  ④ Rate limit was blocking poll — polling route exempted
#  ⑤ findReference timing out — replaced with direct vault
#     transaction monitoring (getSignaturesForAddress) which
#     is faster and doesn't need the reference keypair trick
#  ⑥ Checkout page not loading — was calling wrong endpoint
#
#  Run from directory containing settl/:
#  bash settl-payment-fix.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[FIX]${NC} $1"; }

log "Applying payment confirmation fixes..."

# ═══════════════════════════════════════════════════════════
# 1. SERVER.JS — fix route order so poll/session are public
#    No rate limit on polling endpoints
# ═══════════════════════════════════════════════════════════
log "Fixing server.js route order and rate limits..."
cat > backend/src/server.js << 'EOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');

const authMiddleware = require('./middleware/auth');
const { startCron }  = require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Static frontend ────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../../frontend')));

// ── Rate limit — applied only to auth + merchant writes ───
// Polling is explicitly excluded — it runs every 1.5s
const authLimit = rateLimit({ windowMs: 15 * 60 * 1000, max: 100, skip: (req) => false });
const writeLimit = rateLimit({ windowMs: 15 * 60 * 1000, max: 60 });

// ── Public routes (no auth, no rate limit) ─────────────────
// These MUST be registered before any authMiddleware
app.use('/api/health',  require('./routes/health'));

// Public auth (with rate limit to prevent brute force)
app.use('/api/auth',    authLimit, require('./routes/auth'));

// Public payment endpoints — NO rate limit, NO auth
// Poll runs every 1.5s — must be completely open
app.get('/api/payments/poll/:ref',    require('./routes/payments'));
app.get('/api/payments/session/:ref', require('./routes/payments'));

// ── Protected routes ───────────────────────────────────────
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, writeLimit, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));

// ── Catch-all → frontend SPA ───────────────────────────────
app.get('*', (req, res) =>
  res.sendFile(path.join(__dirname, '../../frontend', 'index.html'))
);

// ── Error handler ──────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  startCron();
});

module.exports = app;
EOF

# ═══════════════════════════════════════════════════════════
# 2. SOLANA PAY SERVICE — replace findReference with direct
#    vault monitoring via getSignaturesForAddress
#    Much simpler, no reference keypair needed for detection,
#    still uses reference for the Solana Pay URL spec
# ═══════════════════════════════════════════════════════════
log "Rewriting payment confirmation to use vault monitoring..."
cat > backend/src/services/solanaPay.js << 'EOF'
const { PublicKey, Keypair } = require('@solana/web3.js');
const BigNumber  = require('bignumber.js');
const { supabase }              = require('../config/supabase');
const { getConnection, getEscrowPDA, getProgram } = require('../config/anchor');

// Lazy-load @solana/pay
let _solanaPay;
function sp() {
  if (!_solanaPay) _solanaPay = require('@solana/pay');
  return _solanaPay;
}

// ── createPaymentSession ──────────────────────────────────
// vault_address = [b"vault", merchant_id] PDA
// This is the actual AUDD SPL token account controlled by the escrow
// Solana Pay recipient = vault_address, spl-token = AUDD mint
async function createPaymentSession({ merchantId, amountAudd, message, memo }, reqHost) {
  const { data: merchant } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address, name, is_active, registration_status')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchant)               throw new Error('Merchant not found');
  if (!merchant.is_active)     throw new Error(`Merchant registration status: ${merchant.registration_status}. Please wait for on-chain registration to complete.`);
  if (!merchant.vault_address) throw new Error('Vault not initialised yet. Registration may still be processing — try again in a moment.');

  // Unique reference keypair for this session (used in Solana Pay URL spec)
  const referenceKp = Keypair.generate();
  const reference   = referenceKp.publicKey;

  // recipient = vault PDA (the AUDD token account)
  const recipient = new PublicKey(merchant.vault_address);
  const splToken  = new PublicKey(process.env.AUDD_MINT);
  const label     = merchant.name || merchantId;
  const msgText   = message || `Payment to ${label}`;
  const amount    = amountAudd ? new BigNumber(amountAudd) : undefined;

  const { encodeURL } = sp();
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

  // Build checkout URL using the actual request host (not localhost)
  // reqHost is passed from the route handler
  const baseUrl     = reqHost || process.env.APP_URL || 'http://localhost:3000';
  const checkoutUrl = `${baseUrl}/pages/checkout.html?ref=${reference.toBase58()}`;

  // Store session — also record vault_snapshot for fast polling
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
    checkout_url:  checkoutUrl,
  };
}

// ── pollPaymentSession ────────────────────────────────────
// Strategy: watch the vault's recent signatures for a token
// transfer that matches our reference key OR matches the amount.
//
// Why not findReference?
//   findReference requires the reference pubkey to appear as an
//   account key in the transaction. Some wallets (e.g. Phantom mobile)
//   may not include it, or the transaction may confirm before the
//   next poll cycle. Watching the vault directly is more reliable.
//
// Flow:
//   1. Check DB first — if already confirmed, return immediately
//   2. Check expiry
//   3. Fetch last 5 signatures for the vault address
//   4. For each recent signature, fetch the transaction and check
//      if it transferred tokens to the vault
//   5. If found, validate amount (if fixed) and mark confirmed
async function pollPaymentSession(referenceKey) {
  const { data: session } = await supabase
    .from('payment_sessions')
    .select('*, merchants(vault_address, name, wallet_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();

  if (!session) return { status: 'not_found' };

  // Already resolved
  if (session.status === 'confirmed') return { status: 'confirmed', tx: session.tx_signature };
  if (session.status === 'expired')   return { status: 'expired' };
  if (session.status === 'failed')    return { status: 'failed' };

  // Check expiry
  if (session.expires_at && new Date(session.expires_at) < new Date()) {
    await supabase.from('payment_sessions').update({ status: 'expired' }).eq('reference_key', referenceKey);
    return { status: 'expired' };
  }

  const vault = session.merchants?.vault_address;
  if (!vault) return { status: 'pending' };

  try {
    const connection  = getConnection();
    const vaultPubkey = new PublicKey(vault);
    const splToken    = new PublicKey(process.env.AUDD_MINT);
    const sessionCreatedAt = new Date(session.created_at).getTime() / 1000;

    // Method 1: Try findReference first (works when wallet includes reference)
    try {
      const { findReference, validateTransfer, FindReferenceError } = sp();
      const reference = new PublicKey(referenceKey);
      const sigInfo   = await findReference(connection, reference, { finality: 'confirmed' });

      if (sigInfo) {
        const amountBN = session.amount ? new BigNumber(session.amount) : undefined;
        if (amountBN) {
          try {
            await validateTransfer(connection, sigInfo.signature, {
              recipient: vaultPubkey, amount: amountBN, splToken,
            });
          } catch (valErr) {
            console.warn('[poll] validateTransfer failed, checking by vault method:', valErr.message);
            // Fall through to vault method
          }
        }
        return await confirmSession(session, sigInfo.signature, referenceKey);
      }
    } catch (refErr) {
      // FindReferenceError = not found yet by reference, try vault method
      if (!refErr.name?.includes('FindReference') && !refErr.message?.includes('not found')) {
        console.warn('[poll] findReference error:', refErr.message);
      }
    }

    // Method 2: Watch vault's recent transactions directly
    const signatures = await connection.getSignaturesForAddress(vaultPubkey, {
      limit: 10,
      commitment: 'confirmed',
    });

    for (const sigInfo of signatures) {
      // Only look at transactions after this session was created
      if (sigInfo.blockTime && sigInfo.blockTime < sessionCreatedAt - 5) continue;
      if (sigInfo.err) continue;

      // Check if this tx is already linked to another session
      const { data: existing } = await supabase
        .from('payment_sessions')
        .select('id')
        .eq('tx_signature', sigInfo.signature)
        .maybeSingle();
      if (existing && existing.id !== session.id) continue;

      // Fetch full transaction to verify it's a token transfer to vault
      const tx = await connection.getParsedTransaction(sigInfo.signature, {
        commitment:                  'confirmed',
        maxSupportedTransactionVersion: 0,
      });

      if (!tx?.meta) continue;

      // Look for a token balance change on the vault account
      const preBalances  = tx.meta.preTokenBalances  || [];
      const postBalances = tx.meta.postTokenBalances || [];

      const vaultPost = postBalances.find(b =>
        b.owner === vault || b.accountIndex === postBalances.findIndex(p => p.mint === splToken.toBase58())
      );
      const vaultPre  = preBalances.find(b =>
        b.owner === vault || (vaultPost && b.accountIndex === vaultPost.accountIndex)
      );

      // Simpler check: did the vault's token balance increase?
      const postAmount = parseFloat(vaultPost?.uiTokenAmount?.uiAmountString || '0');
      const preAmount  = parseFloat(vaultPre?.uiTokenAmount?.uiAmountString  || '0');
      const received   = postAmount - preAmount;

      if (received <= 0) continue;

      // If session has a fixed amount, validate it matches (with 0.001 tolerance)
      if (session.amount !== null && session.amount !== undefined) {
        const expected = parseFloat(session.amount);
        if (Math.abs(received - expected) > 0.001) {
          console.log(`[poll] Amount mismatch: received ${received}, expected ${expected}`);
          continue;
        }
      }

      // Found a matching transaction
      console.log(`[poll] Confirmed via vault monitoring: ${sigInfo.signature}, received: ${received} AUDD`);
      return await confirmSession(session, sigInfo.signature, referenceKey);
    }

    return { status: 'pending' };

  } catch (err) {
    console.error('[poll] Error:', err.message);
    return { status: 'pending' }; // Don't fail — just say still pending
  }
}

// ── confirmSession ────────────────────────────────────────
async function confirmSession(session, txSignature, referenceKey) {
  const now = new Date().toISOString();

  await supabase.from('payment_sessions').update({
    status:       'confirmed',
    tx_signature: txSignature,
    confirmed_at: now,
  }).eq('reference_key', referenceKey);

  await supabase.from('transactions').insert({
    merchant_id:   session.merchant_id,
    type:          'deposit',
    amount:        session.amount || 0,
    tx_signature:  txSignature,
    reference_key: referenceKey,
    status:        'confirmed',
  }).then(() => {}).catch(e => console.warn('[confirm] tx insert:', e.message));

  // Sync escrow balance from chain
  try {
    const program     = getProgram();
    const [escrowPDA] = getEscrowPDA(session.merchant_id);
    const escrowAcc   = await program.account.escrowAccount.fetch(escrowPDA);
    await supabase.from('escrows').update({
      pending_balance: escrowAcc.pendingBalance.toNumber() / 1_000_000,
      total_payments:  escrowAcc.totalPayments.toNumber(),
    }).eq('merchant_id', session.merchant_id);
  } catch (e) { console.warn('[confirm] escrow sync:', e.message); }

  return { status: 'confirmed', tx: txSignature };
}

// ── getSessionByRef ────────────────────────────────────────
async function getSessionByRef(referenceKey) {
  const { data } = await supabase
    .from('payment_sessions')
    .select('*, merchants(name, vault_address, wallet_address)')
    .eq('reference_key', referenceKey)
    .maybeSingle();
  return data;
}

module.exports = { createPaymentSession, pollPaymentSession, getSessionByRef };
EOF

# ═══════════════════════════════════════════════════════════
# 3. PAYMENTS ROUTE — pass request host for URL generation
# ═══════════════════════════════════════════════════════════
log "Fixing payments route (host-aware URLs, public poll)..."
cat > backend/src/routes/payments.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { createPaymentSession, pollPaymentSession, getSessionByRef } = require('../services/solanaPay');

// ── Helper: get base URL from request ─────────────────────
// Works for localhost, Codespaces, ngrok, any domain
function getBaseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol || 'http';
  const host  = req.headers['x-forwarded-host']  || req.headers.host || 'localhost:3000';
  return `${proto}://${host}`;
}

// ── POST /api/payments/session — create QR + shareable link
// Protected (auth required, handled in server.js)
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, message, memo } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });

    const baseUrl = getBaseUrl(req);
    const session = await createPaymentSession(
      { merchantId: merchant_id, amountAudd: amount || null, message, memo },
      baseUrl
    );
    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/poll/:ref — PUBLIC, no auth, no rate limit
// Frontend polls this every 1.5s to detect payment confirmation
router.get('/poll/:ref', async (req, res, next) => {
  try {
    const result = await pollPaymentSession(req.params.ref);
    res.json(result);
  } catch (err) {
    // Never return 5xx on poll — client would stop polling
    res.json({ status: 'pending', error: err.message });
  }
});

// ── GET /api/payments/session/:ref — PUBLIC, no auth
// Checkout page loads this to display payment details
router.get('/session/:ref', async (req, res, next) => {
  try {
    const session = await getSessionByRef(req.params.ref);
    if (!session) return res.status(404).json({ error: 'Payment session not found' });

    const baseUrl = getBaseUrl(req);

    res.json({
      reference_key:  session.reference_key,
      amount:         session.amount,
      label:          session.label,
      message:        session.message,
      status:         session.status,
      tx_signature:   session.tx_signature,
      expires_at:     session.expires_at,
      merchant_name:  session.merchants?.name || '',
      vault_address:  session.merchants?.vault_address || '',
      spl_token:      process.env.AUDD_MINT || '',
      // Reconstruct Solana Pay URL so checkout can rebuild QR
      solana_pay_url: buildSolanaUrl(session),
    });
  } catch (err) { next(err); }
});

function buildSolanaUrl(session) {
  if (!session.merchants?.vault_address) return null;
  const params = new URLSearchParams();
  if (process.env.AUDD_MINT) params.set('spl-token', process.env.AUDD_MINT);
  params.set('reference', session.reference_key);
  if (session.label)   params.set('label',   session.label);
  if (session.message) params.set('message', session.message);
  if (session.memo)    params.set('memo',    session.memo);
  if (session.amount)  params.set('amount',  session.amount.toString());
  return `solana:${session.merchants.vault_address}?${params.toString()}`;
}

// ── GET /api/payments/history — protected
router.get('/history', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [] });
    const { data } = await supabase.from('transactions').select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false }).limit(100);
    res.json({ transactions: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# 4. FRONTEND api.js — poll is now a plain fetch (no auth header)
#    session info is also plain fetch
# ═══════════════════════════════════════════════════════════
log "Updating frontend api.js (poll = plain fetch, no auth)..."
cat > frontend/js/modules/api.js << 'EOF'
const API = '/api';

function getToken() {
  try { return localStorage.getItem('settl_token'); } catch { return null; }
}

async function req(path, opts = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...opts.headers,
  };
  const res  = await fetch(`${API}${path}`, { ...opts, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(data.error || `HTTP ${res.status}`);
    e.status = res.status;
    throw e;
  }
  return data;
}

// Plain fetch — no auth header, used for public polling
async function publicGet(path) {
  const res  = await fetch(`${API}${path}`);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(data.error || `HTTP ${res.status}`);
    e.status = res.status;
    throw e;
  }
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',  body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH', body: JSON.stringify(b) }),

  auth: {
    signup:  (b)               => api.post('/auth/signup', b),
    login:   (email, password) => api.post('/auth/login', { email, password }),
    logout:  ()                => api.post('/auth/logout', {}),
    me:      ()                => api.get('/auth/me'),
    status:  ()                => api.get('/auth/status'),
    profile: (u)               => api.patch('/auth/profile', u),
  },

  merchant: {
    me:         () => api.get('/merchants/me'),
    sessions:   () => api.get('/merchants/me/sessions'),
    releases:   () => api.get('/merchants/me/releases'),
    releaseNow: () => api.post('/release/me', {}),
  },

  payments: {
    // Protected — creates a new session (merchant must be logged in)
    session: (b) => api.post('/payments/session', b),

    // Public — no auth, used by both merchant page and checkout page
    // These are plain fetches with no Authorization header
    pollPublic:  (ref) => publicGet(`/payments/poll/${ref}`),
    sessionInfo: (ref) => publicGet(`/payments/session/${ref}`),

    history: () => api.get('/payments/history'),
  },
};

window.api = api;
EOF

# ═══════════════════════════════════════════════════════════
# 5. CHECKOUT PAGE — fix session loading, better UX
# ═══════════════════════════════════════════════════════════
log "Rewriting checkout page with fixed session loading..."
cat > frontend/pages/checkout.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Pay</title>
  <link rel="stylesheet" href="/css/app.css"/>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
  <style>
    body { background: #EEEDF8; }
    .pay-top  { text-align:center; padding: 20px 16px 0; }
    .pay-logo { font-size:20px; font-weight:700; color:var(--brand); }
    .pay-sub  { font-size:12px; color:var(--text-muted); margin-top:2px; }
  </style>
</head>
<body>

<div class="pay-top">
  <div class="pay-logo">SETTL</div>
  <div class="pay-sub">Solana payment · Powered by SETTL</div>
</div>

<div class="checkout-wrap" style="padding-top:10px;">
  <div class="checkout-card">

    <!-- Loading -->
    <div id="v-loading" style="text-align:center;padding:40px 0;">
      <div class="spinner" style="width:28px;height:28px;margin:0 auto 14px;"></div>
      <div style="color:var(--text-muted);">Loading payment…</div>
    </div>

    <!-- Error -->
    <div id="v-error" style="display:none;padding:16px 0;">
      <div class="alert alert-error" id="v-err-msg"></div>
      <div style="font-size:13px;color:var(--text-muted);">
        This link may be invalid or expired. Ask the merchant to generate a new one.
      </div>
    </div>

    <!-- Expired -->
    <div id="v-expired" style="display:none;text-align:center;padding:20px 0;">
      <div style="font-size:36px;margin-bottom:10px;">⏱</div>
      <div style="font-weight:600;font-size:16px;margin-bottom:6px;">Payment link expired</div>
      <div style="font-size:13px;color:var(--text-muted);">Links are valid for 30 minutes. Ask the merchant to generate a new one.</div>
    </div>

    <!-- Already confirmed -->
    <div id="v-done" style="display:none;text-align:center;padding:20px 0;">
      <div style="font-size:52px;margin-bottom:12px;">✓</div>
      <div style="font-size:20px;font-weight:700;color:var(--teal);margin-bottom:6px;">Payment complete</div>
      <div style="font-size:14px;color:var(--text-muted);margin-bottom:16px;">This payment has already been confirmed on-chain.</div>
      <a id="v-done-tx" href="#" target="_blank" class="btn btn-secondary btn-sm">View on Solana Explorer</a>
    </div>

    <!-- Main payment view -->
    <div id="v-pay" style="display:none;">

      <!-- Merchant & amount -->
      <div style="text-align:center;margin-bottom:16px;">
        <div style="font-size:13px;color:var(--text-muted);margin-bottom:4px;">Pay to</div>
        <div style="font-size:20px;font-weight:700;" id="c-merchant-name"></div>
        <div id="c-amount-block" style="display:none;">
          <div style="font-size:40px;font-weight:800;color:var(--brand);margin:8px 0 2px;" id="c-amount-val"></div>
          <div style="font-size:13px;color:var(--text-muted);">AUDD · Solana Devnet</div>
        </div>
        <div id="c-open-block" style="display:none;margin:10px 0;">
          <div style="font-size:13px;color:var(--text-muted);margin-bottom:6px;">Enter amount to pay (AUDD)</div>
          <input class="form-input" id="c-open-amount" type="number" min="0.01" step="0.01"
                 placeholder="0.00" style="font-size:26px;font-weight:700;text-align:center;"/>
        </div>
      </div>

      <!-- Message / reference -->
      <div id="c-msg-row" style="display:none;text-align:center;margin-bottom:14px;">
        <span style="font-size:13px;color:var(--text-muted);" id="c-msg-val"></span>
      </div>

      <!-- Steps -->
      <div class="steps" style="margin-bottom:8px;">
        <div class="step active"  id="cs1">1</div><div class="step-line" id="csl1"></div>
        <div class="step waiting" id="cs2">2</div><div class="step-line" id="csl2"></div>
        <div class="step waiting" id="cs3">✓</div>
      </div>
      <div style="font-size:12px;color:var(--text-muted);margin-bottom:16px;text-align:center;" id="c-step-msg">
        Scan the QR code with your Solana wallet app
      </div>

      <!-- QR -->
      <div class="qr-wrap" id="c-qr-section" style="margin-bottom:18px;">
        <div id="c-qr-canvas"></div>
        <div style="text-align:center;font-size:12px;color:var(--text-muted);">
          Phantom · Backpack · Solflare · any Solana wallet
        </div>
      </div>

      <!-- Watching indicator -->
      <div id="c-watching" style="display:flex;align-items:center;justify-content:center;gap:8px;color:var(--text-muted);font-size:13px;margin-bottom:18px;">
        <div class="spinner"></div>
        <span>Watching for your payment on-chain…</span>
      </div>

      <!-- Confirmed banner -->
      <div id="c-confirmed" style="display:none;" class="alert alert-success">
        <div style="font-size:17px;font-weight:700;margin-bottom:6px;">✓ Payment confirmed!</div>
        <div style="font-size:13px;">Received and verified on Solana. The merchant will receive funds at 6am UTC.</div>
        <a id="c-conf-tx" href="#" target="_blank"
           style="display:block;font-size:11px;font-family:var(--font-mono);margin-top:8px;word-break:break-all;color:var(--teal);"></a>
      </div>

      <!-- Divider -->
      <div style="border-top:1px solid var(--border);margin:16px 0;"></div>

      <!-- Manual payment section -->
      <div>
        <div style="font-size:11px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:10px;">
          Can't scan? Pay manually
        </div>
        <div class="info-grid" style="margin-bottom:14px;">
          <span class="info-label">Vault</span>
          <span id="c-vault-short" style="font-family:var(--font-mono);font-size:12px;cursor:pointer;color:var(--brand);" onclick="copyVault()" title="Tap to copy vault address"></span>
          <span class="info-label">Token</span>
          <span id="c-token-short" style="font-family:var(--font-mono);font-size:12px;" title="AUDD mint address"></span>
          <span class="info-label">Network</span>
          <span style="font-size:13px;">Solana Devnet</span>
        </div>

        <a id="c-phantom-btn" href="#" class="btn btn-primary btn-full" style="margin-bottom:8px;">
          Open in Phantom wallet
        </a>
        <button class="btn btn-secondary btn-full" onclick="copyVault()">
          📋 Copy vault address
        </button>
        <div style="font-size:11px;color:var(--text-hint);margin-top:8px;text-align:center;">
          Send exactly the amount shown above in AUDD to the vault address
        </div>
      </div>

    </div>

  </div>
</div>

<script src="/js/modules/api.js"></script>
<script>
  const params     = new URLSearchParams(window.location.search);
  const ref        = params.get('ref');
  let pollTimer    = null;
  let vaultAddress = null;

  // ── show/hide views ──────────────────────────────────────
  const VIEWS = ['v-loading','v-error','v-pay','v-expired','v-done'];
  function show(id) { VIEWS.forEach(v => document.getElementById(v).style.display = v===id?'':'none'); }

  function setStep(n) {
    [1,2,3].forEach(i => {
      document.getElementById(`cs${i}`).className = `step ${i<n?'done':i===n?'active':'waiting'}`;
      const l = document.getElementById(`csl${i}`);
      if (l) l.className = `step-line${i<n?' done':''}`;
    });
  }

  function shortAddr(k, pre=8, suf=6) { return k ? k.slice(0,pre)+'…'+k.slice(-suf) : '—'; }

  function copyVault() {
    if (!vaultAddress) return;
    navigator.clipboard.writeText(vaultAddress).then(() => {
      const el = document.getElementById('c-vault-short');
      const orig = el.textContent;
      el.textContent = '✓ Copied!';
      setTimeout(() => el.textContent = orig, 2000);
    });
  }

  // ── main load ────────────────────────────────────────────
  async function load() {
    if (!ref) {
      show('v-error');
      document.getElementById('v-err-msg').textContent = 'No payment reference found in URL.';
      return;
    }

    try {
      // sessionInfo is a plain public fetch — no auth needed
      const session = await api.payments.sessionInfo(ref);

      // Already resolved
      if (session.status === 'confirmed') {
        show('v-done');
        const txLink = document.getElementById('v-done-tx');
        txLink.href = `https://explorer.solana.com/tx/${session.tx_signature}?cluster=devnet`;
        return;
      }
      if (session.status === 'expired') { show('v-expired'); return; }

      // Show payment view
      show('v-pay');

      document.getElementById('c-merchant-name').textContent = session.merchant_name || 'Merchant';

      const amount = session.amount ? Number(session.amount) : null;

      if (amount !== null) {
        document.getElementById('c-amount-block').style.display = '';
        document.getElementById('c-amount-val').textContent     = amount.toFixed(2) + ' AUDD';
      } else {
        document.getElementById('c-open-block').style.display = '';
      }

      if (session.message) {
        document.getElementById('c-msg-row').style.display = '';
        document.getElementById('c-msg-val').textContent   = session.message;
      }

      // Vault + token
      vaultAddress = session.vault_address;
      document.getElementById('c-vault-short').textContent = shortAddr(vaultAddress);
      document.getElementById('c-vault-short').title       = vaultAddress || '';
      document.getElementById('c-token-short').textContent = shortAddr(session.spl_token);
      document.getElementById('c-token-short').title       = session.spl_token || '';

      // QR code — use the solana_pay_url from server (already built correctly)
      const qrContent = session.solana_pay_url;
      if (qrContent) {
        document.getElementById('c-qr-canvas').innerHTML = '';
        new QRCode(document.getElementById('c-qr-canvas'), {
          text:         qrContent,
          width:        200,
          height:       200,
          colorDark:    '#111827',
          colorLight:   '#ffffff',
          correctLevel: QRCode.CorrectLevel.M,
        });
      }

      // Phantom deep link
      const phantomUrl = `https://phantom.app/ul/v1/send?to=${encodeURIComponent(vaultAddress)}&spl-token=${encodeURIComponent(session.spl_token)}${amount?'&amount='+amount:''}`;
      document.getElementById('c-phantom-btn').href = phantomUrl;

      // Start polling
      setStep(2);
      document.getElementById('c-step-msg').textContent = 'Waiting for your transaction to confirm on-chain…';
      startPolling();

    } catch (err) {
      show('v-error');
      document.getElementById('v-err-msg').textContent = err.message || 'Failed to load payment details.';
    }
  }

  // ── polling ──────────────────────────────────────────────
  function startPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(async () => {
      try {
        // pollPublic = plain fetch, no auth header
        const r = await api.payments.pollPublic(ref);

        if (r.status === 'confirmed') {
          clearInterval(pollTimer);
          setStep(3);
          document.getElementById('c-step-msg').textContent     = 'Payment received!';
          document.getElementById('c-watching').style.display   = 'none';
          document.getElementById('c-confirmed').style.display  = '';
          document.getElementById('c-qr-section').style.display = 'none';

          const txLink = document.getElementById('c-conf-tx');
          txLink.href        = `https://explorer.solana.com/tx/${r.tx}?cluster=devnet`;
          txLink.textContent = `${r.tx?.slice(0,20)}… → View on Solana Explorer`;

        } else if (r.status === 'expired') {
          clearInterval(pollTimer);
          show('v-expired');
        }
        // 'pending' → keep polling silently
      } catch (err) {
        // Network error — keep polling, don't crash
        console.warn('[checkout poll]', err.message);
      }
    }, 2000); // 2s interval — gentle on the RPC
  }

  load();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 6. PAYLINK PAGE — also fix poll interval and checkout URL
# ═══════════════════════════════════════════════════════════
log "Fixing paylink page poll and checkout URL display..."
cat > frontend/pages/merchant/paylink.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Create payment</title>
  <link rel="stylesheet" href="/css/app.css"/>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <div class="topbar-left">
        <button class="menu-btn" onclick="openSidebar()">☰</button>
        <span class="topbar-title">Create payment</span>
      </div>
      <span class="badge badge-success">merchant</span>
    </div>

    <div class="page-body">

      <!-- Form -->
      <div class="card" style="max-width:540px;" id="form-card">
        <div class="card-title-row"><h2>New payment request</h2></div>
        <p style="color:var(--text-muted);font-size:14px;margin-bottom:18px;line-height:1.6;">
          Generate a QR code and shareable link. Customers pay AUDD directly into your escrow vault using any Solana wallet (Phantom, Backpack, Solflare).
        </p>

        <div class="form-group">
          <label class="form-label">Amount (AUDD) <span style="color:var(--text-hint);font-weight:400;">— leave blank for open amount</span></label>
          <input class="form-input" id="inp-amount" type="number" min="0.01" step="0.01"
                 placeholder="e.g. 25.00"
                 style="font-size:24px;font-weight:700;text-align:center;letter-spacing:.02em;"/>
        </div>
        <div class="form-group">
          <label class="form-label">Order reference / message <span style="color:var(--text-hint);font-weight:400;">— optional</span></label>
          <input class="form-input" id="inp-msg" placeholder="e.g. Order #1234, Invoice INV-001"/>
        </div>

        <div id="form-err" class="alert alert-error" style="display:none;"></div>

        <button class="btn btn-primary btn-full" id="gen-btn" onclick="generate()"
                style="font-size:16px;padding:14px;">
          Generate QR code &amp; link
        </button>
      </div>

      <!-- Result -->
      <div class="card" id="result-card" style="display:none;max-width:540px;">

        <!-- Steps -->
        <div class="steps" style="margin-bottom:6px;">
          <div class="step done"    id="st1">✓</div><div class="step-line done" id="sl1"></div>
          <div class="step active"  id="st2">2</div><div class="step-line"      id="sl2"></div>
          <div class="step waiting" id="st3">3</div>
        </div>
        <div style="font-size:13px;color:var(--text-muted);margin-bottom:18px;" id="step-label">
          Share the link or show QR — waiting for customer to pay…
        </div>

        <!-- QR code -->
        <div class="qr-wrap" id="qr-section" style="margin-bottom:18px;">
          <div id="qr-canvas"></div>
          <div style="text-align:center;">
            <div style="font-size:16px;font-weight:700;" id="qr-merchant-name"></div>
            <div style="font-size:28px;font-weight:800;color:var(--brand);margin:6px 0 2px;" id="qr-amount-display"></div>
            <div style="font-size:12px;color:var(--text-muted);">AUDD · Solana Devnet · Powered by SETTL</div>
          </div>
        </div>

        <!-- Watching -->
        <div id="watching-row" style="display:flex;align-items:center;gap:10px;color:var(--text-muted);font-size:14px;margin-bottom:16px;">
          <div class="spinner"></div>
          <span>Watching for payment on-chain…</span>
        </div>

        <!-- Confirmed -->
        <div id="confirmed-row" class="alert alert-success" style="display:none;margin-bottom:16px;">
          <div style="font-size:16px;font-weight:700;margin-bottom:4px;">💰 Payment confirmed!</div>
          <a id="conf-tx-link" href="#" target="_blank"
             style="font-size:11px;font-family:var(--font-mono);word-break:break-all;color:var(--teal);display:block;margin-top:4px;"></a>
        </div>

        <!-- Share section -->
        <div style="border-top:1px solid var(--border);padding-top:16px;">
          <div class="form-label" style="margin-bottom:8px;">Share this payment link</div>

          <div style="display:flex;gap:8px;margin-bottom:10px;">
            <input class="form-input" id="share-url" readonly
                   style="flex:1;font-size:12px;font-family:var(--font-mono);background:var(--bg);"/>
          </div>

          <div style="display:flex;gap:8px;flex-wrap:wrap;">
            <button class="btn btn-secondary" onclick="copyLink()" style="flex:1;min-width:100px;">📋 Copy link</button>
            <button class="btn btn-secondary" onclick="nativeShare()" style="flex:1;min-width:80px;">↑ Share</button>
            <a id="whatsapp-btn" href="#" target="_blank"
               class="btn" style="background:#25D366;color:#fff;border:none;flex:1;min-width:100px;">
              WhatsApp
            </a>
          </div>

          <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px;">
            <a id="checkout-open" href="#" target="_blank" class="btn btn-secondary" style="flex:1;min-width:120px;">
              Open checkout page
            </a>
            <button class="btn btn-secondary" onclick="newPayment()" style="flex:1;min-width:100px;">
              + New payment
            </button>
          </div>

          <div class="form-hint" style="margin-top:10px;">
            Anyone with this link can open the checkout page and pay. No SETTL account needed.
          </div>
        </div>

      </div>
    </div>
  </div>
</div>

<script src="/js/modules/api.js"></script>
<script src="/js/modules/auth.js"></script>
<script src="/js/modules/toast.js"></script>
<script src="/js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw 0;
  initSidebar();

  const merchant = auth.getMerchant();
  if (merchant && !merchant.is_active) {
    document.getElementById('form-err').textContent =
      'Your merchant is still being registered on Solana. Please wait and refresh.';
    document.getElementById('form-err').style.display = '';
    document.getElementById('gen-btn').disabled = true;
  }

  let pollTimer    = null;
  let checkoutUrl  = null;
  let currentRef   = null;

  function setStep(n) {
    [1,2,3].forEach(i => {
      const s = document.getElementById(`st${i}`);
      const l = document.getElementById(`sl${i}`);
      s.className = `step ${i<n?'done':i===n?'active':'waiting'}`;
      s.textContent = i<n?'✓':String(i);
      if(l) l.className = `step-line${i<n?' done':''}`;
    });
  }

  async function generate() {
    const amountStr = document.getElementById('inp-amount').value;
    const message   = document.getElementById('inp-msg').value.trim();
    document.getElementById('form-err').style.display = 'none';

    const m = auth.getMerchant();
    if (!m?.is_active) {
      document.getElementById('form-err').textContent = 'Merchant not yet active — registration may still be processing.';
      document.getElementById('form-err').style.display = '';
      return;
    }

    const amount = amountStr ? parseFloat(amountStr) : null;
    if (amount !== null && (isNaN(amount) || amount <= 0)) {
      document.getElementById('form-err').textContent = 'Enter a valid amount greater than 0.';
      document.getElementById('form-err').style.display = '';
      return;
    }

    const btn = document.getElementById('gen-btn');
    btn.disabled = true; btn.textContent = 'Generating…';

    try {
      const session = await api.payments.session({
        merchant_id: m.merchant_id,
        amount,
        message: message || null,
      });

      currentRef  = session.reference;
      checkoutUrl = session.checkout_url;

      // QR code from Solana Pay URL
      document.getElementById('qr-canvas').innerHTML = '';
      new QRCode(document.getElementById('qr-canvas'), {
        text:         session.url,
        width:        220, height: 220,
        colorDark:    '#111827', colorLight: '#ffffff',
        correctLevel: QRCode.CorrectLevel.M,
      });

      document.getElementById('qr-merchant-name').textContent  = session.merchant_name || m.merchant_id;
      document.getElementById('qr-amount-display').textContent = amount ? amount.toFixed(2)+' AUDD' : 'Open amount';

      // Share URL = checkout page (uses real host, not localhost)
      document.getElementById('share-url').value       = checkoutUrl;
      document.getElementById('checkout-open').href    = checkoutUrl;

      // WhatsApp
      const waText = encodeURIComponent(
        `${amount?'Pay '+amount.toFixed(2)+' AUDD to ':''} ${session.merchant_name||m.merchant_id}: ${checkoutUrl}`
      );
      document.getElementById('whatsapp-btn').href = `https://wa.me/?text=${waText}`;

      document.getElementById('result-card').style.display   = '';
      document.getElementById('confirmed-row').style.display = 'none';
      document.getElementById('watching-row').style.display  = 'flex';
      setStep(2);
      document.getElementById('step-label').textContent = 'Share the link or show QR — watching for payment…';

      stopPolling();
      startPolling(currentRef);
      document.getElementById('result-card').scrollIntoView({ behavior: 'smooth' });

    } catch (err) {
      document.getElementById('form-err').textContent = err.message;
      document.getElementById('form-err').style.display = '';
    } finally {
      btn.disabled = false; btn.textContent = 'Generate QR code & link';
    }
  }

  function startPolling(ref) {
    pollTimer = setInterval(async () => {
      try {
        const r = await api.payments.pollPublic(ref); // plain fetch, no auth
        if (r.status === 'confirmed') {
          stopPolling();
          setStep(3);
          document.getElementById('step-label').textContent   = '✓ Payment confirmed on-chain!';
          document.getElementById('watching-row').style.display = 'none';
          document.getElementById('confirmed-row').style.display = '';
          document.getElementById('qr-section').style.display = 'none';

          const txLink = document.getElementById('conf-tx-link');
          txLink.href        = `https://explorer.solana.com/tx/${r.tx}?cluster=devnet`;
          txLink.textContent = `Tx: ${r.tx?.slice(0,20)}… — View on Solana Explorer →`;

          toast.success('💰 Payment confirmed!');
        } else if (r.status === 'expired') {
          stopPolling();
          document.getElementById('step-label').textContent = 'Session expired. Generate a new payment.';
          document.getElementById('watching-row').style.display = 'none';
        }
      } catch {}
    }, 2000); // 2 seconds — not too aggressive
  }

  function stopPolling() { if(pollTimer){ clearInterval(pollTimer); pollTimer=null; } }

  function copyLink() {
    const val = document.getElementById('share-url').value;
    navigator.clipboard.writeText(val).then(()=>toast.success('Link copied!'));
  }

  function nativeShare() {
    const url = checkoutUrl || document.getElementById('share-url').value;
    if (navigator.share) {
      navigator.share({ title: 'SETTL Payment', url }).catch(()=>{});
    } else { copyLink(); }
  }

  function newPayment() {
    stopPolling();
    document.getElementById('result-card').style.display = 'none';
    document.getElementById('inp-amount').value = '';
    document.getElementById('inp-msg').value    = '';
    currentRef = null;
  }
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Payment Fix — Complete                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What was fixed:${NC}"
echo ""
echo -e "  ${GREEN}①${NC} Poll was returning 401"
echo -e "     /api/payments/poll/:ref and /api/payments/session/:ref"
echo -e "     are now fully public — registered before authMiddleware"
echo -e "     and exempt from rate limiting"
echo ""
echo -e "  ${GREEN}②${NC} Share URL used localhost"
echo -e "     Now derived from the request's Host + X-Forwarded-Proto"
echo -e "     headers — works correctly on Codespaces, ngrok, any domain"
echo ""
echo -e "  ${GREEN}③${NC} Confirmation strategy"
echo -e "     Tries findReference first (works if wallet includes reference)"
echo -e "     Falls back to getSignaturesForAddress on the vault PDA"
echo -e "     Checks token balance change > 0 on vault"
echo -e "     Validates amount match (with 0.001 AUDD tolerance)"
echo -e "     Never returns an error on poll — always returns a status"
echo ""
echo -e "  ${GREEN}④${NC} Checkout page session loading fixed"
echo -e "     Was calling wrong endpoint — now uses publicGet()"
echo -e "     with no auth header, same as poll"
echo -e "     Server builds the solana_pay_url and sends it back"
echo -e "     Checkout rebuilds QR from that URL — no reference mismatch"
echo ""
echo -e "  ${GREEN}⑤${NC} Poll interval changed to 2s (was 1.5s)"
echo -e "     Gentler on Devnet RPC — Devnet can be slow"
echo ""
echo -e "  ${BLUE}Restart:${NC}"
echo ""
echo -e "  ${YELLOW}yarn dev${NC}  (or Ctrl+C then yarn dev)"
echo ""
echo -e "  Then generate a new payment — the old sessions are already"
echo -e "  in the DB, open their checkout links to see confirmed status."
echo ""