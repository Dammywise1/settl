#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Phase 1 Setup Script
#  Scaffolds full repo: backend + frontend + supabase config
#  Run: bash settl-phase1-setup.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETTL]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }

log "Starting SETTL Phase 1 scaffold..."

# ───────────────────────────────────────────────────────────
# 1. ROOT STRUCTURE
# ───────────────────────────────────────────────────────────


mkdir -p backend/src/{routes,services,middleware,config}
mkdir -p frontend/{pages/{developer,operator},js/{modules,pages},css,assets}
mkdir -p supabase/migrations

log "Directory structure created"

# ───────────────────────────────────────────────────────────
# 2. ROOT package.json (workspace)
# ───────────────────────────────────────────────────────────
cat > package.json << 'EOF'
{
  "name": "settl",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "cd backend && npm run dev",
    "start": "cd backend && npm start",
    "install:all": "cd backend && npm install"
  }
}
EOF

# ───────────────────────────────────────────────────────────
# 3. .env (root — copy to backend/.env too)
# ───────────────────────────────────────────────────────────
cat > .env.example << 'EOF'
# ── Supabase ──────────────────────────────────────────────
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
SUPABASE_ANON_KEY=your-anon-key

# ── Solana ────────────────────────────────────────────────
SOLANA_RPC_URL=https://api.devnet.solana.com
SETTL_PROGRAM_ID=RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn
AUTHORITY_KEYPAIR_PATH=./keypair.json
TREASURY_WALLET=your-treasury-wallet-pubkey
AUDD_MINT=your-audd-mint-pubkey

# ── Server ────────────────────────────────────────────────
PORT=3000
JWT_SECRET=change-this-to-a-long-random-secret
NODE_ENV=development

# ── CORS ─────────────────────────────────────────────────
FRONTEND_URL=http://localhost:5500
EOF

cp .env.example backend/.env.example
log ".env.example created"

# ───────────────────────────────────────────────────────────
# 4. .gitignore
# ───────────────────────────────────────────────────────────
cat > .gitignore << 'EOF'
node_modules/
.env
backend/.env
*.json.key
keypair.json
dist/
.DS_Store
EOF

# ───────────────────────────────────────────────────────────
# 5. BACKEND package.json
# ───────────────────────────────────────────────────────────
cat > backend/package.json << 'EOF'
{
  "name": "settl-backend",
  "version": "1.0.0",
  "main": "src/server.js",
  "scripts": {
    "dev": "nodemon src/server.js",
    "start": "node src/server.js"
  },
  "dependencies": {
    "@coral-xyz/anchor": "^0.29.0",
    "@solana/web3.js": "^1.91.0",
    "@supabase/supabase-js": "^2.43.0",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "express-rate-limit": "^7.3.1",
    "helmet": "^7.1.0",
    "morgan": "^1.10.0",
    "node-cron": "^3.0.3",
    "uuid": "^9.0.1"
  },
  "devDependencies": {
    "nodemon": "^3.1.3"
  }
}
EOF

# ───────────────────────────────────────────────────────────
# 6. BACKEND — server.js
# ───────────────────────────────────────────────────────────
cat > backend/src/server.js << 'EOF'
require('dotenv').config();
const express    = require('express');
const cors       = require('cors');
const helmet     = require('helmet');
const morgan     = require('morgan');
const rateLimit  = require('express-rate-limit');

const { supabase }      = require('./config/supabase');
const authMiddleware    = require('./middleware/auth');
const apiKeyMiddleware  = require('./middleware/apiKey');
const merchantRoutes    = require('./routes/merchants');
const authRoutes        = require('./routes/auth');
const healthRoutes      = require('./routes/health');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Security & parsing ─────────────────────────────────────
app.use(helmet());
app.use(cors({
  origin: process.env.FRONTEND_URL || 'http://localhost:5500',
  credentials: true,
}));
app.use(express.json());
app.use(morgan('dev'));

// ── Rate limiting ─────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  message: { error: 'Too many requests, please try again later.' },
});
app.use('/api/', limiter);

// ── Routes ────────────────────────────────────────────────
app.use('/api/health',    healthRoutes);
app.use('/api/auth',      authRoutes);
app.use('/api/merchants', authMiddleware, merchantRoutes);

// ── 404 handler ───────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

// ── Error handler ─────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({
    error: err.message || 'Internal server error',
  });
});

app.listen(PORT, () => {
  console.log(`[SETTL] Backend running on http://localhost:${PORT}`);
  console.log(`[SETTL] Environment: ${process.env.NODE_ENV}`);
});

module.exports = app;
EOF

# ───────────────────────────────────────────────────────────
# 7. BACKEND — config/supabase.js
# ───────────────────────────────────────────────────────────
cat > backend/src/config/supabase.js << 'EOF'
const { createClient } = require('@supabase/supabase-js');

const supabaseUrl     = process.env.SUPABASE_URL;
const supabaseKey     = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseKey) {
  throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env');
}

const supabase = createClient(supabaseUrl, supabaseKey, {
  auth: { persistSession: false },
});

module.exports = { supabase };
EOF

# ───────────────────────────────────────────────────────────
# 8. BACKEND — config/anchor.js (stubbed for Phase 2)
# ───────────────────────────────────────────────────────────
cat > backend/src/config/anchor.js << 'EOF'
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program }        = require('@coral-xyz/anchor');
const fs                                  = require('fs');
const path                                = require('path');

let _program = null;

function getProvider() {
  const rpcUrl    = process.env.SOLANA_RPC_URL || 'https://api.devnet.solana.com';
  const connection = new Connection(rpcUrl, 'confirmed');

  const keypairPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(keypairPath)) {
    throw new Error(`Authority keypair not found at ${keypairPath}`);
  }
  const raw      = JSON.parse(fs.readFileSync(keypairPath, 'utf-8'));
  const keypair  = Keypair.fromSecretKey(Uint8Array.from(raw));
  const wallet   = { publicKey: keypair.publicKey, signTransaction: async (tx) => { tx.sign(keypair); return tx; }, signAllTransactions: async (txs) => txs.map(tx => { tx.sign(keypair); return tx; }) };

  return new AnchorProvider(connection, wallet, { commitment: 'confirmed' });
}

// Full program initialisation happens in Phase 2
// when we wire in the IDL
function getProgram() {
  if (_program) return _program;
  console.warn('[Anchor] Program not initialised — wire IDL in Phase 2');
  return null;
}

module.exports = { getProvider, getProgram };
EOF

# ───────────────────────────────────────────────────────────
# 9. BACKEND — middleware/auth.js
# ───────────────────────────────────────────────────────────
cat > backend/src/middleware/auth.js << 'EOF'
const { supabase } = require('../config/supabase');

/**
 * Validates the Supabase JWT from the Authorization header.
 * Attaches req.user on success.
 */
async function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid Authorization header' });
  }

  const token = authHeader.split(' ')[1];

  const { data: { user }, error } = await supabase.auth.getUser(token);
  if (error || !user) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }

  req.user = user;
  next();
}

module.exports = authMiddleware;
EOF

# ───────────────────────────────────────────────────────────
# 10. BACKEND — middleware/apiKey.js
# ───────────────────────────────────────────────────────────
cat > backend/src/middleware/apiKey.js << 'EOF'
const { supabase } = require('../config/supabase');

/**
 * Validates x-api-key header against the api_keys table.
 * Used for programmatic/developer access.
 * Attaches req.apiKeyRecord on success.
 */
async function apiKeyMiddleware(req, res, next) {
  const apiKey = req.headers['x-api-key'];
  if (!apiKey) {
    return res.status(401).json({ error: 'Missing x-api-key header' });
  }

  const { data, error } = await supabase
    .from('api_keys')
    .select('*, merchants(id, merchant_id, is_active)')
    .eq('key', apiKey)
    .eq('is_active', true)
    .single();

  if (error || !data) {
    return res.status(401).json({ error: 'Invalid or revoked API key' });
  }

  // Update last used timestamp (non-blocking)
  supabase
    .from('api_keys')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', data.id)
    .then(() => {});

  req.apiKeyRecord = data;
  next();
}

module.exports = apiKeyMiddleware;
EOF

# ───────────────────────────────────────────────────────────
# 11. BACKEND — routes/health.js
# ───────────────────────────────────────────────────────────
cat > backend/src/routes/health.js << 'EOF'
const router   = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try {
    const { error } = await supabase.from('merchants').select('count').limit(1);
    if (error) db = 'error: ' + error.message;
  } catch (e) {
    db = 'unreachable';
  }

  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    env: process.env.NODE_ENV,
    db,
  });
});

module.exports = router;
EOF

# ───────────────────────────────────────────────────────────
# 12. BACKEND — routes/auth.js
# ───────────────────────────────────────────────────────────
cat > backend/src/routes/auth.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');

// POST /api/auth/login — magic link
router.post('/login', async (req, res, next) => {
  try {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${process.env.FRONTEND_URL}/pages/auth/callback.html`,
      },
    });

    if (error) throw error;
    res.json({ message: 'Magic link sent — check your email' });
  } catch (err) {
    next(err);
  }
});

// GET /api/auth/me — current user profile + role
router.get('/me', async (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader) return res.status(401).json({ error: 'No token provided' });

    const token = authHeader.split(' ')[1];
    const { data: { user }, error } = await supabase.auth.getUser(token);
    if (error || !user) return res.status(401).json({ error: 'Invalid token' });

    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single();

    res.json({ user, profile });
  } catch (err) {
    next(err);
  }
});

// POST /api/auth/logout
router.post('/logout', async (req, res, next) => {
  try {
    const { error } = await supabase.auth.signOut();
    if (error) throw error;
    res.json({ message: 'Logged out' });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
EOF

# ───────────────────────────────────────────────────────────
# 13. BACKEND — routes/merchants.js (Phase 1 stub)
# ───────────────────────────────────────────────────────────
cat > backend/src/routes/merchants.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');

// GET /api/merchants — list all merchants for this user
router.get('/', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json({ merchants: data });
  } catch (err) {
    next(err);
  }
});

// GET /api/merchants/:id — single merchant
router.get('/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants')
      .select('*, escrows(*)')
      .eq('id', req.params.id)
      .single();

    if (error) throw error;
    if (!data) return res.status(404).json({ error: 'Merchant not found' });
    res.json({ merchant: data });
  } catch (err) {
    next(err);
  }
});

// POST /api/merchants — register (stub, wired to contract in Phase 2)
router.post('/', async (req, res, next) => {
  try {
    const { merchant_id, wallet_address, name, email } = req.body;
    if (!merchant_id || !wallet_address) {
      return res.status(400).json({ error: 'merchant_id and wallet_address are required' });
    }

    // Persist to Supabase (on-chain call added in Phase 2)
    const { data, error } = await supabase
      .from('merchants')
      .insert({
        merchant_id,
        wallet_address,
        name: name || merchant_id,
        email,
        is_active: false, // becomes true after on-chain registration in Phase 2
        created_by: req.user.id,
      })
      .select()
      .single();

    if (error) throw error;
    res.status(201).json({ merchant: data, note: 'On-chain registration wired in Phase 2' });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
EOF

# ───────────────────────────────────────────────────────────
# 14. SUPABASE — Migration SQL
# ───────────────────────────────────────────────────────────
cat > supabase/migrations/001_initial_schema.sql << 'EOF'
-- ═══════════════════════════════════════════════════════════
--  SETTL — Phase 1 Schema
-- ═══════════════════════════════════════════════════════════

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- ── profiles ──────────────────────────────────────────────
-- Extends Supabase auth.users with role info
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  role        text not null default 'operator'  -- 'developer' | 'operator'
              check (role in ('developer', 'operator')),
  full_name   text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

alter table profiles enable row level security;

create policy "Users can read own profile"
  on profiles for select using (auth.uid() = id);

create policy "Users can update own profile"
  on profiles for update using (auth.uid() = id);

-- Auto-create profile on signup
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into profiles (id, email, role)
  values (new.id, new.email, 'operator');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();

-- ── merchants ─────────────────────────────────────────────
create table if not exists merchants (
  id              uuid primary key default uuid_generate_v4(),
  merchant_id     text unique not null,          -- on-chain ID (max 64 chars)
  name            text,
  email           text,
  wallet_address  text not null,
  is_active       boolean default false,
  registered_at   timestamptz,                   -- set after on-chain tx confirmed
  on_chain_tx     text,                          -- registration tx signature
  created_by      uuid references profiles(id),
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table merchants enable row level security;

create policy "Authenticated users can read merchants"
  on merchants for select using (auth.role() = 'authenticated');

create policy "Developers can insert merchants"
  on merchants for insert with check (
    exists (
      select 1 from profiles
      where id = auth.uid() and role = 'developer'
    )
  );

create policy "Developers can update merchants"
  on merchants for update using (
    exists (
      select 1 from profiles
      where id = auth.uid() and role = 'developer'
    )
  );

-- ── escrows ───────────────────────────────────────────────
create table if not exists escrows (
  id               uuid primary key default uuid_generate_v4(),
  merchant_id      text not null references merchants(merchant_id) on delete cascade,
  pending_balance  numeric(20, 6) default 0,
  total_payments   integer default 0,
  last_released_at timestamptz,
  vault_address    text,                         -- on-chain vault PDA
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);

alter table escrows enable row level security;

create policy "Authenticated users can read escrows"
  on escrows for select using (auth.role() = 'authenticated');

-- ── transactions ──────────────────────────────────────────
create table if not exists transactions (
  id               uuid primary key default uuid_generate_v4(),
  merchant_id      text not null references merchants(merchant_id),
  type             text not null check (type in ('deposit', 'release', 'fee')),
  amount           numeric(20, 6) not null,
  fee              numeric(20, 6) default 0,
  net              numeric(20, 6),
  customer_wallet  text,
  tx_signature     text,                         -- Solana tx signature
  status           text default 'pending'
                   check (status in ('pending', 'confirmed', 'failed')),
  created_at       timestamptz default now()
);

alter table transactions enable row level security;

create policy "Authenticated users can read transactions"
  on transactions for select using (auth.role() = 'authenticated');

create policy "Service role can insert transactions"
  on transactions for insert with check (true);

-- ── release_logs ──────────────────────────────────────────
create table if not exists release_logs (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text references merchants(merchant_id),
  gross        numeric(20, 6),
  fee          numeric(20, 6),
  net          numeric(20, 6),
  tx_signature text,
  status       text default 'pending'
               check (status in ('pending', 'success', 'failed', 'skipped')),
  error        text,
  released_at  timestamptz default now()
);

alter table release_logs enable row level security;

create policy "Authenticated users can read release logs"
  on release_logs for select using (auth.role() = 'authenticated');

-- ── api_keys ──────────────────────────────────────────────
create table if not exists api_keys (
  id           uuid primary key default uuid_generate_v4(),
  name         text not null,
  key          text unique not null,
  merchant_id  text references merchants(merchant_id),
  is_active    boolean default true,
  last_used_at timestamptz,
  created_by   uuid references profiles(id),
  created_at   timestamptz default now()
);

alter table api_keys enable row level security;

create policy "Users can read own api keys"
  on api_keys for select using (created_by = auth.uid());

create policy "Users can manage own api keys"
  on api_keys for all using (created_by = auth.uid());

-- ── webhook_configs ───────────────────────────────────────
create table if not exists webhook_configs (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text references merchants(merchant_id),
  url          text not null,
  events       text[] default array['release', 'deposit'],
  secret       text,
  is_active    boolean default true,
  created_by   uuid references profiles(id),
  created_at   timestamptz default now()
);

alter table webhook_configs enable row level security;

create policy "Users can manage own webhook configs"
  on webhook_configs for all using (created_by = auth.uid());

-- ── Indexes ───────────────────────────────────────────────
create index if not exists idx_transactions_merchant  on transactions(merchant_id);
create index if not exists idx_transactions_created   on transactions(created_at desc);
create index if not exists idx_release_logs_merchant  on release_logs(merchant_id);
create index if not exists idx_merchants_active       on merchants(is_active);

-- ── updated_at triggers ───────────────────────────────────
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger merchants_updated_at before update on merchants
  for each row execute procedure update_updated_at();
create trigger escrows_updated_at before update on escrows
  for each row execute procedure update_updated_at();
create trigger profiles_updated_at before update on profiles
  for each row execute procedure update_updated_at();

EOF

log "Supabase migration SQL created"

# ───────────────────────────────────────────────────────────
# 15. FRONTEND — index.html (login redirect)
# ───────────────────────────────────────────────────────────
mkdir -p frontend/pages/auth

cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SETTL — Payment Gateway</title>
  <link rel="stylesheet" href="css/app.css" />
</head>
<body>
  <script>
    // Redirect to login if no session, else to dashboard
    const session = localStorage.getItem('settl_session');
    if (session) {
      window.location.href = '/pages/dashboard.html';
    } else {
      window.location.href = '/pages/auth/login.html';
    }
  </script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 16. FRONTEND — css/app.css
# ───────────────────────────────────────────────────────────
cat > frontend/css/app.css << 'EOF'
/* ── Reset & base ────────────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  --brand:        #534AB7;
  --brand-light:  #EEEDFE;
  --brand-dark:   #3C3489;
  --teal:         #1D9E75;
  --teal-light:   #E1F5EE;
  --coral:        #D85A30;
  --coral-light:  #FAECE7;
  --text-primary: #1a1a1a;
  --text-muted:   #6b6b6b;
  --text-hint:    #9b9b9b;
  --bg:           #f8f8f6;
  --surface:      #ffffff;
  --border:       rgba(0,0,0,0.1);
  --border-strong:rgba(0,0,0,0.2);
  --radius-sm:    6px;
  --radius-md:    10px;
  --radius-lg:    16px;
  --shadow-sm:    0 1px 3px rgba(0,0,0,0.08);
  --shadow-md:    0 4px 12px rgba(0,0,0,0.10);
  --font:         system-ui, -apple-system, sans-serif;
  --font-mono:    'Menlo', 'Consolas', monospace;
  --sidebar-w:    240px;
}

body {
  font-family: var(--font);
  font-size: 15px;
  color: var(--text-primary);
  background: var(--bg);
  line-height: 1.6;
}

a { color: var(--brand); text-decoration: none; }
a:hover { text-decoration: underline; }

/* ── Layout ──────────────────────────────────────────────── */
.app-shell {
  display: flex;
  min-height: 100vh;
}

.sidebar {
  width: var(--sidebar-w);
  background: var(--surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
}

.sidebar-logo {
  padding: 20px 20px 12px;
  font-size: 18px;
  font-weight: 600;
  color: var(--brand);
  border-bottom: 1px solid var(--border);
  display: flex;
  align-items: center;
  gap: 8px;
}

.sidebar-section {
  padding: 16px 12px 8px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-hint);
}

.nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 16px;
  margin: 1px 8px;
  border-radius: var(--radius-sm);
  color: var(--text-muted);
  font-size: 14px;
  cursor: pointer;
  transition: background 0.15s, color 0.15s;
  text-decoration: none;
}
.nav-item:hover { background: var(--bg); color: var(--text-primary); text-decoration: none; }
.nav-item.active { background: var(--brand-light); color: var(--brand-dark); font-weight: 500; }

.sidebar-footer {
  margin-top: auto;
  padding: 16px;
  border-top: 1px solid var(--border);
  font-size: 13px;
}

.main-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.topbar {
  height: 56px;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 24px;
  position: sticky;
  top: 0;
  z-index: 10;
}

.topbar-title { font-size: 16px; font-weight: 500; }

.page-body {
  padding: 28px 32px;
  max-width: 1100px;
}

/* ── Mode switch pill ────────────────────────────────────── */
.mode-switch {
  display: flex;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 20px;
  padding: 3px;
  gap: 2px;
}
.mode-btn {
  padding: 5px 16px;
  border-radius: 16px;
  border: none;
  background: transparent;
  font-size: 13px;
  font-weight: 500;
  color: var(--text-muted);
  cursor: pointer;
  transition: background 0.15s, color 0.15s;
}
.mode-btn.active {
  background: var(--surface);
  color: var(--brand);
  box-shadow: var(--shadow-sm);
}

/* ── Cards ───────────────────────────────────────────────── */
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 20px 24px;
  margin-bottom: 16px;
}
.card-title {
  font-size: 13px;
  font-weight: 500;
  color: var(--text-muted);
  margin-bottom: 6px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
.card-value {
  font-size: 28px;
  font-weight: 600;
  color: var(--text-primary);
}
.card-sub {
  font-size: 13px;
  color: var(--text-muted);
  margin-top: 4px;
}

.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 16px;
  margin-bottom: 24px;
}

/* ── Badges ──────────────────────────────────────────────── */
.badge {
  display: inline-flex;
  align-items: center;
  padding: 2px 10px;
  border-radius: 12px;
  font-size: 12px;
  font-weight: 500;
}
.badge-success { background: var(--teal-light);  color: #085041; }
.badge-pending { background: #FAEEDA;             color: #633806; }
.badge-error   { background: #FCEBEB;             color: #791F1F; }
.badge-info    { background: #E6F1FB;             color: #0C447C; }

/* ── Buttons ─────────────────────────────────────────────── */
.btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 18px;
  border-radius: var(--radius-sm);
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  border: none;
  transition: opacity 0.15s;
}
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-primary  { background: var(--brand); color: #fff; }
.btn-primary:hover { opacity: 0.88; }
.btn-secondary { background: var(--bg); color: var(--text-primary); border: 1px solid var(--border-strong); }
.btn-secondary:hover { background: #ebebeb; }
.btn-danger   { background: var(--coral); color: #fff; }

/* ── Forms ───────────────────────────────────────────────── */
.form-group { margin-bottom: 16px; }
.form-label { display: block; font-size: 13px; font-weight: 500; margin-bottom: 6px; }
.form-input {
  width: 100%;
  padding: 9px 12px;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
  font-size: 14px;
  font-family: var(--font);
  background: var(--surface);
  color: var(--text-primary);
  transition: border-color 0.15s;
}
.form-input:focus { outline: none; border-color: var(--brand); }
.form-hint { font-size: 12px; color: var(--text-hint); margin-top: 4px; }

/* ── Table ───────────────────────────────────────────────── */
.table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: var(--radius-md); }
table { width: 100%; border-collapse: collapse; }
thead th {
  background: var(--bg);
  padding: 10px 16px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-muted);
  text-align: left;
  border-bottom: 1px solid var(--border);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
tbody td { padding: 12px 16px; font-size: 14px; border-bottom: 1px solid var(--border); }
tbody tr:last-child td { border-bottom: none; }
tbody tr:hover { background: var(--bg); }

/* ── Toast ───────────────────────────────────────────────── */
#toast-container {
  position: fixed;
  bottom: 24px;
  right: 24px;
  z-index: 999;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.toast {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  padding: 12px 18px;
  font-size: 14px;
  box-shadow: var(--shadow-md);
  min-width: 260px;
  animation: slideIn 0.2s ease;
}
.toast.success { border-left: 3px solid var(--teal); }
.toast.error   { border-left: 3px solid var(--coral); }
@keyframes slideIn { from { transform: translateX(20px); opacity: 0; } to { transform: none; opacity: 1; } }

/* ── Auth page ───────────────────────────────────────────── */
.auth-wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg);
}
.auth-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 40px 44px;
  width: 100%;
  max-width: 420px;
  box-shadow: var(--shadow-md);
}
.auth-logo { font-size: 22px; font-weight: 700; color: var(--brand); margin-bottom: 8px; }
.auth-sub  { color: var(--text-muted); margin-bottom: 28px; font-size: 14px; }

/* ── Empty state ─────────────────────────────────────────── */
.empty-state {
  text-align: center;
  padding: 48px 24px;
  color: var(--text-muted);
}
.empty-state-icon { font-size: 36px; margin-bottom: 12px; opacity: 0.4; }
.empty-state h3   { font-size: 16px; margin-bottom: 6px; color: var(--text-primary); }
EOF

# ───────────────────────────────────────────────────────────
# 17. FRONTEND — js/modules/api.js
# ───────────────────────────────────────────────────────────
cat > frontend/js/modules/api.js << 'EOF'
// ── SETTL API client ──────────────────────────────────────
const API_BASE = 'http://localhost:3000/api';

function getToken() {
  const session = localStorage.getItem('settl_session');
  if (!session) return null;
  try { return JSON.parse(session).access_token; } catch { return null; }
}

async function request(path, options = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...options.headers,
  };

  const res = await fetch(`${API_BASE}${path}`, { ...options, headers });
  const data = await res.json();

  if (!res.ok) {
    const err = new Error(data.error || 'Request failed');
    err.status = res.status;
    throw err;
  }
  return data;
}

const api = {
  get:    (path, opts)         => request(path, { ...opts, method: 'GET' }),
  post:   (path, body, opts)   => request(path, { ...opts, method: 'POST',  body: JSON.stringify(body) }),
  patch:  (path, body, opts)   => request(path, { ...opts, method: 'PATCH', body: JSON.stringify(body) }),
  delete: (path, opts)         => request(path, { ...opts, method: 'DELETE' }),

  auth: {
    login:  (email)  => api.post('/auth/login', { email }),
    me:     ()       => api.get('/auth/me'),
    logout: ()       => api.post('/auth/logout', {}),
  },

  merchants: {
    list:   ()           => api.get('/merchants'),
    get:    (id)         => api.get(`/merchants/${id}`),
    create: (body)       => api.post('/merchants', body),
  },
};

window.api = api;
EOF

# ───────────────────────────────────────────────────────────
# 18. FRONTEND — js/modules/auth.js
# ───────────────────────────────────────────────────────────
cat > frontend/js/modules/auth.js << 'EOF'
// ── Session management ────────────────────────────────────
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
    if (!s) return false;
    if (s.expires_at && Date.now() / 1000 > s.expires_at) {
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

  getMode() {
    return localStorage.getItem('settl_mode') || 'operator';
  },

  setMode(mode) {
    localStorage.setItem('settl_mode', mode);
  },

  getRole() {
    const p = this.getProfile();
    return p?.role || 'operator';
  },
};

window.auth = auth;
EOF

# ───────────────────────────────────────────────────────────
# 19. FRONTEND — js/modules/toast.js
# ───────────────────────────────────────────────────────────
cat > frontend/js/modules/toast.js << 'EOF'
// ── Toast notifications ───────────────────────────────────
(function () {
  const container = document.createElement('div');
  container.id = 'toast-container';
  document.body.appendChild(container);

  function show(message, type = 'info', duration = 3500) {
    const t = document.createElement('div');
    t.className = `toast ${type}`;
    t.textContent = message;
    container.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; t.style.transition = 'opacity 0.3s'; setTimeout(() => t.remove(), 300); }, duration);
  }

  window.toast = {
    success: (msg) => show(msg, 'success'),
    error:   (msg) => show(msg, 'error'),
    info:    (msg) => show(msg, 'info'),
  };
})();
EOF

# ───────────────────────────────────────────────────────────
# 20. FRONTEND — js/modules/nav.js (sidebar renderer)
# ───────────────────────────────────────────────────────────
cat > frontend/js/modules/nav.js << 'EOF'
// ── Sidebar navigation builder ────────────────────────────
const NAV = {
  operator: [
    { label: 'Overview',        href: '/pages/dashboard.html',           icon: '◈' },
    { label: 'Payments',        href: '/pages/operator/payments.html',    icon: '↑' },
    { label: 'Balance',         href: '/pages/operator/balance.html',     icon: '$' },
    { label: 'Payment link',    href: '/pages/operator/paylink.html',     icon: '⊕' },
    { label: 'Settings',        href: '/pages/operator/settings.html',    icon: '⚙' },
  ],
  developer: [
    { label: 'Overview',        href: '/pages/dashboard.html',            icon: '◈' },
    { label: 'Merchants',       href: '/pages/developer/merchants.html',  icon: '⊞' },
    { label: 'Escrow viewer',   href: '/pages/developer/escrow.html',     icon: '⬡' },
    { label: 'Transactions',    href: '/pages/developer/transactions.html',icon: '≡' },
    { label: 'API keys',        href: '/pages/developer/apikeys.html',    icon: '⌘' },
    { label: 'Webhooks',        href: '/pages/developer/webhooks.html',   icon: '⌁' },
    { label: 'Cron monitor',    href: '/pages/developer/cron.html',       icon: '◷' },
  ],
};

function buildSidebar(mode) {
  const profile = window.auth?.getProfile();
  const role    = profile?.role || 'operator';
  const items   = NAV[mode] || NAV.operator;
  const current = window.location.pathname;

  return `
    <div class="sidebar-logo">SETTL</div>
    <div style="padding: 12px 8px 4px;">
      <div class="mode-switch" style="width:100%;">
        <button class="mode-btn ${mode === 'operator'  ? 'active' : ''}" onclick="switchMode('operator')">Operator</button>
        ${role === 'developer' ? `<button class="mode-btn ${mode === 'developer' ? 'active' : ''}" onclick="switchMode('developer')">Developer</button>` : ''}
      </div>
    </div>
    <div class="sidebar-section">${mode === 'developer' ? 'Developer' : 'Business'}</div>
    ${items.map(item => `
      <a href="${item.href}" class="nav-item ${current.includes(item.href.split('/').pop().replace('.html','')) ? 'active' : ''}">
        <span style="font-size:16px;">${item.icon}</span> ${item.label}
      </a>`).join('')}
    <div class="sidebar-footer">
      <div style="font-weight:500; font-size:13px; margin-bottom:4px;">${profile?.full_name || profile?.email || 'User'}</div>
      <a href="#" onclick="handleLogout()" style="font-size:12px; color:var(--text-hint);">Sign out</a>
    </div>
  `;
}

function switchMode(mode) {
  window.auth.setMode(mode);
  const sidebar = document.getElementById('sidebar');
  if (sidebar) sidebar.innerHTML = buildSidebar(mode);
}

async function handleLogout() {
  try { await window.api.auth.logout(); } catch {}
  window.auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.buildSidebar = buildSidebar;
window.switchMode   = switchMode;
window.handleLogout = handleLogout;
EOF

# ───────────────────────────────────────────────────────────
# 21. FRONTEND — pages/auth/login.html
# ───────────────────────────────────────────────────────────
cat > frontend/pages/auth/login.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SETTL — Sign in</title>
  <link rel="stylesheet" href="../../css/app.css" />
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card">
    <div class="auth-logo">SETTL</div>
    <div class="auth-sub">Payment gateway · Sign in to continue</div>

    <div id="form-view">
      <div class="form-group">
        <label class="form-label" for="email">Email address</label>
        <input class="form-input" type="email" id="email" placeholder="you@example.com" autocomplete="email" />
      </div>
      <button class="btn btn-primary" style="width:100%;" id="login-btn" onclick="sendMagicLink()">
        Send magic link
      </button>
      <p class="form-hint" style="margin-top:14px; text-align:center;">
        We'll email you a one-click sign-in link. No password needed.
      </p>
    </div>

    <div id="sent-view" style="display:none; text-align:center;">
      <div style="font-size:32px; margin-bottom:12px;">✉</div>
      <h3 style="margin-bottom:8px;">Check your email</h3>
      <p style="color:var(--text-muted); font-size:14px;">
        We sent a sign-in link to <strong id="sent-email"></strong>.<br/>
        Click the link in the email to continue.
      </p>
      <button class="btn btn-secondary" style="margin-top:20px; width:100%;" onclick="resetForm()">
        Use a different email
      </button>
    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script>
  // Already logged in → redirect
  if (auth.isLoggedIn()) window.location.href = '/pages/dashboard.html';

  async function sendMagicLink() {
    const email = document.getElementById('email').value.trim();
    if (!email) { toast.error('Please enter your email'); return; }

    const btn = document.getElementById('login-btn');
    btn.disabled = true;
    btn.textContent = 'Sending...';

    try {
      await api.auth.login(email);
      document.getElementById('sent-email').textContent = email;
      document.getElementById('form-view').style.display = 'none';
      document.getElementById('sent-view').style.display = 'block';
    } catch (err) {
      toast.error(err.message || 'Failed to send magic link');
      btn.disabled = false;
      btn.textContent = 'Send magic link';
    }
  }

  function resetForm() {
    document.getElementById('form-view').style.display = 'block';
    document.getElementById('sent-view').style.display = 'none';
    const btn = document.getElementById('login-btn');
    btn.disabled = false;
    btn.textContent = 'Send magic link';
  }

  document.getElementById('email').addEventListener('keydown', e => {
    if (e.key === 'Enter') sendMagicLink();
  });
</script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 22. FRONTEND — pages/auth/callback.html
# ───────────────────────────────────────────────────────────
cat > frontend/pages/auth/callback.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>SETTL — Signing in...</title>
  <link rel="stylesheet" href="../../css/app.css" />
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card" style="text-align:center;">
    <div class="auth-logo">SETTL</div>
    <p id="status" style="color:var(--text-muted); margin-top:12px;">Verifying your link...</p>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script>
  // Supabase appends #access_token=... to the callback URL
  (async () => {
    const hash   = window.location.hash.substring(1);
    const params = new URLSearchParams(hash);
    const token  = params.get('access_token');
    const refresh = params.get('refresh_token');
    const expiresAt = params.get('expires_at');

    if (!token) {
      document.getElementById('status').textContent = 'Invalid link — please request a new one.';
      setTimeout(() => window.location.href = '/pages/auth/login.html', 2000);
      return;
    }

    try {
      // Store session
      auth.setSession({ access_token: token, refresh_token: refresh, expires_at: Number(expiresAt) });

      // Fetch profile
      const { profile } = await api.auth.me();
      auth.setSession({ access_token: token, refresh_token: refresh, expires_at: Number(expiresAt) }, profile);

      window.location.href = '/pages/dashboard.html';
    } catch (err) {
      document.getElementById('status').textContent = 'Sign-in failed: ' + err.message;
    }
  })();
</script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 23. FRONTEND — pages/dashboard.html
# ───────────────────────────────────────────────────────────
cat > frontend/pages/dashboard.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SETTL — Dashboard</title>
  <link rel="stylesheet" href="../css/app.css" />
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>

  <div class="main-content">
    <div class="topbar">
      <span class="topbar-title" id="page-title">Overview</span>
      <div style="display:flex; align-items:center; gap:12px;">
        <span class="badge badge-info" id="mode-badge">operator</span>
        <span id="user-email" style="font-size:13px; color:var(--text-muted);"></span>
      </div>
    </div>

    <div class="page-body">
      <div class="card-grid" id="stat-cards">
        <div class="card">
          <div class="card-title">Pending balance</div>
          <div class="card-value" id="stat-balance">—</div>
          <div class="card-sub">AUDD in escrow</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="stat-payments">—</div>
          <div class="card-sub">All time</div>
        </div>
        <div class="card">
          <div class="card-title">Next release</div>
          <div class="card-value" id="stat-release">6am</div>
          <div class="card-sub">Daily automatic</div>
        </div>
        <div class="card">
          <div class="card-title">Active merchants</div>
          <div class="card-value" id="stat-merchants">—</div>
          <div class="card-sub">On-chain registered</div>
        </div>
      </div>

      <div class="card">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:16px;">
          <h2 style="font-size:16px; font-weight:500;">Recent transactions</h2>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Type</th>
                <th>Merchant</th>
                <th>Amount (AUDD)</th>
                <th>Status</th>
                <th>Date</th>
              </tr>
            </thead>
            <tbody id="tx-table-body">
              <tr><td colspan="5" style="text-align:center; color:var(--text-hint); padding:32px;">Loading...</td></tr>
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
  if (!auth.requireAuth()) throw new Error('Not authenticated');

  const mode    = auth.getMode();
  const profile = auth.getProfile();

  document.getElementById('sidebar').innerHTML = buildSidebar(mode);
  document.getElementById('mode-badge').textContent = mode;
  document.getElementById('user-email').textContent  = profile?.email || '';

  async function loadDashboard() {
    try {
      const { merchants } = await api.merchants.list();
      document.getElementById('stat-merchants').textContent = merchants.filter(m => m.is_active).length;

      const tbody = document.getElementById('tx-table-body');
      if (!merchants.length) {
        tbody.innerHTML = `<tr><td colspan="5"><div class="empty-state">
          <div class="empty-state-icon">◈</div>
          <h3>No merchants yet</h3>
          <p>Register your first merchant to get started</p>
        </div></td></tr>`;
        return;
      }
      tbody.innerHTML = `<tr><td colspan="5" style="text-align:center; color:var(--text-hint); padding:24px;">
        Transaction history loads in Phase 3</td></tr>`;
    } catch (err) {
      toast.error('Failed to load dashboard: ' + err.message);
    }
  }

  loadDashboard();
</script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 24. FRONTEND — pages/developer/merchants.html (stub)
# ───────────────────────────────────────────────────────────
cat > frontend/pages/developer/merchants.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SETTL — Merchants</title>
  <link rel="stylesheet" href="../../css/app.css" />
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <span class="topbar-title">Merchants</span>
      <span class="badge badge-info">developer</span>
    </div>
    <div class="page-body">
      <div class="card" style="margin-bottom:20px;">
        <p style="color:var(--text-muted);">
          Merchant registration (on-chain) is wired in <strong>Phase 2</strong>.
          The form and contract call will appear here.
        </p>
      </div>
      <div class="card">
        <h2 style="font-size:16px; font-weight:500; margin-bottom:16px;">Registered merchants</h2>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Merchant ID</th><th>Wallet</th><th>Status</th><th>Registered</th></tr></thead>
            <tbody id="merchant-table">
              <tr><td colspan="4" style="text-align:center; padding:32px; color:var(--text-hint);">Loading...</td></tr>
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

  api.merchants.list().then(({ merchants }) => {
    const tbody = document.getElementById('merchant-table');
    if (!merchants.length) {
      tbody.innerHTML = `<tr><td colspan="4" style="text-align:center; padding:32px; color:var(--text-hint);">No merchants registered yet</td></tr>`;
      return;
    }
    tbody.innerHTML = merchants.map(m => `
      <tr>
        <td style="font-family:var(--font-mono); font-size:13px;">${m.merchant_id}</td>
        <td style="font-family:var(--font-mono); font-size:12px;">${m.wallet_address?.slice(0,8)}…</td>
        <td><span class="badge ${m.is_active ? 'badge-success' : 'badge-pending'}">${m.is_active ? 'Active' : 'Pending'}</span></td>
        <td style="color:var(--text-muted); font-size:13px;">${m.created_at ? new Date(m.created_at).toLocaleDateString() : '—'}</td>
      </tr>`).join('');
  }).catch(err => toast.error(err.message));
</script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 25. FRONTEND — pages/operator/balance.html (stub)
# ───────────────────────────────────────────────────────────
cat > frontend/pages/operator/balance.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>SETTL — Balance</title>
  <link rel="stylesheet" href="../../css/app.css" />
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <span class="topbar-title">Balance</span>
      <span class="badge badge-success">operator</span>
    </div>
    <div class="page-body">
      <div class="card-grid">
        <div class="card">
          <div class="card-title">Pending balance</div>
          <div class="card-value">—</div>
          <div class="card-sub">Releases at 6am daily</div>
        </div>
        <div class="card">
          <div class="card-title">Total released</div>
          <div class="card-value">—</div>
          <div class="card-sub">All time AUDD</div>
        </div>
        <div class="card">
          <div class="card-title">Total fees paid</div>
          <div class="card-value">—</div>
          <div class="card-sub">1.5% per release</div>
        </div>
      </div>
      <div class="card">
        <p style="color:var(--text-muted);">Live balance from escrow vault loads in <strong>Phase 2</strong> once contract integration is complete.</p>
      </div>
    </div>
  </div>
</div>
<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('operator');
</script>
</body>
</html>
EOF

# ───────────────────────────────────────────────────────────
# 26. README
# ───────────────────────────────────────────────────────────
cat > README.md << 'EOF'
# SETTL — Payment Gateway

Solana-based AUDD escrow payment gateway.
Program ID: `RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn`

## Setup

### 1. Install dependencies
```bash
cd backend && npm install
```

### 2. Configure environment
```bash
cp backend/.env.example backend/.env
# Fill in your Supabase and Solana values
```

### 3. Run Supabase migration
Paste `supabase/migrations/001_initial_schema.sql` into your Supabase SQL editor and run it.

### 4. Start the backend
```bash
npm run dev
```

### 5. Serve the frontend
```bash
# From the repo root — any static server works
npx serve frontend -p 5500
# or
python3 -m http.server 5500 --directory frontend
```

Open http://localhost:5500

## Structure
```
settl/
├── backend/src/
│   ├── config/      supabase.js, anchor.js
│   ├── middleware/  auth.js, apiKey.js
│   ├── routes/      health.js, auth.js, merchants.js
│   └── server.js
├── frontend/
│   ├── css/         app.css
│   ├── js/modules/  api.js, auth.js, toast.js, nav.js
│   └── pages/       auth/, developer/, operator/
└── supabase/
    └── migrations/  001_initial_schema.sql
```

## Phases
- **Phase 1** (this) — scaffold, auth, schema, shell UI ✓
- **Phase 2** — Anchor SDK, register_merchant, escrow init
- **Phase 3** — deposits, 6am cron release, operator dashboard
- **Phase 4** — webhooks, realtime, API keys, CSV export
EOF

# ───────────────────────────────────────────────────────────
# 27. Install backend dependencies
# ───────────────────────────────────────────────────────────
log "Installing backend dependencies..."
cd backend
npm install --silent
cd ..

# ───────────────────────────────────────────────────────────
# Done
# ───────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Phase 1 — Setup complete           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Next steps:${NC}"
echo ""
echo -e "  1. Copy and fill your env file:"
echo -e "     ${YELLOW}cp backend/.env.example backend/.env${NC}"
echo ""
echo -e "  2. Run the Supabase migration:"
echo -e "     ${YELLOW}Paste supabase/migrations/001_initial_schema.sql${NC}"
echo -e "     into your Supabase SQL editor and execute it."
echo ""
echo -e "  3. Start the backend:"
echo -e "     ${YELLOW}npm run dev${NC}"
echo ""
echo -e "  4. Serve the frontend:"
echo -e "     ${YELLOW}npx serve frontend -p 5500${NC}"
echo ""
echo -e "  5. Open ${BLUE}http://localhost:5500${NC}"
echo ""
warn "Add your authority keypair.json to the backend/ folder before Phase 2."
echo ""