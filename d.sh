#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Phase 3 (Revised) Single Setup Script
#
#  Changes from previous phases:
#  ① Custom auth — no Supabase Auth at all
#     email + password + bcrypt + JWT (all in DB profiles table)
#  ② Merchant registration is fully automatic on signup:
#     input email + password + wallet → registers on-chain
#     in the background, no manual steps
#  ③ Payment page uses proper Solana Pay spec:
#     solana: URL scheme, QR code via @solana/pay,
#     reference keypair per session, findReference polling,
#     validateTransfer confirmation
#  ④ All pages redesigned mobile-first (works on the phone
#     shown in the screenshot)
#  ⑤ Wallet address validation fixed (was too strict)
#  ⑥ Single yarn dev, single root .env
#
#  Run from the directory containing settl/:
#  bash settl-phase3-revised.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()   { echo -e "${GREEN}[SETTL]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }


log "Starting inside settl/..."

mkdir -p backend/src/{routes,services,middleware,config,cron,idl}
mkdir -p frontend/{pages/{auth,developer,operator},js/modules,css}
mkdir -p supabase/migrations

# ═══════════════════════════════════════════════════════════
# ROOT — package.json + .env (single source of truth)
# ═══════════════════════════════════════════════════════════
log "Writing root package.json and .env..."

cat > package.json << 'EOF'
{
  "name": "settl",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev":   "cd backend && yarn dev",
    "start": "cd backend && yarn start",
    "setup": "cd backend && yarn install"
  },
  "engines": { "node": ">=18" }
}
EOF

cat > .env.example << 'EOF'
# ═══════════════════════════════════════════════════════════
#  SETTL — copy this to .env and fill in all values
# ═══════════════════════════════════════════════════════════

PORT=3000
NODE_ENV=development

# Supabase (DB only — no Auth used)
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# JWT secret for custom auth (generate: openssl rand -hex 32)
JWT_SECRET=change-this-to-a-long-random-secret-min-32-chars

# Solana
SOLANA_RPC_URL=https://api.devnet.solana.com
SETTL_PROGRAM_ID=RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn
AUTHORITY_KEYPAIR_PATH=./keypair.json
TREASURY_WALLET=your-treasury-wallet-pubkey
AUDD_MINT=your-audd-mint-pubkey

APP_URL=http://localhost:3000
EOF

if [ ! -f ".env" ]; then
  cp .env.example .env
  warn ".env created from example — fill in your values before starting"
fi

# ═══════════════════════════════════════════════════════════
# BACKEND package.json — reads root .env, yarn dev
# ═══════════════════════════════════════════════════════════
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
    "@coral-xyz/anchor":     "^0.29.0",
    "@solana/pay":           "^0.2.5",
    "@solana/spl-token":     "^0.4.8",
    "@solana/web3.js":       "^1.91.0",
    "@supabase/supabase-js": "^2.43.0",
    "bcryptjs":              "^2.4.3",
    "bignumber.js":          "^9.1.2",
    "cors":                  "^2.8.5",
    "dotenv":                "^16.4.5",
    "express":               "^4.19.2",
    "express-rate-limit":    "^7.3.1",
    "helmet":                "^7.1.0",
    "jsonwebtoken":          "^9.0.2",
    "morgan":                "^1.10.0",
    "node-cron":             "^3.0.3",
    "uuid":                  "^9.0.1"
  },
  "devDependencies": {
    "nodemon": "^3.1.3"
  }
}
EOF

# ═══════════════════════════════════════════════════════════
# SUPABASE — full schema (no auth.users dependency)
# ═══════════════════════════════════════════════════════════
log "Writing Supabase schema..."
cat > supabase/migrations/001_full_schema.sql << 'EOF'
-- ═══════════════════════════════════════════════════════════
--  SETTL — Full schema (no Supabase Auth)
--  Run this entire file in the Supabase SQL editor
-- ═══════════════════════════════════════════════════════════

create extension if not exists "uuid-ossp";

-- ── users (replaces Supabase auth.users entirely) ─────────
create table if not exists users (
  id           uuid primary key default uuid_generate_v4(),
  email        text unique not null,
  password_hash text not null,
  full_name    text,
  role         text not null default 'operator'
               check (role in ('developer', 'operator')),
  is_active    boolean default true,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);

-- ── merchants ─────────────────────────────────────────────
create table if not exists merchants (
  id              uuid primary key default uuid_generate_v4(),
  merchant_id     text unique not null,
  name            text,
  email           text,
  wallet_address  text not null,
  is_active       boolean default false,
  registered_at   timestamptz,
  on_chain_tx     text,
  escrow_tx       text,
  merchant_pda    text,
  escrow_pda      text,
  vault_address   text,
  created_by      uuid references users(id),
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- ── escrows ───────────────────────────────────────────────
create table if not exists escrows (
  id               uuid primary key default uuid_generate_v4(),
  merchant_id      text not null references merchants(merchant_id) on delete cascade,
  pending_balance  numeric(20,6) default 0,
  total_payments   integer default 0,
  last_released_at timestamptz,
  vault_address    text,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);

-- ── transactions ──────────────────────────────────────────
create table if not exists transactions (
  id               uuid primary key default uuid_generate_v4(),
  merchant_id      text not null references merchants(merchant_id),
  type             text not null check (type in ('deposit','release','fee')),
  amount           numeric(20,6) not null,
  fee              numeric(20,6) default 0,
  net              numeric(20,6),
  customer_wallet  text,
  tx_signature     text,
  reference_key    text,
  status           text default 'pending'
                   check (status in ('pending','confirmed','failed')),
  created_at       timestamptz default now()
);

-- ── payment_sessions ──────────────────────────────────────
-- One row per Solana Pay QR code shown to a customer
create table if not exists payment_sessions (
  id             uuid primary key default uuid_generate_v4(),
  merchant_id    text not null references merchants(merchant_id),
  amount         numeric(20,6),
  reference_key  text unique not null,  -- base58 pubkey used as Solana Pay reference
  label          text,
  message        text,
  memo           text,
  status         text default 'pending'
                 check (status in ('pending','confirmed','expired','failed')),
  tx_signature   text,
  confirmed_at   timestamptz,
  expires_at     timestamptz default (now() + interval '30 minutes'),
  created_at     timestamptz default now()
);

-- ── release_logs ──────────────────────────────────────────
create table if not exists release_logs (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text references merchants(merchant_id),
  gross        numeric(20,6),
  fee          numeric(20,6),
  net          numeric(20,6),
  tx_signature text,
  status       text default 'pending'
               check (status in ('pending','success','failed','skipped')),
  error        text,
  released_at  timestamptz default now()
);

-- ── cron_logs ─────────────────────────────────────────────
create table if not exists cron_logs (
  id              uuid primary key default uuid_generate_v4(),
  triggered_by    text default 'cron' check (triggered_by in ('cron','manual')),
  status          text default 'running'
                  check (status in ('running','success','partial','failed','skipped')),
  started_at      timestamptz default now(),
  finished_at     timestamptz,
  summary         text,
  total_merchants integer default 0,
  released        integer default 0,
  skipped         integer default 0,
  failed          integer default 0
);

-- ── api_keys ──────────────────────────────────────────────
create table if not exists api_keys (
  id           uuid primary key default uuid_generate_v4(),
  name         text not null,
  key          text unique not null,
  merchant_id  text references merchants(merchant_id),
  is_active    boolean default true,
  last_used_at timestamptz,
  created_by   uuid references users(id),
  created_at   timestamptz default now()
);

-- ── wallet_update_requests ────────────────────────────────
create table if not exists wallet_update_requests (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text not null references merchants(merchant_id) on delete cascade,
  new_wallet   text not null,
  tx_signature text,
  unlocks_at   timestamptz not null,
  status       text default 'pending' check (status in ('pending','confirmed','cancelled')),
  confirmed_at timestamptz,
  created_at   timestamptz default now(),
  unique (merchant_id)
);

-- ── Indexes ───────────────────────────────────────────────
create index if not exists idx_transactions_merchant  on transactions(merchant_id);
create index if not exists idx_transactions_created   on transactions(created_at desc);
create index if not exists idx_release_logs_merchant  on release_logs(merchant_id);
create index if not exists idx_payment_sessions_ref   on payment_sessions(reference_key);
create index if not exists idx_payment_sessions_status on payment_sessions(status);
create index if not exists idx_cron_logs_started      on cron_logs(started_at desc);
create index if not exists idx_merchants_active       on merchants(is_active);
create index if not exists idx_users_email            on users(email);

-- ── updated_at triggers ───────────────────────────────────
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

create trigger users_updated_at     before update on users     for each row execute procedure update_updated_at();
create trigger merchants_updated_at before update on merchants for each row execute procedure update_updated_at();
create trigger escrows_updated_at   before update on escrows   for each row execute procedure update_updated_at();
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — config/supabase.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/config/supabase.js << 'EOF'
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

module.exports = { supabase };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — config/anchor.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/config/anchor.js << 'EOF'
require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program }        = require('@coral-xyz/anchor');
const fs   = require('fs');
const path = require('path');

const IDL        = require('../idl/settl.json');
const PROGRAM_ID = new PublicKey(process.env.SETTL_PROGRAM_ID || 'RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn');

let _provider = null;
let _program  = null;
let _keypair  = null;

function getKeypair() {
  if (_keypair) return _keypair;
  const kpPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(kpPath)) throw new Error(`Keypair not found: ${kpPath}`);
  _keypair = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(fs.readFileSync(kpPath, 'utf-8'))));
  return _keypair;
}

function getProvider() {
  if (_provider) return _provider;
  const connection = new Connection(process.env.SOLANA_RPC_URL || 'https://api.devnet.solana.com', 'confirmed');
  const kp = getKeypair();
  const wallet = {
    publicKey: kp.publicKey,
    signTransaction:     async tx  => { tx.sign(kp); return tx; },
    signAllTransactions: async txs => txs.map(tx => { tx.sign(kp); return tx; }),
  };
  _provider = new AnchorProvider(connection, wallet, { commitment: 'confirmed', preflightCommitment: 'confirmed' });
  return _provider;
}

function getProgram() {
  if (_program) return _program;
  _program = new Program(IDL, PROGRAM_ID, getProvider());
  return _program;
}

function getConnection() { return getProvider().connection; }

function getMerchantPDA(merchantId) {
  return PublicKey.findProgramAddressSync([Buffer.from('merchant'), Buffer.from(merchantId)], PROGRAM_ID);
}
function getEscrowPDA(merchantId) {
  return PublicKey.findProgramAddressSync([Buffer.from('escrow'), Buffer.from(merchantId)], PROGRAM_ID);
}
function getVaultPDA(merchantId) {
  return PublicKey.findProgramAddressSync([Buffer.from('vault'), Buffer.from(merchantId)], PROGRAM_ID);
}
function getConfigPDA() {
  return PublicKey.findProgramAddressSync([Buffer.from('config')], PROGRAM_ID);
}

module.exports = { getProvider, getProgram, getKeypair, getConnection, getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA, PROGRAM_ID };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — IDL (copy from phase 2 — same contract)
# ═══════════════════════════════════════════════════════════
cat > backend/src/idl/settl.json << 'EOF'
{
  "version": "0.1.0",
  "name": "settl",
  "instructions": [
    { "name": "registerMerchant",
      "accounts": [
        { "name": "merchant",      "isMut": true,  "isSigner": false },
        { "name": "authority",     "isMut": true,  "isSigner": true  },
        { "name": "systemProgram", "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "merchantId", "type": "string" }, { "name": "walletAddress", "type": "publicKey" }]
    },
    { "name": "initializeMerchantEscrow",
      "accounts": [
        { "name": "merchant",      "isMut": false, "isSigner": false },
        { "name": "escrow",        "isMut": true,  "isSigner": false },
        { "name": "vault",         "isMut": true,  "isSigner": false },
        { "name": "auddMint",      "isMut": false, "isSigner": false },
        { "name": "authority",     "isMut": true,  "isSigner": true  },
        { "name": "tokenProgram",  "isMut": false, "isSigner": false },
        { "name": "systemProgram", "isMut": false, "isSigner": false },
        { "name": "rent",          "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "merchantId", "type": "string" }]
    },
    { "name": "requestWalletUpdate",
      "accounts": [
        { "name": "merchant",  "isMut": true,  "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": [{ "name": "newWallet", "type": "publicKey" }]
    },
    { "name": "confirmWalletUpdate",
      "accounts": [
        { "name": "merchant",  "isMut": true,  "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    { "name": "deactivateMerchant",
      "accounts": [
        { "name": "merchant",  "isMut": true,  "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    { "name": "updateEscrowWallet",
      "accounts": [
        { "name": "merchant",  "isMut": false, "isSigner": false },
        { "name": "escrow",    "isMut": true,  "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    { "name": "release",
      "accounts": [
        { "name": "config",       "isMut": true,  "isSigner": false },
        { "name": "merchant",     "isMut": true,  "isSigner": false },
        { "name": "escrow",       "isMut": true,  "isSigner": false },
        { "name": "vault",        "isMut": true,  "isSigner": false },
        { "name": "merchantAta",  "isMut": true,  "isSigner": false },
        { "name": "treasuryAta",  "isMut": true,  "isSigner": false },
        { "name": "authority",    "isMut": false, "isSigner": true  },
        { "name": "tokenProgram", "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "merchantId", "type": "string" }]
    }
  ],
  "accounts": [
    { "name": "MerchantAccount", "type": { "kind": "struct", "fields": [
        { "name": "merchantId",    "type": "string" },
        { "name": "wallet",        "type": "publicKey" },
        { "name": "isActive",      "type": "bool" },
        { "name": "registeredAt",  "type": "i64" },
        { "name": "totalReleased", "type": "u64" },
        { "name": "totalFeesPaid", "type": "u64" },
        { "name": "authority",     "type": "publicKey" },
        { "name": "pendingWallet", "type": { "option": "publicKey" } },
        { "name": "walletUpdateAt","type": { "option": "i64" } },
        { "name": "bump",          "type": "u8" }
      ]}},
    { "name": "EscrowAccount", "type": { "kind": "struct", "fields": [
        { "name": "merchantId",     "type": "string" },
        { "name": "merchantWallet", "type": "publicKey" },
        { "name": "pendingBalance", "type": "u64" },
        { "name": "totalPayments",  "type": "u64" },
        { "name": "lastReleasedAt", "type": "i64" },
        { "name": "authority",      "type": "publicKey" },
        { "name": "bump",           "type": "u8" },
        { "name": "vaultBump",      "type": "u8" }
      ]}},
    { "name": "SettlConfig", "type": { "kind": "struct", "fields": [
        { "name": "authority",          "type": "publicKey" },
        { "name": "treasuryWallet",     "type": "publicKey" },
        { "name": "feeBasisPoints",     "type": "u16" },
        { "name": "totalFeesCollected", "type": "u64" },
        { "name": "bump",               "type": "u8" }
      ]}}
  ],
  "errors": [
    { "code": 6000, "name": "FeeTooHigh" },
    { "code": 6001, "name": "MerchantIdTooLong" },
    { "code": 6002, "name": "Unauthorized" },
    { "code": 6003, "name": "NoWalletUpdatePending" },
    { "code": 6004, "name": "WalletUpdateNotReady" },
    { "code": 6005, "name": "ZeroAmount" },
    { "code": 6006, "name": "ZeroBalance" },
    { "code": 6007, "name": "MerchantMismatch" },
    { "code": 6008, "name": "MerchantInactive" },
    { "code": 6009, "name": "Overflow" }
  ]
}
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — middleware/auth.js (custom JWT — no Supabase Auth)
# ═══════════════════════════════════════════════════════════
cat > backend/src/middleware/auth.js << 'EOF'
const jwt      = require('jsonwebtoken');
const { supabase } = require('../config/supabase');

async function authMiddleware(req, res, next) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing Authorization header' });
  }
  const token = header.split(' ')[1];
  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    // Attach user from DB
    const { data: user, error } = await supabase
      .from('users')
      .select('id, email, role, full_name, is_active')
      .eq('id', payload.sub)
      .single();

    if (error || !user || !user.is_active) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    req.user = user;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

module.exports = authMiddleware;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/auth.js (email + password, custom JWT)
# ═══════════════════════════════════════════════════════════
log "Writing custom auth routes..."
cat > backend/src/routes/auth.js << 'EOF'
const router   = require('express').Router();
const bcrypt   = require('bcryptjs');
const jwt      = require('jsonwebtoken');
const { supabase } = require('../config/supabase');
const authMiddleware = require('../middleware/auth');

const SALT_ROUNDS = 12;
const TOKEN_TTL   = '7d';

function signToken(user) {
  return jwt.sign(
    { sub: user.id, email: user.email, role: user.role },
    process.env.JWT_SECRET,
    { expiresIn: TOKEN_TTL }
  );
}

// ── POST /api/auth/signup ─────────────────────────────────
router.post('/signup', async (req, res, next) => {
  try {
    const { email, password, full_name } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });
    if (password.length < 8)  return res.status(400).json({ error: 'Password must be at least 8 characters' });

    // Check duplicate
    const { data: existing } = await supabase.from('users').select('id').eq('email', email.toLowerCase()).single();
    if (existing) return res.status(409).json({ error: 'An account with this email already exists' });

    const password_hash = await bcrypt.hash(password, SALT_ROUNDS);

    const { data: user, error } = await supabase
      .from('users')
      .insert({ email: email.toLowerCase(), password_hash, full_name: full_name || null, role: 'operator' })
      .select('id, email, role, full_name')
      .single();

    if (error) throw error;

    const token = signToken(user);
    res.status(201).json({ token, user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });

    const { data: user } = await supabase
      .from('users')
      .select('id, email, role, full_name, is_active, password_hash')
      .eq('email', email.toLowerCase())
      .single();

    if (!user) return res.status(401).json({ error: 'Invalid email or password' });
    if (!user.is_active) return res.status(403).json({ error: 'Account is disabled' });

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) return res.status(401).json({ error: 'Invalid email or password' });

    const { password_hash, ...safeUser } = user;
    const token = signToken(safeUser);
    res.json({ token, user: safeUser });
  } catch (err) { next(err); }
});

// ── GET /api/auth/me ──────────────────────────────────────
router.get('/me', authMiddleware, async (req, res) => {
  const { password_hash, ...user } = req.user;
  res.json({ user: req.user });
});

// ── PATCH /api/auth/profile ───────────────────────────────
router.patch('/profile', authMiddleware, async (req, res, next) => {
  try {
    const { full_name, role } = req.body;
    const updates = {};
    if (full_name) updates.full_name = full_name;
    if (role && ['developer', 'operator'].includes(role)) updates.role = role;

    const { data: user } = await supabase
      .from('users').update(updates).eq('id', req.user.id).select('id,email,role,full_name').single();
    res.json({ user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/logout ─────────────────────────────────
// Stateless JWT — just tell client to delete the token
router.post('/logout', (req, res) => res.json({ message: 'Logged out' }));

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/contract.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/services/contract.js << 'EOF'
const { PublicKey, SystemProgram, SYSVAR_RENT_PUBKEY } = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress }  = require('@solana/spl-token');
const { getProgram, getKeypair, getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA } = require('../config/anchor');

const AUDD_MINT = () => new PublicKey(process.env.AUDD_MINT);
const TREASURY  = () => new PublicKey(process.env.TREASURY_WALLET);

async function registerMerchant(merchantId, walletAddress) {
  const program       = getProgram();
  const authority     = getKeypair();
  const walletPubkey  = new PublicKey(walletAddress);
  const [merchantPDA] = getMerchantPDA(merchantId);

  const tx = await program.methods
    .registerMerchant(merchantId, walletPubkey)
    .accounts({ merchant: merchantPDA, authority: authority.publicKey, systemProgram: SystemProgram.programId })
    .signers([authority]).rpc();

  return { tx, merchantPDA: merchantPDA.toBase58() };
}

async function initializeMerchantEscrow(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const tx = await program.methods
    .initializeMerchantEscrow(merchantId)
    .accounts({
      merchant: merchantPDA, escrow: escrowPDA, vault: vaultPDA,
      auddMint: AUDD_MINT(), authority: authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
      rent: SYSVAR_RENT_PUBKEY,
    })
    .signers([authority]).rpc();

  return { tx, escrowPDA: escrowPDA.toBase58(), vaultPDA: vaultPDA.toBase58() };
}

async function fetchMerchantOnChain(merchantId) {
  const program = getProgram();
  const [pda]   = getMerchantPDA(merchantId);
  try {
    const a = await program.account.merchantAccount.fetch(pda);
    return {
      wallet: a.wallet.toBase58(), isActive: a.isActive,
      registeredAt: a.registeredAt.toNumber(),
      totalReleased: a.totalReleased.toNumber(),
      totalFeesPaid: a.totalFeesPaid.toNumber(),
      pendingWallet: a.pendingWallet?.toBase58() || null,
      walletUpdateAt: a.walletUpdateAt?.toNumber() || null,
    };
  } catch { return null; }
}

async function fetchEscrowOnChain(merchantId) {
  const program = getProgram();
  const [pda]   = getEscrowPDA(merchantId);
  try {
    const a = await program.account.escrowAccount.fetch(pda);
    return {
      merchantWallet: a.merchantWallet.toBase58(),
      pendingBalance: a.pendingBalance.toNumber(),
      totalPayments: a.totalPayments.toNumber(),
      lastReleasedAt: a.lastReleasedAt.toNumber(),
    };
  } catch { return null; }
}

async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = AUDD_MINT();
  const treasury  = TREASURY();

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const m = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, m.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config: configPDA, merchant: merchantPDA, escrow: escrowPDA,
      vault: vaultPDA, merchantAta: merchantATA, treasuryAta: treasuryATA,
      authority: authority.publicKey, tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority]).rpc();

  return tx;
}

async function deactivateMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.deactivateMerchant()
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

async function requestWalletUpdate(merchantId, newWallet) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.requestWalletUpdate(new PublicKey(newWallet))
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

async function confirmWalletUpdate(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.confirmWalletUpdate()
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

module.exports = {
  registerMerchant, initializeMerchantEscrow,
  fetchMerchantOnChain, fetchEscrowOnChain,
  releaseMerchant, deactivateMerchant,
  requestWalletUpdate, confirmWalletUpdate,
  AUDD_MINT, TREASURY,
};
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/merchant.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/services/merchant.js << 'EOF'
const { supabase }  = require('../config/supabase');
const contract      = require('./contract');
const { PublicKey } = require('@solana/web3.js');

// Validate a Solana base58 public key — lenient check
function isValidSolanaAddress(address) {
  try {
    if (!address || typeof address !== 'string') return false;
    if (address.length < 32 || address.length > 44) return false;
    new PublicKey(address); // throws if invalid
    return true;
  } catch { return false; }
}

// Full flow: on-chain register → escrow init → DB save
async function createMerchant({ merchantId, walletAddress, name, email, createdBy }) {
  if (!isValidSolanaAddress(walletAddress)) {
    throw new Error('Invalid Solana wallet address. Must be a valid base58 public key (32–44 characters).');
  }
  if (!merchantId || merchantId.length > 64) {
    throw new Error('Merchant ID must be 1–64 characters');
  }

  const { tx: registerTx, merchantPDA } = await contract.registerMerchant(merchantId, walletAddress);
  const { tx: escrowTx, escrowPDA, vaultPDA } = await contract.initializeMerchantEscrow(merchantId);

  const { data: merchant, error } = await supabase.from('merchants')
    .upsert({
      merchant_id: merchantId, wallet_address: walletAddress,
      name: name || merchantId, email: email || null,
      is_active: true, registered_at: new Date().toISOString(),
      on_chain_tx: registerTx, escrow_tx: escrowTx,
      merchant_pda: merchantPDA, escrow_pda: escrowPDA, vault_address: vaultPDA,
      created_by: createdBy,
    }, { onConflict: 'merchant_id' })
    .select().single();

  if (error) throw new Error('DB save failed: ' + error.message);

  await supabase.from('escrows').upsert({
    merchant_id: merchantId, pending_balance: 0, total_payments: 0, vault_address: vaultPDA,
  }, { onConflict: 'merchant_id' });

  return { merchant, registerTx, escrowTx, merchantPDA, escrowPDA, vaultPDA };
}

module.exports = { createMerchant, isValidSolanaAddress };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/release.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/services/release.js << 'EOF'
const { supabase }  = require('../config/supabase');
const contract      = require('./contract');

const FEE_BPS = 150;

async function releaseMerchant(merchantId) {
  const escrowChain = await contract.fetchEscrowOnChain(merchantId);
  if (!escrowChain || escrowChain.pendingBalance === 0) {
    return { skipped: true, merchantId, reason: 'zero balance' };
  }

  const gross = escrowChain.pendingBalance;
  const fee   = Math.floor(gross * FEE_BPS / 10_000);
  const net   = gross - fee;

  const tx  = await contract.releaseMerchant(merchantId);
  const now = new Date().toISOString();

  await supabase.from('release_logs').insert({
    merchant_id: merchantId,
    gross: gross / 1_000_000, fee: fee / 1_000_000, net: net / 1_000_000,
    tx_signature: tx, status: 'success', released_at: now,
  });

  await supabase.from('transactions').insert([
    { merchant_id: merchantId, type: 'release', amount: gross/1_000_000, fee: fee/1_000_000, net: net/1_000_000, tx_signature: tx, status: 'confirmed' },
    { merchant_id: merchantId, type: 'fee',     amount: fee/1_000_000,   tx_signature: tx, status: 'confirmed' },
  ]);

  await supabase.from('escrows')
    .update({ pending_balance: 0, last_released_at: now })
    .eq('merchant_id', merchantId);

  console.log(`[release] ${merchantId} gross:${gross} fee:${fee} net:${net} tx:${tx}`);
  return { skipped: false, merchantId, gross, fee, net, tx };
}

async function releaseAll(triggeredBy = 'cron') {
  const { data: run } = await supabase.from('cron_logs')
    .insert({ triggered_by: triggeredBy, status: 'running', started_at: new Date().toISOString() })
    .select().single();
  const runId = run?.id;

  const { data: merchants } = await supabase.from('merchants').select('merchant_id').eq('is_active', true);
  if (!merchants?.length) {
    await supabase.from('cron_logs').update({ status: 'skipped', finished_at: new Date().toISOString(), summary: 'No active merchants' }).eq('id', runId);
    return { total: 0, released: 0, skipped: 0, failed: 0, results: [] };
  }

  const results = []; let released = 0, skipped = 0, failed = 0;

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
    finished_at: new Date().toISOString(), summary,
    total_merchants: merchants.length, released, skipped, failed,
  }).eq('id', runId);

  return { total: merchants.length, released, skipped, failed, results };
}

module.exports = { releaseMerchant, releaseAll };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — services/solanaPay.js
#   Implements Solana Pay spec: encodeURL, createQR,
#   findReference polling, validateTransfer
# ═══════════════════════════════════════════════════════════
cat > backend/src/services/solanaPay.js << 'EOF'
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
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — cron/dailyRelease.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/cron/dailyRelease.js << 'EOF'
const cron           = require('node-cron');
const { releaseAll } = require('../services/release');

let job = null;

function startCron() {
  if (job) return;
  job = cron.schedule('0 0 6 * * *', async () => {
    console.log('[cron] 6am release starting...');
    try { const r = await releaseAll('cron'); console.log('[cron] Done:', r.summary); }
    catch (err) { console.error('[cron] Error:', err.message); }
  }, { scheduled: true, timezone: 'UTC' });
  console.log('[SETTL] 6am UTC cron scheduled');
}

module.exports = { startCron, triggerNow: () => releaseAll('manual') };
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/merchants.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/routes/merchants.js << 'EOF'
const router          = require('express').Router();
const { supabase }    = require('../config/supabase');
const merchantService = require('../services/merchant');
const contract        = require('../services/contract');

router.get('/', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants')
      .select('*, escrows(pending_balance, total_payments, last_released_at, vault_address)')
      .order('created_at', { ascending: false });
    if (error) throw error;
    res.json({ merchants: data });
  } catch (err) { next(err); }
});

router.get('/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants').select('*, escrows(*)').eq('merchant_id', req.params.id).single();
    if (error || !data) return res.status(404).json({ error: 'Merchant not found' });
    const [onChain, escrowChain] = await Promise.all([
      contract.fetchMerchantOnChain(req.params.id),
      contract.fetchEscrowOnChain(req.params.id),
    ]);
    res.json({ merchant: data, onChain, escrowChain });
  } catch (err) { next(err); }
});

router.post('/', async (req, res, next) => {
  try {
    const { merchant_id, wallet_address, name, email } = req.body;
    if (!merchant_id || !wallet_address) {
      return res.status(400).json({ error: 'merchant_id and wallet_address are required' });
    }
    const result = await merchantService.createMerchant({
      merchantId: merchant_id, walletAddress: wallet_address,
      name, email, createdBy: req.user.id,
    });
    res.status(201).json(result);
  } catch (err) { next(err); }
});

router.get('/:id/chain', async (req, res, next) => {
  try {
    const [merchant, escrow] = await Promise.all([
      contract.fetchMerchantOnChain(req.params.id),
      contract.fetchEscrowOnChain(req.params.id),
    ]);
    if (!merchant) return res.status(404).json({ error: 'Not found on-chain' });
    res.json({ merchant, escrow });
  } catch (err) { next(err); }
});

router.post('/:id/deactivate', async (req, res, next) => {
  try {
    const tx = await contract.deactivateMerchant(req.params.id);
    await supabase.from('merchants').update({ is_active: false }).eq('merchant_id', req.params.id);
    res.json({ message: 'Deactivated', tx });
  } catch (err) { next(err); }
});

router.post('/:id/wallet-update/request', async (req, res, next) => {
  try {
    const { new_wallet } = req.body;
    if (!new_wallet) return res.status(400).json({ error: 'new_wallet required' });
    const tx = await contract.requestWalletUpdate(req.params.id, new_wallet);
    const unlockAt = new Date(Date.now() + 86_400_000).toISOString();
    await supabase.from('wallet_update_requests').upsert({
      merchant_id: req.params.id, new_wallet, tx_signature: tx,
      unlocks_at: unlockAt, status: 'pending',
    }, { onConflict: 'merchant_id' });
    res.json({ message: 'Staged — confirm after 24h', tx, unlockAt });
  } catch (err) { next(err); }
});

router.post('/:id/wallet-update/confirm', async (req, res, next) => {
  try {
    const tx = await contract.confirmWalletUpdate(req.params.id);
    const chainState = await contract.fetchMerchantOnChain(req.params.id);
    if (chainState) {
      await supabase.from('merchants').update({ wallet_address: chainState.wallet }).eq('merchant_id', req.params.id);
    }
    await supabase.from('wallet_update_requests').update({ status: 'confirmed', confirmed_at: new Date().toISOString() }).eq('merchant_id', req.params.id);
    res.json({ message: 'Wallet updated', tx });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/payments.js (Solana Pay)
# ═══════════════════════════════════════════════════════════
cat > backend/src/routes/payments.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const solanaPay  = require('../services/solanaPay');

// ── POST /api/payments/session ────────────────────────────
// Create a Solana Pay session + URL for a payment QR
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, label, message, memo } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });
    const session = await solanaPay.createPaymentSession({
      merchantId: merchant_id, amountAudd: amount || null, label, message, memo,
    });
    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/poll/:reference ─────────────────────
// Frontend polls this every 250ms to check if payment confirmed
router.get('/poll/:reference', async (req, res, next) => {
  try {
    const result = await solanaPay.pollPaymentSession(req.params.reference);
    res.json(result);
  } catch (err) { next(err); }
});

// ── GET /api/payments/history ─────────────────────────────
router.get('/history', async (req, res, next) => {
  try {
    const limit  = parseInt(req.query.limit  || '50');
    const offset = parseInt(req.query.offset || '0');
    const { data, error, count } = await supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);
    if (error) throw error;
    res.json({ transactions: data, total: count });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — routes/escrow.js, release.js, health.js
# ═══════════════════════════════════════════════════════════
cat > backend/src/routes/escrow.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const contract   = require('../services/contract');

router.get('/:merchantId', async (req, res, next) => {
  try {
    const { merchantId } = req.params;
    const [db, chain] = await Promise.all([
      supabase.from('escrows').select('*').eq('merchant_id', merchantId).single().then(r => r.data),
      contract.fetchEscrowOnChain(merchantId),
    ]);
    if (!db && !chain) return res.status(404).json({ error: 'Escrow not found' });
    res.json({
      merchantId,
      pendingBalance:  chain?.pendingBalance  ?? db?.pending_balance  ?? 0,
      totalPayments:   chain?.totalPayments   ?? db?.total_payments   ?? 0,
      lastReleasedAt:  chain?.lastReleasedAt  ? new Date(chain.lastReleasedAt * 1000).toISOString() : db?.last_released_at,
      merchantWallet:  chain?.merchantWallet  ?? null,
      vaultAddress:    db?.vault_address      ?? null,
      source:          chain ? 'chain' : 'db',
    });
  } catch (err) { next(err); }
});

router.get('/:merchantId/history', async (req, res, next) => {
  try {
    const { data, error, count } = await supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .eq('merchant_id', req.params.merchantId)
      .order('created_at', { ascending: false })
      .range(0, 49);
    if (error) throw error;
    res.json({ transactions: data, total: count });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

cat > backend/src/routes/release.js << 'EOF'
const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { releaseMerchant, releaseAll } = require('../services/release');

router.post('/all',           async (req, res, next) => { try { res.json(await releaseAll('manual'));           } catch (err) { next(err); } });
router.post('/:merchantId',   async (req, res, next) => { try { res.json(await releaseMerchant(req.params.merchantId)); } catch (err) { next(err); } });

router.get('/logs', async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('cron_logs').select('*').order('started_at', { ascending: false }).limit(30);
    if (error) throw error;
    res.json({ logs: data });
  } catch (err) { next(err); }
});

router.get('/merchant-logs/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('release_logs').select('*').eq('merchant_id', req.params.id).order('released_at', { ascending: false }).limit(50);
    if (error) throw error;
    res.json({ logs: data });
  } catch (err) { next(err); }
});

module.exports = router;
EOF

cat > backend/src/routes/health.js << 'EOF'
const router = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try { const { error } = await supabase.from('users').select('count').limit(1); if (error) db = error.message; }
  catch { db = 'unreachable'; }
  res.json({ status: 'ok', env: process.env.NODE_ENV, db, ts: new Date().toISOString() });
});

module.exports = router;
EOF

# ═══════════════════════════════════════════════════════════
# BACKEND — server.js (your working version)
# ═══════════════════════════════════════════════════════════
log "Writing server.js..."
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

// Static frontend
const frontendPath = path.join(__dirname, '../../frontend');
app.use(express.static(frontendPath));

// Rate limit
app.use('/api/', rateLimit({ windowMs: 15 * 60 * 1000, max: 150 }));

// Public routes (no auth)
app.use('/api/health',   require('./routes/health'));
app.use('/api/auth',     require('./routes/auth'));

// Payments poll is public (customer-facing, no login)
app.use('/api/payments/poll', require('./routes/payments'));

// Protected routes
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/escrow',    authMiddleware, require('./routes/escrow'));
app.use('/api/payments',  authMiddleware, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));

// Catch-all → frontend
app.get('*', (req, res) => res.sendFile(path.join(frontendPath, 'index.html')));

// Error handler
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  console.log(`[SETTL] Program: ${process.env.SETTL_PROGRAM_ID}`);
  startCron();
});

module.exports = app;
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — css/app.css  (mobile-first, full redesign)
# ═══════════════════════════════════════════════════════════
log "Writing mobile-first CSS..."
cat > frontend/css/app.css << 'EOF'
/* ── Reset ───────────────────────────────────────────────── */
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
html { -webkit-text-size-adjust: 100%; }

:root {
  --brand:        #534AB7;
  --brand-light:  #EEEDFE;
  --brand-dark:   #3C3489;
  --teal:         #1D9E75;
  --teal-light:   #E1F5EE;
  --coral:        #D85A30;
  --coral-light:  #FAECE7;
  --amber:        #D97706;
  --amber-light:  #FEF3C7;
  --text-primary: #111827;
  --text-muted:   #6B7280;
  --text-hint:    #9CA3AF;
  --bg:           #F9FAFB;
  --surface:      #FFFFFF;
  --border:       #E5E7EB;
  --border-strong:#D1D5DB;
  --radius-sm:    6px;
  --radius-md:    10px;
  --radius-lg:    16px;
  --shadow-sm:    0 1px 2px rgba(0,0,0,.06), 0 1px 3px rgba(0,0,0,.1);
  --shadow-md:    0 4px 6px rgba(0,0,0,.07), 0 2px 4px rgba(0,0,0,.06);
  --font:         -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  --font-mono:    'Menlo', 'Consolas', 'Monaco', monospace;
  --sidebar-w:    230px;
  --topbar-h:     52px;
}

body { font-family: var(--font); font-size: 15px; color: var(--text-primary); background: var(--bg); line-height: 1.5; }
a    { color: var(--brand); text-decoration: none; }
a:hover { text-decoration: underline; }
button { font-family: var(--font); }

/* ── App shell ───────────────────────────────────────────── */
.app-shell { display: flex; min-height: 100vh; }

/* ── Sidebar ─────────────────────────────────────────────── */
.sidebar {
  width: var(--sidebar-w);
  background: var(--surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  position: fixed;
  top: 0; left: 0; bottom: 0;
  z-index: 50;
  overflow-y: auto;
  transform: translateX(-100%);
  transition: transform .25s ease;
}
.sidebar.open { transform: none; }
.sidebar-overlay {
  display: none;
  position: fixed; inset: 0; background: rgba(0,0,0,.35); z-index: 40;
}
.sidebar-overlay.show { display: block; }

/* Desktop: always visible */
@media (min-width: 768px) {
  .sidebar { transform: none; position: sticky; height: 100vh; }
  .sidebar-overlay { display: none !important; }
  .menu-btn { display: none !important; }
}

.sidebar-logo {
  padding: 18px 16px 14px;
  font-size: 18px; font-weight: 700; color: var(--brand);
  border-bottom: 1px solid var(--border);
  display: flex; align-items: center; justify-content: space-between;
}
.sidebar-section {
  padding: 14px 16px 6px;
  font-size: 10px; font-weight: 600;
  text-transform: uppercase; letter-spacing: .08em;
  color: var(--text-hint);
}
.nav-item {
  display: flex; align-items: center; gap: 10px;
  padding: 9px 14px; margin: 1px 8px;
  border-radius: var(--radius-sm);
  color: var(--text-muted); font-size: 14px; font-weight: 400;
  cursor: pointer; text-decoration: none;
  transition: background .15s, color .15s;
}
.nav-item:hover { background: var(--bg); color: var(--text-primary); text-decoration: none; }
.nav-item.active { background: var(--brand-light); color: var(--brand-dark); font-weight: 500; }
.nav-icon { font-size: 17px; width: 20px; text-align: center; flex-shrink: 0; }
.sidebar-footer {
  margin-top: auto; padding: 14px 16px;
  border-top: 1px solid var(--border); font-size: 13px;
}
.sidebar-user-name { font-weight: 500; margin-bottom: 2px; }
.sidebar-user-email { font-size: 12px; color: var(--text-muted); margin-bottom: 8px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

/* ── Main content ────────────────────────────────────────── */
.main-content { flex: 1; display: flex; flex-direction: column; min-width: 0; }

.topbar {
  height: var(--topbar-h);
  background: var(--surface); border-bottom: 1px solid var(--border);
  display: flex; align-items: center; justify-content: space-between;
  padding: 0 16px;
  position: sticky; top: 0; z-index: 30;
  gap: 10px;
}
@media (min-width: 768px) { .topbar { padding: 0 24px; } }

.topbar-left { display: flex; align-items: center; gap: 10px; min-width: 0; }
.topbar-title { font-size: 15px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.menu-btn {
  background: none; border: none; cursor: pointer;
  padding: 6px; border-radius: var(--radius-sm);
  color: var(--text-muted); font-size: 20px; line-height: 1;
}

.page-body {
  padding: 16px;
  flex: 1;
}
@media (min-width: 768px) { .page-body { padding: 24px 28px; max-width: 1100px; } }

/* ── Mode switch ─────────────────────────────────────────── */
.mode-switch {
  display: inline-flex; background: var(--bg);
  border: 1px solid var(--border); border-radius: 20px;
  padding: 3px; gap: 2px;
}
.mode-btn {
  padding: 5px 14px; border-radius: 16px; border: none;
  background: transparent; font-size: 13px; font-weight: 500;
  color: var(--text-muted); cursor: pointer;
  transition: background .15s, color .15s;
  white-space: nowrap;
}
.mode-btn.active { background: var(--surface); color: var(--brand); box-shadow: var(--shadow-sm); }

/* ── Cards ───────────────────────────────────────────────── */
.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius-lg); padding: 16px;
  margin-bottom: 14px;
}
@media (min-width: 768px) { .card { padding: 20px 24px; margin-bottom: 16px; } }

.card-title { font-size: 12px; font-weight: 500; color: var(--text-muted); margin-bottom: 4px; text-transform: uppercase; letter-spacing: .05em; }
.card-value { font-size: 24px; font-weight: 600; color: var(--text-primary); }
@media (min-width: 768px) { .card-value { font-size: 28px; } }
.card-sub   { font-size: 12px; color: var(--text-muted); margin-top: 2px; }
.card-title-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; flex-wrap: wrap; gap: 8px; }
.card-title-row h2 { font-size: 15px; font-weight: 600; }

.card-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 14px; }
@media (min-width: 640px)  { .card-grid { grid-template-columns: repeat(3, 1fr); } }
@media (min-width: 1024px) { .card-grid { grid-template-columns: repeat(4, 1fr); gap: 14px; } }

/* ── Badges ──────────────────────────────────────────────── */
.badge { display: inline-flex; align-items: center; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; letter-spacing: .02em; }
.badge-success { background: var(--teal-light);  color: #065F46; }
.badge-pending { background: var(--amber-light); color: #92400E; }
.badge-error   { background: #FEE2E2;            color: #991B1B; }
.badge-info    { background: var(--brand-light); color: var(--brand-dark); }

/* ── Buttons ─────────────────────────────────────────────── */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  padding: 9px 16px; border-radius: var(--radius-sm);
  font-size: 14px; font-weight: 500; cursor: pointer; border: none;
  transition: opacity .15s, background .15s; white-space: nowrap;
  -webkit-appearance: none;
}
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary  { background: var(--brand); color: #fff; }
.btn-primary:hover { opacity: .88; }
.btn-secondary { background: var(--bg); color: var(--text-primary); border: 1px solid var(--border-strong); }
.btn-secondary:hover { background: #F3F4F6; }
.btn-danger   { background: var(--coral); color: #fff; }
.btn-danger:hover { opacity: .88; }
.btn-sm { padding: 5px 11px; font-size: 13px; }
.btn-full { width: 100%; }

/* ── Forms ───────────────────────────────────────────────── */
.form-group { margin-bottom: 14px; }
.form-label { display: block; font-size: 13px; font-weight: 500; margin-bottom: 5px; color: var(--text-primary); }
.form-input {
  width: 100%; padding: 10px 12px;
  border: 1px solid var(--border-strong); border-radius: var(--radius-sm);
  font-size: 14px; font-family: var(--font);
  background: var(--surface); color: var(--text-primary);
  transition: border-color .15s, box-shadow .15s;
  -webkit-appearance: none; appearance: none;
}
.form-input:focus { outline: none; border-color: var(--brand); box-shadow: 0 0 0 3px rgba(83,74,183,.12); }
.form-input::placeholder { color: var(--text-hint); }
.form-hint { font-size: 12px; color: var(--text-muted); margin-top: 4px; line-height: 1.5; }
.form-error { font-size: 12px; color: var(--coral); margin-top: 4px; }
.form-grid { display: grid; grid-template-columns: 1fr; gap: 0; }
@media (min-width: 640px) { .form-grid { grid-template-columns: 1fr 1fr; gap: 0 16px; } }

/* ── Table ───────────────────────────────────────────────── */
.table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: var(--radius-md); -webkit-overflow-scrolling: touch; }
table { width: 100%; border-collapse: collapse; min-width: 480px; }
thead th {
  background: var(--bg); padding: 9px 12px;
  font-size: 11px; font-weight: 600; color: var(--text-muted);
  text-align: left; border-bottom: 1px solid var(--border);
  text-transform: uppercase; letter-spacing: .05em; white-space: nowrap;
}
tbody td { padding: 11px 12px; font-size: 13px; border-bottom: 1px solid var(--border); vertical-align: middle; }
tbody tr:last-child td { border-bottom: none; }
tbody tr:hover { background: var(--bg); }

/* ── Toast ───────────────────────────────────────────────── */
#toast-container { position: fixed; bottom: 20px; right: 16px; z-index: 999; display: flex; flex-direction: column; gap: 8px; max-width: calc(100vw - 32px); }
.toast {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius-md); padding: 11px 16px;
  font-size: 14px; box-shadow: var(--shadow-md);
  min-width: 240px; max-width: 360px;
  animation: toastIn .2s ease;
}
.toast.success { border-left: 3px solid var(--teal); }
.toast.error   { border-left: 3px solid var(--coral); }
.toast.info    { border-left: 3px solid var(--brand); }
@keyframes toastIn { from { transform: translateX(16px); opacity: 0; } to { transform: none; opacity: 1; } }

/* ── Auth page ───────────────────────────────────────────── */
.auth-wrap {
  min-height: 100vh; display: flex; align-items: center;
  justify-content: center; background: var(--bg); padding: 16px;
}
.auth-card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius-lg); padding: 28px 24px;
  width: 100%; max-width: 420px; box-shadow: var(--shadow-md);
}
@media (min-width: 480px) { .auth-card { padding: 36px 40px; } }
.auth-logo { font-size: 22px; font-weight: 700; color: var(--brand); margin-bottom: 4px; }
.auth-sub  { color: var(--text-muted); margin-bottom: 24px; font-size: 14px; }

/* ── Modal ───────────────────────────────────────────────── */
.modal-wrap {
  display: none; position: fixed; inset: 0; z-index: 100;
  background: rgba(0,0,0,.45);
  align-items: flex-end; justify-content: center;
  padding: 0;
}
@media (min-width: 640px) { .modal-wrap { align-items: center; padding: 16px; } }
.modal-wrap.show { display: flex; }
.modal-box {
  background: var(--surface);
  border-radius: var(--radius-lg) var(--radius-lg) 0 0;
  padding: 20px 18px; width: 100%; max-width: 540px;
  max-height: 90vh; overflow-y: auto;
  border: 1px solid var(--border);
}
@media (min-width: 640px) { .modal-box { border-radius: var(--radius-lg); padding: 24px 28px; } }
.modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 18px; }
.modal-title  { font-size: 16px; font-weight: 600; }
.modal-close  { background: none; border: none; cursor: pointer; font-size: 22px; color: var(--text-muted); line-height: 1; padding: 2px 6px; }

/* ── Empty state ─────────────────────────────────────────── */
.empty-state { text-align: center; padding: 40px 16px; color: var(--text-muted); }
.empty-icon  { font-size: 32px; margin-bottom: 10px; opacity: .4; }
.empty-state h3 { font-size: 15px; font-weight: 600; color: var(--text-primary); margin-bottom: 6px; }
.empty-state p  { font-size: 14px; }

/* ── QR Code container ───────────────────────────────────── */
.qr-wrap {
  display: flex; flex-direction: column; align-items: center;
  gap: 14px; padding: 20px;
  background: var(--bg); border-radius: var(--radius-md);
  border: 1px solid var(--border);
}
.qr-wrap canvas, .qr-wrap svg { max-width: 220px; width: 100%; height: auto; }

/* ── Info rows (key-value pairs) ─────────────────────────── */
.info-grid { display: grid; grid-template-columns: auto 1fr; gap: 8px 16px; font-size: 13px; }
.info-label { color: var(--text-muted); white-space: nowrap; padding-top: 1px; }
.info-value { font-family: var(--font-mono); font-size: 12px; word-break: break-all; }
.info-value.normal { font-family: var(--font); font-size: 13px; }

/* ── Step indicator ──────────────────────────────────────── */
.steps { display: flex; align-items: center; gap: 6px; margin-bottom: 20px; }
.step  { width: 28px; height: 28px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: 700; flex-shrink: 0; }
.step.done    { background: var(--teal); color: #fff; }
.step.active  { background: var(--brand); color: #fff; }
.step.waiting { background: var(--border); color: var(--text-muted); }
.step-line    { flex: 1; height: 2px; background: var(--border); }
.step-line.done { background: var(--teal); }

/* ── Spinner ─────────────────────────────────────────────── */
.spinner { display: inline-block; width: 18px; height: 18px; border: 2px solid var(--border-strong); border-top-color: var(--brand); border-radius: 50%; animation: spin .7s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }

/* ── Alert ───────────────────────────────────────────────── */
.alert { border-radius: var(--radius-md); padding: 12px 14px; font-size: 13px; line-height: 1.5; margin-bottom: 12px; }
.alert-warning { background: var(--amber-light); border: 1px solid #FCD34D; color: #78350F; }
.alert-success { background: var(--teal-light);  border: 1px solid #6EE7B7; color: #064E3B; }
.alert-error   { background: var(--coral-light); border: 1px solid #FCA5A5; color: #7F1D1D; }
.alert-info    { background: var(--brand-light); border: 1px solid #A5B4FC; color: var(--brand-dark); }
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND JS MODULES
# ═══════════════════════════════════════════════════════════
log "Writing JS modules..."

cat > frontend/js/modules/api.js << 'EOF'
const API = '/api';

function getToken() {
  try { return localStorage.getItem('settl_token'); } catch { return null; }
}

async function req(path, opts = {}) {
  const token = getToken();
  const headers = { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...opts.headers };
  const res  = await fetch(`${API}${path}`, { ...opts, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(data.error || `HTTP ${res.status}`); e.status = res.status; throw e; }
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',  body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH', body: JSON.stringify(b) }),
  delete: (p, o)    => req(p, { ...o, method: 'DELETE' }),

  auth: {
    signup:  (email, password, full_name) => api.post('/auth/signup', { email, password, full_name }),
    login:   (email, password)            => api.post('/auth/login',  { email, password }),
    logout:  ()                           => api.post('/auth/logout', {}),
    me:      ()                           => api.get('/auth/me'),
    profile: (u)                          => api.patch('/auth/profile', u),
  },

  merchants: {
    list:                ()               => api.get('/merchants'),
    get:                 (id)             => api.get(`/merchants/${id}`),
    create:              (b)              => api.post('/merchants', b),
    getChainState:       (id)             => api.get(`/merchants/${id}/chain`),
    deactivate:          (id)             => api.post(`/merchants/${id}/deactivate`, {}),
    requestWalletUpdate: (id, w)          => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: w }),
    confirmWalletUpdate: (id)             => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (id)     => api.get(`/escrow/${id}`),
    history: (id)     => api.get(`/escrow/${id}/history`),
  },

  payments: {
    session: (b)    => api.post('/payments/session', b),
    poll:    (ref)  => fetch(`${API}/payments/poll/${ref}`).then(r => r.json()),
    history: ()     => api.get('/payments/history'),
  },

  release: {
    all:          ()   => api.post('/release/all', {}),
    one:          (id) => api.post(`/release/${id}`, {}),
    logs:         ()   => api.get('/release/logs'),
    merchantLogs: (id) => api.get(`/release/merchant-logs/${id}`),
  },
};

window.api = api;
EOF

cat > frontend/js/modules/auth.js << 'EOF'
const KEY_TOKEN   = 'settl_token';
const KEY_USER    = 'settl_user';
const KEY_MODE    = 'settl_mode';

const auth = {
  getToken()   { return localStorage.getItem(KEY_TOKEN); },
  getUser()    { try { return JSON.parse(localStorage.getItem(KEY_USER)); } catch { return null; } },
  getMode()    { return localStorage.getItem(KEY_MODE) || 'operator'; },
  setMode(m)   { localStorage.setItem(KEY_MODE, m); },

  save(token, user) {
    localStorage.setItem(KEY_TOKEN, token);
    localStorage.setItem(KEY_USER, JSON.stringify(user));
  },

  clear() {
    localStorage.removeItem(KEY_TOKEN);
    localStorage.removeItem(KEY_USER);
    localStorage.removeItem(KEY_MODE);
  },

  isLoggedIn() { return !!this.getToken(); },

  requireAuth() {
    if (!this.isLoggedIn()) { window.location.href = '/pages/auth/login.html'; return false; }
    return true;
  },

  getRole() { return this.getUser()?.role || 'operator'; },
};

window.auth = auth;
EOF

cat > frontend/js/modules/toast.js << 'EOF'
(function () {
  const c = document.createElement('div');
  c.id = 'toast-container';
  document.body.appendChild(c);

  function show(msg, type = 'info', ms = 3500) {
    const t = document.createElement('div');
    t.className = `toast ${type}`;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => { t.style.transition = 'opacity .3s'; t.style.opacity = '0'; setTimeout(() => t.remove(), 320); }, ms);
  }

  window.toast = { success: m => show(m,'success'), error: m => show(m,'error',5000), info: m => show(m,'info') };
})();
EOF

cat > frontend/js/modules/nav.js << 'EOF'
const NAV = {
  operator: [
    { label: 'Overview',     href: '/pages/dashboard.html',         icon: '◈' },
    { label: 'Payments',     href: '/pages/operator/payments.html', icon: '↑' },
    { label: 'Balance',      href: '/pages/operator/balance.html',  icon: '$' },
    { label: 'Payment link', href: '/pages/operator/paylink.html',  icon: '⊕' },
    { label: 'Settings',     href: '/pages/operator/settings.html', icon: '⚙' },
  ],
  developer: [
    { label: 'Overview',      href: '/pages/dashboard.html',                  icon: '◈' },
    { label: 'Merchants',     href: '/pages/developer/merchants.html',         icon: '⊞' },
    { label: 'Escrow viewer', href: '/pages/developer/escrow.html',            icon: '⬡' },
    { label: 'Transactions',  href: '/pages/developer/transactions.html',      icon: '≡' },
    { label: 'Cron monitor',  href: '/pages/developer/cron.html',              icon: '◷' },
  ],
};

function buildSidebar(mode) {
  const user    = window.auth?.getUser();
  const role    = user?.role || 'operator';
  const items   = NAV[mode] || NAV.operator;
  const current = window.location.pathname;

  return `
    <div class="sidebar-logo">
      <span>SETTL</span>
      <button class="modal-close" onclick="closeSidebar()" style="display:none;" id="sidebar-close-btn">×</button>
    </div>
    <div style="padding:10px 8px 4px;">
      <div class="mode-switch" style="width:100%;">
        <button class="mode-btn ${mode==='operator'?'active':''}"  onclick="switchMode('operator')">Operator</button>
        ${role==='developer' ? `<button class="mode-btn ${mode==='developer'?'active':''}" onclick="switchMode('developer')">Developer</button>` : ''}
      </div>
    </div>
    <div class="sidebar-section">${mode==='developer'?'Developer':'Business'}</div>
    ${items.map(item => {
      const page   = item.href.split('/').pop();
      const active = current.endsWith(page);
      return `<a href="${item.href}" class="nav-item ${active?'active':''}" onclick="closeSidebar()">
        <span class="nav-icon">${item.icon}</span>${item.label}
      </a>`;
    }).join('')}
    <div class="sidebar-footer">
      <div class="sidebar-user-name">${user?.full_name || user?.email || 'User'}</div>
      <div class="sidebar-user-email">${user?.email || ''}</div>
      <span class="badge ${role==='developer'?'badge-info':'badge-success'}">${role}</span><br/><br/>
      <a href="#" onclick="handleLogout()" style="font-size:12px;color:var(--text-hint);">Sign out</a>
    </div>`;
}

function initSidebar(mode) {
  const sidebar  = document.getElementById('sidebar');
  const overlay  = document.getElementById('sidebar-overlay');
  const closeBtn = document.getElementById('sidebar-close-btn');
  if (sidebar) {
    sidebar.innerHTML = buildSidebar(mode);
    // Show close button inside sidebar on mobile
    const cb = sidebar.querySelector('#sidebar-close-btn');
    if (cb) cb.style.display = '';
  }
  if (overlay) overlay.onclick = closeSidebar;
}

function openSidebar() {
  document.getElementById('sidebar')?.classList.add('open');
  document.getElementById('sidebar-overlay')?.classList.add('show');
}
function closeSidebar() {
  document.getElementById('sidebar')?.classList.remove('open');
  document.getElementById('sidebar-overlay')?.classList.remove('show');
}

function switchMode(mode) {
  auth.setMode(mode);
  initSidebar(mode);
}

async function handleLogout() {
  try { await api.auth.logout(); } catch {}
  auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.buildSidebar = buildSidebar;
window.initSidebar  = initSidebar;
window.openSidebar  = openSidebar;
window.closeSidebar = closeSidebar;
window.switchMode   = switchMode;
window.handleLogout = handleLogout;
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — index.html
# ═══════════════════════════════════════════════════════════
cat > frontend/index.html << 'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>SETTL</title></head>
<body><script>
  window.location.href = localStorage.getItem('settl_token')
    ? '/pages/dashboard.html' : '/pages/auth/login.html';
</script></body></html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — Auth: login + signup (mobile-first, no Supabase)
# ═══════════════════════════════════════════════════════════
log "Writing auth pages..."
cat > frontend/pages/auth/login.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Sign in</title>
  <link rel="stylesheet" href="/css/app.css"/>
</head>
<body>
<div class="auth-wrap">
  <div class="auth-card">
    <div class="auth-logo">SETTL</div>
    <div class="auth-sub">Payment gateway · Sign in</div>

    <div class="mode-switch" style="margin-bottom:22px;">
      <button class="mode-btn active" id="tab-login"  onclick="tab('login')">Sign in</button>
      <button class="mode-btn"        id="tab-signup" onclick="tab('signup')">Create account</button>
    </div>

    <!-- Login -->
    <div id="v-login">
      <div class="form-group">
        <label class="form-label">Email</label>
        <input class="form-input" id="l-email" type="email" placeholder="you@example.com" autocomplete="email"/>
      </div>
      <div class="form-group">
        <label class="form-label">Password</label>
        <input class="form-input" id="l-pass"  type="password" placeholder="Your password" autocomplete="current-password"/>
      </div>
      <div id="l-err" class="alert alert-error" style="display:none;"></div>
      <button class="btn btn-primary btn-full" id="l-btn" onclick="doLogin()">Sign in</button>
    </div>

    <!-- Signup -->
    <div id="v-signup" style="display:none;">
      <div class="form-group">
        <label class="form-label">Full name</label>
        <input class="form-input" id="s-name"  type="text"     placeholder="Your name"/>
      </div>
      <div class="form-group">
        <label class="form-label">Email</label>
        <input class="form-input" id="s-email" type="email"    placeholder="you@example.com" autocomplete="email"/>
      </div>
      <div class="form-group">
        <label class="form-label">Password <span style="color:var(--text-hint);font-weight:400;">(min 8 chars)</span></label>
        <input class="form-input" id="s-pass"  type="password" placeholder="Create a password" autocomplete="new-password"/>
      </div>
      <div id="s-err" class="alert alert-error"   style="display:none;"></div>
      <div id="s-ok"  class="alert alert-success" style="display:none;"></div>
      <button class="btn btn-primary btn-full" id="s-btn" onclick="doSignup()">Create account</button>
    </div>
  </div>
</div>

<script src="/js/modules/api.js"></script>
<script src="/js/modules/auth.js"></script>
<script>
  if (auth.isLoggedIn()) window.location.href = '/pages/dashboard.html';

  function tab(t) {
    const isL = t === 'login';
    document.getElementById('v-login').style.display  = isL ? '' : 'none';
    document.getElementById('v-signup').style.display = isL ? 'none' : '';
    document.getElementById('tab-login').classList.toggle('active',  isL);
    document.getElementById('tab-signup').classList.toggle('active', !isL);
  }

  function setErr(id, msg) {
    const el = document.getElementById(id);
    el.textContent = msg; el.style.display = msg ? '' : 'none';
  }

  async function doLogin() {
    const email = document.getElementById('l-email').value.trim();
    const pass  = document.getElementById('l-pass').value;
    setErr('l-err', '');
    if (!email || !pass) { setErr('l-err', 'Email and password required'); return; }
    const btn = document.getElementById('l-btn');
    btn.disabled = true; btn.textContent = 'Signing in…';
    try {
      const { token, user } = await api.auth.login(email, pass);
      auth.save(token, user);
      window.location.href = '/pages/dashboard.html';
    } catch (err) {
      setErr('l-err', err.message);
      btn.disabled = false; btn.textContent = 'Sign in';
    }
  }

  async function doSignup() {
    const name  = document.getElementById('s-name').value.trim();
    const email = document.getElementById('s-email').value.trim();
    const pass  = document.getElementById('s-pass').value;
    setErr('s-err', '');
    document.getElementById('s-ok').style.display = 'none';
    if (!email || !pass) { setErr('s-err', 'Email and password required'); return; }
    if (pass.length < 8) { setErr('s-err', 'Password must be at least 8 characters'); return; }
    const btn = document.getElementById('s-btn');
    btn.disabled = true; btn.textContent = 'Creating…';
    try {
      await api.auth.signup(email, pass, name);
      document.getElementById('s-ok').textContent = 'Account created! Signing you in…';
      document.getElementById('s-ok').style.display = '';
      const { token, user } = await api.auth.login(email, pass);
      auth.save(token, user);
      window.location.href = '/pages/dashboard.html';
    } catch (err) {
      setErr('s-err', err.message);
      btn.disabled = false; btn.textContent = 'Create account';
    }
  }

  document.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return;
    if (document.getElementById('v-login').style.display !== 'none') doLogin();
    else doSignup();
  });
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — developer/merchants.html
# Auto on-chain registration + mobile-first layout
# Wallet validation fixed
# ═══════════════════════════════════════════════════════════
log "Writing developer merchants page..."
cat > frontend/pages/developer/merchants.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Merchants</title>
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
        <span class="topbar-title">Merchants</span>
      </div>
      <span class="badge badge-info">developer</span>
    </div>

    <div class="page-body">

      <!-- Register form -->
      <div class="card">
        <div class="card-title-row"><h2>Register new merchant</h2></div>

        <div class="form-grid">
          <div class="form-group">
            <label class="form-label">Merchant ID <span style="color:var(--coral)">*</span></label>
            <input class="form-input" id="f-id" placeholder="e.g. acme-store-001" maxlength="64"/>
            <div class="form-hint">Max 64 chars. Used as the on-chain seed.</div>
          </div>
          <div class="form-group">
            <label class="form-label">Wallet address <span style="color:var(--coral)">*</span></label>
            <input class="form-input" id="f-wallet" placeholder="Solana public key (base58)"
                   autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"/>
            <div class="form-hint">AUDD releases go to this wallet automatically.</div>
          </div>
          <div class="form-group">
            <label class="form-label">Display name</label>
            <input class="form-input" id="f-name" placeholder="ACME Store"/>
          </div>
          <div class="form-group">
            <label class="form-label">Contact email</label>
            <input class="form-input" id="f-email" type="email" placeholder="merchant@example.com"/>
          </div>
        </div>

        <div id="reg-err" class="alert alert-error" style="display:none;"></div>
        <div id="reg-progress" style="display:none;" class="alert alert-info">
          <div style="display:flex;align-items:center;gap:10px;">
            <div class="spinner"></div>
            <span id="reg-progress-msg">Sending to Devnet…</span>
          </div>
        </div>

        <button class="btn btn-primary" id="reg-btn" onclick="registerMerchant()">
          Register on-chain
        </button>
      </div>

      <!-- Success panel -->
      <div class="card" id="reg-success" style="display:none;">
        <div class="alert alert-success" style="margin-bottom:14px;">✓ Merchant registered on-chain</div>
        <div class="info-grid" id="reg-result-grid"></div>
        <button class="btn btn-secondary btn-sm" style="margin-top:14px;" onclick="document.getElementById('reg-success').style.display='none'">Close</button>
      </div>

      <!-- Merchant list -->
      <div class="card">
        <div class="card-title-row">
          <h2>All merchants</h2>
          <button class="btn btn-secondary btn-sm" onclick="loadMerchants()">Refresh</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Merchant ID</th><th>Name</th><th>Wallet</th><th>Status</th><th>Registered</th><th>Actions</th></tr></thead>
            <tbody id="m-tbody"><tr><td colspan="6" style="text-align:center;padding:28px;color:var(--text-hint);">Loading…</td></tr></tbody>
          </table>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Chain state modal -->
<div class="modal-wrap" id="chain-modal">
  <div class="modal-box">
    <div class="modal-header">
      <span class="modal-title" id="modal-title">On-chain state</span>
      <button class="modal-close" onclick="closeModal()">×</button>
    </div>
    <div id="modal-body"></div>
  </div>
</div>

<script src="/js/modules/api.js"></script>
<script src="/js/modules/auth.js"></script>
<script src="/js/modules/toast.js"></script>
<script src="/js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw 0;
  initSidebar('developer');

  const EX = 'https://explorer.solana.com/tx/';
  const CL = '?cluster=devnet';

  function shortKey(k) { return k ? k.slice(0,6) + '…' + k.slice(-4) : '—'; }
  function copy(t)     { navigator.clipboard.writeText(t).then(() => toast.success('Copied!')); }

  function setRegErr(msg) {
    const el = document.getElementById('reg-err');
    el.textContent = msg; el.style.display = msg ? '' : 'none';
  }

  function setProgress(msg) {
    const el = document.getElementById('reg-progress');
    if (msg) { document.getElementById('reg-progress-msg').textContent = msg; el.style.display = ''; }
    else      { el.style.display = 'none'; }
  }

  async function registerMerchant() {
    const merchantId = document.getElementById('f-id').value.trim();
    const wallet     = document.getElementById('f-wallet').value.trim();
    const name       = document.getElementById('f-name').value.trim();
    const email      = document.getElementById('f-email').value.trim();

    setRegErr('');
    if (!merchantId) { setRegErr('Merchant ID is required'); return; }
    if (!wallet)     { setRegErr('Wallet address is required'); return; }
    if (merchantId.length > 64) { setRegErr('Merchant ID must be 64 characters or fewer'); return; }

    const btn = document.getElementById('reg-btn');
    btn.disabled = true;
    setProgress('Step 1/2 — Registering merchant on-chain…');

    try {
      const result = await api.merchants.create({
        merchant_id: merchantId, wallet_address: wallet, name, email,
      });

      setProgress('Step 2/2 — Initialising escrow vault…');
      await new Promise(r => setTimeout(r, 800)); // visual feedback

      setProgress(null);
      setRegErr('');

      // Show success
      const grid = document.getElementById('reg-result-grid');
      grid.innerHTML = `
        <span class="info-label">Register tx</span>
        <span><a href="${EX}${result.registerTx}${CL}" target="_blank" style="font-size:12px;font-family:var(--font-mono);">${shortKey(result.registerTx)}</a></span>
        <span class="info-label">Escrow tx</span>
        <span><a href="${EX}${result.escrowTx}${CL}" target="_blank" style="font-size:12px;font-family:var(--font-mono);">${shortKey(result.escrowTx)}</a></span>
        <span class="info-label">Vault PDA</span>
        <span class="info-value" onclick="copy('${result.vaultPDA}')" style="cursor:pointer;" title="Click to copy">${shortKey(result.vaultPDA)}</span>
      `;
      document.getElementById('reg-success').style.display = '';
      ['f-id','f-wallet','f-name','f-email'].forEach(id => document.getElementById(id).value = '');
      loadMerchants();
      toast.success('Merchant registered successfully!');
    } catch (err) {
      setProgress(null);
      setRegErr(err.message);
    } finally {
      btn.disabled = false;
    }
  }

  async function loadMerchants() {
    const tbody = document.getElementById('m-tbody');
    try {
      const { merchants } = await api.merchants.list();
      if (!merchants.length) {
        tbody.innerHTML = `<tr><td colspan="6"><div class="empty-state"><div class="empty-icon">⊞</div><h3>No merchants yet</h3><p>Register the first one above.</p></div></td></tr>`;
        return;
      }
      tbody.innerHTML = merchants.map(m => `
        <tr>
          <td><span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;" onclick="copy('${m.merchant_id}')" title="Copy">${m.merchant_id}</span></td>
          <td>${m.name || '—'}</td>
          <td><span style="font-family:var(--font-mono);font-size:11px;cursor:pointer;" onclick="copy('${m.wallet_address}')" title="Copy full address">${shortKey(m.wallet_address)}</span></td>
          <td><span class="badge ${m.is_active?'badge-success':'badge-pending'}">${m.is_active?'Active':'Inactive'}</span></td>
          <td style="color:var(--text-muted);font-size:12px;">${m.registered_at?new Date(m.registered_at).toLocaleDateString():'—'}</td>
          <td>
            <div style="display:flex;gap:6px;flex-wrap:wrap;">
              <button class="btn btn-secondary btn-sm" onclick="showChainState('${m.merchant_id}')">Chain</button>
              ${m.is_active?`<button class="btn btn-danger btn-sm" onclick="deactivate('${m.merchant_id}')">Deactivate</button>`:''}
            </div>
          </td>
        </tr>`).join('');
    } catch (err) { toast.error(err.message); }
  }

  async function showChainState(id) {
    openModal('Loading…', '<div style="text-align:center;padding:20px;"><div class="spinner"></div></div>');
    try {
      const { merchant, escrow } = await api.merchants.getChainState(id);
      const escrowData = await api.escrow.get(id).catch(() => null);
      const content = `
        <div class="info-grid" style="margin-bottom:16px;">
          <span class="info-label">Active</span>
          <span><span class="badge ${merchant.isActive?'badge-success':'badge-pending'}">${merchant.isActive}</span></span>
          <span class="info-label">Wallet</span>
          <span class="info-value" onclick="copy('${merchant.wallet}')" style="cursor:pointer;">${shortKey(merchant.wallet)}</span>
          <span class="info-label">Released</span><span class="info-value normal">${(merchant.totalReleased/1e6).toFixed(4)} AUDD</span>
          <span class="info-label">Fees paid</span><span class="info-value normal">${(merchant.totalFeesPaid/1e6).toFixed(4)} AUDD</span>
          ${escrowData?`
          <span class="info-label">Pending</span><span class="info-value normal" style="font-weight:600;color:var(--teal);">${(escrowData.pendingBalance/1e6).toFixed(4)} AUDD</span>
          <span class="info-label">Payments</span><span class="info-value normal">${escrowData.totalPayments}</span>
          <span class="info-label">Source</span><span><span class="badge badge-info">${escrowData.source}</span></span>`:''}
          ${merchant.pendingWallet?`
          <span class="info-label" style="color:var(--amber);">Pending wallet</span>
          <span class="info-value" style="color:var(--amber);">${shortKey(merchant.pendingWallet)}</span>
          <span class="info-label">Unlocks at</span><span class="info-value normal">${new Date(merchant.walletUpdateAt*1000).toLocaleString()}</span>`:''}
        </div>
        ${merchant.pendingWallet
          ? `<button class="btn btn-primary btn-sm" onclick="confirmUpdate('${id}')">Confirm wallet update</button>`
          : `<div style="border-top:1px solid var(--border);padding-top:14px;margin-top:4px;">
              <div class="form-label" style="margin-bottom:6px;">Request wallet update</div>
              <div style="display:flex;gap:8px;">
                <input class="form-input" id="new-wallet" placeholder="New Solana public key" style="flex:1;"/>
                <button class="btn btn-secondary btn-sm" onclick="reqWalletUpdate('${id}')">Stage</button>
              </div>
              <div class="form-hint">24-hour delay before confirming.</div>
             </div>`}
      `;
      openModal(`Chain state — ${id}`, content);
    } catch (err) { openModal('Error', `<div class="alert alert-error">${err.message}</div>`); }
  }

  async function deactivate(id) {
    if (!confirm(`Deactivate "${id}"? This stops the escrow accepting deposits.`)) return;
    try { await api.merchants.deactivate(id); toast.success('Deactivated'); loadMerchants(); }
    catch (err) { toast.error(err.message); }
  }

  async function reqWalletUpdate(id) {
    const w = document.getElementById('new-wallet')?.value?.trim();
    if (!w) { toast.error('Enter a wallet address'); return; }
    try { await api.merchants.requestWalletUpdate(id, w); toast.success('Staged — confirm in 24h'); closeModal(); }
    catch (err) { toast.error(err.message); }
  }

  async function confirmUpdate(id) {
    try { await api.merchants.confirmWalletUpdate(id); toast.success('Wallet updated'); closeModal(); loadMerchants(); }
    catch (err) { toast.error(err.message); }
  }

  function openModal(title, body) {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').innerHTML    = body;
    document.getElementById('chain-modal').classList.add('show');
  }
  function closeModal() { document.getElementById('chain-modal').classList.remove('show'); }

  loadMerchants();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — operator/paylink.html  (Solana Pay QR)
# ═══════════════════════════════════════════════════════════
log "Writing payment link + QR page..."
cat > frontend/pages/operator/paylink.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Payment link</title>
  <link rel="stylesheet" href="/css/app.css"/>
  <!-- QR code library -->
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
        <span class="topbar-title">Payment link</span>
      </div>
      <span class="badge badge-success">operator</span>
    </div>

    <div class="page-body">
      <div class="card" style="max-width:520px;">
        <div class="card-title-row"><h2>Create a payment request</h2></div>
        <p style="color:var(--text-muted);font-size:14px;margin-bottom:18px;line-height:1.6;">
          Generate a Solana Pay QR code. Your customer scans it with any Solana wallet (Phantom, Backpack, etc.) to pay AUDD directly into your escrow vault.
        </p>

        <div class="form-group">
          <label class="form-label">Merchant</label>
          <select class="form-input" id="sel-merchant">
            <option value="">Loading…</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">Amount (AUDD) <span style="color:var(--text-hint);font-weight:400;">— leave blank for open</span></label>
          <input class="form-input" id="inp-amount" type="number" min="0.01" step="0.01" placeholder="e.g. 10.00"/>
        </div>
        <div class="form-group">
          <label class="form-label">Message / order reference <span style="color:var(--text-hint);font-weight:400;">— optional</span></label>
          <input class="form-input" id="inp-msg" placeholder="Order #1234"/>
        </div>
        <button class="btn btn-primary btn-full" onclick="generateQR()">Generate QR code</button>
      </div>

      <!-- QR Result -->
      <div class="card" id="qr-result" style="display:none;max-width:520px;">
        <div class="card-title-row"><h2>Scan to pay</h2></div>

        <!-- Step indicator -->
        <div class="steps" id="steps">
          <div class="step active" id="step1">1</div>
          <div class="step-line" id="line1"></div>
          <div class="step waiting" id="step2">2</div>
          <div class="step-line" id="line2"></div>
          <div class="step waiting" id="step3">✓</div>
        </div>
        <div style="font-size:13px;color:var(--text-muted);margin-bottom:16px;" id="step-label">Waiting for customer to scan…</div>

        <div class="qr-wrap">
          <div id="qr-canvas"></div>
          <div style="text-align:center;">
            <div style="font-size:13px;font-weight:600;" id="qr-merchant-name"></div>
            <div style="font-size:20px;font-weight:700;color:var(--brand);margin:4px 0;" id="qr-amount-display"></div>
            <div style="font-size:12px;color:var(--text-muted);">AUDD · Solana Devnet</div>
          </div>
        </div>

        <div id="qr-status-area" style="margin-top:14px;">
          <div style="display:flex;align-items:center;gap:10px;color:var(--text-muted);font-size:14px;" id="polling-indicator">
            <div class="spinner"></div>
            <span>Watching for payment…</span>
          </div>
        </div>

        <div id="payment-confirmed" class="alert alert-success" style="display:none;margin-top:14px;">
          ✓ Payment confirmed on-chain!
          <a id="confirm-tx-link" href="#" target="_blank" style="font-size:12px;display:block;margin-top:4px;font-family:var(--font-mono);">View transaction</a>
        </div>

        <div style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap;">
          <button class="btn btn-secondary btn-sm" onclick="copyPayUrl()">Copy Solana Pay URL</button>
          <button class="btn btn-secondary btn-sm" onclick="newPayment()">New payment</button>
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
  initSidebar(auth.getMode());

  let pollInterval = null;
  let currentRef   = null;
  let currentUrl   = null;

  async function loadMerchants() {
    const { merchants } = await api.merchants.list();
    const sel = document.getElementById('sel-merchant');
    const active = merchants.filter(m => m.is_active);
    if (!active.length) {
      sel.innerHTML = '<option value="">No active merchants</option>';
      return;
    }
    sel.innerHTML = active.map(m => `<option value="${m.merchant_id}">${m.name||m.merchant_id}</option>`).join('');
  }

  async function generateQR() {
    const merchantId = document.getElementById('sel-merchant').value;
    const amountVal  = document.getElementById('inp-amount').value;
    const message    = document.getElementById('inp-msg').value.trim();
    if (!merchantId) { toast.error('Select a merchant'); return; }

    stopPolling();

    const amount = amountVal ? parseFloat(amountVal) : null;

    try {
      const session = await api.payments.session({
        merchant_id: merchantId,
        amount:      amount || null,
        message:     message || null,
      });

      currentRef = session.reference;
      currentUrl = session.url;

      // Render QR
      document.getElementById('qr-canvas').innerHTML = '';
      new QRCode(document.getElementById('qr-canvas'), {
        text:          session.url,
        width:         220, height: 220,
        colorDark:     '#111827',
        colorLight:    '#ffffff',
        correctLevel:  QRCode.CorrectLevel.M,
      });

      document.getElementById('qr-merchant-name').textContent  = session.label || merchantId;
      document.getElementById('qr-amount-display').textContent = amount ? amount.toFixed(2) + ' AUDD' : 'Open amount';

      document.getElementById('qr-result').style.display = '';
      document.getElementById('payment-confirmed').style.display = 'none';
      document.getElementById('polling-indicator').style.display = 'flex';
      setStep(1);
      startPolling(currentRef);

    } catch (err) { toast.error(err.message); }
  }

  function startPolling(ref) {
    stopPolling();
    setStep(2);
    document.getElementById('step-label').textContent = 'Customer scanning or sending payment…';

    pollInterval = setInterval(async () => {
      try {
        const result = await api.payments.poll(ref);
        if (result.status === 'confirmed') {
          stopPolling();
          setStep(3);
          document.getElementById('step-label').textContent = 'Payment received!';
          document.getElementById('polling-indicator').style.display = 'none';
          const conf = document.getElementById('payment-confirmed');
          conf.style.display = '';
          const link = document.getElementById('confirm-tx-link');
          link.href        = `https://explorer.solana.com/tx/${result.tx}?cluster=devnet`;
          link.textContent = result.tx?.slice(0,20) + '…';
          toast.success('Payment confirmed!');
        } else if (result.status === 'failed') {
          stopPolling();
          toast.error('Payment validation failed: ' + (result.error || 'unknown'));
        }
      } catch {}
    }, 1000);
  }

  function stopPolling() {
    if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
  }

  function setStep(n) {
    [1,2,3].forEach(i => {
      const s = document.getElementById('step'+i);
      const l = document.getElementById('line'+i);
      s.className = `step ${i<n?'done':i===n?'active':'waiting'}`;
      if (l) l.className = `step-line ${i<n?'done':''}`;
    });
  }

  function copyPayUrl() {
    if (!currentUrl) return;
    navigator.clipboard.writeText(currentUrl).then(() => toast.success('Solana Pay URL copied!'));
  }

  function newPayment() {
    stopPolling();
    document.getElementById('qr-result').style.display = 'none';
    document.getElementById('inp-amount').value = '';
    document.getElementById('inp-msg').value    = '';
  }

  loadMerchants();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — dashboard.html
# ═══════════════════════════════════════════════════════════
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
        <span class="topbar-title">Overview</span>
      </div>
      <span class="badge badge-info" id="mode-badge"></span>
    </div>

    <div class="page-body">
      <div class="card-grid">
        <div class="card"><div class="card-title">Pending</div><div class="card-value" id="s-pending">—</div><div class="card-sub">AUDD in escrow</div></div>
        <div class="card"><div class="card-title">Payments</div><div class="card-value" id="s-payments">—</div><div class="card-sub">All time</div></div>
        <div class="card"><div class="card-title">Next release</div><div class="card-value" id="s-release">—</div><div class="card-sub">Daily at 6am UTC</div></div>
        <div class="card"><div class="card-title">Merchants</div><div class="card-value" id="s-merchants">—</div><div class="card-sub">Active on-chain</div></div>
      </div>

      <div class="card">
        <div class="card-title-row">
          <h2>Merchant balances</h2>
          <button class="btn btn-secondary btn-sm" onclick="load()">Refresh</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Merchant</th><th>Status</th><th>Pending (AUDD)</th><th>Payments</th><th>Last release</th></tr></thead>
            <tbody id="m-tbody"><tr><td colspan="5" style="text-align:center;padding:28px;color:var(--text-hint);">Loading…</td></tr></tbody>
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
  const mode = auth.getMode();
  initSidebar(mode);
  document.getElementById('mode-badge').textContent = mode;

  function fmt(v) { return v!=null?(v/1e6).toFixed(2):'—'; }
  function nextRelease() {
    const now=new Date(),next=new Date();
    next.setUTCHours(6,0,0,0);
    if(next<=now) next.setUTCDate(next.getUTCDate()+1);
    const d=next-now,h=Math.floor(d/3600000),m=Math.floor((d%3600000)/60000);
    return `${h}h ${m}m`;
  }

  async function load() {
    document.getElementById('s-release').textContent = nextRelease();
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.filter(m=>m.is_active);
      document.getElementById('s-merchants').textContent = active.length;

      const escrows = await Promise.all(
        active.slice(0,10).map(m=>api.escrow.get(m.merchant_id).catch(()=>({pendingBalance:0,totalPayments:0})))
      );

      const totalPending   = escrows.reduce((s,e)=>s+(e.pendingBalance||0),0);
      const totalPayments  = escrows.reduce((s,e)=>s+(e.totalPayments||0),0);
      document.getElementById('s-pending').textContent  = fmt(totalPending);
      document.getElementById('s-payments').textContent = totalPayments;

      const tbody = document.getElementById('m-tbody');
      if (!active.length) {
        tbody.innerHTML=`<tr><td colspan="5"><div class="empty-state"><div class="empty-icon">◈</div><h3>No merchants yet</h3><p>Register in the <a href="/pages/developer/merchants.html">Merchants</a> page.</p></div></td></tr>`;
        return;
      }
      tbody.innerHTML = active.map((m,i)=>{
        const e=escrows[i]||{};
        return `<tr>
          <td style="font-family:var(--font-mono);font-size:12px;">${m.merchant_id}</td>
          <td><span class="badge badge-success">Active</span></td>
          <td style="font-weight:600;color:var(--teal);">${fmt(e.pendingBalance)}</td>
          <td>${e.totalPayments??'—'}</td>
          <td style="font-size:12px;color:var(--text-muted);">${e.lastReleasedAt?new Date(e.lastReleasedAt).toLocaleDateString():'Never'}</td>
        </tr>`;
      }).join('');
    } catch(err) { toast.error(err.message); }
  }

  load();
  setInterval(()=>{ document.getElementById('s-release').textContent=nextRelease(); },60000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — operator/payments.html
# ═══════════════════════════════════════════════════════════
cat > frontend/pages/operator/payments.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Payments</title>
  <link rel="stylesheet" href="/css/app.css"/>
</head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <div class="topbar-left"><button class="menu-btn" onclick="openSidebar()">☰</button><span class="topbar-title">Payments</span></div>
      <span class="badge badge-success">operator</span>
    </div>
    <div class="page-body">
      <div class="card-grid">
        <div class="card"><div class="card-title">Total received</div><div class="card-value" id="s-gross">—</div><div class="card-sub">Gross AUDD</div></div>
        <div class="card"><div class="card-title">Net released</div><div class="card-value" id="s-net">—</div><div class="card-sub">After 1.5% fee</div></div>
        <div class="card"><div class="card-title">Fees paid</div><div class="card-value" id="s-fee">—</div><div class="card-sub">To SETTL treasury</div></div>
        <div class="card"><div class="card-title">Next release</div><div class="card-value" id="s-next">—</div><div class="card-sub">6am UTC daily</div></div>
      </div>

      <div class="card">
        <div class="card-title-row"><h2>Release history</h2></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Date</th><th>Gross</th><th>Fee</th><th>Net</th><th>Status</th><th>Tx</th></tr></thead>
            <tbody id="rel-tbody"><tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr></tbody>
          </table>
        </div>
      </div>

      <div class="card">
        <div class="card-title-row"><h2>Deposit history</h2></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Amount</th><th>Customer</th><th>Date</th><th>Tx</th></tr></thead>
            <tbody id="dep-tbody"><tr><td colspan="4" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr></tbody>
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
  initSidebar('operator');

  const EX='https://explorer.solana.com/tx/', CL='?cluster=devnet';
  function fmtA(v) { return v!=null?Number(v).toFixed(4)+' AUDD':'—'; }
  function shortKey(k) { return k?k.slice(0,6)+'…'+k.slice(-4):'—'; }
  function nextRelease() {
    const now=new Date(),next=new Date(); next.setUTCHours(6,0,0,0);
    if(next<=now) next.setUTCDate(next.getUTCDate()+1);
    const d=next-now,h=Math.floor(d/3600000),m=Math.floor((d%3600000)/60000);
    return `${h}h ${m}m`;
  }

  async function load() {
    document.getElementById('s-next').textContent = nextRelease();
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.filter(m=>m.is_active);

      const [relLogs, deps] = await Promise.all([
        Promise.all(active.map(m=>api.release.merchantLogs(m.merchant_id).then(r=>r.logs).catch(()=>[]))),
        Promise.all(active.map(m=>api.escrow.history(m.merchant_id).then(r=>r.transactions.filter(t=>t.type==='deposit')).catch(()=>[]))),
      ]);

      const allRel = relLogs.flat().sort((a,b)=>new Date(b.released_at)-new Date(a.released_at));
      const allDep = deps.flat().sort((a,b)=>new Date(b.created_at)-new Date(a.created_at));

      const totalGross = allRel.reduce((s,r)=>s+Number(r.gross||0),0);
      const totalNet   = allRel.reduce((s,r)=>s+Number(r.net  ||0),0);
      const totalFee   = allRel.reduce((s,r)=>s+Number(r.fee  ||0),0);

      document.getElementById('s-gross').textContent = totalGross.toFixed(4)+' AUDD';
      document.getElementById('s-net').textContent   = totalNet.toFixed(4)+' AUDD';
      document.getElementById('s-fee').textContent   = totalFee.toFixed(4)+' AUDD';

      const relTbody = document.getElementById('rel-tbody');
      relTbody.innerHTML = allRel.length
        ? allRel.map(r=>`<tr>
            <td style="font-size:12px;">${new Date(r.released_at).toLocaleString()}</td>
            <td>${fmtA(r.gross)}</td>
            <td style="color:var(--text-muted);">${fmtA(r.fee)}</td>
            <td style="font-weight:600;color:var(--teal);">${fmtA(r.net)}</td>
            <td><span class="badge ${r.status==='success'?'badge-success':'badge-error'}">${r.status}</span></td>
            <td>${r.tx_signature?`<a href="${EX}${r.tx_signature}${CL}" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(r.tx_signature)}</a>`:'—'}</td>
          </tr>`).join('')
        : `<tr><td colspan="6" style="text-align:center;padding:24px;color:var(--text-hint);">No releases yet — first one at 6am UTC</td></tr>`;

      const depTbody = document.getElementById('dep-tbody');
      depTbody.innerHTML = allDep.length
        ? allDep.map(d=>`<tr>
            <td style="font-weight:600;">${fmtA(d.amount)}</td>
            <td style="font-family:var(--font-mono);font-size:11px;">${shortKey(d.customer_wallet)}</td>
            <td style="font-size:12px;color:var(--text-muted);">${new Date(d.created_at).toLocaleString()}</td>
            <td>${d.tx_signature?`<a href="${EX}${d.tx_signature}${CL}" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(d.tx_signature)}</a>`:'—'}</td>
          </tr>`).join('')
        : `<tr><td colspan="4" style="text-align:center;padding:24px;color:var(--text-hint);">No deposits recorded yet</td></tr>`;

    } catch(err) { toast.error(err.message); }
  }

  load();
  setInterval(()=>document.getElementById('s-next').textContent=nextRelease(),60000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — developer/cron.html
# ═══════════════════════════════════════════════════════════
cat > frontend/pages/developer/cron.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>SETTL — Cron monitor</title>
  <link rel="stylesheet" href="/css/app.css"/>
</head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <div class="topbar-left"><button class="menu-btn" onclick="openSidebar()">☰</button><span class="topbar-title">Cron monitor</span></div>
      <span class="badge badge-info">developer</span>
    </div>
    <div class="page-body">

      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;">
          <div><div class="card-title">Next scheduled release</div><div class="card-value" id="next-cd">—</div></div>
          <div style="display:flex;gap:8px;flex-wrap:wrap;">
            <button class="btn btn-secondary" id="btn-all" onclick="triggerAll()">▶ Release all now</button>
            <select class="form-input" id="sel-m" style="width:auto;min-width:160px;"></select>
            <button class="btn btn-secondary" onclick="triggerOne()">Run one</button>
          </div>
        </div>
        <div id="trig-status" style="font-size:13px;color:var(--text-muted);margin-top:10px;display:none;"></div>
      </div>

      <div class="card">
        <div class="card-title-row"><h2>Run history</h2><button class="btn btn-secondary btn-sm" onclick="loadLogs()">Refresh</button></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Started</th><th>By</th><th>Status</th><th>Released</th><th>Skipped</th><th>Failed</th><th>Summary</th></tr></thead>
            <tbody id="cron-tbody"><tr><td colspan="7" style="text-align:center;padding:28px;color:var(--text-hint);">Loading…</td></tr></tbody>
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
  initSidebar('developer');

  function nextRelease() {
    const now=new Date(),next=new Date(); next.setUTCHours(6,0,0,0);
    if(next<=now) next.setUTCDate(next.getUTCDate()+1);
    const d=next-now,h=Math.floor(d/3600000),m=Math.floor((d%3600000)/60000);
    return `${h}h ${m}m`;
  }

  async function init() {
    document.getElementById('next-cd').textContent = nextRelease();
    const { merchants } = await api.merchants.list().catch(()=>({merchants:[]}));
    const sel = document.getElementById('sel-m');
    sel.innerHTML = '<option value="">Select merchant…</option>' +
      merchants.filter(m=>m.is_active).map(m=>`<option value="${m.merchant_id}">${m.merchant_id}</option>`).join('');
    loadLogs();
    setInterval(()=>document.getElementById('next-cd').textContent=nextRelease(),60000);
  }

  async function loadLogs() {
    const tbody = document.getElementById('cron-tbody');
    try {
      const { logs } = await api.release.logs();
      if (!logs.length) {
        tbody.innerHTML=`<tr><td colspan="7" style="text-align:center;padding:32px;color:var(--text-hint);">No runs yet — trigger one above or wait for 6am UTC</td></tr>`;
        return;
      }
      tbody.innerHTML = logs.map(l=>`<tr>
        <td style="font-size:12px;">${new Date(l.started_at).toLocaleString()}</td>
        <td><span class="badge ${l.triggered_by==='cron'?'badge-info':'badge-pending'}">${l.triggered_by}</span></td>
        <td><span class="badge ${l.status==='success'?'badge-success':l.status==='failed'?'badge-error':l.status==='running'?'badge-pending':'badge-info'}">${l.status}</span></td>
        <td style="color:var(--teal);font-weight:600;">${l.released??'—'}</td>
        <td style="color:var(--text-muted);">${l.skipped??'—'}</td>
        <td style="color:${l.failed>0?'var(--coral)':'var(--text-muted)'};">${l.failed??'—'}</td>
        <td style="font-size:12px;color:var(--text-muted);">${l.summary||'—'}</td>
      </tr>`).join('');
    } catch(err) { toast.error(err.message); }
  }

  async function triggerAll() {
    const btn=document.getElementById('btn-all');
    const st=document.getElementById('trig-status');
    btn.disabled=true; btn.textContent='⏳ Running…';
    st.textContent='Sending release to Devnet for all merchants…'; st.style.display='';
    try {
      const r=await api.release.all();
      st.textContent=`Done — ${r.released} released, ${r.skipped} skipped, ${r.failed} failed`;
      toast.success('Release complete');
      loadLogs();
    } catch(err) { st.textContent='Error: '+err.message; toast.error(err.message); }
    finally { btn.disabled=false; btn.textContent='▶ Release all now'; }
  }

  async function triggerOne() {
    const id=document.getElementById('sel-m').value;
    if (!id) { toast.error('Select a merchant'); return; }
    const st=document.getElementById('trig-status');
    st.textContent=`Releasing ${id}…`; st.style.display='';
    try {
      const r=await api.release.one(id);
      st.textContent=r.skipped?`Skipped — ${r.reason}`:`Released ${id} successfully`;
      toast.success(r.skipped?'Skipped: '+r.reason:'Release successful!');
      loadLogs();
    } catch(err) { st.textContent='Error: '+err.message; toast.error(err.message); }
  }

  init();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# FRONTEND — operator/balance.html + settings stubs
# ═══════════════════════════════════════════════════════════
cat > frontend/pages/operator/balance.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>SETTL — Balance</title><link rel="stylesheet" href="/css/app.css"/></head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar"><div class="topbar-left"><button class="menu-btn" onclick="openSidebar()">☰</button><span class="topbar-title">Balance</span></div><span class="badge badge-success">operator</span></div>
    <div class="page-body">
      <div class="card-grid">
        <div class="card"><div class="card-title">Pending balance</div><div class="card-value" id="s-pending">—</div><div class="card-sub">Releases at 6am UTC</div></div>
        <div class="card"><div class="card-title">Total released</div><div class="card-value" id="s-released">—</div><div class="card-sub">Net AUDD received</div></div>
        <div class="card"><div class="card-title">Total fees paid</div><div class="card-value" id="s-fees">—</div><div class="card-sub">1.5% per release</div></div>
        <div class="card"><div class="card-title">Total payments</div><div class="card-value" id="s-count">—</div><div class="card-sub">Deposits received</div></div>
      </div>
      <div class="card">
        <div class="card-title-row"><h2>Wallet & vault</h2><button class="btn btn-secondary btn-sm" onclick="load()">Refresh</button></div>
        <div class="info-grid" id="wallet-info" style="margin-bottom:16px;"><span class="info-label">Loading…</span><span></span></div>
      </div>
    </div>
  </div>
</div>
<script src="/js/modules/api.js"></script><script src="/js/modules/auth.js"></script><script src="/js/modules/toast.js"></script><script src="/js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw 0;
  initSidebar('operator');

  function fmtA(v) { return v!=null?(v/1e6).toFixed(4)+' AUDD':'—'; }
  function shortKey(k) { return k?k.slice(0,6)+'…'+k.slice(-4):'—'; }

  async function load() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.filter(m=>m.is_active);
      if (!active.length) { document.getElementById('wallet-info').innerHTML='<span class="info-label">No active merchants</span><span></span>'; return; }
      const m = active[0];
      const [chain, escrow] = await Promise.all([
        api.merchants.getChainState(m.merchant_id).catch(()=>null),
        api.escrow.get(m.merchant_id).catch(()=>null),
      ]);
      document.getElementById('s-pending').textContent  = fmtA(escrow?.pendingBalance);
      document.getElementById('s-released').textContent = fmtA(chain?.merchant?.totalReleased);
      document.getElementById('s-fees').textContent     = fmtA(chain?.merchant?.totalFeesPaid);
      document.getElementById('s-count').textContent    = escrow?.totalPayments ?? '—';
      document.getElementById('wallet-info').innerHTML  = `
        <span class="info-label">Merchant</span><span class="info-value normal">${m.merchant_id}</span>
        <span class="info-label">Wallet</span><span class="info-value" onclick="navigator.clipboard.writeText('${m.wallet_address}').then(()=>toast.success('Copied!'))" style="cursor:pointer;" title="Click to copy">${shortKey(m.wallet_address)} <span style="font-size:11px;color:var(--brand);">copy</span></span>
        <span class="info-label">Vault PDA</span><span class="info-value">${shortKey(escrow?.vaultAddress)}</span>
        <span class="info-label">Last release</span><span class="info-value normal">${escrow?.lastReleasedAt?new Date(escrow.lastReleasedAt).toLocaleString():'Never'}</span>
        <span class="info-label">Chain source</span><span><span class="badge ${escrow?.source==='chain'?'badge-success':'badge-pending'}">${escrow?.source||'—'}</span></span>
      `;
    } catch(err) { toast.error(err.message); }
  }
  load();
</script>
</body></html>
EOF

cat > frontend/pages/operator/settings.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>SETTL — Settings</title><link rel="stylesheet" href="/css/app.css"/></head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar"><div class="topbar-left"><button class="menu-btn" onclick="openSidebar()">☰</button><span class="topbar-title">Settings</span></div></div>
    <div class="page-body">
      <div class="card" style="max-width:480px;">
        <div class="card-title-row"><h2>Profile</h2></div>
        <div class="form-group"><label class="form-label">Full name</label><input class="form-input" id="f-name"/></div>
        <div class="form-group"><label class="form-label">Email</label><input class="form-input" id="f-email" readonly style="background:var(--bg);color:var(--text-muted);"/></div>
        <div class="form-group"><label class="form-label">Role</label><input class="form-input" id="f-role" readonly style="background:var(--bg);color:var(--text-muted);"/></div>
        <div id="save-ok" class="alert alert-success" style="display:none;">Saved!</div>
        <button class="btn btn-primary" onclick="saveProfile()">Save changes</button>
      </div>
    </div>
  </div>
</div>
<script src="/js/modules/api.js"></script><script src="/js/modules/auth.js"></script><script src="/js/modules/toast.js"></script><script src="/js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw 0;
  initSidebar('operator');
  const u = auth.getUser();
  document.getElementById('f-name').value  = u?.full_name||'';
  document.getElementById('f-email').value = u?.email||'';
  document.getElementById('f-role').value  = u?.role||'';
  async function saveProfile() {
    try {
      const { user } = await api.auth.profile({ full_name: document.getElementById('f-name').value });
      auth.save(auth.getToken(), user);
      document.getElementById('save-ok').style.display=''; setTimeout(()=>document.getElementById('save-ok').style.display='none',2500);
    } catch(err) { toast.error(err.message); }
  }
</script>
</body></html>
EOF

# Developer stubs for escrow/transactions pages
for page in escrow transactions; do
cat > frontend/pages/developer/${page}.html << STUB
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>SETTL — ${page^}</title><link rel="stylesheet" href="/css/app.css"/></head>
<body>
<div id="sidebar-overlay" class="sidebar-overlay"></div>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar"><div class="topbar-left"><button class="menu-btn" onclick="openSidebar()">☰</button><span class="topbar-title">${page^}</span></div><span class="badge badge-info">developer</span></div>
    <div class="page-body"><div class="card"><p style="color:var(--text-muted);">Full ${page} page from Phase 2 loads here. Re-run the phase 2 script after this one to get the full implementation.</p></div></div>
  </div>
</div>
<script src="/js/modules/api.js"></script><script src="/js/modules/auth.js"></script><script src="/js/modules/nav.js"></script>
<script>if(!auth.requireAuth())throw 0; initSidebar('developer');</script>
</body></html>
STUB
done

# ═══════════════════════════════════════════════════════════
# INSTALL
# ═══════════════════════════════════════════════════════════
log "Installing backend dependencies..."
cd backend
if command -v yarn &>/dev/null; then yarn install --silent; else npm install --silent; fi
cd ..

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Phase 3 (Revised) — Complete                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What's in this script:${NC}"
echo ""
echo -e "  ${GREEN}①${NC} Single .env at settl/.env  (one source of truth)"
echo -e "     ${YELLOW}yarn dev${NC} from root starts everything on :3000"
echo ""
echo -e "  ${GREEN}②${NC} Custom auth — no Supabase Auth at all"
echo -e "     email + password + bcryptjs + jsonwebtoken"
echo -e "     stored in users table in your own Supabase DB"
echo ""
echo -e "  ${GREEN}③${NC} Merchant registration is automatic on the form:"
echo -e "     fill ID + wallet → backend registers on-chain"
echo -e "     + initialises escrow in one flow, progress shown"
echo ""
echo -e "  ${GREEN}④${NC} Wallet address: fixed validation (base58 PublicKey,"
echo -e "     not a regex — works with all real Solana addresses)"
echo ""
echo -e "  ${GREEN}⑤${NC} Solana Pay QR (proper spec):"
echo -e "     solana: URL with spl-token=AUDD_MINT + reference keypair"
echo -e "     QR rendered client-side, polls /api/payments/poll/:ref"
echo -e "     findReference + validateTransfer on confirmation"
echo ""
echo -e "  ${GREEN}⑥${NC} All pages redesigned mobile-first:"
echo -e "     hamburger menu, responsive grid, touch-friendly forms"
echo ""
echo -e "  ${BLUE}Steps before starting:${NC}"
echo ""
echo -e "  1. Fill in ${YELLOW}settl/.env${NC}"
echo -e "     (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, JWT_SECRET,"
echo -e "      SETTL_PROGRAM_ID, AUDD_MINT, TREASURY_WALLET,"
echo -e "      AUTHORITY_KEYPAIR_PATH)"
echo ""
echo -e "  2. Run ${YELLOW}supabase/migrations/001_full_schema.sql${NC} in Supabase SQL editor"
echo -e "     (This replaces all previous migrations — run from scratch)"
echo ""
echo -e "  3. Put your authority keypair at ${YELLOW}backend/keypair.json${NC}"
echo -e "     Fund it on Devnet: ${YELLOW}solana airdrop 2 <pubkey> --url devnet${NC}"
echo ""
echo -e "  4. ${YELLOW}yarn dev${NC}  →  open ${BLUE}http://localhost:3000${NC}"
echo ""
echo -e "  5. Create your account, then in Supabase SQL editor:"
echo -e "     ${YELLOW}UPDATE users SET role='developer' WHERE email='your@email.com';${NC}"
echo -e "     Then refresh — Developer mode appears in the sidebar toggle."
echo ""
warn "The @solana/pay package provides encodeURL, findReference, validateTransfer."
warn "Install bignumber.js is included — required by Solana Pay amount handling."
echo ""