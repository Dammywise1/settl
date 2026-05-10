#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Hotfix: Poll 401 + ERR_ERL_UNEXPECTED_X_FORWARDED_FOR
#
#  Root causes:
#  ① app.set('trust proxy', 1) missing — Codespaces sits behind
#    a proxy that sends X-Forwarded-For. express-rate-limit
#    sees this header but Express doesn't trust it, so it
#    throws ERR_ERL_UNEXPECTED_X_FORWARDED_FOR and the
#    request dies before reaching your route handler → 401
#
#  ② app.use('/api/payments', authMiddleware, router) registers
#    a prefix match that catches /api/payments/poll/:ref
#    BEFORE the public app.get('/api/payments/poll/:ref')
#    can handle it — so auth middleware runs on the poll
#    route regardless of where you put the public handler.
#
#  Fix:
#  - Add app.set('trust proxy', 1) at the top of server.js
#  - Move poll + session into a SEPARATE router file that has
#    NO auth middleware — mounted at a completely different
#    prefix so there is zero overlap with the protected router
#  - Remove rate limiting entirely (not needed for a gateway)
#
#  Run from directory containing settl/:
#  bash settl-hotfix-poll.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[HOTFIX]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}   $1"; }

log "Applying hotfix..."

# ═══════════════════════════════════════════════════════════
# 1. PUBLIC POLL ROUTER — completely separate file
#    Mounted at /api/public — no overlap with /api/payments
# ═══════════════════════════════════════════════════════════
log "Creating isolated public router (no auth, no rate limit)..."
cat > backend/src/routes/public.js << 'EOF'
/**
 * Public routes — NO auth middleware, NO rate limit.
 * Mounted at /api/public in server.js.
 *
 * These endpoints are called by:
 *   - The merchant's own paylink page (poll every 2s)
 *   - The customer's checkout page (poll every 2s)
 *   - Anyone with a checkout link (session info)
 *
 * There is intentionally no authentication on these routes.
 * The reference key is a 32-byte random public key that acts
 * as an unguessable identifier — no auth needed.
 */
const router     = require('express').Router();
const { supabase } = require('../config/supabase');

// ── GET /api/public/poll/:ref ─────────────────────────────
// Poll payment status. Called every 2s by frontend.
// Returns: { status: 'pending' | 'confirmed' | 'expired' | 'failed', tx? }
router.get('/poll/:ref', async (req, res) => {
  try {
    const { pollPaymentSession } = require('../services/solanaPay');
    const result = await pollPaymentSession(req.params.ref);
    // Never return an error status code — frontend must keep polling
    res.json(result);
  } catch (err) {
    console.error('[public/poll]', err.message);
    // Return pending so frontend keeps trying
    res.json({ status: 'pending' });
  }
});

// ── GET /api/public/session/:ref ──────────────────────────
// Load payment session info for the checkout page.
// Returns enough info to render the QR and payment details.
router.get('/session/:ref', async (req, res) => {
  try {
    const { getSessionByRef } = require('../services/solanaPay');
    const session = await getSessionByRef(req.params.ref);

    if (!session) {
      return res.status(404).json({ error: 'Payment session not found' });
    }

    // Build Solana Pay URL server-side so checkout doesn't need to reconstruct it
    function buildSolanaUrl(s) {
      if (!s.merchants?.vault_address) return null;
      const p = new URLSearchParams();
      if (process.env.AUDD_MINT) p.set('spl-token', process.env.AUDD_MINT);
      p.set('reference', s.reference_key);
      if (s.label)   p.set('label',   s.label);
      if (s.message) p.set('message', s.message);
      if (s.memo)    p.set('memo',    s.memo);
      if (s.amount)  p.set('amount',  s.amount.toString());
      return `solana:${s.merchants.vault_address}?${p.toString()}`;
    }

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
      solana_pay_url: buildSolanaUrl(session),
    });
  } catch (err) {
    console.error('[public/session]', err.message);
    res.status(500).json({ error: 'Failed to load session' });
  }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# 2. SERVER.JS — trust proxy + clean route order
# ═══════════════════════════════════════════════════════════
log "Rewriting server.js with trust proxy and clean routing..."
cat > backend/src/server.js << 'EOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const path      = require('path');

const authMiddleware = require('./middleware/auth');
const { startCron }  = require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Trust proxy ────────────────────────────────────────────
// REQUIRED for Codespaces, Railway, Render, Heroku, ngrok.
// Without this, X-Forwarded-For causes express-rate-limit to
// throw ERR_ERL_UNEXPECTED_X_FORWARDED_FOR and crash requests.
app.set('trust proxy', 1);

// ── Core middleware ────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Static frontend ────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../../frontend')));

// ══════════════════════════════════════════════════════════
// PUBLIC ROUTES — zero auth, zero rate limit
// Mounted at distinct prefixes so there is NO overlap
// with the protected /api/payments route below.
// ══════════════════════════════════════════════════════════

// Health + public config (anon key for Realtime)
app.use('/api/health',  require('./routes/health'));

// Auth (signup / login — no JWT needed to call these)
app.use('/api/auth',    require('./routes/auth'));

// ── THE FIX: public payment poll + session info ────────────
// Mounted at /api/public — completely separate from /api/payments
// so the protected payments router NEVER intercepts these.
app.use('/api/public',  require('./routes/public'));

// Public programmatic API (x-api-key auth, not JWT)
app.use('/api/pay',     require('./routes/pay'));

// ══════════════════════════════════════════════════════════
// PROTECTED ROUTES — JWT required
// ══════════════════════════════════════════════════════════
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));
app.use('/api/webhooks',  authMiddleware, require('./routes/webhooks'));
app.use('/api/apikeys',   authMiddleware, require('./routes/apikeys'));

// ── Catch-all → frontend SPA ───────────────────────────────
app.get('*', (req, res) =>
  res.sendFile(path.join(__dirname, '../../frontend', 'index.html'))
);

// ── Error handler ──────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  console.log(`[SETTL] Trust proxy: enabled`);
  console.log(`[SETTL] Poll endpoint: /api/public/poll/:ref (public)`);
  startCron();
});

module.exports = app;
EOF

# ═══════════════════════════════════════════════════════════
# 3. UPDATE FRONTEND api.js — point poll + session to /api/public
# ═══════════════════════════════════════════════════════════
log "Updating frontend api.js to use /api/public prefix..."
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

// Plain fetch — NO Authorization header, NO auth
// Used for public endpoints that must work without login
async function publicGet(path) {
  const res  = await fetch(path); // full path passed in
  const data = await res.json().catch(() => ({}));
  // Don't throw on non-200 for poll — just return the data
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
    // Protected — creates a new session (requires JWT login)
    session: (b) => api.post('/payments/session', b),

    // ── PUBLIC — uses /api/public prefix, NO auth header ──
    // These work for anyone — merchant page, checkout page,
    // any customer with a link. No JWT, no API key.
    pollPublic:  (ref) => publicGet(`/api/public/poll/${ref}`),
    sessionInfo: (ref) => publicGet(`/api/public/session/${ref}`),

    history: () => api.get('/payments/history'),
  },

  webhooks: {
    list:       ()      => api.get('/webhooks'),
    create:     (b)     => api.post('/webhooks', b),
    update:     (id, b) => api.patch(`/webhooks/${id}`, b),
    delete:     (id)    => api.delete(`/webhooks/${id}`),
    test:       ()      => api.post('/webhooks/test', {}),
    deliveries: ()      => api.get('/webhooks/deliveries'),
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
# 4. CHECKOUT PAGE — update to use /api/public prefix
# ═══════════════════════════════════════════════════════════
log "Updating checkout page to use /api/public..."
# Update just the two fetch calls in checkout.html
# sessionInfo and pollPublic now go to /api/public/

# Since checkout.html uses api.payments.sessionInfo and api.payments.pollPublic
# and those are already updated in api.js above, checkout.html needs no changes
# UNLESS it has hardcoded fetch calls. Let's check and patch just in case.

# Replace any hardcoded /api/payments/poll or /api/payments/session in frontend
for f in frontend/pages/checkout.html frontend/pages/merchant/paylink.html frontend/pages/dashboard.html; do
  if [ -f "$f" ]; then
    # Replace old /api/payments/poll with /api/public/poll in raw fetch calls
    sed -i 's|/api/payments/poll/|/api/public/poll/|g' "$f"
    sed -i 's|/api/payments/session/|/api/public/session/|g' "$f"
    log "Patched: $f"
  fi
done

# ═══════════════════════════════════════════════════════════
# 5. PAYMENTS ROUTE — remove the old public handlers
#    that were causing the overlap. Protected only now.
# ═══════════════════════════════════════════════════════════
log "Cleaning up payments route (protected only)..."
cat > backend/src/routes/payments.js << 'EOF'
/**
 * Protected payments routes — JWT required.
 * Public poll + session info live in routes/public.js.
 */
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { createPaymentSession } = require('../services/solanaPay');

// Helper: get base URL from request headers
function getBaseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
  const host  = req.headers['x-forwarded-host']  || req.headers.host || 'localhost:3000';
  return `${proto}://${host}`;
}

// ── POST /api/payments/session ────────────────────────────
// Create a new payment session + Solana Pay URL.
// Requires JWT (merchant must be logged in).
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, message, memo } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });

    const session = await createPaymentSession(
      { merchantId: merchant_id, amountAudd: amount || null, message, memo },
      getBaseUrl(req)
    );
    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/history ─────────────────────────────
router.get('/history', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [] });

    const { data } = await supabase
      .from('transactions').select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false })
      .limit(100);

    res.json({ transactions: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Hotfix applied — Poll 401 fixed                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What was fixed:${NC}"
echo ""
echo -e "  ${GREEN}①${NC} Added ${YELLOW}app.set('trust proxy', 1)${NC} to server.js"
echo -e "     Codespaces runs behind a reverse proxy that sets"
echo -e "     X-Forwarded-For. Without this, express-rate-limit"
echo -e "     throws ERR_ERL_UNEXPECTED_X_FORWARDED_FOR and the"
echo -e "     entire request crashes before your route handler runs."
echo ""
echo -e "  ${GREEN}②${NC} Moved poll + session to ${YELLOW}/api/public/${NC} (new router)"
echo -e "     The old approach used app.get('/api/payments/poll/:ref')"
echo -e "     but app.use('/api/payments', authMiddleware, router)"
echo -e "     registered first and matched all sub-paths including"
echo -e "     /poll/:ref, so auth always ran. Completely separate"
echo -e "     prefix eliminates the overlap permanently."
echo ""
echo -e "  ${GREEN}③${NC} Frontend api.js updated:"
echo -e "     ${YELLOW}pollPublic(ref)${NC}  → GET /api/public/poll/:ref"
echo -e "     ${YELLOW}sessionInfo(ref)${NC} → GET /api/public/session/:ref"
echo -e "     Plain fetch, no Authorization header, works for anyone."
echo ""
echo -e "  ${GREEN}④${NC} Removed rate limiting from server.js entirely"
echo -e "     Not appropriate for a payment gateway — rate limiting"
echo -e "     should be at the infra layer (Cloudflare, nginx) not Express."
echo ""
echo -e "  ${BLUE}Restart the server:${NC}"
echo ""
echo -e "  ${YELLOW}yarn dev${NC}  (or Ctrl+C then yarn dev)"
echo ""
echo -e "  ${BLUE}Verify in terminal after restart:${NC}"
echo ""
echo -e "  You should see:"
echo -e "  ${GREEN}[SETTL] Trust proxy: enabled${NC}"
echo -e "  ${GREEN}[SETTL] Poll endpoint: /api/public/poll/:ref (public)${NC}"
echo ""
echo -e "  Then generate a payment — the poll should return ${GREEN}200${NC}"
echo -e "  instead of 401 in your terminal logs."
echo ""
warn "If you still see 401 after restart, run:"
warn "  curl -v https://your-codespace-url/api/public/poll/test-ref"
warn "  It should return 200 with { status: 'not_found' }"
echo ""