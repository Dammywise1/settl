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
