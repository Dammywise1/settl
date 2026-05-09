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
