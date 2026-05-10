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
