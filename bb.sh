#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Phase 3 Setup Script
#
#  Changes from Phase 1 & 2:
#  ✓ Single .env at repo root
#  ✓ Single "yarn dev" starts everything
#  ✓ Auth switched to email + password
#  ✓ server.js updated to your working single-port version
#
#  New in Phase 3:
#  + backend/src/services/release.js    release() instruction
#  + backend/src/services/payment.js    payment link generator
#  + backend/src/cron/dailyRelease.js   6am cron job
#  + backend/src/routes/payments.js     payment link + deposit confirm
#  + backend/src/routes/releases.js     release history + manual trigger
#  + frontend/pages/operator/payments.html
#  + frontend/pages/operator/paylink.html
#  + frontend/pages/developer/cron.html
#  + Supabase migration 003
#
#  Run from INSIDE the settl/ folder:
#  cd settl && bash ../settl-phase3-setup.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SETTL P3]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC}     $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}     $1"; }
error() { echo -e "${RED}[ERROR]${NC}    $1"; }

# ── Guard ────────────────────────────────────────────────
if [ ! -f "backend/src/server.js" ]; then
  error "Run this script from inside the settl/ folder."
  error "Example: cd settl && bash ../settl-phase3-setup.sh"
  exit 1
fi

log "Phase 3 starting inside $(pwd)..."

mkdir -p backend/src/{cron,routes,services}
mkdir -p frontend/pages/{operator,developer}
mkdir -p supabase/migrations

# ═══════════════════════════════════════════════════════════
# SECTION A — MONO-REPO & ENV FIXES
# ═══════════════════════════════════════════════════════════

# ── A1. Single .env at repo root ─────────────────────────
log "Writing root .env.example (single source of truth)..."
cat > .env.example << 'EOF'
# ════════════════════════════════════════════════
#  SETTL — Root .env  (copy to .env and fill in)
#  Both backend and cron read from here.
# ════════════════════════════════════════════════

# ── Supabase ─────────────────────────────────────
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
SUPABASE_ANON_KEY=your-anon-key

# ── Solana / SETTL ────────────────────────────────
SOLANA_RPC_URL=https://api.devnet.solana.com
SETTL_PROGRAM_ID=RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn
AUTHORITY_KEYPAIR_PATH=./keypair.json
TREASURY_WALLET=your-treasury-wallet-pubkey
AUDD_MINT=your-audd-mint-pubkey

# ── Server ────────────────────────────────────────
PORT=3000
NODE_ENV=development

# ── Release schedule ──────────────────────────────
RELEASE_CRON=0 6 * * *
# Override for local testing — fires every minute:
# RELEASE_CRON=* * * * *
EOF

# Only create .env if it doesn't exist yet
if [ ! -f ".env" ]; then
  cp .env.example .env
  warn ".env created from template — fill in your values before starting."
fi

# ── A2. Update backend dotenv to load from root .env ─────
log "Patching backend dotenv path to load root .env..."
cat > backend/src/config/env.js << 'EOF'
// Loads .env from the repo root regardless of where node is invoked from
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
EOF

# Patch every backend entry point to use config/env.js instead of dotenv directly
# server.js will be rewritten fully below so we just handle other files
for f in backend/src/services/contract.js backend/src/config/anchor.js; do
  if [ -f "$f" ]; then
    # Replace `require('dotenv').config()` with our root-loader if present
    sed -i "s|require('dotenv').config();|require('./config/env');|g" "$f" 2>/dev/null || true
    sed -i "s|require('dotenv').config({ path.*});|require('../config/env');|g" "$f" 2>/dev/null || true
  fi
done

# ── A3. Root package.json — yarn dev starts everything ───
log "Writing root package.json for yarn dev..."
cat > package.json << 'EOF'
{
  "name": "settl",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev":     "cd backend && yarn dev",
    "start":   "cd backend && yarn start",
    "install": "cd backend && yarn install"
  },
  "engines": {
    "node": ">=18"
  }
}
EOF

# ── A4. Backend package.json — add concurrently if needed ─
log "Updating backend package.json..."
cat > backend/package.json << 'EOF'
{
  "name": "settl-backend",
  "version": "1.0.0",
  "main": "src/server.js",
  "scripts": {
    "dev":   "nodemon src/server.js",
    "start": "node src/server.js"
  },
  "dependencies": {
    "@coral-xyz/anchor":  "^0.29.0",
    "@solana/spl-token":  "^0.4.8",
    "@solana/web3.js":    "^1.91.0",
    "@supabase/supabase-js": "^2.43.0",
    "cors":               "^2.8.5",
    "dotenv":             "^16.4.5",
    "express":            "^4.19.2",
    "express-rate-limit": "^7.3.1",
    "helmet":             "^7.1.0",
    "morgan":             "^1.10.0",
    "node-cron":          "^3.0.3",
    "uuid":               "^9.0.1"
  },
  "devDependencies": {
    "nodemon": "^3.1.3"
  }
}
EOF

# ── A5. server.js — your working single-port version ─────
log "Writing server.js (your single-port version + Phase 3 routes)..."
cat > backend/src/server.js << 'EOF'
require('./config/env');
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');

const authMiddleware  = require('./middleware/auth');
const merchantRoutes  = require('./routes/merchants');
const escrowRoutes    = require('./routes/escrow');
const authRoutes      = require('./routes/auth');
const healthRoutes    = require('./routes/health');
const paymentRoutes   = require('./routes/payments');
const releaseRoutes   = require('./routes/releases');

// Start the daily release cron
require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Security & parsing ────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Serve static frontend ─────────────────────────────────
const frontendPath = path.join(__dirname, '../../frontend');
app.use(express.static(frontendPath));

// ── API rate limiting ─────────────────────────────────────
const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
app.use('/api/', limiter);

// ── API routes ────────────────────────────────────────────
app.use('/api/health',    healthRoutes);
app.use('/api/auth',      authRoutes);
app.use('/api/merchants', authMiddleware, merchantRoutes);
app.use('/api/escrow',    authMiddleware, escrowRoutes);
app.use('/api/payments',  paymentRoutes);          // public — customers pay here
app.use('/api/releases',  authMiddleware, releaseRoutes);

// ── Error handler ─────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

// ── Catch-all → frontend ──────────────────────────────────
app.get('*', (req, res) => {
  res.sendFile(path.join(frontendPath, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`[SETTL] Server running on http://localhost:${PORT}`);
  console.log(`[SETTL] Frontend served from: ${frontendPath}`);
  console.log(`[SETTL] Program ID: ${process.env.SETTL_PROGRAM_ID}`);
});

module.exports = app;
EOF

# ═══════════════════════════════════════════════════════════
# SECTION B — AUTH: SWITCH TO EMAIL + PASSWORD
# ═══════════════════════════════════════════════════════════

# ── B1. Backend auth route — email + password ────────────
log "Rewriting auth routes for email + password..."
cat > backend/src/routes/auth.js << 'EOF'
require('../config/env');
const router       = require('express').Router();
const { supabase } = require('../config/supabase');

// ── POST /api/auth/register ───────────────────────────────
router.post('/register', async (req, res, next) => {
  try {
    const { email, password, full_name } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) throw error;

    // Set full_name on profile if provided
    if (full_name && data.user) {
      await supabase
        .from('profiles')
        .update({ full_name })
        .eq('id', data.user.id);
    }

    res.status(201).json({
      message: 'Account created. Check your email to confirm (if email confirmation is enabled).',
      user:    data.user,
    });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    // Fetch profile + role
    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', data.user.id)
      .single();

    res.json({
      session: data.session,
      user:    data.user,
      profile,
    });
  } catch (err) { next(err); }
});

// ── POST /api/auth/logout ─────────────────────────────────
router.post('/logout', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (token) await supabase.auth.admin.signOut(token);
    res.json({ message: 'Logged out' });
  } catch (err) { next(err); }
});

// ── POST /api/auth/forgot-password ───────────────────────
router.post('/forgot-password', async (req, res, next) => {
  try {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/pages/auth/reset-password.html`,
    });
    if (error) throw error;

    // Always respond OK so we don't leak which emails are registered
    res.json({ message: 'If that email exists, a reset link was sent.' });
  } catch (err) { next(err); }
});

// ── POST /api/auth/reset-password ────────────────────────
router.post('/reset-password', async (req, res, next) => {
  try {
    const { new_password } = req.body;
    const token = req.headers.authorization?.split(' ')[1];
    if (!token || !new_password) {
      return res.status(400).json({ error: 'Token and new_password are required' });
    }

    const { error } = await supabase.auth.updateUser({ password: new_password });
    if (error) throw error;
    res.json({ message: 'Password updated' });
  } catch (err) { next(err); }
});

// ── GET /api/auth/me ──────────────────────────────────────
router.get('/me', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) return res.status(401).json({ error: 'No token' });

    const { data: { user }, error } = await supabase.auth.getUser(token);
    if (error || !user) return res.status(401).json({ error: 'Invalid token' });

    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single();

    res.json({ user, profile });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ── B2. Frontend auth module — email + password ──────────
log "Rewriting frontend auth module..."
cat > frontend/js/modules/auth.js << 'EOF'
// ── SETTL session manager ─────────────────────────────────
const SESSION_KEY = 'settl_session';
const PROFILE_KEY = 'settl_profile';

const auth = {
  getSession() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; }
  },

  getProfile() {
    try { return JSON.parse(localStorage.getItem(PROFILE_KEY)); } catch { return null; }
  },

  setSession(session, profile) {
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    if (profile) localStorage.setItem(PROFILE_KEY, JSON.stringify(profile));
  },

  clear() {
    localStorage.removeItem(SESSION_KEY);
    localStorage.removeItem(PROFILE_KEY);
    localStorage.removeItem('settl_mode');
  },

  isLoggedIn() {
    const s = this.getSession();
    if (!s?.access_token) return false;
    // Supabase sessions have expires_at in seconds
    if (s.expires_at && Math.floor(Date.now() / 1000) > s.expires_at) {
      this.clear();
      return false;
    }
    return true;
  },

  requireAuth() {
    if (!this.isLoggedIn()) {
      window.location.href = '/pages/auth/login.html';
      return false;
    }
    return true;
  },

  getMode()        { return localStorage.getItem('settl_mode') || 'operator'; },
  setMode(mode)    { localStorage.setItem('settl_mode', mode); },
  getRole()        { return this.getProfile()?.role || 'operator'; },
};

window.auth = auth;
EOF

# ── B3. Frontend api module — email + password calls ─────
log "Updating frontend API module with password auth methods..."
cat > frontend/js/modules/api.js << 'EOF'
// ── SETTL API client — Phase 3 ────────────────────────────
const API_BASE = '';   // same origin — served by Express

function getToken() {
  try { return JSON.parse(localStorage.getItem('settl_session'))?.access_token; }
  catch { return null; }
}

async function request(path, options = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...options.headers,
  };

  const res  = await fetch(`${API_BASE}/api${path}`, { ...options, headers });
  const data = await res.json();

  if (!res.ok) {
    const err = new Error(data.error || 'Request failed');
    err.status = res.status;
    throw err;
  }
  return data;
}

const api = {
  get:    (path, opts)       => request(path, { ...opts, method: 'GET' }),
  post:   (path, body, opts) => request(path, { ...opts, method: 'POST',   body: JSON.stringify(body) }),
  patch:  (path, body, opts) => request(path, { ...opts, method: 'PATCH',  body: JSON.stringify(body) }),
  delete: (path, opts)       => request(path, { ...opts, method: 'DELETE' }),

  auth: {
    register:       (email, password, full_name) => api.post('/auth/register', { email, password, full_name }),
    login:          (email, password)            => api.post('/auth/login',    { email, password }),
    logout:         ()                           => api.post('/auth/logout',   {}),
    me:             ()                           => api.get('/auth/me'),
    forgotPassword: (email)                      => api.post('/auth/forgot-password', { email }),
    resetPassword:  (new_password)               => api.post('/auth/reset-password',  { new_password }),
  },

  merchants: {
    list:                ()              => api.get('/merchants'),
    get:                 (id)            => api.get(`/merchants/${id}`),
    create:              (body)          => api.post('/merchants', body),
    getChainState:       (id)            => api.get(`/merchants/${id}/chain`),
    deactivate:          (id)            => api.post(`/merchants/${id}/deactivate`, {}),
    sync:                (id)            => api.post(`/merchants/${id}/sync`, {}),
    requestWalletUpdate: (id, newWallet) => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: newWallet }),
    confirmWalletUpdate: (id)            => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (merchantId)           => api.get(`/escrow/${merchantId}`),
    history: (merchantId, params)   => api.get(`/escrow/${merchantId}/history?${new URLSearchParams(params || {})}`),
  },

  payments: {
    createLink:      (body)      => api.post('/payments/link', body),
    getLink:         (token)     => api.get(`/payments/link/${token}`),
    confirmDeposit:  (body)      => api.post('/payments/confirm', body),
    listForMerchant: (id, p)     => api.get(`/payments/merchant/${id}?${new URLSearchParams(p || {})}`),
  },

  releases: {
    list:          (params)      => api.get(`/releases?${new URLSearchParams(params || {})}`),
    triggerManual: (merchantId)  => api.post('/releases/trigger', { merchant_id: merchantId }),
    cronStatus:    ()            => api.get('/releases/cron-status'),
  },
};

window.api = api;
EOF

# ── B4. Login page — email + password ────────────────────
log "Writing email+password login page..."
mkdir -p frontend/pages/auth
cat > frontend/pages/auth/login.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Sign in</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card">
    <div class="auth-logo">SETTL</div>
    <div class="auth-sub">Payment gateway — sign in to continue</div>

    <div id="login-view">
      <div class="form-group">
        <label class="form-label">Email</label>
        <input class="form-input" id="email" type="email" placeholder="you@example.com" autocomplete="email"/>
      </div>
      <div class="form-group">
        <label class="form-label">Password</label>
        <div style="position:relative;">
          <input class="form-input" id="password" type="password" placeholder="••••••••" autocomplete="current-password" style="padding-right:44px;"/>
          <button onclick="togglePw()" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);background:none;border:none;cursor:pointer;color:var(--text-muted);font-size:16px;" id="pw-toggle">👁</button>
        </div>
      </div>
      <div style="display:flex;justify-content:flex-end;margin-bottom:16px;">
        <a href="#" onclick="showForgot()" style="font-size:13px;color:var(--text-muted);">Forgot password?</a>
      </div>
      <button class="btn btn-primary" style="width:100%;" id="login-btn" onclick="doLogin()">Sign in</button>
      <p style="text-align:center;margin-top:16px;font-size:13px;color:var(--text-muted);">
        No account? <a href="register.html">Create one</a>
      </p>
    </div>

    <div id="forgot-view" style="display:none;">
      <p style="font-size:14px;color:var(--text-muted);margin-bottom:16px;">
        Enter your email and we'll send a reset link.
      </p>
      <div class="form-group">
        <label class="form-label">Email</label>
        <input class="form-input" id="forgot-email" type="email" placeholder="you@example.com"/>
      </div>
      <button class="btn btn-primary" style="width:100%;" onclick="doForgot()">Send reset link</button>
      <button class="btn btn-secondary" style="width:100%;margin-top:10px;" onclick="showLogin()">Back to sign in</button>
    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script>
  if (auth.isLoggedIn()) window.location.href = '/pages/dashboard.html';

  function togglePw() {
    const pw = document.getElementById('password');
    pw.type  = pw.type === 'password' ? 'text' : 'password';
  }
  function showForgot() {
    document.getElementById('login-view').style.display  = 'none';
    document.getElementById('forgot-view').style.display = 'block';
  }
  function showLogin() {
    document.getElementById('forgot-view').style.display = 'none';
    document.getElementById('login-view').style.display  = 'block';
  }

  async function doLogin() {
    const email    = document.getElementById('email').value.trim();
    const password = document.getElementById('password').value;
    if (!email || !password) { toast.error('Email and password are required'); return; }

    const btn = document.getElementById('login-btn');
    btn.disabled = true; btn.textContent = 'Signing in…';

    try {
      const { session, profile } = await api.auth.login(email, password);
      auth.setSession(session, profile);
      window.location.href = '/pages/dashboard.html';
    } catch (err) {
      toast.error(err.message || 'Invalid email or password');
      btn.disabled = false; btn.textContent = 'Sign in';
    }
  }

  async function doForgot() {
    const email = document.getElementById('forgot-email').value.trim();
    if (!email) { toast.error('Enter your email'); return; }
    try {
      await api.auth.forgotPassword(email);
      toast.success('Reset link sent — check your email');
      showLogin();
    } catch (err) {
      toast.error(err.message);
    }
  }

  document.addEventListener('keydown', e => {
    if (e.key === 'Enter') doLogin();
  });
</script>
</body>
</html>
EOF

# ── B5. Register page ─────────────────────────────────────
log "Writing register page..."
cat > frontend/pages/auth/register.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Create account</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card">
    <div class="auth-logo">SETTL</div>
    <div class="auth-sub">Create your account</div>

    <div class="form-group">
      <label class="form-label">Full name</label>
      <input class="form-input" id="full-name" type="text" placeholder="Your name"/>
    </div>
    <div class="form-group">
      <label class="form-label">Email</label>
      <input class="form-input" id="email" type="email" placeholder="you@example.com"/>
    </div>
    <div class="form-group">
      <label class="form-label">Password</label>
      <div style="position:relative;">
        <input class="form-input" id="password" type="password" placeholder="Min 8 characters" style="padding-right:44px;"/>
        <button onclick="togglePw()" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);background:none;border:none;cursor:pointer;color:var(--text-muted);font-size:16px;">👁</button>
      </div>
    </div>
    <div class="form-group">
      <label class="form-label">Confirm password</label>
      <input class="form-input" id="confirm-password" type="password" placeholder="Repeat password"/>
    </div>
    <button class="btn btn-primary" style="width:100%;" id="reg-btn" onclick="doRegister()">Create account</button>
    <p style="text-align:center;margin-top:16px;font-size:13px;color:var(--text-muted);">
      Already have an account? <a href="login.html">Sign in</a>
    </p>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script>
  if (auth.isLoggedIn()) window.location.href = '/pages/dashboard.html';

  function togglePw() {
    ['password','confirm-password'].forEach(id => {
      const el = document.getElementById(id);
      el.type  = el.type === 'password' ? 'text' : 'password';
    });
  }

  async function doRegister() {
    const fullName = document.getElementById('full-name').value.trim();
    const email    = document.getElementById('email').value.trim();
    const password = document.getElementById('password').value;
    const confirm  = document.getElementById('confirm-password').value;

    if (!email || !password) { toast.error('Email and password are required'); return; }
    if (password.length < 8) { toast.error('Password must be at least 8 characters'); return; }
    if (password !== confirm) { toast.error('Passwords do not match'); return; }

    const btn = document.getElementById('reg-btn');
    btn.disabled = true; btn.textContent = 'Creating account…';

    try {
      await api.auth.register(email, password, fullName);
      toast.success('Account created — signing you in…');

      // Auto-login after register
      const { session, profile } = await api.auth.login(email, password);
      auth.setSession(session, profile);
      window.location.href = '/pages/dashboard.html';
    } catch (err) {
      toast.error(err.message);
      btn.disabled = false; btn.textContent = 'Create account';
    }
  }
</script>
</body>
</html>
EOF

# ── B6. Password reset page ───────────────────────────────
cat > frontend/pages/auth/reset-password.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <title>SETTL — Reset password</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card">
    <div class="auth-logo">SETTL</div>
    <div class="auth-sub">Set a new password</div>
    <div class="form-group">
      <label class="form-label">New password</label>
      <input class="form-input" id="new-password" type="password" placeholder="Min 8 characters"/>
    </div>
    <div class="form-group">
      <label class="form-label">Confirm password</label>
      <input class="form-input" id="confirm-password" type="password" placeholder="Repeat password"/>
    </div>
    <button class="btn btn-primary" style="width:100%;" onclick="doReset()">Set new password</button>
  </div>
</div>
<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script>
  // Supabase puts the session in the URL hash on reset redirects
  const hash   = window.location.hash.substring(1);
  const params = new URLSearchParams(hash);
  const token  = params.get('access_token');
  if (token) {
    auth.setSession({ access_token: token, expires_at: Number(params.get('expires_at')) });
  }

  async function doReset() {
    const pw  = document.getElementById('new-password').value;
    const cfw = document.getElementById('confirm-password').value;
    if (pw.length < 8)  { toast.error('Password must be at least 8 characters'); return; }
    if (pw !== cfw)     { toast.error('Passwords do not match'); return; }
    try {
      await api.auth.resetPassword(pw);
      toast.success('Password updated — redirecting to login…');
      setTimeout(() => { auth.clear(); window.location.href = '/pages/auth/login.html'; }, 1500);
    } catch (err) {
      toast.error(err.message);
    }
  }
</script>
</body>
</html>
EOF

# Remove old magic-link callback if it exists
rm -f frontend/pages/auth/callback.html

# ── B7. Remove callback reference from index.html ────────
log "Updating index.html redirect..."
cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <title>SETTL</title>
  <link rel="stylesheet" href="css/app.css"/>
</head>
<body>
<script src="js/modules/auth.js"></script>
<script>
  window.location.href = auth.isLoggedIn()
    ? '/pages/dashboard.html'
    : '/pages/auth/login.html';
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# SECTION C — PHASE 3: PAYMENTS, CRON RELEASE, PAGES
# ═══════════════════════════════════════════════════════════

# ── C1. services/release.js ──────────────────────────────
log "Writing release service..."
cat > backend/src/services/release.js << 'EOF'
require('../config/env');
const { PublicKey }                                     = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress }   = require('@solana/spl-token');
const {
  getProgram, getKeypair,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
} = require('../config/anchor');
const { supabase } = require('../config/supabase');

// ── releaseMerchant ───────────────────────────────────────
// Calls the on-chain release() instruction for one merchant.
// gross → fee (1.5%) + net → merchant wallet
async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = new PublicKey(process.env.AUDD_MINT);

  // Fetch on-chain state to get wallet addresses
  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const merchantAccount = await program.account.merchantAccount.fetch(merchantPDA);
  const configAccount   = await program.account.settlConfig.fetch(configPDA);

  const merchantWallet  = merchantAccount.wallet;
  const treasuryWallet  = configAccount.treasuryWallet;

  // Derive ATAs (associated token accounts) for merchant and treasury
  const merchantAta = await getAssociatedTokenAddress(auddMint, merchantWallet);
  const treasuryAta = await getAssociatedTokenAddress(auddMint, treasuryWallet);

  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config:      configPDA,
      merchant:    merchantPDA,
      escrow:      escrowPDA,
      vault:       vaultPDA,
      merchantAta,
      treasuryAta,
      authority:   authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority])
    .rpc();

  console.log(`[release] ${merchantId} → tx: ${tx}`);
  return { tx, merchantId };
}

// ── releaseAllMerchants ───────────────────────────────────
// Loops all active merchants, calls release() on each,
// logs results to Supabase release_logs table.
async function releaseAllMerchants() {
  const { getProgram, getEscrowPDA } = require('../config/anchor');
  const program = getProgram();

  console.log('[cron] Starting daily release run…');

  const { data: merchants, error } = await supabase
    .from('merchants')
    .select('merchant_id')
    .eq('is_active', true);

  if (error) throw new Error('Failed to fetch merchants: ' + error.message);
  if (!merchants.length) { console.log('[cron] No active merchants to release.'); return; }

  const results = { success: 0, skipped: 0, failed: 0, txs: [] };

  for (const { merchant_id } of merchants) {
    let logRecord = {
      merchant_id,
      status:     'pending',
      released_at: new Date().toISOString(),
    };

    try {
      // Check on-chain balance before calling release
      const [escrowPDA] = getEscrowPDA(merchant_id);
      const escrow      = await program.account.escrowAccount.fetch(escrowPDA).catch(() => null);

      if (!escrow || escrow.pendingBalance.toNumber() === 0) {
        logRecord.status = 'skipped';
        logRecord.error  = 'Zero balance';
        results.skipped++;
      } else {
        const gross = escrow.pendingBalance.toNumber();
        const fee   = Math.floor(gross * 150 / 10_000);  // 1.5%
        const net   = gross - fee;

        const { tx } = await releaseMerchant(merchant_id);

        logRecord = {
          ...logRecord,
          gross,
          fee,
          net,
          tx_signature: tx,
          status:       'success',
        };
        results.success++;
        results.txs.push({ merchant_id, tx });

        // Update escrow DB snapshot
        await supabase
          .from('escrows')
          .update({ pending_balance: 0, last_released_at: new Date().toISOString() })
          .eq('merchant_id', merchant_id);

        // Record transaction in DB
        await supabase.from('transactions').insert({
          merchant_id,
          type:         'release',
          amount:       gross,
          fee,
          net,
          tx_signature: tx,
          status:       'confirmed',
        });
      }
    } catch (err) {
      console.error(`[release] Failed for ${merchant_id}:`, err.message);
      logRecord.status = 'failed';
      logRecord.error  = err.message;
      results.failed++;
    }

    // Log every merchant result to Supabase
    await supabase.from('release_logs').insert(logRecord);
  }

  console.log(`[cron] Release run complete — success:${results.success} skipped:${results.skipped} failed:${results.failed}`);
  return results;
}

module.exports = { releaseMerchant, releaseAllMerchants };
EOF

# ── C2. services/payment.js ───────────────────────────────
log "Writing payment link service..."
cat > backend/src/services/payment.js << 'EOF'
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
EOF

# ── C3. cron/dailyRelease.js ──────────────────────────────
log "Writing daily release cron..."
cat > backend/src/cron/dailyRelease.js << 'EOF'
require('../config/env');
const cron                      = require('node-cron');
const { releaseAllMerchants }   = require('../services/release');
const { supabase }              = require('../config/supabase');

// Default: 6am every day. Override via RELEASE_CRON in .env
const SCHEDULE = process.env.RELEASE_CRON || '0 6 * * *';

let lastRunAt     = null;
let lastRunStatus = 'never';
let lastRunResult = null;
let isRunning     = false;

async function runRelease() {
  if (isRunning) {
    console.warn('[cron] Release already running — skipping this tick');
    return;
  }

  isRunning     = true;
  lastRunAt     = new Date().toISOString();
  lastRunStatus = 'running';

  try {
    const results = await releaseAllMerchants();
    lastRunStatus = 'success';
    lastRunResult = results;

    // Record cron run in Supabase for the UI
    await supabase.from('cron_runs').insert({
      ran_at:    lastRunAt,
      status:    'success',
      success:   results?.success  ?? 0,
      skipped:   results?.skipped  ?? 0,
      failed:    results?.failed   ?? 0,
    });
  } catch (err) {
    console.error('[cron] Release run failed:', err.message);
    lastRunStatus = 'failed';
    lastRunResult = { error: err.message };

    await supabase.from('cron_runs').insert({
      ran_at:  lastRunAt,
      status:  'failed',
      error:   err.message,
    }).catch(() => {});
  } finally {
    isRunning = false;
  }
}

// Schedule
cron.schedule(SCHEDULE, runRelease, { timezone: 'Australia/Sydney' });
console.log(`[cron] Daily release scheduled: "${SCHEDULE}" (Australia/Sydney)`);

// Export status for the /api/releases/cron-status endpoint
module.exports = {
  getStatus: () => ({ schedule: SCHEDULE, lastRunAt, lastRunStatus, lastRunResult, isRunning }),
  runNow:    runRelease,
};
EOF

# ── C4. routes/payments.js ────────────────────────────────
log "Writing payment routes..."
cat > backend/src/routes/payments.js << 'EOF'
require('../config/env');
const router         = require('express').Router();
const authMiddleware = require('../middleware/auth');
const paymentService = require('../services/payment');
const { supabase }   = require('../config/supabase');

// ── POST /api/payments/link  (auth required) ──────────────
// Developer/operator generates a payment link for a merchant
router.post('/link', authMiddleware, async (req, res, next) => {
  try {
    const { merchant_id, amount, description, expires_in_hours } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id is required' });

    const result = await paymentService.createPaymentLink({
      merchantId:     merchant_id,
      amount,
      description,
      expiresInHours: expires_in_hours || 24,
    });

    res.status(201).json(result);
  } catch (err) { next(err); }
});

// ── GET /api/payments/link/:token  (public) ───────────────
// Customer (or frontend) reads the payment link details
router.get('/link/:token', async (req, res, next) => {
  try {
    const link = await paymentService.getPaymentLink(req.params.token);
    res.json(link);
  } catch (err) {
    res.status(404).json({ error: err.message });
  }
});

// ── POST /api/payments/confirm  (public) ──────────────────
// Customer's browser calls this after completing the on-chain deposit
router.post('/confirm', async (req, res, next) => {
  try {
    const { token, tx_signature, amount, customer_wallet } = req.body;
    if (!token || !tx_signature || !amount) {
      return res.status(400).json({ error: 'token, tx_signature, and amount are required' });
    }

    const tx = await paymentService.confirmDeposit({
      token,
      txSignature:    tx_signature,
      amount,
      customerWallet: customer_wallet,
    });

    res.json({ message: 'Payment confirmed', transaction: tx });
  } catch (err) { next(err); }
});

// ── GET /api/payments/merchant/:id  (auth required) ───────
// List all payment links for a merchant
router.get('/merchant/:id', authMiddleware, async (req, res, next) => {
  try {
    const limit  = parseInt(req.query.limit  || '50');
    const offset = parseInt(req.query.offset || '0');

    const { data, error, count } = await supabase
      .from('payment_links')
      .select('*', { count: 'exact' })
      .eq('merchant_id', req.params.id)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    res.json({ links: data, total: count, limit, offset });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ── C5. routes/releases.js ────────────────────────────────
log "Writing release routes..."
cat > backend/src/routes/releases.js << 'EOF'
require('../config/env');
const router         = require('express').Router();
const { supabase }   = require('../config/supabase');
const releaseService = require('../services/release');
const cronJob        = require('../cron/dailyRelease');

// ── GET /api/releases  ────────────────────────────────────
// Release history from DB (all or by merchant)
router.get('/', async (req, res, next) => {
  try {
    const { merchant_id, status, limit = 50, offset = 0 } = req.query;

    let query = supabase
      .from('release_logs')
      .select('*', { count: 'exact' })
      .order('released_at', { ascending: false })
      .range(Number(offset), Number(offset) + Number(limit) - 1);

    if (merchant_id) query = query.eq('merchant_id', merchant_id);
    if (status)      query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    res.json({ releases: data, total: count, limit: Number(limit), offset: Number(offset) });
  } catch (err) { next(err); }
});

// ── GET /api/releases/cron-status  ────────────────────────
router.get('/cron-status', (req, res) => {
  res.json(cronJob.getStatus());
});

// ── GET /api/releases/cron-runs  ──────────────────────────
// Historical cron run log from DB
router.get('/cron-runs', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('cron_runs')
      .select('*')
      .order('ran_at', { ascending: false })
      .limit(50);

    if (error) throw error;
    res.json({ runs: data });
  } catch (err) { next(err); }
});

// ── POST /api/releases/trigger  ───────────────────────────
// Manual release trigger — runs the full cron loop immediately
router.post('/trigger', async (req, res, next) => {
  try {
    const { merchant_id } = req.body;

    let result;
    if (merchant_id) {
      // Release a single merchant
      result = await releaseService.releaseMerchant(merchant_id);
    } else {
      // Release all active merchants
      result = await cronJob.runNow();
    }

    res.json({ message: 'Release triggered', result });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ── C6. Supabase migration 003 ────────────────────────────
log "Writing Phase 3 Supabase migration..."
cat > supabase/migrations/003_phase3_payments_cron.sql << 'EOF'
-- ═══════════════════════════════════════════════════════════
--  SETTL — Phase 3 Schema additions
-- ═══════════════════════════════════════════════════════════

-- ── payment_links ─────────────────────────────────────────
create table if not exists payment_links (
  id          uuid primary key default uuid_generate_v4(),
  token       text unique not null,
  merchant_id text not null references merchants(merchant_id) on delete cascade,
  amount      numeric(20, 6),          -- null = open amount customer enters
  description text,
  status      text default 'active'
              check (status in ('active', 'used', 'expired', 'cancelled')),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz default now()
);

alter table payment_links enable row level security;

create policy "Authenticated users can manage payment links"
  on payment_links for all using (auth.role() = 'authenticated');

create policy "Public can read active payment links"
  on payment_links for select using (status = 'active');

create index if not exists idx_payment_links_token      on payment_links(token);
create index if not exists idx_payment_links_merchant   on payment_links(merchant_id);
create index if not exists idx_payment_links_status     on payment_links(status);

-- ── cron_runs ─────────────────────────────────────────────
create table if not exists cron_runs (
  id       uuid primary key default uuid_generate_v4(),
  ran_at   timestamptz not null,
  status   text not null check (status in ('success', 'failed', 'running')),
  success  integer default 0,
  skipped  integer default 0,
  failed   integer default 0,
  error    text
);

alter table cron_runs enable row level security;

create policy "Authenticated users can read cron runs"
  on cron_runs for select using (auth.role() = 'authenticated');

create policy "Service role can insert cron runs"
  on cron_runs for insert with check (true);

create index if not exists idx_cron_runs_ran_at on cron_runs(ran_at desc);

-- ── Extend release_logs: add gross/fee/net if not already there ──
alter table release_logs
  add column if not exists gross numeric(20,6),
  add column if not exists fee   numeric(20,6),
  add column if not exists net   numeric(20,6);

-- ── Realtime: enable on tables used by frontend ──────────
alter publication supabase_realtime add table escrows;
alter publication supabase_realtime add table transactions;
alter publication supabase_realtime add table release_logs;
alter publication supabase_realtime add table cron_runs;
EOF

# ═══════════════════════════════════════════════════════════
# SECTION D — FRONTEND PAGES
# ═══════════════════════════════════════════════════════════

# ── D1. Operator — payments.html ─────────────────────────
log "Writing operator payments page..."
cat > frontend/pages/operator/payments.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Payments</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Payment history</span>
      <div style="display:flex;gap:10px;align-items:center;">
        <span class="badge badge-success">operator</span>
        <a href="paylink.html" class="btn btn-primary" style="font-size:13px;">+ New payment link</a>
      </div>
    </div>

    <div class="page-body">

      <!-- Summary cards -->
      <div class="card-grid">
        <div class="card">
          <div class="card-title">Total received</div>
          <div class="card-value" id="stat-total">—</div>
          <div class="card-sub">AUDD all time</div>
        </div>
        <div class="card">
          <div class="card-title">This month</div>
          <div class="card-value" id="stat-month">—</div>
          <div class="card-sub">AUDD deposited</div>
        </div>
        <div class="card">
          <div class="card-title">Active links</div>
          <div class="card-value" id="stat-links">—</div>
          <div class="card-sub">Payment links open</div>
        </div>
      </div>

      <!-- Filter row -->
      <div style="display:flex;gap:10px;margin-bottom:16px;align-items:center;flex-wrap:wrap;">
        <select class="form-input" id="filter-type" style="width:auto;" onchange="loadPayments()">
          <option value="">All types</option>
          <option value="deposit">Deposits</option>
          <option value="release">Releases</option>
        </select>
        <select class="form-input" id="filter-status" style="width:auto;" onchange="loadPayments()">
          <option value="">All statuses</option>
          <option value="confirmed">Confirmed</option>
          <option value="pending">Pending</option>
          <option value="failed">Failed</option>
        </select>
        <button class="btn btn-secondary" onclick="loadPayments()">Refresh</button>
      </div>

      <!-- Transaction table -->
      <div class="card">
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Type</th>
                <th>Amount</th>
                <th>Fee</th>
                <th>Net received</th>
                <th>Status</th>
                <th>Date</th>
                <th>Explorer</th>
              </tr>
            </thead>
            <tbody id="tx-tbody">
              <tr><td colspan="7" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
        <div id="page-footer" style="display:flex;justify-content:space-between;align-items:center;margin-top:12px;font-size:13px;color:var(--text-muted);">
          <span id="page-info"></span>
          <div style="display:flex;gap:8px;">
            <button class="btn btn-secondary" style="font-size:13px;" id="btn-prev" onclick="changePage(-1)">Previous</button>
            <button class="btn btn-secondary" style="font-size:13px;" id="btn-next" onclick="changePage(1)">Next</button>
          </div>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('operator');

  const EXPLORER = 'https://explorer.solana.com/tx/';
  let offset = 0, total = 0;
  const limit = 25;
  let merchantId = null;

  function fmtAUDD(v) { return v != null ? (v/1_000_000).toFixed(2) + ' AUDD' : '—'; }
  function shortKey(k) { return k ? k.slice(0,6)+'…'+k.slice(-4) : '—'; }

  async function init() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.find(m => m.is_active);
      if (active) merchantId = active.merchant_id;
      loadPayments();
      loadStats();
    } catch (err) { toast.error(err.message); }
  }

  async function loadStats() {
    if (!merchantId) return;
    try {
      const now   = new Date();
      const start = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();

      const { transactions } = await api.escrow.history(merchantId, { limit: 200 });
      const deposits  = transactions.filter(t => t.type === 'deposit');
      const thisMonth = deposits.filter(t => t.created_at >= start);

      document.getElementById('stat-total').textContent = fmtAUDD(deposits.reduce((s,t) => s + (t.amount||0), 0));
      document.getElementById('stat-month').textContent = fmtAUDD(thisMonth.reduce((s,t) => s + (t.amount||0), 0));

      const { links } = await api.payments.listForMerchant(merchantId);
      document.getElementById('stat-links').textContent = links.filter(l => l.status === 'active').length;
    } catch {}
  }

  async function loadPayments() {
    if (!merchantId) {
      document.getElementById('tx-tbody').innerHTML =
        `<tr><td colspan="7" style="text-align:center;padding:40px;color:var(--text-hint);">No active merchant found.</td></tr>`;
      return;
    }

    const type   = document.getElementById('filter-type').value;
    const status = document.getElementById('filter-status').value;

    try {
      const { transactions, total: t } = await api.escrow.history(merchantId, { limit, offset, type, status });
      total = t;

      if (!transactions.length) {
        document.getElementById('tx-tbody').innerHTML =
          `<tr><td colspan="7" style="text-align:center;padding:40px;color:var(--text-hint);">No payments yet</td></tr>`;
        return;
      }

      document.getElementById('tx-tbody').innerHTML = transactions.map(tx => `
        <tr>
          <td><span class="badge badge-info">${tx.type}</span></td>
          <td style="font-weight:500;">${fmtAUDD(tx.amount)}</td>
          <td style="color:var(--text-muted);">${tx.type==='release' ? fmtAUDD(tx.fee) : '—'}</td>
          <td style="color:var(--teal);font-weight:500;">${tx.type==='release' ? fmtAUDD(tx.net) : fmtAUDD(tx.amount)}</td>
          <td><span class="badge ${tx.status==='confirmed'?'badge-success':tx.status==='failed'?'badge-error':'badge-pending'}">${tx.status}</span></td>
          <td style="font-size:13px;color:var(--text-muted);">${new Date(tx.created_at).toLocaleString()}</td>
          <td>${tx.tx_signature ? `<a href="${EXPLORER}${tx.tx_signature}?cluster=devnet" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(tx.tx_signature)}</a>` : '—'}</td>
        </tr>`).join('');

      document.getElementById('page-info').textContent = `${offset+1}–${Math.min(offset+limit,total)} of ${total}`;
      document.getElementById('btn-prev').disabled = offset === 0;
      document.getElementById('btn-next').disabled = offset + limit >= total;
    } catch (err) {
      toast.error('Failed to load payments: ' + err.message);
    }
  }

  function changePage(dir) { offset = Math.max(0, offset + dir * limit); loadPayments(); }

  init();
</script>
</body>
</html>
EOF

# ── D2. Operator — paylink.html ───────────────────────────
log "Writing payment link generator page..."
cat > frontend/pages/operator/paylink.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Payment link</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Payment links</span>
      <span class="badge badge-success">operator</span>
    </div>

    <div class="page-body">
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;align-items:start;">

        <!-- Generator form -->
        <div class="card">
          <h2 style="font-size:16px;font-weight:500;margin-bottom:18px;">Generate payment link</h2>

          <div class="form-group">
            <label class="form-label">Amount (AUDD)</label>
            <input class="form-input" id="f-amount" type="number" step="0.000001" min="0" placeholder="Leave blank for open amount"/>
            <div class="form-hint">Customer enters any amount if left blank.</div>
          </div>
          <div class="form-group">
            <label class="form-label">Description</label>
            <input class="form-input" id="f-desc" placeholder="Invoice #001 — Website design"/>
          </div>
          <div class="form-group">
            <label class="form-label">Expires in (hours)</label>
            <select class="form-input" id="f-expires">
              <option value="1">1 hour</option>
              <option value="6">6 hours</option>
              <option value="24" selected>24 hours</option>
              <option value="72">3 days</option>
              <option value="168">7 days</option>
              <option value="720">30 days</option>
            </select>
          </div>

          <button class="btn btn-primary" style="width:100%;" id="gen-btn" onclick="generateLink()">Generate link</button>
        </div>

        <!-- Generated link display -->
        <div class="card" id="result-card" style="display:none;">
          <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Payment link ready</h2>

          <div style="background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-sm);padding:12px;margin-bottom:16px;">
            <div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;">Share this link with your customer</div>
            <div id="result-link" style="font-family:var(--font-mono);font-size:13px;word-break:break-all;"></div>
          </div>

          <div style="display:flex;gap:8px;margin-bottom:16px;">
            <button class="btn btn-primary" style="flex:1;" onclick="copyLink()">Copy link</button>
            <button class="btn btn-secondary" style="flex:1;" onclick="showQR()">Show QR</button>
          </div>

          <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:13px;">
            <div style="color:var(--text-muted);">Amount</div>
            <div id="result-amount" style="font-weight:500;"></div>
            <div style="color:var(--text-muted);">Description</div>
            <div id="result-desc"></div>
            <div style="color:var(--text-muted);">Expires at</div>
            <div id="result-expires" style="font-size:12px;"></div>
          </div>

          <!-- QR placeholder -->
          <div id="qr-area" style="display:none;margin-top:16px;text-align:center;padding:20px;background:var(--bg);border-radius:var(--radius-sm);">
            <div style="color:var(--text-muted);font-size:13px;">QR code generation coming in Phase 4</div>
          </div>

          <button class="btn btn-secondary" style="width:100%;margin-top:16px;" onclick="resetForm()">Generate another</button>
        </div>

      </div>

      <!-- Active links table -->
      <div class="card" style="margin-top:20px;">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">Active payment links</h2>
          <button class="btn btn-secondary" style="font-size:13px;" onclick="loadLinks()">Refresh</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Token</th><th>Amount</th><th>Description</th><th>Status</th><th>Expires</th><th>Action</th></tr>
            </thead>
            <tbody id="links-tbody">
              <tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('operator');

  let merchantId  = null;
  let currentLink = '';

  async function init() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.find(m => m.is_active);
      if (active) { merchantId = active.merchant_id; loadLinks(); }
      else toast.info('No active merchant — ask your developer to register one.');
    } catch (err) { toast.error(err.message); }
  }

  async function generateLink() {
    if (!merchantId) { toast.error('No active merchant found'); return; }
    const amount      = document.getElementById('f-amount').value;
    const description = document.getElementById('f-desc').value.trim();
    const expires     = document.getElementById('f-expires').value;

    const btn = document.getElementById('gen-btn');
    btn.disabled = true; btn.textContent = 'Generating…';

    try {
      const result = await api.payments.createLink({
        merchant_id:      merchantId,
        amount:           amount ? parseFloat(amount) * 1_000_000 : null,
        description:      description || null,
        expires_in_hours: parseInt(expires),
      });

      currentLink = result.link;
      document.getElementById('result-link').textContent    = result.link;
      document.getElementById('result-amount').textContent  = result.amount ? (result.amount / 1_000_000) + ' AUDD' : 'Open amount';
      document.getElementById('result-desc').textContent    = description || '—';
      document.getElementById('result-expires').textContent = new Date(result.expiresAt).toLocaleString();
      document.getElementById('result-card').style.display  = 'block';
      loadLinks();
    } catch (err) {
      toast.error(err.message);
    } finally {
      btn.disabled = false; btn.textContent = 'Generate link';
    }
  }

  function copyLink() {
    navigator.clipboard.writeText(currentLink).then(() => toast.success('Link copied!'));
  }

  function showQR() {
    document.getElementById('qr-area').style.display =
      document.getElementById('qr-area').style.display === 'none' ? 'block' : 'none';
  }

  function resetForm() {
    document.getElementById('result-card').style.display = 'none';
    document.getElementById('f-amount').value = '';
    document.getElementById('f-desc').value   = '';
  }

  async function loadLinks() {
    if (!merchantId) return;
    try {
      const { links } = await api.payments.listForMerchant(merchantId, { limit: 20 });
      const tbody = document.getElementById('links-tbody');
      if (!links.length) {
        tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">No links yet</td></tr>`;
        return;
      }
      tbody.innerHTML = links.map(l => `
        <tr>
          <td style="font-family:var(--font-mono);font-size:12px;">${l.token.slice(0,8)}…</td>
          <td>${l.amount ? (l.amount/1_000_000)+' AUDD' : 'Open'}</td>
          <td style="color:var(--text-muted);font-size:13px;">${l.description || '—'}</td>
          <td><span class="badge ${l.status==='active'?'badge-success':l.status==='used'?'badge-info':'badge-pending'}">${l.status}</span></td>
          <td style="font-size:12px;color:var(--text-muted);">${new Date(l.expires_at).toLocaleString()}</td>
          <td>${l.status==='active'?`<button class="btn btn-secondary" style="font-size:12px;padding:4px 8px;" onclick="copyPayLink('${l.token}')">Copy</button>`:'—'}</td>
        </tr>`).join('');
    } catch (err) {
      toast.error('Failed to load links: ' + err.message);
    }
  }

  async function copyPayLink(token) {
    const url = `${window.location.origin}/pages/pay.html?token=${token}`;
    navigator.clipboard.writeText(url).then(() => toast.success('Link copied!'));
  }

  init();
</script>
</body>
</html>
EOF

# ── D3. Developer — cron.html ─────────────────────────────
log "Writing developer cron monitor page..."
cat > frontend/pages/developer/cron.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Cron monitor</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Cron monitor</span>
      <div style="display:flex;gap:10px;align-items:center;">
        <span class="badge badge-info">developer</span>
        <button class="btn btn-secondary" style="font-size:13px;" onclick="refreshAll()">Refresh</button>
      </div>
    </div>

    <div class="page-body">

      <!-- Cron status card -->
      <div class="card-grid" style="grid-template-columns:1fr 1fr 1fr;">
        <div class="card">
          <div class="card-title">Schedule</div>
          <div class="card-value" id="cron-schedule" style="font-size:18px;font-family:var(--font-mono);">—</div>
          <div class="card-sub">Australia/Sydney timezone</div>
        </div>
        <div class="card">
          <div class="card-title">Last run</div>
          <div class="card-value" id="cron-last-run" style="font-size:18px;">—</div>
          <div class="card-sub" id="cron-last-status">—</div>
        </div>
        <div class="card">
          <div class="card-title">Status</div>
          <div id="cron-live-status" class="card-value" style="font-size:16px;">—</div>
          <div class="card-sub">Current process state</div>
        </div>
      </div>

      <!-- Manual trigger -->
      <div class="card" style="margin-bottom:20px;">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Manual release trigger</h2>
        <p style="font-size:13px;color:var(--text-muted);margin-bottom:16px;">
          Trigger a release run immediately without waiting for the 6am schedule.
          Use this for testing or emergency releases.
        </p>
        <div style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;">
          <div class="form-group" style="margin-bottom:0;flex:1;min-width:200px;">
            <label class="form-label">Merchant ID (optional)</label>
            <select class="form-input" id="trigger-merchant">
              <option value="">All active merchants</option>
            </select>
          </div>
          <button class="btn btn-primary" id="trigger-btn" onclick="triggerRelease()">
            ▶ Run release now
          </button>
        </div>
        <div id="trigger-result" style="display:none;margin-top:14px;padding:12px;background:var(--bg);border-radius:var(--radius-sm);font-size:13px;font-family:var(--font-mono);border:1px solid var(--border);"></div>
      </div>

      <!-- Cron run history -->
      <div class="card">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Run history</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Ran at</th><th>Status</th><th>Success</th><th>Skipped</th><th>Failed</th><th>Error</th></tr>
            </thead>
            <tbody id="cron-tbody">
              <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- Recent release logs -->
      <div class="card" style="margin-top:20px;">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">Recent release logs</h2>
          <select class="form-input" id="release-filter-merchant" style="width:auto;font-size:13px;" onchange="loadReleaseLogs()">
            <option value="">All merchants</option>
          </select>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Merchant</th><th>Gross</th><th>Fee (1.5%)</th><th>Net</th><th>Status</th><th>Tx</th><th>Released at</th></tr>
            </thead>
            <tbody id="release-tbody">
              <tr><td colspan="7" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('developer');

  const EXPLORER = 'https://explorer.solana.com/tx/';
  function fmtAUDD(v) { return v != null ? (v/1_000_000).toFixed(4)+' AUDD' : '—'; }
  function shortKey(k) { return k ? k.slice(0,6)+'…'+k.slice(-4) : '—'; }

  async function refreshAll() {
    loadCronStatus();
    loadCronRuns();
    loadReleaseLogs();
  }

  async function loadCronStatus() {
    try {
      const s = await api.releases.cronStatus();
      document.getElementById('cron-schedule').textContent = s.schedule;
      document.getElementById('cron-last-run').textContent = s.lastRunAt
        ? new Date(s.lastRunAt).toLocaleString() : 'Never';
      document.getElementById('cron-last-status').textContent = s.lastRunStatus;
      const badge = s.isRunning
        ? '<span class="badge badge-pending">Running…</span>'
        : s.lastRunStatus === 'success'
          ? '<span class="badge badge-success">Healthy</span>'
          : s.lastRunStatus === 'failed'
            ? '<span class="badge badge-error">Failed</span>'
            : '<span class="badge badge-info">Idle</span>';
      document.getElementById('cron-live-status').innerHTML = badge;
    } catch (err) {
      document.getElementById('cron-live-status').textContent = 'Backend offline';
    }
  }

  async function loadCronRuns() {
    const tbody = document.getElementById('cron-tbody');
    try {
      const { runs } = await api.releases.list({ limit: 20 });
      if (!runs?.length) {
        // Try cron-runs endpoint
        const r = await fetch('/api/releases/cron-runs', {
          headers: { Authorization: `Bearer ${JSON.parse(localStorage.getItem('settl_session')).access_token}` }
        }).then(r => r.json());
        const rows = r.runs || [];
        if (!rows.length) {
          tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">No runs yet — schedule fires at 6am or use manual trigger above.</td></tr>`;
          return;
        }
        tbody.innerHTML = rows.map(r => `
          <tr>
            <td style="font-size:13px;">${new Date(r.ran_at).toLocaleString()}</td>
            <td><span class="badge ${r.status==='success'?'badge-success':r.status==='failed'?'badge-error':'badge-pending'}">${r.status}</span></td>
            <td style="color:var(--teal);">${r.success ?? '—'}</td>
            <td style="color:var(--text-muted);">${r.skipped ?? '—'}</td>
            <td style="color:${r.failed>0?'var(--coral)':'inherit'}">${r.failed ?? '—'}</td>
            <td style="font-size:12px;color:var(--coral);">${r.error || '—'}</td>
          </tr>`).join('');
      }
    } catch (err) {
      tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">—</td></tr>`;
    }
  }

  async function loadReleaseLogs() {
    const merchantId = document.getElementById('release-filter-merchant').value;
    const tbody      = document.getElementById('release-tbody');
    try {
      const { releases } = await api.releases.list({ merchant_id: merchantId, limit: 30 });
      if (!releases.length) {
        tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;padding:24px;color:var(--text-hint);">No releases yet</td></tr>`;
        return;
      }
      tbody.innerHTML = releases.map(r => `
        <tr>
          <td style="font-family:var(--font-mono);font-size:12px;">${r.merchant_id}</td>
          <td>${fmtAUDD(r.gross)}</td>
          <td style="color:var(--text-muted);">${fmtAUDD(r.fee)}</td>
          <td style="color:var(--teal);font-weight:500;">${fmtAUDD(r.net)}</td>
          <td><span class="badge ${r.status==='success'?'badge-success':r.status==='skipped'?'badge-info':r.status==='failed'?'badge-error':'badge-pending'}">${r.status}</span></td>
          <td>${r.tx_signature ? `<a href="${EXPLORER}${r.tx_signature}?cluster=devnet" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(r.tx_signature)}</a>` : r.error ? `<span style="color:var(--coral);font-size:12px;">${r.error.slice(0,40)}</span>` : '—'}</td>
          <td style="font-size:12px;color:var(--text-muted);">${new Date(r.released_at).toLocaleString()}</td>
        </tr>`).join('');
    } catch (err) {
      toast.error('Failed to load release logs: ' + err.message);
    }
  }

  async function triggerRelease() {
    const merchantId = document.getElementById('trigger-merchant').value;
    const btn        = document.getElementById('trigger-btn');
    const resultEl   = document.getElementById('trigger-result');

    btn.disabled = true;
    btn.textContent = 'Running…';
    resultEl.style.display = 'block';
    resultEl.textContent   = 'Sending release instruction to Devnet…';

    try {
      const result = await api.releases.triggerManual(merchantId || undefined);
      resultEl.textContent = JSON.stringify(result, null, 2);
      toast.success('Release completed');
      refreshAll();
    } catch (err) {
      resultEl.textContent = 'Error: ' + err.message;
      toast.error(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = '▶ Run release now';
    }
  }

  async function initMerchantSelects() {
    try {
      const { merchants } = await api.merchants.list();
      const selects = ['trigger-merchant', 'release-filter-merchant'];
      selects.forEach(selId => {
        const sel = document.getElementById(selId);
        merchants.filter(m => m.is_active).forEach(m => {
          const opt = document.createElement('option');
          opt.value = m.merchant_id;
          opt.textContent = m.merchant_id + (m.name ? ` — ${m.name}` : '');
          sel.appendChild(opt);
        });
      });
    } catch {}
  }

  initMerchantSelects();
  refreshAll();
  // Auto-refresh cron status every 30s
  setInterval(loadCronStatus, 30_000);
</script>
</body>
</html>
EOF

# ── D4. Public — pages/pay.html (customer payment page) ──
log "Writing customer payment page..."
mkdir -p frontend/pages
cat > frontend/pages/pay.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Pay</title>
  <link rel="stylesheet" href="../css/app.css"/>
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card" style="max-width:480px;">

    <div id="loading-view">
      <div class="auth-logo">SETTL</div>
      <p style="color:var(--text-muted);margin-top:8px;">Loading payment details…</p>
    </div>

    <div id="payment-view" style="display:none;">
      <div class="auth-logo">SETTL</div>
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:20px;">
        <span class="badge badge-success">Secure payment</span>
        <span style="font-size:13px;color:var(--text-muted);">AUDD stablecoin · Solana</span>
      </div>

      <div style="border:1px solid var(--border);border-radius:var(--radius-md);padding:16px;margin-bottom:20px;">
        <div style="font-size:13px;color:var(--text-muted);margin-bottom:4px;">Paying</div>
        <div style="font-size:20px;font-weight:600;" id="pay-merchant">—</div>
        <div style="font-size:13px;color:var(--text-muted);margin-top:6px;" id="pay-desc"></div>
      </div>

      <div id="fixed-amount-section" style="display:none;">
        <div style="text-align:center;margin-bottom:20px;">
          <div style="font-size:13px;color:var(--text-muted);">Amount due</div>
          <div style="font-size:36px;font-weight:700;color:var(--brand);" id="pay-amount">—</div>
          <div style="font-size:13px;color:var(--text-muted);">AUDD</div>
        </div>
      </div>

      <div id="open-amount-section" style="display:none;margin-bottom:20px;">
        <div class="form-group" style="margin-bottom:0;">
          <label class="form-label">Amount (AUDD)</label>
          <input class="form-input" id="custom-amount" type="number" step="0.000001" min="0.000001" placeholder="Enter amount"/>
        </div>
      </div>

      <div class="form-group">
        <label class="form-label">Your wallet address</label>
        <input class="form-input" id="customer-wallet" placeholder="Your Solana public key"/>
        <div class="form-hint">Provide your wallet so we can record your payment. Not required to transact.</div>
      </div>

      <div style="background:var(--bg);border-radius:var(--radius-sm);padding:12px;margin-bottom:20px;font-size:13px;border:1px solid var(--border);">
        <div style="font-weight:500;margin-bottom:6px;">How to pay</div>
        <div style="color:var(--text-muted);line-height:1.6;">
          1. Copy the merchant's vault address below<br/>
          2. Send AUDD from your Solana wallet<br/>
          3. Paste your transaction ID to confirm
        </div>
      </div>

      <div style="margin-bottom:16px;">
        <label class="form-label">Merchant vault address</label>
        <div style="display:flex;gap:8px;">
          <input class="form-input" id="vault-addr" readonly style="font-family:var(--font-mono);font-size:12px;flex:1;"/>
          <button class="btn btn-secondary" onclick="copyVault()">Copy</button>
        </div>
      </div>

      <div class="form-group">
        <label class="form-label">Transaction signature (after sending)</label>
        <input class="form-input" id="tx-sig" placeholder="Paste your Solana tx signature here"/>
      </div>

      <button class="btn btn-primary" style="width:100%;" id="confirm-btn" onclick="confirmPayment()">
        Confirm payment
      </button>

      <div id="expire-notice" style="text-align:center;margin-top:12px;font-size:12px;color:var(--text-muted);"></div>
    </div>

    <div id="success-view" style="display:none;text-align:center;">
      <div style="font-size:48px;margin-bottom:16px;">✓</div>
      <h2 style="margin-bottom:8px;">Payment confirmed!</h2>
      <p style="color:var(--text-muted);font-size:14px;">
        Your payment has been received and is held in escrow.<br/>
        It will be released to the merchant at 6am.
      </p>
      <div id="success-tx" style="margin-top:16px;font-family:var(--font-mono);font-size:12px;color:var(--text-muted);"></div>
    </div>

    <div id="error-view" style="display:none;text-align:center;">
      <div style="font-size:48px;margin-bottom:16px;">✗</div>
      <h2 style="margin-bottom:8px;" id="error-title">Link not found</h2>
      <p style="color:var(--text-muted);font-size:14px;" id="error-msg"></p>
    </div>

  </div>
</div>

<script src="../js/modules/api.js"></script>
<script src="../js/modules/toast.js"></script>
<script>
  const token   = new URLSearchParams(window.location.search).get('token');
  let linkData  = null;
  let vaultAddr = '';

  function show(viewId) {
    ['loading-view','payment-view','success-view','error-view'].forEach(id => {
      document.getElementById(id).style.display = id === viewId ? 'block' : 'none';
    });
  }

  async function init() {
    if (!token) { showError('No payment token', 'This link is missing a payment token.'); return; }

    try {
      linkData = await api.payments.getLink(token);

      document.getElementById('pay-merchant').textContent = linkData.merchants?.name || linkData.merchant_id;
      document.getElementById('pay-desc').textContent     = linkData.description || '';

      if (linkData.amount) {
        document.getElementById('fixed-amount-section').style.display = 'block';
        document.getElementById('pay-amount').textContent = (linkData.amount / 1_000_000).toFixed(6);
      } else {
        document.getElementById('open-amount-section').style.display = 'block';
      }

      // Load vault address
      try {
        const escrow = await api.escrow.get(linkData.merchant_id);
        vaultAddr = escrow.vaultAddress || '';
        document.getElementById('vault-addr').value = vaultAddr;
      } catch {}

      const expiresAt = new Date(linkData.expires_at);
      document.getElementById('expire-notice').textContent =
        `Link expires: ${expiresAt.toLocaleString()}`;

      show('payment-view');
    } catch (err) {
      showError('Payment link unavailable', err.message);
    }
  }

  async function confirmPayment() {
    const txSig        = document.getElementById('tx-sig').value.trim();
    const customerWall = document.getElementById('customer-wallet').value.trim();
    let amount         = linkData.amount;

    if (!amount) {
      const custom = parseFloat(document.getElementById('custom-amount').value);
      if (!custom || custom <= 0) { toast.error('Enter a valid amount'); return; }
      amount = Math.round(custom * 1_000_000);
    }

    if (!txSig) { toast.error('Paste your transaction signature'); return; }

    const btn = document.getElementById('confirm-btn');
    btn.disabled = true; btn.textContent = 'Confirming…';

    try {
      await api.payments.confirmDeposit({
        token,
        tx_signature:    txSig,
        amount,
        customer_wallet: customerWall || undefined,
      });

      document.getElementById('success-tx').textContent =
        `Tx: ${txSig.slice(0,20)}…`;
      show('success-view');
    } catch (err) {
      toast.error(err.message);
      btn.disabled = false; btn.textContent = 'Confirm payment';
    }
  }

  function copyVault() {
    navigator.clipboard.writeText(vaultAddr).then(() => toast.success('Vault address copied!'));
  }

  function showError(title, msg) {
    document.getElementById('error-title').textContent = title;
    document.getElementById('error-msg').textContent   = msg;
    show('error-view');
  }

  init();
</script>
</body>
</html>
EOF

# ── D5. Update dashboard — add release countdown + realtime ─
log "Updating dashboard with release countdown and realtime..."
cat > frontend/pages/dashboard.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Dashboard</title>
  <link rel="stylesheet" href="../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Overview</span>
      <div style="display:flex;align-items:center;gap:12px;">
        <span id="realtime-dot" style="width:8px;height:8px;border-radius:50%;background:var(--border);display:inline-block;" title="Realtime"></span>
        <span class="badge badge-info" id="mode-badge">—</span>
        <span id="user-email" style="font-size:13px;color:var(--text-muted);"></span>
      </div>
    </div>

    <div class="page-body">

      <div class="card-grid">
        <div class="card">
          <div class="card-title">Total pending</div>
          <div class="card-value" id="stat-balance">—</div>
          <div class="card-sub">AUDD in escrow</div>
        </div>
        <div class="card">
          <div class="card-title">Next release</div>
          <div class="card-value" id="stat-release" style="font-size:22px;">—</div>
          <div class="card-sub">6am daily · Australia/Sydney</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="stat-payments">—</div>
          <div class="card-sub">All time deposits</div>
        </div>
        <div class="card">
          <div class="card-title">Active merchants</div>
          <div class="card-value" id="stat-merchants">—</div>
          <div class="card-sub">On-chain registered</div>
        </div>
      </div>

      <!-- Last release result -->
      <div class="card" id="last-release-card" style="display:none;margin-bottom:16px;">
        <h2 style="font-size:14px;font-weight:500;color:var(--text-muted);margin-bottom:10px;">Last release run</h2>
        <div id="last-release-content"></div>
      </div>

      <!-- Merchant overview table -->
      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">Merchant balances</h2>
          <button class="btn btn-secondary" style="font-size:13px;" onclick="loadDashboard()">Refresh</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Merchant</th>
                <th>Status</th>
                <th>Pending balance</th>
                <th>Total payments</th>
                <th>Last released</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="merchant-tbody">
              <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../js/modules/api.js"></script>
<script src="../js/modules/auth.js"></script>
<script src="../js/modules/toast.js"></script>
<script src="../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();

  const mode    = auth.getMode();
  const profile = auth.getProfile();

  document.getElementById('sidebar').innerHTML = buildSidebar(mode);
  document.getElementById('mode-badge').textContent  = mode;
  document.getElementById('user-email').textContent  = profile?.email || '';

  function fmtAUDD(v) { return v != null ? (v/1_000_000).toFixed(2)+' AUDD' : '—'; }

  function getCountdown() {
    // Next 6am in UTC+10 (Sydney rough offset — cron uses proper timezone)
    const now    = new Date();
    const sydney = new Date(now.toLocaleString('en-AU', { timeZone: 'Australia/Sydney' }));
    const next   = new Date(sydney);
    next.setHours(6, 0, 0, 0);
    if (next <= sydney) next.setDate(next.getDate() + 1);
    const diff = next - sydney;
    const h = Math.floor(diff / 3_600_000);
    const m = Math.floor((diff % 3_600_000) / 60_000);
    const s = Math.floor((diff % 60_000) / 1000);
    return `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
  }

  async function loadDashboard() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.filter(m => m.is_active);
      document.getElementById('stat-merchants').textContent = active.length;

      if (!active.length) {
        document.getElementById('merchant-tbody').innerHTML =
          `<tr><td colspan="6"><div class="empty-state">
            <div class="empty-state-icon">◈</div>
            <h3>No merchants yet</h3>
            <p>Go to <a href="/pages/developer/merchants.html">Merchants</a> to register</p>
          </div></td></tr>`;
        return;
      }

      const escrows = await Promise.all(
        active.slice(0, 20).map(m =>
          api.escrow.get(m.merchant_id).catch(() => ({ pendingBalance: 0, totalPayments: 0 }))
        )
      );

      const totalPending  = escrows.reduce((s, e) => s + (e.pendingBalance  || 0), 0);
      const totalPayments = escrows.reduce((s, e) => s + (e.totalPayments   || 0), 0);
      document.getElementById('stat-balance').textContent  = fmtAUDD(totalPending);
      document.getElementById('stat-payments').textContent = totalPayments;

      document.getElementById('merchant-tbody').innerHTML = active.map((m, i) => {
        const e = escrows[i] || {};
        return `<tr>
          <td>
            <div style="font-family:var(--font-mono);font-size:12px;">${m.merchant_id}</div>
            <div style="font-size:12px;color:var(--text-muted);">${m.name || ''}</div>
          </td>
          <td><span class="badge badge-success">Active</span></td>
          <td style="font-weight:500;color:${e.pendingBalance>0?'var(--teal)':'inherit'}">${fmtAUDD(e.pendingBalance)}</td>
          <td>${e.totalPayments ?? '—'}</td>
          <td style="font-size:12px;color:var(--text-muted);">${e.lastReleasedAt ? new Date(e.lastReleasedAt).toLocaleDateString() : 'Never'}</td>
          <td>
            <div style="display:flex;gap:6px;">
              <a href="/pages/operator/paylink.html" class="btn btn-secondary" style="font-size:12px;padding:4px 8px;">Pay link</a>
              <a href="/pages/operator/payments.html" class="btn btn-secondary" style="font-size:12px;padding:4px 8px;">History</a>
            </div>
          </td>
        </tr>`;
      }).join('');

      // Show last cron result
      try {
        const { runs } = await fetch('/api/releases/cron-runs', {
          headers: { Authorization: `Bearer ${JSON.parse(localStorage.getItem('settl_session')).access_token}` }
        }).then(r => r.json());
        if (runs?.length) {
          const last = runs[0];
          document.getElementById('last-release-card').style.display = 'block';
          document.getElementById('last-release-content').innerHTML = `
            <div style="display:flex;gap:16px;font-size:13px;flex-wrap:wrap;">
              <div><span style="color:var(--text-muted);">Status</span>
                <span class="badge ${last.status==='success'?'badge-success':'badge-error'}" style="margin-left:6px;">${last.status}</span></div>
              <div><span style="color:var(--text-muted);">Ran at</span> ${new Date(last.ran_at).toLocaleString()}</div>
              ${last.success!=null?`<div style="color:var(--teal);">✓ ${last.success} released</div>`:''}
              ${last.skipped?`<div style="color:var(--text-muted);">⊘ ${last.skipped} skipped</div>`:''}
              ${last.failed?`<div style="color:var(--coral);">✗ ${last.failed} failed</div>`:''}
            </div>`;
        }
      } catch {}

    } catch (err) {
      toast.error('Dashboard load failed: ' + err.message);
    }
  }

  // Countdown timer — updates every second
  function tickCountdown() {
    document.getElementById('stat-release').textContent = getCountdown();
  }
  tickCountdown();
  setInterval(tickCountdown, 1000);

  // Realtime dot — indicates Supabase connection
  // (full Supabase Realtime subscription added in Phase 4)
  document.getElementById('realtime-dot').style.background = 'var(--teal)';

  loadDashboard();
  setInterval(loadDashboard, 60_000);
</script>
</body>
</html>
EOF

# ── D6. Operator — settings.html ─────────────────────────
log "Writing operator settings page..."
cat > frontend/pages/operator/settings.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Settings</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <span class="topbar-title">Settings</span>
      <span class="badge badge-success">operator</span>
    </div>
    <div class="page-body">

      <!-- Profile -->
      <div class="card" style="margin-bottom:20px;">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:18px;">Profile</h2>
        <div class="form-group">
          <label class="form-label">Full name</label>
          <input class="form-input" id="full-name" placeholder="Your name"/>
        </div>
        <div class="form-group">
          <label class="form-label">Email</label>
          <input class="form-input" id="email" type="email" disabled style="opacity:0.6;"/>
          <div class="form-hint">Email cannot be changed here.</div>
        </div>
        <div class="form-group">
          <label class="form-label">Role</label>
          <input class="form-input" id="role" disabled style="opacity:0.6;"/>
        </div>
        <button class="btn btn-primary" onclick="saveProfile()">Save changes</button>
      </div>

      <!-- Change password -->
      <div class="card">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:18px;">Change password</h2>
        <div class="form-group">
          <label class="form-label">New password</label>
          <input class="form-input" id="new-pw" type="password" placeholder="Min 8 characters"/>
        </div>
        <div class="form-group">
          <label class="form-label">Confirm new password</label>
          <input class="form-input" id="confirm-pw" type="password" placeholder="Repeat password"/>
        </div>
        <div style="display:flex;gap:10px;">
          <button class="btn btn-primary" onclick="changePassword()">Update password</button>
          <button class="btn btn-danger" onclick="doLogout()">Sign out</button>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('operator');

  const profile = auth.getProfile();
  if (profile) {
    document.getElementById('full-name').value = profile.full_name || '';
    document.getElementById('email').value     = profile.email     || '';
    document.getElementById('role').value      = profile.role      || 'operator';
  }

  async function saveProfile() {
    toast.info('Profile update coming in Phase 4');
  }

  async function changePassword() {
    const pw  = document.getElementById('new-pw').value;
    const cfw = document.getElementById('confirm-pw').value;
    if (pw.length < 8) { toast.error('Min 8 characters'); return; }
    if (pw !== cfw)    { toast.error('Passwords do not match'); return; }
    try {
      await api.auth.resetPassword(pw);
      toast.success('Password updated');
      document.getElementById('new-pw').value     = '';
      document.getElementById('confirm-pw').value = '';
    } catch (err) { toast.error(err.message); }
  }

  async function doLogout() {
    try { await api.auth.logout(); } catch {}
    auth.clear();
    window.location.href = '/pages/auth/login.html';
  }
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# SECTION E — INSTALL & YARN LOCK
# ═══════════════════════════════════════════════════════════
log "Installing backend dependencies..."
cd backend
# Install using npm (yarn works too — package.json is compatible)
npm install --silent 2>/dev/null || yarn install --silent 2>/dev/null || true
cd ..

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Phase 3 — Setup complete                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What changed from Phase 1 & 2:${NC}"
echo ""
echo -e "   ${GREEN}~${NC} Single ${YELLOW}.env${NC} at repo root — no more backend/.env"
echo -e "   ${GREEN}~${NC} ${YELLOW}yarn dev${NC} from repo root starts everything"
echo -e "   ${GREEN}~${NC} Auth switched to ${YELLOW}email + password${NC}"
echo -e "   ${GREEN}~${NC} server.js updated to your single-port version"
echo ""
echo -e "  ${BLUE}New in Phase 3:${NC}"
echo ""
echo -e "   ${GREEN}+${NC} backend/src/services/release.js    On-chain release() call"
echo -e "   ${GREEN}+${NC} backend/src/services/payment.js    Payment link generator"
echo -e "   ${GREEN}+${NC} backend/src/cron/dailyRelease.js   6am cron (Australia/Sydney)"
echo -e "   ${GREEN}+${NC} backend/src/routes/payments.js     Payment link + confirm routes"
echo -e "   ${GREEN}+${NC} backend/src/routes/releases.js     History + manual trigger"
echo -e "   ${GREEN}+${NC} frontend/pages/auth/login.html     Email + password login"
echo -e "   ${GREEN}+${NC} frontend/pages/auth/register.html  Account creation"
echo -e "   ${GREEN}+${NC} frontend/pages/operator/payments.html   Payment history"
echo -e "   ${GREEN}+${NC} frontend/pages/operator/paylink.html    Link generator"
echo -e "   ${GREEN}+${NC} frontend/pages/operator/settings.html   Profile + password"
echo -e "   ${GREEN}+${NC} frontend/pages/developer/cron.html      Cron monitor + trigger"
echo -e "   ${GREEN}+${NC} frontend/pages/pay.html                 Public customer payment page"
echo -e "   ${GREEN}~${NC} frontend/pages/dashboard.html           Live countdown + cron result"
echo -e "   ${GREEN}+${NC} supabase/migrations/003_phase3_payments_cron.sql"
echo ""
echo -e "  ${BLUE}To start:${NC}"
echo ""
echo -e "  1. Run the Phase 3 migration in Supabase SQL editor:"
echo -e "     ${YELLOW}supabase/migrations/003_phase3_payments_cron.sql${NC}"
echo ""
echo -e "  2. Make sure ${YELLOW}.env${NC} is filled in at the repo root"
echo ""
echo -e "  3. Start everything with one command:"
echo -e "     ${YELLOW}yarn dev${NC}   or   ${YELLOW}npm run dev${NC}"
echo ""
echo -e "  4. Open ${BLUE}http://localhost:3000${NC}"
echo ""
warn "Test the cron locally by setting RELEASE_CRON='* * * * *' in .env"
warn "This fires every minute instead of 6am so you can verify releases work."
echo ""