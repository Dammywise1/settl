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

drop trigger if exists  on_auth_user_created on auth.users;
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

