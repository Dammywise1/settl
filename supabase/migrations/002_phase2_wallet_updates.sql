-- ═══════════════════════════════════════════════════════════
--  SETTL — Phase 2 Schema additions
-- ═══════════════════════════════════════════════════════════

-- ── wallet_update_requests ────────────────────────────────
-- Tracks the 24-hour delayed wallet change flow
create table if not exists wallet_update_requests (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text not null references merchants(merchant_id) on delete cascade,
  new_wallet   text not null,
  tx_signature text,
  unlocks_at   timestamptz not null,
  status       text default 'pending'
               check (status in ('pending', 'confirmed', 'cancelled')),
  confirmed_at timestamptz,
  created_at   timestamptz default now(),
  constraint wallet_update_requests_merchant_id_key unique (merchant_id)
);

alter table wallet_update_requests enable row level security;

create policy "Authenticated users can read wallet update requests"
  on wallet_update_requests for select using (auth.role() = 'authenticated');

create policy "Service role can manage wallet update requests"
  on wallet_update_requests for all using (true);

-- ── Index for pending wallet updates ──────────────────────
create index if not exists idx_wallet_updates_status
  on wallet_update_requests(status);

-- ── Add on_chain_pda columns to merchants ────────────────
alter table merchants
  add column if not exists merchant_pda text,
  add column if not exists escrow_pda   text;
