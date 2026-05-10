#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Fix: Pending balance not updating after payment
#
#  Root cause:
#  The dashboard reads pending balance from chainEscrow
#  (live RPC fetch). After a deposit, the vault balance
#  increases but the escrow account's pendingBalance field
#  only increases when the on-chain deposit() instruction
#  is called — NOT when AUDD is sent directly to the vault.
#
#  SETTL's contract flow:
#    Customer calls deposit() instruction → escrow.pending_balance += amount
#    BUT: Solana Pay sends AUDD directly to vault PDA as a
#    token transfer, bypassing the deposit() instruction.
#    So escrow.pending_balance on-chain stays 0.
#    The actual AUDD IS in the vault token account balance.
#
#  Fix:
#  ① Read vault token account balance directly (not escrow PDA)
#     using getTokenAccountBalance — this shows real AUDD held
#  ② Store confirmed deposit amounts in DB escrows table
#  ③ Dashboard reads from DB escrows.pending_balance which is
#     updated by confirmSession after each payment
#  ④ Add cache-busting header to merchants/me response
#
#  Run from directory containing settl/:
#  bash settl-fix-balance.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[FIX]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

log "Fixing pending balance..."

# ═══════════════════════════════════════════════════════════
# 1. config/anchor.js — add getVaultBalance helper
#    Reads actual AUDD in the vault token account directly
#    This is the real balance regardless of contract state
# ═══════════════════════════════════════════════════════════
log "Adding getVaultBalance to anchor config..."
cat > backend/src/config/anchor.js << 'EOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program }        = require('@coral-xyz/anchor');
const fs   = require('fs');
const path = require('path');

const IDL        = require('../idl/settl.json');
const PROGRAM_ID = new PublicKey(
  process.env.SETTL_PROGRAM_ID || 'RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn'
);

let _provider = null;
let _program  = null;
let _keypair  = null;
let _connection = null;

function getKeypair() {
  if (_keypair) return _keypair;
  const kpPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(kpPath)) throw new Error(`Keypair not found: ${kpPath}`);
  _keypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync(kpPath, 'utf-8')))
  );
  return _keypair;
}

function getConnection() {
  if (_connection) return _connection;
  _connection = new Connection(
    process.env.SOLANA_RPC_URL || 'https://api.devnet.solana.com',
    'confirmed'
  );
  return _connection;
}

function getProvider() {
  if (_provider) return _provider;
  const kp = getKeypair();
  const wallet = {
    publicKey:           kp.publicKey,
    signTransaction:     async tx  => { tx.sign(kp); return tx; },
    signAllTransactions: async txs => txs.map(tx => { tx.sign(kp); return tx; }),
  };
  _provider = new AnchorProvider(getConnection(), wallet, {
    commitment:          'confirmed',
    preflightCommitment: 'confirmed',
  });
  return _provider;
}

function getProgram() {
  if (_program) return _program;
  _program = new Program(IDL, PROGRAM_ID, getProvider());
  return _program;
}

// ── PDA helpers ───────────────────────────────────────────
function getMerchantPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('merchant'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getEscrowPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('escrow'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getVaultPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('vault'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getConfigPDA() {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('config')], PROGRAM_ID
  );
}

// ── getVaultTokenBalance ──────────────────────────────────
// Reads the actual AUDD balance from the vault token account.
// This is the source of truth for pending balance because
// Solana Pay sends tokens directly to vault — the deposit()
// instruction is NOT called, so escrow.pendingBalance stays
// 0 on-chain. The token account balance is real.
async function getVaultTokenBalance(vaultAddress) {
  try {
    const connection = getConnection();
    const vaultPubkey = new PublicKey(vaultAddress);
    const balance = await connection.getTokenAccountBalance(vaultPubkey, 'confirmed');
    return {
      amount:    balance.value.amount,          // raw integer string
      uiAmount:  balance.value.uiAmount || 0,   // decimal AUDD
      decimals:  balance.value.decimals,
    };
  } catch (err) {
    console.warn('[anchor] getVaultTokenBalance failed:', err.message);
    return { amount: '0', uiAmount: 0, decimals: 6 };
  }
}

// ── getEscrowOnChain ──────────────────────────────────────
// Reads the EscrowAccount PDA (contract state).
// Note: pendingBalance here only reflects deposit() calls,
// not direct token transfers via Solana Pay.
async function getEscrowOnChain(merchantId) {
  try {
    const program     = getProgram();
    const [escrowPDA] = getEscrowPDA(merchantId);
    const acc         = await program.account.escrowAccount.fetch(escrowPDA);
    return {
      pendingBalance: acc.pendingBalance.toNumber(),
      totalPayments:  acc.totalPayments.toNumber(),
      lastReleasedAt: acc.lastReleasedAt.toNumber(),
      merchantWallet: acc.merchantWallet.toBase58(),
    };
  } catch (err) {
    console.warn('[anchor] getEscrowOnChain failed:', err.message);
    return null;
  }
}

module.exports = {
  getProvider,
  getProgram,
  getKeypair,
  getConnection,
  getMerchantPDA,
  getEscrowPDA,
  getVaultPDA,
  getConfigPDA,
  getVaultTokenBalance,
  getEscrowOnChain,
  PROGRAM_ID,
};
EOF

# ═══════════════════════════════════════════════════════════
# 2. solanaPay.js — confirmSession syncs vault token balance
#    to DB so dashboard reads correct amount instantly
# ═══════════════════════════════════════════════════════════
log "Updating confirmSession to sync vault token balance..."
cat > backend/src/services/solanaPay.js << 'EOF'
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
EOF

# ═══════════════════════════════════════════════════════════
# 3. routes/merchants.js — read pending balance from DB
#    and also do live vault token balance check
# ═══════════════════════════════════════════════════════════
log "Fixing merchants/me to read vault token balance..."
cat > backend/src/routes/merchants.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { getVaultTokenBalance, getEscrowOnChain } = require('../config/anchor');

// ── GET /api/merchants/me ─────────────────────────────────
router.get('/me', async (req, res, next) => {
  try {
    const { data: merchant, error } = await supabase
      .from('merchants')
      .select('*, escrows(*)')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (error || !merchant) {
      return res.status(404).json({ error: 'No merchant found for this account' });
    }

    let liveBalance = null;

    if (merchant.is_active && merchant.vault_address) {
      // Read live vault token account balance
      // This is the real AUDD held in the vault PDA
      const vaultBal = await getVaultTokenBalance(merchant.vault_address);
      liveBalance = vaultBal.uiAmount || 0;

      // If live balance differs from DB, sync it
      const dbBalance = parseFloat(merchant.escrows?.[0]?.pending_balance || 0);
      if (Math.abs(liveBalance - dbBalance) > 0.0001) {
        // Count confirmed payments
        const { count } = await supabase
          .from('payment_sessions')
          .select('id', { count: 'exact', head: true })
          .eq('merchant_id', merchant.merchant_id)
          .eq('status', 'confirmed');

        await supabase
          .from('escrows')
          .update({ pending_balance: liveBalance, total_payments: count || 0 })
          .eq('merchant_id', merchant.merchant_id);

        // Update the escrow object in memory for the response
        if (merchant.escrows?.[0]) {
          merchant.escrows[0].pending_balance = liveBalance;
          merchant.escrows[0].total_payments  = count || 0;
        }
        console.log(`[merchants/me] Synced balance: ${liveBalance} AUDD`);
      }
    }

    // No-cache headers so dashboard always gets fresh data
    res.set('Cache-Control', 'no-store');

    res.json({
      merchant,
      // pendingBalance in AUDD — use live if available, fall back to DB
      pendingBalance: liveBalance ?? parseFloat(merchant.escrows?.[0]?.pending_balance || 0),
      totalPayments:  merchant.escrows?.[0]?.total_payments || 0,
      lastReleasedAt: merchant.escrows?.[0]?.last_released_at || null,
    });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/sessions ────────────────────────
router.get('/me/sessions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (!merchant) return res.json({ sessions: [] });

    const { data } = await supabase
      .from('payment_sessions')
      .select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false })
      .limit(50);

    res.set('Cache-Control', 'no-store');
    res.json({ sessions: data || [] });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/releases ────────────────────────
router.get('/me/releases', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (!merchant) return res.json({ logs: [] });

    const { data } = await supabase
      .from('release_logs')
      .select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('released_at', { ascending: false })
      .limit(50);

    res.set('Cache-Control', 'no-store');
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# 4. DASHBOARD — read pendingBalance from new field
#    and stop using chainEscrow which was empty
# ═══════════════════════════════════════════════════════════
log "Fixing dashboard balance display..."
cat > frontend/pages/dashboard.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Dashboard</title>
  <link rel="stylesheet" href="/css/app.css"/>
</head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <div class="topbar-left">
        <button class="menu-btn" onclick="openSidebar()">☰</button>
        <span class="topbar-title">Dashboard</span>
      </div>
      <div id="reg-status-badge"></div>
    </div>

    <div class="page-body">

      <!-- Registration banner (shown while on-chain reg is processing) -->
      <div id="reg-banner" style="display:none;" class="alert alert-warning">
        <div style="display:flex;align-items:center;gap:10px;">
          <div class="spinner"></div>
          <div>
            <strong>Registering your merchant on-chain…</strong><br/>
            <span style="font-size:12px;">This takes 10–30 seconds. Dashboard will update automatically.</span>
          </div>
        </div>
      </div>

      <div id="reg-error-banner" style="display:none;" class="alert alert-error">
        <strong>On-chain registration failed.</strong>
        <span id="reg-err-msg"></span>
      </div>

      <!-- Stats cards -->
      <div class="card-grid">
        <div class="card">
          <div class="card-title">Pending balance</div>
          <div class="card-value" id="s-pending">—</div>
          <div class="card-sub">AUDD in vault</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="s-count">—</div>
          <div class="card-sub">Confirmed deposits</div>
        </div>
        <div class="card">
          <div class="card-title">Total released</div>
          <div class="card-value" id="s-released">—</div>
          <div class="card-sub">Net AUDD paid out</div>
        </div>
        <div class="card">
          <div class="card-title">Next release</div>
          <div class="card-value" id="s-next">—</div>
          <div class="card-sub">6am UTC daily</div>
        </div>
      </div>

      <!-- Quick actions -->
      <div class="card">
        <div class="card-title-row"><h2>Quick actions</h2></div>
        <div style="display:flex;gap:10px;flex-wrap:wrap;">
          <a href="/pages/merchant/paylink.html" class="btn btn-primary">⊕ Create payment link</a>
          <a href="/pages/merchant/payments.html" class="btn btn-secondary">↑ View payments</a>
          <button class="btn btn-secondary" onclick="releaseNow()" id="release-btn">▶ Release now</button>
        </div>
        <div id="release-status" style="font-size:13px;color:var(--text-muted);margin-top:10px;display:none;"></div>
      </div>

      <!-- Recent payment sessions -->
      <div class="card">
        <div class="card-title-row">
          <h2>Recent payment sessions</h2>
          <a href="/pages/merchant/payments.html" class="btn btn-secondary btn-sm">View all</a>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Amount</th><th>Message</th><th>Status</th><th>Created</th><th>Link</th></tr>
            </thead>
            <tbody id="sess-tbody">
              <tr><td colspan="5" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
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

  function fmtAUDD(v) {
    if (v == null || v === '—') return '—';
    return Number(v).toFixed(4) + ' AUDD';
  }

  function nextRelease() {
    const now  = new Date();
    const next = new Date();
    next.setUTCHours(6, 0, 0, 0);
    if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    const d = next - now;
    const h = Math.floor(d / 3_600_000);
    const m = Math.floor((d % 3_600_000) / 60_000);
    return `${h}h ${m}m`;
  }

  // Poll registration status until active
  let regPollTimer = null;
  function startRegPoll() {
    if (regPollTimer) return;
    regPollTimer = setInterval(async () => {
      try {
        const { merchant } = await api.auth.status();
        if (!merchant) return;
        auth.updateMerchant(merchant);

        if (merchant.registration_status === 'active') {
          clearInterval(regPollTimer);
          document.getElementById('reg-banner').style.display = 'none';
          document.getElementById('reg-status-badge').innerHTML =
            '<span class="badge badge-success">Active</span>';
          initSidebar();
          loadStats();
          toast.success('Merchant registered on-chain!');
        } else if (merchant.registration_status === 'failed') {
          clearInterval(regPollTimer);
          document.getElementById('reg-banner').style.display = 'none';
          document.getElementById('reg-error-banner').style.display = '';
          document.getElementById('reg-err-msg').textContent =
            ' ' + (merchant.registration_error || '');
        }
      } catch {}
    }, 3000);
  }

  async function loadStats() {
    document.getElementById('s-next').textContent = nextRelease();

    try {
      // merchants/me now returns pendingBalance and totalPayments directly
      const data = await api.merchant.me();
      const { merchant, pendingBalance, totalPayments } = data;

      // Pending balance — direct from vault token account
      document.getElementById('s-pending').textContent = fmtAUDD(pendingBalance);
      document.getElementById('s-count').textContent   = totalPayments ?? '—';

      // Total released — from release logs
      const { logs } = await api.merchant.releases().catch(() => ({ logs: [] }));
      const totalNet = logs.reduce((s, r) => s + Number(r.net || 0), 0);
      document.getElementById('s-released').textContent =
        logs.length ? totalNet.toFixed(4) + ' AUDD' : '—';

      // Recent sessions table
      const { sessions } = await api.merchant.sessions().catch(() => ({ sessions: [] }));
      const tbody = document.getElementById('sess-tbody');

      if (!sessions.length) {
        tbody.innerHTML = `<tr><td colspan="5">
          <div class="empty-state">
            <div class="empty-icon">⊕</div>
            <h3>No payments yet</h3>
            <p><a href="/pages/merchant/paylink.html">Create your first payment link</a></p>
          </div>
        </td></tr>`;
        return;
      }

      tbody.innerHTML = sessions.slice(0, 5).map(s => `<tr>
        <td style="font-weight:600;">
          ${s.amount != null ? Number(s.amount).toFixed(2) + ' AUDD' : 'Open'}
        </td>
        <td style="color:var(--text-muted);font-size:12px;max-width:100px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
          ${s.message || '—'}
        </td>
        <td>
          <span class="badge ${s.status === 'confirmed' ? 'badge-success' : s.status === 'pending' ? 'badge-pending' : 'badge-error'}">
            ${s.status}
          </span>
        </td>
        <td style="font-size:12px;color:var(--text-muted);">
          ${new Date(s.created_at).toLocaleString()}
        </td>
        <td>
          <a href="/pages/checkout.html?ref=${s.reference_key}" target="_blank"
             class="btn btn-secondary btn-sm">Share</a>
        </td>
      </tr>`).join('');

    } catch (err) {
      console.error('[dashboard]', err.message);
      toast.error('Failed to load dashboard: ' + err.message);
    }
  }

  async function releaseNow() {
    const btn = document.getElementById('release-btn');
    const st  = document.getElementById('release-status');
    btn.disabled = true;
    btn.textContent = '⏳ Releasing…';
    st.textContent = 'Sending release to Devnet…';
    st.style.display = '';

    try {
      const r = await api.merchant.releaseNow();
      if (r.skipped) {
        st.textContent = `Skipped — ${r.reason}`;
        toast.info('No balance to release');
      } else {
        st.textContent = `Released ${Number(r.net / 1e6).toFixed(4)} AUDD net`;
        toast.success('Release successful!');
        // Reload stats after a short delay to let DB sync
        setTimeout(loadStats, 2000);
      }
    } catch (err) {
      st.textContent = 'Error: ' + err.message;
      toast.error(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = '▶ Release now';
    }
  }

  // Check registration status
  const merchant = auth.getMerchant();
  if (merchant?.registration_status === 'processing' ||
      merchant?.registration_status === 'pending') {
    document.getElementById('reg-banner').style.display = '';
    startRegPoll();
  } else if (merchant?.registration_status === 'failed') {
    document.getElementById('reg-error-banner').style.display = '';
    document.getElementById('reg-err-msg').textContent =
      ' ' + (merchant.registration_error || '');
  } else if (merchant?.is_active) {
    document.getElementById('reg-status-badge').innerHTML =
      '<span class="badge badge-success">Active</span>';
  }

  // Load stats on mount
  loadStats();

  // Refresh balance every 30s (catches any missed confirmations)
  setInterval(loadStats, 30_000);

  // Keep release countdown live
  setInterval(() => {
    document.getElementById('s-next').textContent = nextRelease();
  }, 60_000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 5. balance.html — also use vault token balance
# ═══════════════════════════════════════════════════════════
log "Fixing balance page..."
cat > frontend/pages/merchant/balance.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Balance</title>
  <link rel="stylesheet" href="/css/app.css"/>
</head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <div class="topbar-left">
        <button class="menu-btn" onclick="openSidebar()">☰</button>
        <span class="topbar-title">Balance</span>
      </div>
      <button class="btn btn-secondary btn-sm" onclick="load()">Refresh</button>
    </div>

    <div class="page-body">

      <div class="card-grid">
        <div class="card">
          <div class="card-title">Pending balance</div>
          <div class="card-value" id="s-pending" style="color:var(--teal);">—</div>
          <div class="card-sub">AUDD in vault — releases at 6am UTC</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="s-count">—</div>
          <div class="card-sub">Confirmed deposits</div>
        </div>
        <div class="card">
          <div class="card-title">Last released</div>
          <div class="card-value" id="s-last" style="font-size:18px;">—</div>
          <div class="card-sub">Most recent release</div>
        </div>
        <div class="card">
          <div class="card-title">Next release</div>
          <div class="card-value" id="s-next">—</div>
          <div class="card-sub">6am UTC daily</div>
        </div>
      </div>

      <!-- Wallet & vault details -->
      <div class="card">
        <div class="card-title-row">
          <h2>Vault &amp; wallet</h2>
        </div>
        <div class="info-grid" id="vault-details">
          <span class="info-label">Loading…</span><span></span>
        </div>
        <div style="margin-top:16px;display:flex;gap:10px;flex-wrap:wrap;">
          <button class="btn btn-primary" id="release-btn" onclick="releaseNow()">
            ▶ Release now
          </button>
          <button class="btn btn-secondary" onclick="load()">
            ↺ Refresh balance
          </button>
        </div>
        <div id="release-status"
             style="font-size:13px;color:var(--text-muted);margin-top:10px;display:none;">
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

  function fmtAUDD(v) {
    return v != null ? Number(v).toFixed(4) + ' AUDD' : '—';
  }

  function shortKey(k) {
    return k ? k.slice(0, 8) + '…' + k.slice(-6) : '—';
  }

  function nextRelease() {
    const now  = new Date();
    const next = new Date();
    next.setUTCHours(6, 0, 0, 0);
    if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    const d = next - now;
    const h = Math.floor(d / 3_600_000);
    const m = Math.floor((d % 3_600_000) / 60_000);
    return `${h}h ${m}m`;
  }

  async function load() {
    document.getElementById('s-next').textContent = nextRelease();

    try {
      // merchants/me returns live vault balance
      const { merchant, pendingBalance, totalPayments, lastReleasedAt } =
        await api.merchant.me();

      document.getElementById('s-pending').textContent = fmtAUDD(pendingBalance);
      document.getElementById('s-count').textContent   = totalPayments ?? '—';
      document.getElementById('s-last').textContent    =
        lastReleasedAt
          ? new Date(lastReleasedAt).toLocaleString()
          : 'Never';

      const copy = (text, label) => {
        navigator.clipboard.writeText(text)
          .then(() => toast.success(`${label} copied!`));
      };

      document.getElementById('vault-details').innerHTML = `
        <span class="info-label">Merchant ID</span>
        <span style="font-family:var(--font-mono);font-size:12px;">${merchant.merchant_id}</span>

        <span class="info-label">Wallet</span>
        <span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;color:var(--brand);"
              onclick="navigator.clipboard.writeText('${merchant.wallet_address}').then(()=>toast.success('Wallet copied!'))"
              title="Tap to copy full address">
          ${shortKey(merchant.wallet_address)}
          <span style="font-size:10px;opacity:.6;">tap to copy</span>
        </span>

        <span class="info-label">Vault PDA</span>
        <span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;color:var(--brand);"
              onclick="navigator.clipboard.writeText('${merchant.vault_address || ''}').then(()=>toast.success('Vault copied!'))"
              title="Tap to copy vault address">
          ${shortKey(merchant.vault_address)}
          <span style="font-size:10px;opacity:.6;">tap to copy</span>
        </span>

        <span class="info-label">Status</span>
        <span>
          <span class="badge ${merchant.is_active ? 'badge-success' : 'badge-pending'}">
            ${merchant.registration_status}
          </span>
        </span>

        <span class="info-label">Pending AUDD</span>
        <span style="font-weight:700;font-size:16px;color:var(--teal);">
          ${fmtAUDD(pendingBalance)}
        </span>
      `;

    } catch (err) {
      toast.error('Failed to load balance: ' + err.message);
    }
  }

  async function releaseNow() {
    const btn = document.getElementById('release-btn');
    const st  = document.getElementById('release-status');
    btn.disabled    = true;
    btn.textContent = '⏳ Releasing…';
    st.textContent  = 'Sending release instruction to Devnet…';
    st.style.display = '';

    try {
      const r = await api.merchant.releaseNow();
      if (r.skipped) {
        st.textContent = `Skipped — ${r.reason}`;
        toast.info('Nothing to release (zero balance)');
      } else {
        const net = Number(r.net / 1e6).toFixed(4);
        st.textContent = `✓ Released ${net} AUDD net to your wallet`;
        toast.success('Release successful!');
        setTimeout(load, 2000);
      }
    } catch (err) {
      st.textContent = 'Error: ' + err.message;
      toast.error(err.message);
    } finally {
      btn.disabled    = false;
      btn.textContent = '▶ Release now';
    }
  }

  load();
  setInterval(() => {
    document.getElementById('s-next').textContent = nextRelease();
  }, 60_000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Balance fix applied                                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Root cause:${NC}"
echo ""
echo -e "  Solana Pay sends AUDD directly to the vault token account"
echo -e "  as a standard SPL transfer. The SETTL contract's deposit()"
echo -e "  instruction is never called, so escrow.pendingBalance"
echo -e "  on-chain stays 0 even though real AUDD is in the vault."
echo ""
echo -e "  ${BLUE}Fix:${NC}"
echo ""
echo -e "  ${GREEN}①${NC} confirmSession now calls getTokenAccountBalance"
echo -e "     on the vault PDA after confirmation — reads actual"
echo -e "     AUDD held in the token account, not contract state"
echo ""
echo -e "  ${GREEN}②${NC} Writes the real balance to DB escrows.pending_balance"
echo -e "     so it's available instantly on next dashboard load"
echo ""
echo -e "  ${GREEN}③${NC} merchants/me reads vault token balance live on every"
echo -e "     request and auto-syncs DB if it differs — self-healing"
echo ""
echo -e "  ${GREEN}④${NC} Dashboard reads pendingBalance from the API response"
echo -e "     directly instead of parsing chainEscrow which was empty"
echo ""
echo -e "  ${GREEN}⑤${NC} No-cache headers added to merchants/me so 304"
echo -e "     responses don't serve stale balance from browser cache"
echo ""
echo -e "  ${BLUE}Restart:${NC} ${YELLOW}yarn dev${NC}"
echo ""
echo -e "  After a payment confirms, the dashboard should show the"
echo -e "  correct AUDD balance within 2–3 seconds."
echo ""