-- ═══════════════════════════════════════════════════════════
--  SETTL — Full schema (no roles, every user is a merchant)
--  Run this entire file in Supabase SQL editor
-- ═══════════════════════════════════════════════════════════
create extension if not exists "uuid-ossp";

-- ── users (every user is a merchant) ─────────────────────
create table if not exists users (
  id            uuid primary key default uuid_generate_v4(),
  email         text unique not null,
  password_hash text not null,
  full_name     text,
  is_active     boolean default true,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- ── merchants ─────────────────────────────────────────────
-- One merchant per user, created automatically on signup
create table if not exists merchants (
  id             uuid primary key default uuid_generate_v4(),
  user_id        uuid unique references users(id) on delete cascade,
  merchant_id    text unique not null,  -- on-chain seed
  name           text,
  wallet_address text not null,
  is_active      boolean default false, -- true after on-chain tx confirms
  registered_at  timestamptz,
  on_chain_tx    text,
  escrow_tx      text,
  merchant_pda   text,
  escrow_pda     text,
  vault_address  text,                  -- [b"vault", merchant_id] PDA — used in Solana Pay
  registration_status text default 'pending'
    check (registration_status in ('pending','processing','active','failed')),
  registration_error  text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

-- ── escrows ───────────────────────────────────────────────
create table if not exists escrows (
  id               uuid primary key default uuid_generate_v4(),
  merchant_id      text unique not null references merchants(merchant_id) on delete cascade,
  pending_balance  numeric(20,6) default 0,
  total_payments   integer default 0,
  last_released_at timestamptz,
  vault_address    text,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now()
);

-- ── payment_sessions ──────────────────────────────────────
-- Each QR code / payment link = one session
create table if not exists payment_sessions (
  id             uuid primary key default uuid_generate_v4(),
  merchant_id    text not null references merchants(merchant_id),
  amount         numeric(20,6),            -- in AUDD units (not lamports)
  reference_key  text unique not null,     -- base58 pubkey used in Solana Pay
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

-- ── Indexes ───────────────────────────────────────────────
create index if not exists idx_transactions_merchant   on transactions(merchant_id);
create index if not exists idx_transactions_created    on transactions(created_at desc);
create index if not exists idx_payment_sessions_ref    on payment_sessions(reference_key);
create index if not exists idx_payment_sessions_status on payment_sessions(status);
create index if not exists idx_merchants_active        on merchants(is_active);
create index if not exists idx_merchants_user          on merchants(user_id);
create index if not exists idx_release_logs_merchant   on release_logs(merchant_id);
create index if not exists idx_cron_logs_started       on cron_logs(started_at desc);

-- ── updated_at triggers ───────────────────────────────────
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

create trigger users_ts     before update on users     for each row execute procedure update_updated_at();
create trigger merchants_ts before update on merchants for each row execute procedure update_updated_at();
create trigger escrows_ts   before update on escrows   for each row execute procedure update_updated_at();
