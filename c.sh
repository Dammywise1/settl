#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Phase 4: Webhooks + API Keys + Realtime + Email
#
#  What this adds:
#  ① Webhooks — POST to merchant URL after every deposit
#    confirmation and every 6am release. Retry logic (3
#    attempts, exponential backoff). HMAC-SHA256 signature
#    on every request so the merchant can verify it's real.
#
#  ② API keys — merchants generate named keys to call
#    /api/pay/charge from their own backend without a JWT.
#    Key is shown once, stored as bcrypt hash.
#
#  ③ Supabase Realtime — dashboard balance card updates
#    live when escrow table changes (no polling needed).
#    Session status on paylink page also updates live.
#
#  ④ CSV export — download full payment + release history
#    as a spreadsheet from the payments page.
#
#  ⑤ Email notifications — on payment confirmed + on
#    release completed. Uses nodemailer with any SMTP.
#    Optional — only fires if SMTP_HOST is set in .env.
#
#  ⑥ Session expiry cleanup — cron runs every hour and
#    marks expired payment_sessions as 'expired'.
#
#  ⑦ Public charge endpoint — POST /api/pay/charge with
#    an API key creates a payment session programmatically.
#    Merchants use this from their own backend.
#
#  Run from directory containing settl/:
#  bash settl-phase4.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()   { echo -e "${GREEN}[P4]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
log "Phase 4 starting..."

mkdir -p backend/src/{routes,services,middleware,cron}
mkdir -p frontend/pages/merchant
mkdir -p supabase/migrations

# ═══════════════════════════════════════════════════════════
# DEPENDENCIES — add to backend/package.json
# ═══════════════════════════════════════════════════════════
log "Updating backend/package.json..."
cat > backend/package.json << 'EOF'
{
  "name": "settl-backend",
  "version": "1.0.0",
  "main": "src/server.js",
  "scripts": {
    "dev":   "nodemon -r dotenv/config src/server.js dotenv_config_path=../.env",
    "start": "node  -r dotenv/config src/server.js dotenv_config_path=../.env"
  },
  "dependencies": {
    "@coral-xyz/anchor":      "^0.29.0",
    "@solana/pay":            "^0.2.5",
    "@solana/spl-token":      "^0.4.8",
    "@solana/web3.js":        "^1.91.0",
    "@supabase/supabase-js":  "^2.43.0",
    "bcryptjs":               "^2.4.3",
    "bignumber.js":           "^9.1.2",
    "cors":                   "^2.8.5",
    "dotenv":                 "^16.4.5",
    "express":                "^4.19.2",
    "express-rate-limit":     "^7.3.1",
    "helmet":                 "^7.1.0",
    "jsonwebtoken":           "^9.0.2",
    "morgan":                 "^1.10.0",
    "node-cron":              "^3.0.3",
    "nodemailer":             "^6.9.13",
    "uuid":                   "^9.0.1"
  },
  "devDependencies": {
    "nodemon": "^3.1.3"
  }
}
EOF

# ═══════════════════════════════════════════════════════════
# .env.example — add Phase 4 vars
# ═══════════════════════════════════════════════════════════
log "Adding Phase 4 env vars to .env.example..."
cat >> .env.example << 'EOF'

# ── Phase 4 additions ─────────────────────────────────────

# Webhook signing secret (generate: openssl rand -hex 32)
# Every webhook POST is signed with HMAC-SHA256 using this key
WEBHOOK_SECRET=change-this-to-a-long-random-secret

# Email notifications (optional — leave blank to disable)
# Works with any SMTP: Gmail, Resend, Mailgun, SendGrid, etc.
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your@gmail.com
SMTP_PASS=your-app-password
EMAIL_FROM=SETTL Payments <your@gmail.com>

# Supabase Realtime (anon key used client-side for subscriptions)
# This is the public anon key — safe to use in frontend
SUPABASE_ANON_KEY=your-supabase-anon-key
EOF

# ═══════════════════════════════════════════════════════════
# SUPABASE — Phase 4 schema additions
# ═══════════════════════════════════════════════════════════
log "Writing Phase 4 Supabase migration..."
cat > supabase/migrations/002_phase4_webhooks_apikeys.sql << 'SQLEOF'
-- ═══════════════════════════════════════════════════════════
--  SETTL Phase 4 — Webhooks, API keys, notification log
--  Run in Supabase SQL editor after 001_full_schema.sql
-- ═══════════════════════════════════════════════════════════

-- ── webhook_configs ───────────────────────────────────────
-- Merchants configure URLs to receive event POSTs
create table if not exists webhook_configs (
  id          uuid primary key default uuid_generate_v4(),
  merchant_id text not null references merchants(merchant_id) on delete cascade,
  url         text not null,
  description text,
  events      text[] not null default array['deposit.confirmed', 'release.completed'],
  secret      text not null,          -- HMAC signing secret (stored plaintext, shown once)
  is_active   boolean default true,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- ── webhook_deliveries ────────────────────────────────────
-- Every webhook attempt is logged (success and failure)
create table if not exists webhook_deliveries (
  id            uuid primary key default uuid_generate_v4(),
  webhook_id    uuid references webhook_configs(id) on delete cascade,
  merchant_id   text references merchants(merchant_id),
  event         text not null,
  payload       jsonb not null,
  response_code integer,
  response_body text,
  attempt       integer default 1,
  status        text default 'pending'
                check (status in ('pending','success','failed','retrying')),
  error         text,
  delivered_at  timestamptz,
  created_at    timestamptz default now()
);

-- ── api_keys ──────────────────────────────────────────────
-- Merchants generate named keys for programmatic access
create table if not exists api_keys (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text not null references merchants(merchant_id) on delete cascade,
  name         text not null,
  key_hash     text not null unique,  -- bcrypt hash — original shown once
  key_prefix   text not null,         -- first 8 chars for display (sk_live_XXXXXXXX...)
  is_active    boolean default true,
  last_used_at timestamptz,
  created_at   timestamptz default now()
);

-- ── notification_log ──────────────────────────────────────
-- Track email sends so we don't double-notify
create table if not exists notification_log (
  id          uuid primary key default uuid_generate_v4(),
  merchant_id text references merchants(merchant_id),
  type        text not null,  -- 'deposit.confirmed' | 'release.completed'
  ref         text,           -- reference_key or release tx
  sent_at     timestamptz default now()
);

-- ── Indexes ───────────────────────────────────────────────
create index if not exists idx_webhook_configs_merchant  on webhook_configs(merchant_id);
create index if not exists idx_webhook_deliveries_merchant on webhook_deliveries(merchant_id);
create index if not exists idx_webhook_deliveries_status on webhook_deliveries(status);
create index if not exists idx_api_keys_merchant         on api_keys(merchant_id);
create index if not exists idx_api_keys_hash             on api_keys(key_hash);
create index if not exists idx_notif_log_merchant        on notification_log(merchant_id);

-- ── updated_at trigger for webhook_configs ────────────────
create trigger webhook_configs_ts before update on webhook_configs
  for each row execute procedure update_updated_at();

-- ── Enable Realtime on key tables ─────────────────────────
-- Run these two lines separately in Supabase SQL editor
-- if the above migration doesn't enable them automatically:
--   alter publication supabase_realtime add table escrows;
--   alter publication supabase_realtime add table payment_sessions;
SQLEOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/webhook.js
# Dispatch webhook events with HMAC signing + retry logic
# ═══════════════════════════════════════════════════════════
log "Writing webhook service..."
cat > backend/src/services/webhook.js << 'EOF'
const crypto   = require('crypto');
const { supabase } = require('../config/supabase');

// ── sign ──────────────────────────────────────────────────
// HMAC-SHA256 signature so merchants can verify the request
function sign(payload, secret) {
  return crypto
    .createHmac('sha256', secret)
    .update(typeof payload === 'string' ? payload : JSON.stringify(payload))
    .digest('hex');
}

// ── dispatch ──────────────────────────────────────────────
// Fire all active webhooks for a merchant + event type.
// Non-blocking — called with .catch() so it never blocks the caller.
async function dispatch(merchantId, event, data) {
  try {
    const { data: webhooks, error } = await supabase
      .from('webhook_configs')
      .select('id, url, secret')
      .eq('merchant_id', merchantId)
      .eq('is_active', true)
      .contains('events', [event]);

    if (error || !webhooks?.length) return;

    for (const wh of webhooks) {
      await deliverWebhook(wh, merchantId, event, data, 1);
    }
  } catch (err) {
    console.error('[webhook] dispatch error:', err.message);
  }
}

// ── deliverWebhook ────────────────────────────────────────
// Single delivery attempt. Retries up to 3 times with
// exponential backoff (1s, 3s, 9s).
async function deliverWebhook(webhook, merchantId, event, data, attempt) {
  const payload = {
    event,
    merchant_id: merchantId,
    timestamp:   new Date().toISOString(),
    data,
  };

  const body      = JSON.stringify(payload);
  const signature = sign(body, webhook.secret);

  // Log the attempt
  const { data: delivery } = await supabase
    .from('webhook_deliveries')
    .insert({
      webhook_id:  webhook.id,
      merchant_id: merchantId,
      event,
      payload,
      attempt,
      status: 'pending',
    })
    .select()
    .single();

  const deliveryId = delivery?.id;

  try {
    const controller = new AbortController();
    const timeout    = setTimeout(() => controller.abort(), 10_000); // 10s timeout

    const res = await fetch(webhook.url, {
      method:  'POST',
      headers: {
        'Content-Type':       'application/json',
        'X-SETTL-Signature':  `sha256=${signature}`,
        'X-SETTL-Event':      event,
        'X-SETTL-Delivery':   deliveryId || '',
        'User-Agent':         'SETTL-Webhooks/1.0',
      },
      body,
      signal: controller.signal,
    });

    clearTimeout(timeout);

    const responseBody = await res.text().catch(() => '');
    const success      = res.status >= 200 && res.status < 300;

    if (deliveryId) {
      await supabase.from('webhook_deliveries').update({
        status:        success ? 'success' : 'failed',
        response_code: res.status,
        response_body: responseBody.slice(0, 500),
        delivered_at:  success ? new Date().toISOString() : null,
        error:         success ? null : `HTTP ${res.status}`,
      }).eq('id', deliveryId);
    }

    if (!success && attempt < 3) {
      // Exponential backoff: 1s, 3s, 9s
      const delay = Math.pow(3, attempt) * 1000;
      console.log(`[webhook] Retry ${attempt+1} for ${webhook.url} in ${delay}ms`);
      setTimeout(() => deliverWebhook(webhook, merchantId, event, data, attempt + 1), delay);
    } else if (!success) {
      console.error(`[webhook] Failed after 3 attempts: ${webhook.url}`);
    } else {
      console.log(`[webhook] Delivered ${event} to ${webhook.url}`);
    }

  } catch (err) {
    console.error(`[webhook] Request error (attempt ${attempt}):`, err.message);
    if (deliveryId) {
      await supabase.from('webhook_deliveries').update({
        status: attempt < 3 ? 'retrying' : 'failed',
        error:  err.message,
      }).eq('id', deliveryId);
    }
    if (attempt < 3) {
      const delay = Math.pow(3, attempt) * 1000;
      setTimeout(() => deliverWebhook(webhook, merchantId, event, data, attempt + 1), delay);
    }
  }
}

// ── verifySignature ───────────────────────────────────────
// For merchants to verify incoming webhooks in their own code
// (also used in our test endpoint)
function verifySignature(body, signature, secret) {
  const expected = `sha256=${sign(body, secret)}`;
  try {
    return crypto.timingSafeEqual(
      Buffer.from(signature),
      Buffer.from(expected)
    );
  } catch { return false; }
}

module.exports = { dispatch, verifySignature, sign };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/email.js
# Optional email notifications via nodemailer
# ═══════════════════════════════════════════════════════════
log "Writing email service..."
cat > backend/src/services/email.js << 'EOF'
let _transporter = null;

function getTransporter() {
  if (_transporter) return _transporter;
  if (!process.env.SMTP_HOST) return null;

  const nodemailer = require('nodemailer');
  _transporter = nodemailer.createTransport({
    host:   process.env.SMTP_HOST,
    port:   parseInt(process.env.SMTP_PORT || '587'),
    secure: process.env.SMTP_PORT === '465',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
    },
  });
  return _transporter;
}

// ── send ──────────────────────────────────────────────────
async function send({ to, subject, html, text }) {
  const t = getTransporter();
  if (!t) return; // Email not configured — skip silently

  try {
    await t.sendMail({
      from:    process.env.EMAIL_FROM || 'SETTL <noreply@settl.app>',
      to,
      subject,
      html,
      text: text || html.replace(/<[^>]+>/g, ''),
    });
    console.log(`[email] Sent "${subject}" to ${to}`);
  } catch (err) {
    console.error('[email] Send failed:', err.message);
    // Never throw — email is non-critical
  }
}

// ── sendDepositConfirmed ──────────────────────────────────
async function sendDepositConfirmed({ email, merchantName, amount, txSignature, reference }) {
  const explorerUrl = `https://explorer.solana.com/tx/${txSignature}?cluster=devnet`;
  await send({
    to:      email,
    subject: `💰 Payment received — ${Number(amount).toFixed(2)} AUDD`,
    html: `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#534AB7;margin-bottom:4px;">SETTL</h2>
        <p style="color:#6B7280;margin-bottom:24px;">Payment Gateway</p>
        <h3 style="margin-bottom:8px;">Payment confirmed ✓</h3>
        <p>A payment of <strong>${Number(amount).toFixed(2)} AUDD</strong> has been received into your escrow vault.</p>
        <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:8px;padding:16px;margin:16px 0;">
          <div style="font-size:13px;color:#6B7280;margin-bottom:4px;">Amount</div>
          <div style="font-size:24px;font-weight:700;color:#534AB7;">${Number(amount).toFixed(4)} AUDD</div>
        </div>
        <p style="font-size:13px;color:#6B7280;">
          Funds will be released to your wallet at 6am UTC.<br/>
          Reference: <code>${reference}</code>
        </p>
        <a href="${explorerUrl}" style="display:inline-block;margin-top:12px;color:#1D9E75;font-size:13px;">
          View on Solana Explorer →
        </a>
        <hr style="border:none;border-top:1px solid #E5E7EB;margin:24px 0;"/>
        <p style="font-size:11px;color:#9CA3AF;">SETTL Payment Gateway · Solana Devnet</p>
      </div>
    `,
  });
}

// ── sendReleaseCompleted ──────────────────────────────────
async function sendReleaseCompleted({ email, merchantName, gross, fee, net, txSignature }) {
  const explorerUrl = `https://explorer.solana.com/tx/${txSignature}?cluster=devnet`;
  await send({
    to:      email,
    subject: `✅ Release completed — ${Number(net).toFixed(2)} AUDD sent to your wallet`,
    html: `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#534AB7;margin-bottom:4px;">SETTL</h2>
        <p style="color:#6B7280;margin-bottom:24px;">Payment Gateway</p>
        <h3 style="margin-bottom:8px;">Daily release completed ✓</h3>
        <p>Your escrow balance has been released to your wallet.</p>
        <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:8px;padding:16px;margin:16px 0;">
          <table style="width:100%;font-size:14px;">
            <tr><td style="color:#6B7280;padding:4px 0;">Gross collected</td><td style="text-align:right;font-weight:600;">${Number(gross).toFixed(4)} AUDD</td></tr>
            <tr><td style="color:#6B7280;padding:4px 0;">SETTL fee (1.5%)</td><td style="text-align:right;color:#D85A30;">-${Number(fee).toFixed(4)} AUDD</td></tr>
            <tr style="border-top:1px solid #E5E7EB;">
              <td style="padding:8px 0 4px;font-weight:600;">Net sent to wallet</td>
              <td style="text-align:right;font-size:18px;font-weight:700;color:#1D9E75;padding:8px 0 4px;">${Number(net).toFixed(4)} AUDD</td>
            </tr>
          </table>
        </div>
        <a href="${explorerUrl}" style="display:inline-block;margin-top:4px;color:#1D9E75;font-size:13px;">
          View transaction on Solana Explorer →
        </a>
        <hr style="border:none;border-top:1px solid #E5E7EB;margin:24px 0;"/>
        <p style="font-size:11px;color:#9CA3AF;">SETTL Payment Gateway · Solana Devnet</p>
      </div>
    `,
  });
}

module.exports = { send, sendDepositConfirmed, sendReleaseCompleted };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/apiKey.js
# Generate, validate, and revoke API keys
# ═══════════════════════════════════════════════════════════
log "Writing API key service..."
cat > backend/src/services/apiKey.js << 'EOF'
const crypto   = require('crypto');
const bcrypt   = require('bcryptjs');
const { supabase } = require('../config/supabase');

// ── generate ──────────────────────────────────────────────
// Returns the raw key once (never stored).
// Stores a bcrypt hash. Prefix stored for display.
async function generateKey(merchantId, name) {
  // Format: sk_live_<32 random hex chars>
  const raw    = `sk_live_${crypto.randomBytes(16).toString('hex')}`;
  const prefix = raw.slice(0, 16); // "sk_live_XXXXXXXX"
  const hash   = await bcrypt.hash(raw, 10);

  const { data, error } = await supabase
    .from('api_keys')
    .insert({ merchant_id: merchantId, name, key_hash: hash, key_prefix: prefix })
    .select('id, name, key_prefix, created_at')
    .single();

  if (error) throw new Error('Failed to create API key: ' + error.message);

  return {
    ...data,
    key: raw, // shown ONCE to the merchant
    warning: 'Copy this key now — it will never be shown again.',
  };
}

// ── validate ──────────────────────────────────────────────
// Called by API key middleware on every protected request.
// bcrypt.compare is slow by design — cache result if needed.
async function validateKey(rawKey) {
  if (!rawKey?.startsWith('sk_live_')) return null;

  const prefix = rawKey.slice(0, 16);

  // Find keys matching the prefix (reduces bcrypt calls)
  const { data: keys } = await supabase
    .from('api_keys')
    .select('*, merchants(merchant_id, name, is_active, vault_address)')
    .eq('key_prefix', prefix)
    .eq('is_active', true);

  if (!keys?.length) return null;

  for (const key of keys) {
    const match = await bcrypt.compare(rawKey, key.key_hash);
    if (match) {
      // Update last_used_at (fire and forget)
      supabase.from('api_keys')
        .update({ last_used_at: new Date().toISOString() })
        .eq('id', key.id)
        .then(() => {}).catch(() => {});

      return key;
    }
  }
  return null;
}

// ── listKeys ──────────────────────────────────────────────
async function listKeys(merchantId) {
  const { data } = await supabase
    .from('api_keys')
    .select('id, name, key_prefix, is_active, last_used_at, created_at')
    .eq('merchant_id', merchantId)
    .order('created_at', { ascending: false });
  return data || [];
}

// ── revokeKey ─────────────────────────────────────────────
async function revokeKey(keyId, merchantId) {
  const { error } = await supabase
    .from('api_keys')
    .update({ is_active: false })
    .eq('id', keyId)
    .eq('merchant_id', merchantId);
  if (error) throw error;
}

module.exports = { generateKey, validateKey, listKeys, revokeKey };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — middleware/apiKey.js
# Validates x-api-key header for programmatic access
# ═══════════════════════════════════════════════════════════
cat > backend/src/middleware/apiKey.js << 'EOF'
const { validateKey } = require('../services/apiKey');

async function apiKeyMiddleware(req, res, next) {
  const key = req.headers['x-api-key'];
  if (!key) return res.status(401).json({ error: 'Missing x-api-key header' });

  const keyRecord = await validateKey(key);
  if (!keyRecord) return res.status(401).json({ error: 'Invalid or revoked API key' });
  if (!keyRecord.merchants?.is_active) {
    return res.status(403).json({ error: 'Merchant account is not active' });
  }

  req.apiKey   = keyRecord;
  req.merchant = keyRecord.merchants;
  next();
}

module.exports = apiKeyMiddleware;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/webhooks.js
# CRUD for webhook configs + delivery log
# ═══════════════════════════════════════════════════════════
log "Writing webhook routes..."
cat > backend/src/routes/webhooks.js << 'EOF'
const router   = require('express').Router();
const crypto   = require('crypto');
const { supabase } = require('../config/supabase');
const { verifySignature } = require('../services/webhook');

// Helper: get merchant_id for the logged-in user
async function getMerchantId(userId) {
  const { data } = await supabase
    .from('merchants').select('merchant_id').eq('user_id', userId).maybeSingle();
  return data?.merchant_id;
}

// ── GET /api/webhooks ─────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ webhooks: [] });

    const { data } = await supabase
      .from('webhook_configs')
      .select('id, url, description, events, is_active, created_at')
      .eq('merchant_id', mid)
      .order('created_at', { ascending: false });

    res.json({ webhooks: data || [] });
  } catch (err) { next(err); }
});

// ── POST /api/webhooks ────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { url, description, events } = req.body;
    if (!url) return res.status(400).json({ error: 'url is required' });

    // Validate URL format
    try { new URL(url); } catch {
      return res.status(400).json({ error: 'Invalid URL format' });
    }

    // Generate a unique signing secret for this webhook
    const secret = crypto.randomBytes(24).toString('hex');

    const validEvents = ['deposit.confirmed', 'release.completed'];
    const chosenEvents = Array.isArray(events)
      ? events.filter(e => validEvents.includes(e))
      : validEvents;

    const { data, error } = await supabase
      .from('webhook_configs')
      .insert({ merchant_id: mid, url, description: description || null, events: chosenEvents, secret })
      .select()
      .single();

    if (error) throw error;

    res.status(201).json({
      webhook: { ...data },
      signing_secret: secret,
      note: 'Save the signing_secret — it will not be shown again. Use it to verify webhook signatures.',
    });
  } catch (err) { next(err); }
});

// ── PATCH /api/webhooks/:id ───────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    const { url, description, events, is_active } = req.body;
    const updates = {};
    if (url         !== undefined) updates.url         = url;
    if (description !== undefined) updates.description = description;
    if (events      !== undefined) updates.events      = events;
    if (is_active   !== undefined) updates.is_active   = is_active;

    const { data, error } = await supabase
      .from('webhook_configs')
      .update(updates)
      .eq('id', req.params.id)
      .eq('merchant_id', mid)
      .select()
      .single();

    if (error) throw error;
    res.json({ webhook: data });
  } catch (err) { next(err); }
});

// ── DELETE /api/webhooks/:id ──────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    await supabase.from('webhook_configs').delete()
      .eq('id', req.params.id).eq('merchant_id', mid);
    res.json({ message: 'Webhook deleted' });
  } catch (err) { next(err); }
});

// ── GET /api/webhooks/deliveries ──────────────────────────
router.get('/deliveries', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ deliveries: [] });

    const { data } = await supabase
      .from('webhook_deliveries')
      .select('id, event, status, response_code, attempt, error, delivered_at, created_at, webhook_configs(url)')
      .eq('merchant_id', mid)
      .order('created_at', { ascending: false })
      .limit(50);

    res.json({ deliveries: data || [] });
  } catch (err) { next(err); }
});

// ── POST /api/webhooks/test ───────────────────────────────
// Sends a test event to all active webhooks
router.post('/test', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { dispatch } = require('../services/webhook');
    await dispatch(mid, 'deposit.confirmed', {
      test:          true,
      reference_key: 'test-reference',
      amount:        1.00,
      tx_signature:  'test-tx-signature',
      timestamp:     new Date().toISOString(),
    });

    res.json({ message: 'Test event dispatched to all active webhooks' });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/apikeys.js
# ═══════════════════════════════════════════════════════════
log "Writing API key routes..."
cat > backend/src/routes/apikeys.js << 'EOF'
const router   = require('express').Router();
const { supabase } = require('../config/supabase');
const { generateKey, listKeys, revokeKey } = require('../services/apiKey');

async function getMerchantId(userId) {
  const { data } = await supabase.from('merchants').select('merchant_id').eq('user_id', userId).maybeSingle();
  return data?.merchant_id;
}

// ── GET /api/apikeys ──────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ keys: [] });
    const keys = await listKeys(mid);
    res.json({ keys });
  } catch (err) { next(err); }
});

// ── POST /api/apikeys ─────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { name } = req.body;
    if (!name) return res.status(400).json({ error: 'name is required' });

    // Max 5 active keys per merchant
    const existing = await listKeys(mid);
    const active   = existing.filter(k => k.is_active);
    if (active.length >= 5) {
      return res.status(400).json({ error: 'Maximum 5 active API keys per merchant. Revoke one first.' });
    }

    const result = await generateKey(mid, name);
    res.status(201).json(result);
  } catch (err) { next(err); }
});

// ── DELETE /api/apikeys/:id ───────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });
    await revokeKey(req.params.id, mid);
    res.json({ message: 'API key revoked' });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/pay.js (public API key endpoint)
# POST /api/pay/charge — programmatic payment session creation
# Merchants call this from their own backend with an API key
# ═══════════════════════════════════════════════════════════
log "Writing public /api/pay/charge endpoint..."
cat > backend/src/routes/pay.js << 'EOF'
const router         = require('express').Router();
const apiKeyMiddleware = require('../middleware/apiKey');
const { createPaymentSession } = require('../services/solanaPay');

// ── POST /api/pay/charge ───────────────────────────────────
// Used by merchants from their own server backend.
// Requires: x-api-key header with a valid sk_live_... key
//
// Body:
//   amount   {number}  — AUDD amount (e.g. 25.00). Optional for open.
//   message  {string}  — order reference shown on checkout. Optional.
//   memo     {string}  — on-chain memo. Optional.
//
// Returns:
//   url          — Solana Pay URL (solana:...)
//   checkout_url — shareable checkout link
//   reference    — unique reference key for polling
//   session_id   — DB session ID
//
// Example:
//   curl -X POST https://your-settl.com/api/pay/charge \
//     -H "x-api-key: sk_live_..." \
//     -H "Content-Type: application/json" \
//     -d '{"amount": 25.00, "message": "Order #1234"}'
router.post('/charge', apiKeyMiddleware, async (req, res, next) => {
  try {
    const { amount, message, memo } = req.body;
    const merchantId = req.merchant.merchant_id;

    function getBaseUrl(req) {
      const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
      const host  = req.headers['x-forwarded-host']  || req.headers.host || 'localhost:3000';
      return `${proto}://${host}`;
    }

    const session = await createPaymentSession(
      { merchantId, amountAudd: amount || null, message, memo },
      getBaseUrl(req)
    );

    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/pay/status/:ref ───────────────────────────────
// Check payment status programmatically (no auth needed)
router.get('/status/:ref', async (req, res, next) => {
  try {
    const { pollPaymentSession } = require('../services/solanaPay');
    const result = await pollPaymentSession(req.params.ref);
    res.json(result);
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — update solanaPay.js to fire webhooks + emails
# after confirming a payment
# ═══════════════════════════════════════════════════════════
log "Updating solanaPay.js to dispatch webhooks and emails on confirmation..."
cat > backend/src/services/solanaPay.js << 'EOF'
const { PublicKey, Keypair } = require('@solana/web3.js');
const BigNumber  = require('bignumber.js');
const { supabase }              = require('../config/supabase');
const { getConnection, getEscrowPDA, getProgram } = require('../config/anchor');

let _sp;
function sp() { if (!_sp) _sp = require('@solana/pay'); return _sp; }

function getBaseUrl(reqHost) {
  return reqHost || process.env.APP_URL || 'http://localhost:3000';
}

async function createPaymentSession({ merchantId, amountAudd, message, memo }, reqHost) {
  const { data: merchant } = await supabase
    .from('merchants')
    .select('vault_address, wallet_address, name, is_active, registration_status')
    .eq('merchant_id', merchantId)
    .maybeSingle();

  if (!merchant)               throw new Error('Merchant not found');
  if (!merchant.is_active)     throw new Error(`Merchant not active yet (${merchant.registration_status}). Try again in a moment.`);
  if (!merchant.vault_address) throw new Error('Vault not ready yet. Registration still processing — try again in a moment.');

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

  const { data: session } = await supabase.from('payment_sessions').insert({
    merchant_id:   merchantId,
    amount:        amountAudd || null,
    reference_key: reference.toBase58(),
    label, message: msgText,
    memo: memo || null,
    status: 'pending',
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
        if (session.amount) {
          try {
            await validateTransfer(connection, sigInfo.signature, {
              recipient: vaultPubkey,
              amount:    new BigNumber(session.amount),
              splToken,
            });
          } catch { /* fall through to vault method */ }
        }
        return await confirmSession(session, sigInfo.signature, referenceKey);
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
        .from('payment_sessions').select('id').eq('tx_signature', sig.signature).maybeSingle();
      if (existing && existing.id !== session.id) continue;

      const tx = await connection.getParsedTransaction(sig.signature, {
        commitment: 'confirmed', maxSupportedTransactionVersion: 0,
      });
      if (!tx?.meta) continue;

      const pre  = tx.meta.preTokenBalances  || [];
      const post = tx.meta.postTokenBalances || [];

      const vaultPost = post.find(b => b.mint === splToken.toBase58());
      const vaultPre  = pre.find(b =>  b.mint === splToken.toBase58() && vaultPost && b.accountIndex === vaultPost.accountIndex);

      const postAmt = parseFloat(vaultPost?.uiTokenAmount?.uiAmountString || '0');
      const preAmt  = parseFloat(vaultPre?.uiTokenAmount?.uiAmountString  || '0');
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

async function confirmSession(session, txSignature, referenceKey) {
  const now = new Date().toISOString();

  await supabase.from('payment_sessions').update({
    status: 'confirmed', tx_signature: txSignature, confirmed_at: now,
  }).eq('reference_key', referenceKey);

  await supabase.from('transactions').insert({
    merchant_id:   session.merchant_id,
    type:          'deposit',
    amount:        session.amount || 0,
    tx_signature:  txSignature,
    reference_key: referenceKey,
    status:        'confirmed',
  }).then(()=>{}).catch(e => console.warn('[confirm] tx insert:', e.message));

  // Sync escrow from chain
  try {
    const program     = getProgram();
    const [escrowPDA] = getEscrowPDA(session.merchant_id);
    const acc         = await program.account.escrowAccount.fetch(escrowPDA);
    await supabase.from('escrows').update({
      pending_balance: acc.pendingBalance.toNumber() / 1_000_000,
      total_payments:  acc.totalPayments.toNumber(),
    }).eq('merchant_id', session.merchant_id);
  } catch (e) { console.warn('[confirm] escrow sync:', e.message); }

  // ── Fire webhook + email (non-blocking) ──────────────────
  setImmediate(async () => {
    try {
      const { dispatch } = require('./webhook');
      await dispatch(session.merchant_id, 'deposit.confirmed', {
        reference_key: referenceKey,
        amount:        session.amount || 0,
        tx_signature:  txSignature,
        confirmed_at:  now,
      });
    } catch (e) { console.warn('[confirm] webhook dispatch:', e.message); }

    try {
      const email  = require('./email');
      const { data: merchant } = await supabase
        .from('merchants')
        .select('name')
        .eq('merchant_id', session.merchant_id)
        .maybeSingle();
      const { data: user } = await supabase
        .from('users')
        .select('email')
        .eq('id', (await supabase.from('merchants').select('user_id').eq('merchant_id', session.merchant_id).maybeSingle()).data?.user_id)
        .maybeSingle();

      if (user?.email) {
        // Deduplicate — don't email twice for same session
        const { data: already } = await supabase
          .from('notification_log')
          .select('id').eq('ref', referenceKey).eq('type', 'deposit.confirmed').maybeSingle();
        if (!already) {
          await email.sendDepositConfirmed({
            email:         user.email,
            merchantName:  merchant?.name || session.merchant_id,
            amount:        session.amount || 0,
            txSignature,
            reference:     referenceKey,
          });
          await supabase.from('notification_log').insert({
            merchant_id: session.merchant_id,
            type:        'deposit.confirmed',
            ref:         referenceKey,
          });
        }
      }
    } catch (e) { console.warn('[confirm] email:', e.message); }
  });

  return { status: 'confirmed', tx: txSignature };
}

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
# BACKEND — update release.js to fire webhooks + emails
# ═══════════════════════════════════════════════════════════
log "Updating release service to dispatch webhooks and emails..."
cat > backend/src/services/release.js << 'EOF'
const { PublicKey }                               = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } = require('@solana/spl-token');
const { supabase }   = require('../config/supabase');
const { getProgram, getKeypair, getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA } = require('../config/anchor');

const FEE_BPS = 150;

async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);
  const treasury  = new PublicKey(process.env.TREASURY_WALLET);

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const escrowBefore = await program.account.escrowAccount.fetch(escrowPDA);
  const gross        = escrowBefore.pendingBalance.toNumber();
  if (gross === 0) return { skipped: true, merchantId, reason: 'zero balance' };

  const fee = Math.floor(gross * FEE_BPS / 10_000);
  const net = gross - fee;

  const m = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, m.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  const tx = await program.methods.release(merchantId).accounts({
    config: configPDA, merchant: merchantPDA, escrow: escrowPDA,
    vault: vaultPDA, merchantAta: merchantATA, treasuryAta: treasuryATA,
    authority: authority.publicKey, tokenProgram: TOKEN_PROGRAM_ID,
  }).signers([authority]).rpc();

  const now = new Date().toISOString();
  const grossAudd = gross/1_000_000, feeAudd = fee/1_000_000, netAudd = net/1_000_000;

  await supabase.from('release_logs').insert({
    merchant_id: merchantId, gross: grossAudd, fee: feeAudd, net: netAudd,
    tx_signature: tx, status: 'success', released_at: now,
  });
  await supabase.from('transactions').insert([
    { merchant_id: merchantId, type: 'release', amount: grossAudd, fee: feeAudd, net: netAudd, tx_signature: tx, status: 'confirmed' },
    { merchant_id: merchantId, type: 'fee',     amount: feeAudd,   tx_signature: tx, status: 'confirmed' },
  ]);
  await supabase.from('escrows').update({ pending_balance: 0, last_released_at: now }).eq('merchant_id', merchantId);

  console.log(`[release] ${merchantId} gross:${grossAudd} fee:${feeAudd} net:${netAudd} tx:${tx}`);

  // ── Fire webhook + email (non-blocking) ──────────────────
  setImmediate(async () => {
    try {
      const { dispatch } = require('./webhook');
      await dispatch(merchantId, 'release.completed', {
        gross: grossAudd, fee: feeAudd, net: netAudd,
        tx_signature: tx, released_at: now,
      });
    } catch (e) { console.warn('[release] webhook:', e.message); }

    try {
      const email = require('./email');
      const { data: merchant } = await supabase
        .from('merchants').select('user_id, name').eq('merchant_id', merchantId).maybeSingle();
      if (merchant?.user_id) {
        const { data: user } = await supabase
          .from('users').select('email').eq('id', merchant.user_id).maybeSingle();
        if (user?.email) {
          const { data: already } = await supabase
            .from('notification_log').select('id').eq('ref', tx).eq('type', 'release.completed').maybeSingle();
          if (!already) {
            await email.sendReleaseCompleted({
              email: user.email, merchantName: merchant.name,
              gross: grossAudd, fee: feeAudd, net: netAudd, txSignature: tx,
            });
            await supabase.from('notification_log').insert({
              merchant_id: merchantId, type: 'release.completed', ref: tx,
            });
          }
        }
      }
    } catch (e) { console.warn('[release] email:', e.message); }
  });

  return { skipped: false, merchantId, gross, fee, net, tx };
}

async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase.from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running' }).select().single();
  const runId = run?.id;

  const { data: merchants } = await supabase.from('merchants').select('merchant_id').eq('is_active', true);
  if (!merchants?.length) {
    await supabase.from('cron_logs').update({ status: 'skipped', finished_at: new Date().toISOString(), summary: 'No active merchants' }).eq('id', runId);
    return { total: 0, released: 0, skipped: 0, failed: 0, results: [], summary: 'No active merchants' };
  }

  let released=0, skipped=0, failed=0; const results=[];
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
    finished_at: new Date().toISOString(),
    summary, total_merchants: merchants.length, released, skipped, failed,
  }).eq('id', runId);

  return { total: merchants.length, released, skipped, failed, results, summary };
}

module.exports = { releaseMerchant, releaseAll };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — cron/dailyRelease.js (add session expiry cleanup)
# ═══════════════════════════════════════════════════════════
log "Updating cron with session expiry cleanup..."
cat > backend/src/cron/dailyRelease.js << 'EOF'
const cron           = require('node-cron');
const { releaseAll } = require('../services/release');
const { supabase }   = require('../config/supabase');

let releaseJob = null;
let cleanupJob = null;

function startCron() {
  if (releaseJob) return;

  // ── 6am daily release ─────────────────────────────────
  releaseJob = cron.schedule('0 0 6 * * *', async () => {
    console.log('[cron] 6am release starting...');
    try {
      const r = await releaseAll('cron');
      console.log('[cron] Release done:', r.summary);
    } catch (err) {
      console.error('[cron] Release error:', err.message);
    }
  }, { scheduled: true, timezone: 'UTC' });

  // ── Hourly session expiry cleanup ─────────────────────
  cleanupJob = cron.schedule('0 0 * * * *', async () => {
    try {
      const { data, error } = await supabase
        .from('payment_sessions')
        .update({ status: 'expired' })
        .eq('status', 'pending')
        .lt('expires_at', new Date().toISOString())
        .select('id');

      if (!error && data?.length > 0) {
        console.log(`[cron] Expired ${data.length} stale payment session(s)`);
      }
    } catch (err) {
      console.error('[cron] Session cleanup error:', err.message);
    }
  }, { scheduled: true, timezone: 'UTC' });

  console.log('[SETTL] Crons scheduled: 6am release + hourly session cleanup');
}

module.exports = {
  startCron,
  triggerNow: () => releaseAll('manual'),
};
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — server.js — add new routes
# ═══════════════════════════════════════════════════════════
log "Updating server.js with Phase 4 routes..."
cat > backend/src/server.js << 'EOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');

const authMiddleware   = require('./middleware/auth');
const { startCron }    = require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Static frontend ────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../../frontend')));

// ── Rate limits ────────────────────────────────────────────
const authLimit  = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
const writeLimit = rateLimit({ windowMs: 15 * 60 * 1000, max: 60  });

// ── Public routes — NO auth ────────────────────────────────
app.use('/api/health',  require('./routes/health'));
app.use('/api/auth',    authLimit, require('./routes/auth'));

// Payment poll + session info — public, no rate limit
app.get('/api/payments/poll/:ref',    require('./routes/payments'));
app.get('/api/payments/session/:ref', require('./routes/payments'));

// Public API key endpoint (protected by x-api-key, not JWT)
app.use('/api/pay', require('./routes/pay'));

// ── Protected routes — JWT required ───────────────────────
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, writeLimit, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));
app.use('/api/webhooks',  authMiddleware, require('./routes/webhooks'));
app.use('/api/apikeys',   authMiddleware, require('./routes/apikeys'));

// ── Catch-all → frontend ───────────────────────────────────
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
# FRONTEND — js/modules/api.js — add Phase 4 endpoints
# ═══════════════════════════════════════════════════════════
log "Updating frontend api.js with Phase 4 endpoints..."
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

async function publicGet(path) {
  const res  = await fetch(`${API}${path}`);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(data.error || `HTTP ${res.status}`); e.status = res.status; throw e; }
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',   body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH',  body: JSON.stringify(b) }),
  delete: (p, o)    => req(p, { ...o, method: 'DELETE' }),

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
    session:     (b)   => api.post('/payments/session', b),
    pollPublic:  (ref) => publicGet(`/payments/poll/${ref}`),
    sessionInfo: (ref) => publicGet(`/payments/session/${ref}`),
    history:     ()    => api.get('/payments/history'),
  },

  webhooks: {
    list:      ()          => api.get('/webhooks'),
    create:    (b)         => api.post('/webhooks', b),
    update:    (id, b)     => api.patch(`/webhooks/${id}`, b),
    delete:    (id)        => api.delete(`/webhooks/${id}`),
    test:      ()          => api.post('/webhooks/test', {}),
    deliveries:()          => api.get('/webhooks/deliveries'),
  },

  apikeys: {
    list:   ()     => api.get('/apikeys'),
    create: (name) => api.post('/apikeys', { name }),
    revoke: (id)   => api.delete(`/apikeys/${id}`),
  },
};

window.api = api;
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — merchant/webhooks.html
# ═══════════════════════════════════════════════════════════
log "Writing webhooks page..."
cat > frontend/pages/merchant/webhooks.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Webhooks</title>
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
        <span class="topbar-title">Webhooks</span>
      </div>
    </div>

    <div class="page-body">

      <!-- Info -->
      <div class="alert alert-info" style="margin-bottom:16px;">
        SETTL will POST to your URL on every payment confirmation and daily release.
        Each request is signed with <code>X-SETTL-Signature: sha256=&lt;hmac&gt;</code>
        so you can verify it's genuine.
      </div>

      <!-- Add webhook form -->
      <div class="card">
        <div class="card-title-row"><h2>Add webhook endpoint</h2></div>
        <div class="form-group">
          <label class="form-label">Endpoint URL <span style="color:var(--coral)">*</span></label>
          <input class="form-input" id="w-url" type="url" placeholder="https://your-server.com/webhooks/settl"/>
        </div>
        <div class="form-group">
          <label class="form-label">Description <span style="color:var(--text-hint);font-weight:400;">— optional</span></label>
          <input class="form-input" id="w-desc" placeholder="e.g. Production order fulfilment"/>
        </div>
        <div class="form-group">
          <label class="form-label">Events</label>
          <div style="display:flex;gap:16px;flex-wrap:wrap;margin-top:4px;">
            <label style="display:flex;align-items:center;gap:8px;font-size:14px;cursor:pointer;">
              <input type="checkbox" id="ev-deposit" checked style="width:16px;height:16px;accent-color:var(--brand);"/>
              deposit.confirmed
            </label>
            <label style="display:flex;align-items:center;gap:8px;font-size:14px;cursor:pointer;">
              <input type="checkbox" id="ev-release" checked style="width:16px;height:16px;accent-color:var(--brand);"/>
              release.completed
            </label>
          </div>
        </div>
        <div id="w-err" class="alert alert-error" style="display:none;"></div>
        <button class="btn btn-primary" onclick="addWebhook()">Add endpoint</button>
      </div>

      <!-- Secret modal -->
      <div class="modal-wrap" id="secret-modal">
        <div class="modal-box">
          <div class="modal-header">
            <span class="modal-title">Signing secret — save this now</span>
            <button class="modal-close" onclick="closeSecretModal()">×</button>
          </div>
          <div class="alert alert-warning" style="margin-bottom:16px;">
            This secret will only be shown once. Copy it now and store it securely.
          </div>
          <div class="form-group">
            <label class="form-label">Signing secret</label>
            <div style="display:flex;gap:8px;">
              <input class="form-input" id="secret-val" readonly style="font-family:var(--font-mono);font-size:12px;flex:1;"/>
              <button class="btn btn-secondary" onclick="copySecret()">Copy</button>
            </div>
          </div>
          <div style="font-size:13px;color:var(--text-muted);line-height:1.6;">
            <strong>Verify incoming webhooks:</strong><br/>
            <code style="background:var(--bg);padding:2px 6px;border-radius:4px;font-size:12px;">
              crypto.createHmac('sha256', secret).update(rawBody).digest('hex')
            </code><br/>
            Compare with the <code>X-SETTL-Signature</code> header (strip the <code>sha256=</code> prefix).
          </div>
          <button class="btn btn-primary" style="margin-top:16px;width:100%;" onclick="closeSecretModal()">
            I've saved the secret
          </button>
        </div>
      </div>

      <!-- Webhooks list -->
      <div class="card">
        <div class="card-title-row">
          <h2>Active endpoints</h2>
          <button class="btn btn-secondary btn-sm" onclick="sendTest()">Send test event</button>
        </div>
        <div id="webhooks-list">
          <div style="text-align:center;padding:28px;color:var(--text-hint);">Loading…</div>
        </div>
      </div>

      <!-- Delivery log -->
      <div class="card">
        <div class="card-title-row"><h2>Delivery log</h2><button class="btn btn-secondary btn-sm" onclick="loadDeliveries()">Refresh</button></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Event</th><th>URL</th><th>Status</th><th>HTTP</th><th>Attempt</th><th>Time</th></tr></thead>
            <tbody id="deliveries-tbody">
              <tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>
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

  async function addWebhook() {
    const url   = document.getElementById('w-url').value.trim();
    const desc  = document.getElementById('w-desc').value.trim();
    const events = [];
    if (document.getElementById('ev-deposit').checked) events.push('deposit.confirmed');
    if (document.getElementById('ev-release').checked) events.push('release.completed');
    document.getElementById('w-err').style.display = 'none';

    if (!url) { document.getElementById('w-err').textContent='URL is required'; document.getElementById('w-err').style.display=''; return; }
    if (!events.length) { document.getElementById('w-err').textContent='Select at least one event'; document.getElementById('w-err').style.display=''; return; }

    try {
      const result = await api.webhooks.create({ url, description: desc || null, events });
      document.getElementById('secret-val').value = result.signing_secret;
      document.getElementById('secret-modal').classList.add('show');
      document.getElementById('w-url').value  = '';
      document.getElementById('w-desc').value = '';
      loadWebhooks();
      toast.success('Webhook added!');
    } catch(err) {
      document.getElementById('w-err').textContent = err.message;
      document.getElementById('w-err').style.display = '';
    }
  }

  function copySecret() {
    navigator.clipboard.writeText(document.getElementById('secret-val').value)
      .then(()=>toast.success('Secret copied!'));
  }
  function closeSecretModal() { document.getElementById('secret-modal').classList.remove('show'); }

  async function loadWebhooks() {
    const container = document.getElementById('webhooks-list');
    try {
      const { webhooks } = await api.webhooks.list();
      if (!webhooks.length) {
        container.innerHTML = '<div style="text-align:center;padding:28px;color:var(--text-hint);">No webhook endpoints yet. Add one above.</div>';
        return;
      }
      container.innerHTML = webhooks.map(w => `
        <div style="display:flex;justify-content:space-between;align-items:flex-start;padding:14px 0;border-bottom:1px solid var(--border);gap:12px;flex-wrap:wrap;">
          <div style="min-width:0;flex:1;">
            <div style="font-family:var(--font-mono);font-size:13px;font-weight:500;word-break:break-all;">${w.url}</div>
            <div style="font-size:12px;color:var(--text-muted);margin-top:4px;">
              ${w.description||'No description'} &nbsp;·&nbsp;
              ${w.events.map(e=>`<span class="badge badge-info" style="font-size:10px;margin-right:4px;">${e}</span>`).join('')}
            </div>
          </div>
          <div style="display:flex;gap:6px;flex-shrink:0;">
            <span class="badge ${w.is_active?'badge-success':'badge-error'}">${w.is_active?'Active':'Inactive'}</span>
            <button class="btn btn-secondary btn-sm" onclick="toggleWebhook('${w.id}',${w.is_active})">${w.is_active?'Disable':'Enable'}</button>
            <button class="btn btn-danger btn-sm"    onclick="deleteWebhook('${w.id}')">Delete</button>
          </div>
        </div>`).join('');
    } catch(err) { toast.error(err.message); }
  }

  async function toggleWebhook(id, isActive) {
    try {
      await api.webhooks.update(id, { is_active: !isActive });
      loadWebhooks();
      toast.success(isActive ? 'Webhook disabled' : 'Webhook enabled');
    } catch(err) { toast.error(err.message); }
  }

  async function deleteWebhook(id) {
    if (!confirm('Delete this webhook? All delivery history will also be removed.')) return;
    try {
      await api.webhooks.delete(id);
      loadWebhooks(); loadDeliveries();
      toast.success('Webhook deleted');
    } catch(err) { toast.error(err.message); }
  }

  async function sendTest() {
    try {
      await api.webhooks.test();
      toast.success('Test event sent to all active webhooks');
      setTimeout(loadDeliveries, 2000);
    } catch(err) { toast.error(err.message); }
  }

  async function loadDeliveries() {
    const tbody = document.getElementById('deliveries-tbody');
    try {
      const { deliveries } = await api.webhooks.deliveries();
      if (!deliveries.length) {
        tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">No deliveries yet — send a test event above.</td></tr>';
        return;
      }
      tbody.innerHTML = deliveries.map(d => `<tr>
        <td><span class="badge badge-info" style="font-size:10px;">${d.event}</span></td>
        <td style="font-size:11px;font-family:var(--font-mono);max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${d.webhook_configs?.url||''}">${d.webhook_configs?.url||'—'}</td>
        <td><span class="badge ${d.status==='success'?'badge-success':d.status==='retrying'?'badge-pending':'badge-error'}">${d.status}</span></td>
        <td style="font-size:13px;color:${d.response_code>=200&&d.response_code<300?'var(--teal)':'var(--coral)'};">${d.response_code||'—'}</td>
        <td style="font-size:12px;color:var(--text-muted);">${d.attempt}</td>
        <td style="font-size:11px;color:var(--text-muted);">${new Date(d.created_at).toLocaleTimeString()}</td>
      </tr>`).join('');
    } catch(err) { toast.error(err.message); }
  }

  loadWebhooks();
  loadDeliveries();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — merchant/apikeys.html
# ═══════════════════════════════════════════════════════════
log "Writing API keys page..."
cat > frontend/pages/merchant/apikeys.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — API Keys</title>
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
        <span class="topbar-title">API Keys</span>
      </div>
    </div>

    <div class="page-body">

      <!-- How to use -->
      <div class="card" style="max-width:640px;">
        <div class="card-title-row"><h2>Programmatic access</h2></div>
        <p style="font-size:14px;color:var(--text-muted);margin-bottom:16px;line-height:1.6;">
          Use API keys to create payment sessions from your own backend without logging in.
          Add the key as an <code>x-api-key</code> header.
        </p>
        <div style="background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-md);padding:14px;font-size:12px;font-family:var(--font-mono);line-height:1.8;overflow-x:auto;">
          <span style="color:var(--text-muted);"># Create a payment session</span><br/>
          curl -X POST https://your-settl.com/api/pay/charge \<br/>
          &nbsp;&nbsp;-H "x-api-key: sk_live_..." \<br/>
          &nbsp;&nbsp;-H "Content-Type: application/json" \<br/>
          &nbsp;&nbsp;-d '{"amount": 25.00, "message": "Order #1234"}'<br/>
          <br/>
          <span style="color:var(--text-muted);"># Response includes:</span><br/>
          <span style="color:var(--teal);">{ "checkout_url": "...", "reference": "...", "url": "solana:..." }</span><br/>
          <br/>
          <span style="color:var(--text-muted);"># Poll for confirmation (no auth needed)</span><br/>
          curl https://your-settl.com/api/pay/status/:reference
        </div>
      </div>

      <!-- Create key -->
      <div class="card" style="max-width:640px;">
        <div class="card-title-row"><h2>Create new key</h2></div>
        <div style="display:flex;gap:10px;">
          <input class="form-input" id="key-name" placeholder="e.g. Production backend, Test server" style="flex:1;"/>
          <button class="btn btn-primary" onclick="createKey()" style="white-space:nowrap;">Create key</button>
        </div>
        <div class="form-hint" style="margin-top:8px;">Max 5 active keys per merchant.</div>
      </div>

      <!-- Key reveal modal -->
      <div class="modal-wrap" id="key-modal">
        <div class="modal-box">
          <div class="modal-header">
            <span class="modal-title">Your new API key</span>
          </div>
          <div class="alert alert-warning" style="margin-bottom:16px;">
            This key will only be shown once. Copy it now and store it securely like a password.
          </div>
          <div class="form-group">
            <label class="form-label">API key</label>
            <div style="display:flex;gap:8px;">
              <input class="form-input" id="key-val" readonly style="font-family:var(--font-mono);font-size:12px;flex:1;"/>
              <button class="btn btn-secondary" onclick="copyKey()">Copy</button>
            </div>
          </div>
          <div class="form-hint">Use this as the <code>x-api-key</code> header in your requests.</div>
          <button class="btn btn-primary btn-full" style="margin-top:16px;" onclick="closeKeyModal()">
            I've saved my key
          </button>
        </div>
      </div>

      <!-- Keys list -->
      <div class="card" style="max-width:640px;">
        <div class="card-title-row"><h2>Active keys</h2><button class="btn btn-secondary btn-sm" onclick="loadKeys()">Refresh</button></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Name</th><th>Key prefix</th><th>Last used</th><th>Created</th><th>Action</th></tr></thead>
            <tbody id="keys-tbody">
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

  async function createKey() {
    const name = document.getElementById('key-name').value.trim();
    if (!name) { toast.error('Enter a name for the key'); return; }
    try {
      const result = await api.apikeys.create(name);
      document.getElementById('key-val').value = result.key;
      document.getElementById('key-modal').classList.add('show');
      document.getElementById('key-name').value = '';
      loadKeys();
    } catch(err) { toast.error(err.message); }
  }

  function copyKey() {
    navigator.clipboard.writeText(document.getElementById('key-val').value)
      .then(()=>toast.success('Key copied!'));
  }
  function closeKeyModal() { document.getElementById('key-modal').classList.remove('show'); }

  async function loadKeys() {
    const tbody = document.getElementById('keys-tbody');
    try {
      const { keys } = await api.apikeys.list();
      const active = keys.filter(k => k.is_active);
      if (!active.length) {
        tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:24px;color:var(--text-hint);">No API keys yet. Create one above.</td></tr>';
        return;
      }
      tbody.innerHTML = active.map(k => `<tr>
        <td style="font-weight:500;">${k.name}</td>
        <td style="font-family:var(--font-mono);font-size:12px;">${k.key_prefix}••••••••••••••••</td>
        <td style="font-size:12px;color:var(--text-muted);">${k.last_used_at ? new Date(k.last_used_at).toLocaleString() : 'Never'}</td>
        <td style="font-size:12px;color:var(--text-muted);">${new Date(k.created_at).toLocaleDateString()}</td>
        <td><button class="btn btn-danger btn-sm" onclick="revokeKey('${k.id}','${k.name}')">Revoke</button></td>
      </tr>`).join('');
    } catch(err) { toast.error(err.message); }
  }

  async function revokeKey(id, name) {
    if (!confirm(`Revoke "${name}"? Any app using this key will stop working immediately.`)) return;
    try {
      await api.apikeys.revoke(id);
      toast.success('Key revoked');
      loadKeys();
    } catch(err) { toast.error(err.message); }
  }

  loadKeys();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — merchant/payments.html — add CSV export
# ═══════════════════════════════════════════════════════════
log "Updating payments page with CSV export and Realtime..."
cat > frontend/pages/merchant/payments.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Payments</title>
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
        <span class="topbar-title">Payments</span>
      </div>
      <button class="btn btn-secondary btn-sm" onclick="exportCSV()">⬇ Export CSV</button>
    </div>

    <div class="page-body">
      <div class="card-grid">
        <div class="card"><div class="card-title">Total gross</div><div class="card-value" id="s-gross">—</div><div class="card-sub">AUDD collected</div></div>
        <div class="card"><div class="card-title">Net received</div><div class="card-value" id="s-net">—</div><div class="card-sub">After 1.5% fee</div></div>
        <div class="card"><div class="card-title">Fees paid</div><div class="card-value" id="s-fee">—</div><div class="card-sub">To SETTL</div></div>
        <div class="card"><div class="card-title">Next release</div><div class="card-value" id="s-next">—</div><div class="card-sub">6am UTC daily</div></div>
      </div>

      <!-- Payment sessions -->
      <div class="card">
        <div class="card-title-row">
          <h2>Payment sessions</h2>
          <div style="display:flex;gap:8px;">
            <span id="realtime-dot" style="font-size:11px;color:var(--text-hint);">● connecting</span>
            <a href="/pages/merchant/paylink.html" class="btn btn-primary btn-sm">+ New</a>
          </div>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Amount</th><th>Message</th><th>Status</th><th>Created</th><th>Checkout link</th></tr></thead>
            <tbody id="sess-tbody"><tr><td colspan="5" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr></tbody>
          </table>
        </div>
      </div>

      <!-- Release history -->
      <div class="card">
        <div class="card-title-row"><h2>Release history</h2></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Date</th><th>Gross</th><th>Fee (1.5%)</th><th>Net</th><th>Status</th><th>Explorer</th></tr></thead>
            <tbody id="rel-tbody"><tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr></tbody>
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

  const EX='https://explorer.solana.com/tx/', CL='?cluster=devnet';
  const fmtA = v => v!=null ? Number(v).toFixed(4)+' AUDD' : '—';
  function shortKey(k) { return k ? k.slice(0,6)+'…'+k.slice(-4) : '—'; }
  function nextRelease() {
    const now=new Date(),next=new Date(); next.setUTCHours(6,0,0,0);
    if(next<=now) next.setUTCDate(next.getUTCDate()+1);
    const d=next-now,h=Math.floor(d/3600000),m=Math.floor((d%3600000)/60000);
    return `${h}h ${m}m`;
  }

  // ── Supabase Realtime subscription ────────────────────────
  // Live balance updates when payment_sessions table changes
  function initRealtime() {
    const anonKey = window.__SUPABASE_ANON_KEY__;
    const url     = window.__SUPABASE_URL__;
    if (!anonKey || !url) {
      document.getElementById('realtime-dot').textContent = '● offline';
      return;
    }

    // Simple Supabase Realtime via websocket
    const wsUrl = `${url.replace('https','wss')}/realtime/v1/websocket?apikey=${anonKey}&vsn=1.0.0`;
    const ws    = new WebSocket(wsUrl);
    let heartbeat;

    ws.onopen = () => {
      document.getElementById('realtime-dot').style.color = 'var(--teal)';
      document.getElementById('realtime-dot').textContent = '● live';

      // Subscribe to payment_sessions changes
      ws.send(JSON.stringify({
        topic: 'realtime:public:payment_sessions',
        event: 'phx_join',
        payload: { config: { broadcast: { self: false }, presence: { key: '' }, postgres_changes: [{ event: '*', schema: 'public', table: 'payment_sessions' }] } },
        ref: '1',
      }));

      heartbeat = setInterval(() => ws.send(JSON.stringify({ topic: 'phoenix', event: 'heartbeat', payload: {}, ref: '0' })), 25000);
    };

    ws.onmessage = (evt) => {
      try {
        const msg = JSON.parse(evt.data);
        if (msg.event === 'postgres_changes' || (msg.payload?.data?.type && ['INSERT','UPDATE'].includes(msg.payload.data.type))) {
          // Reload data when a payment session changes
          loadData();
        }
      } catch {}
    };

    ws.onerror = () => {
      document.getElementById('realtime-dot').textContent = '● error';
      document.getElementById('realtime-dot').style.color = 'var(--coral)';
    };

    ws.onclose = () => {
      clearInterval(heartbeat);
      document.getElementById('realtime-dot').textContent = '● disconnected';
      document.getElementById('realtime-dot').style.color = 'var(--text-hint)';
      // Reconnect after 5s
      setTimeout(initRealtime, 5000);
    };
  }

  // ── CSV export ─────────────────────────────────────────────
  async function exportCSV() {
    try {
      const [{ sessions }, { logs }] = await Promise.all([
        api.merchant.sessions(), api.merchant.releases(),
      ]);

      const rows = [
        ['Type','Date','Amount (AUDD)','Fee (AUDD)','Net (AUDD)','Status','Reference/TX','Message'],
        ...sessions.map(s => [
          'deposit',
          new Date(s.created_at).toISOString(),
          s.amount != null ? Number(s.amount).toFixed(4) : '',
          '', '',
          s.status,
          s.reference_key,
          s.message || '',
        ]),
        ...logs.map(r => [
          'release',
          new Date(r.released_at).toISOString(),
          Number(r.gross).toFixed(4),
          Number(r.fee).toFixed(4),
          Number(r.net).toFixed(4),
          r.status,
          r.tx_signature || '',
          '',
        ]),
      ];

      const csv  = rows.map(r => r.map(c => `"${String(c).replace(/"/g,'""')}"`).join(',')).join('\n');
      const blob = new Blob([csv], { type: 'text/csv' });
      const url  = URL.createObjectURL(blob);
      const a    = document.createElement('a');
      a.href     = url;
      a.download = `settl-payments-${new Date().toISOString().slice(0,10)}.csv`;
      a.click();
      URL.revokeObjectURL(url);
      toast.success('CSV exported!');
    } catch(err) { toast.error('Export failed: ' + err.message); }
  }

  async function loadData() {
    document.getElementById('s-next').textContent = nextRelease();
    try {
      const [{ sessions }, { logs }] = await Promise.all([
        api.merchant.sessions(), api.merchant.releases(),
      ]);

      const totalGross = logs.reduce((s,r)=>s+Number(r.gross||0),0);
      const totalNet   = logs.reduce((s,r)=>s+Number(r.net  ||0),0);
      const totalFee   = logs.reduce((s,r)=>s+Number(r.fee  ||0),0);
      document.getElementById('s-gross').textContent = totalGross.toFixed(4)+' AUDD';
      document.getElementById('s-net').textContent   = totalNet.toFixed(4)+' AUDD';
      document.getElementById('s-fee').textContent   = totalFee.toFixed(4)+' AUDD';

      const sb = document.getElementById('sess-tbody');
      sb.innerHTML = sessions.length ? sessions.map(s=>`<tr>
        <td style="font-weight:600;">${s.amount!=null?Number(s.amount).toFixed(2)+' AUDD':'Open'}</td>
        <td style="color:var(--text-muted);font-size:12px;max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${s.message||'—'}</td>
        <td><span class="badge ${s.status==='confirmed'?'badge-success':s.status==='pending'?'badge-pending':'badge-error'}">${s.status}</span></td>
        <td style="font-size:12px;color:var(--text-muted);">${new Date(s.created_at).toLocaleString()}</td>
        <td>
          <div style="display:flex;gap:6px;">
            <a href="/pages/checkout.html?ref=${s.reference_key}" target="_blank" class="btn btn-secondary btn-sm">Open</a>
            <button class="btn btn-secondary btn-sm" onclick="navigator.clipboard.writeText(location.origin+'/pages/checkout.html?ref=${s.reference_key}').then(()=>toast.success('Copied!'))">Copy</button>
          </div>
        </td>
      </tr>`).join('')
      : `<tr><td colspan="5" style="text-align:center;padding:24px;color:var(--text-hint);">No sessions yet — <a href="/pages/merchant/paylink.html">create one</a></td></tr>`;

      const rb = document.getElementById('rel-tbody');
      rb.innerHTML = logs.length ? logs.map(r=>`<tr>
        <td style="font-size:12px;">${new Date(r.released_at).toLocaleString()}</td>
        <td>${fmtA(r.gross)}</td>
        <td style="color:var(--text-muted);">${fmtA(r.fee)}</td>
        <td style="font-weight:600;color:var(--teal);">${fmtA(r.net)}</td>
        <td><span class="badge ${r.status==='success'?'badge-success':'badge-error'}">${r.status}</span></td>
        <td>${r.tx_signature?`<a href="${EX}${r.tx_signature}${CL}" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(r.tx_signature)}</a>`:'—'}</td>
      </tr>`).join('')
      : `<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">No releases yet — first at 6am UTC</td></tr>`;
    } catch(err) { console.error(err); }
  }

  // Inject Supabase config for Realtime (server renders this in a script tag via frontend serving)
  // We read from meta tags set by the app
  window.__SUPABASE_URL__      = ''; // Set from .env on build, or use inline config
  window.__SUPABASE_ANON_KEY__ = ''; // Set from .env on build

  // Try to get from a config endpoint
  fetch('/api/health').then(r=>r.json()).then(d=>{
    // Health endpoint can expose public config
  }).catch(()=>{});

  loadData();
  initRealtime();
  setInterval(()=>document.getElementById('s-next').textContent=nextRelease(), 60000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — health route updated to expose public Supabase config
# Frontend needs SUPABASE_URL + ANON_KEY for Realtime
# ═══════════════════════════════════════════════════════════
log "Updating health route to expose public Supabase config..."
cat > backend/src/routes/health.js << 'EOF'
const router = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try {
    const { error } = await supabase.from('users').select('count').limit(1);
    if (error) db = error.message;
  } catch { db = 'unreachable'; }

  res.json({
    status: 'ok',
    db,
    ts: new Date().toISOString(),
    // Public config for frontend Realtime (anon key is safe to expose)
    config: {
      supabase_url:      process.env.SUPABASE_URL || '',
      supabase_anon_key: process.env.SUPABASE_ANON_KEY || '',
    },
  });
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — update nav.js to include Phase 4 pages
# ═══════════════════════════════════════════════════════════
log "Updating nav with Phase 4 pages..."
cat > frontend/js/modules/nav.js << 'EOF'
const NAV = [
  { label: 'Dashboard',      href: '/pages/dashboard.html',           icon: '◈' },
  { label: 'Create payment', href: '/pages/merchant/paylink.html',    icon: '⊕' },
  { label: 'Payments',       href: '/pages/merchant/payments.html',   icon: '↑' },
  { label: 'Balance',        href: '/pages/merchant/balance.html',    icon: '$' },
  { label: 'Webhooks',       href: '/pages/merchant/webhooks.html',   icon: '⌁' },
  { label: 'API keys',       href: '/pages/merchant/apikeys.html',    icon: '⌘' },
  { label: 'Settings',       href: '/pages/merchant/settings.html',   icon: '⚙' },
];

function initSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (!sidebar) return;

  const user     = window.auth?.getUser();
  const merchant = window.auth?.getMerchant();
  const current  = window.location.pathname;

  sidebar.innerHTML = `
    <div class="sidebar-logo">
      <span>SETTL</span>
      <button class="modal-close" onclick="closeSidebar()" style="font-size:22px;display:block;" id="sb-close">×</button>
    </div>
    <div class="sidebar-section">Merchant</div>
    ${NAV.map(item => {
      const page   = item.href.split('/').pop();
      const active = current.endsWith(page);
      return `<a href="${item.href}" class="nav-item ${active?'active':''}" onclick="closeSidebar()">
        <span class="nav-icon">${item.icon}</span>${item.label}
      </a>`;
    }).join('')}
    <div class="sidebar-footer">
      <div class="sidebar-user-name">${user?.full_name || user?.email || ''}</div>
      <div class="sidebar-user-email">${user?.email || ''}</div>
      ${merchant ? `<div style="margin:6px 0;"><span class="badge ${merchant.is_active?'badge-success':'badge-pending'}">${merchant.is_active?'Active':'Setting up…'}</span></div>` : ''}
      <br/>
      <a href="#" onclick="handleLogout()" style="font-size:12px;color:var(--text-hint);">Sign out</a>
    </div>`;

  if (overlay) overlay.onclick = closeSidebar;

  // Load Supabase config for Realtime
  fetch('/api/health').then(r=>r.json()).then(d=>{
    if (d.config?.supabase_url)      window.__SUPABASE_URL__      = d.config.supabase_url;
    if (d.config?.supabase_anon_key) window.__SUPABASE_ANON_KEY__ = d.config.supabase_anon_key;
  }).catch(()=>{});
}

function openSidebar()  { document.getElementById('sidebar')?.classList.add('open');    document.getElementById('sidebar-overlay')?.classList.add('show'); }
function closeSidebar() { document.getElementById('sidebar')?.classList.remove('open'); document.getElementById('sidebar-overlay')?.classList.remove('show'); }

async function handleLogout() {
  try { await window.api.auth.logout(); } catch {}
  window.auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.initSidebar  = initSidebar;
window.openSidebar  = openSidebar;
window.closeSidebar = closeSidebar;
window.handleLogout = handleLogout;
EOF

# ═══════════════════════════════════════════════════════════
# INSTALL new dependencies
# ═══════════════════════════════════════════════════════════
log "Installing new dependencies (nodemailer)..."
cd backend
if command -v yarn &>/dev/null; then
  yarn install --silent
else
  npm install --silent
fi
cd ..

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Phase 4 — Complete                               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What was added:${NC}"
echo ""
echo -e "  ${GREEN}①${NC} Webhooks"
echo -e "     /api/webhooks — CRUD for endpoint configs"
echo -e "     HMAC-SHA256 signed: X-SETTL-Signature header"
echo -e "     Retry: 3 attempts, 1s/3s/9s backoff"
echo -e "     Events: deposit.confirmed, release.completed"
echo -e "     Full delivery log per endpoint"
echo -e "     Test event button to verify your endpoint"
echo ""
echo -e "  ${GREEN}②${NC} API keys"
echo -e "     /api/apikeys — generate, list, revoke"
echo -e "     Format: sk_live_<32 hex chars>"
echo -e "     Stored as bcrypt hash — never retrievable"
echo -e "     /api/pay/charge — create session with x-api-key"
echo -e "     /api/pay/status/:ref — poll status (no auth)"
echo ""
echo -e "  ${GREEN}③${NC} Supabase Realtime"
echo -e "     Payments page subscribes to payment_sessions changes"
echo -e "     Table reloads automatically when new payment confirmed"
echo -e "     Live dot indicator (● live / ● disconnected)"
echo -e "     Health endpoint exposes anon key for frontend"
echo ""
echo -e "  ${GREEN}④${NC} CSV export"
echo -e "     ⬇ Export CSV button on payments page"
echo -e "     Includes deposits + releases in one file"
echo -e "     Date-stamped filename"
echo ""
echo -e "  ${GREEN}⑤${NC} Email notifications (optional)"
echo -e "     On deposit.confirmed → email with amount + tx link"
echo -e "     On release.completed → email with gross/fee/net"
echo -e "     Deduplicated — never sent twice for same event"
echo -e "     Set SMTP_HOST in .env to enable, leave blank to skip"
echo ""
echo -e "  ${GREEN}⑥${NC} Session expiry cleanup"
echo -e "     Cron runs every hour"
echo -e "     Marks pending sessions older than 30 min as expired"
echo ""
echo -e "  ${BLUE}Setup steps:${NC}"
echo ""
echo -e "  1. Run ${YELLOW}supabase/migrations/002_phase4_webhooks_apikeys.sql${NC}"
echo -e "     in Supabase SQL editor"
echo ""
echo -e "  2. Enable Realtime in Supabase dashboard:"
echo -e "     ${YELLOW}Database → Replication → Tables → enable payment_sessions + escrows${NC}"
echo ""
echo -e "  3. Add to ${YELLOW}settl/.env${NC}:"
echo -e "     ${YELLOW}WEBHOOK_SECRET=<openssl rand -hex 32>${NC}"
echo -e "     ${YELLOW}SUPABASE_ANON_KEY=<your anon key>${NC}"
echo -e "     ${YELLOW}SMTP_HOST=... (optional for emails)${NC}"
echo ""
echo -e "  4. ${YELLOW}yarn dev${NC}"
echo ""
echo -e "  ${BLUE}Test webhooks:${NC}"
echo -e "  Use ${YELLOW}https://webhook.site${NC} as your endpoint URL to see"
echo -e "  live requests with headers and payload."
echo ""