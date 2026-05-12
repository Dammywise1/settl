-- ═══════════════════════════════════════════════════════════
--  SETTL — Payment UX schema additions
--  Run in Supabase SQL editor
-- ═══════════════════════════════════════════════════════════

-- ── merchant_profile additions ────────────────────────────
-- Add branding + redirect fields to merchants table
alter table merchants
  add column if not exists brand_name     text,       -- display name on checkout
  add column if not exists brand_logo_url text,       -- https://... logo shown on checkout
  add column if not exists success_url    text,       -- redirect after payment confirmed
  add column if not exists support_email  text;       -- shown on checkout for customer queries

-- ── payment_links (reusable links) ───────────────────────
-- A permanent link that creates a fresh session each visit
create table if not exists payment_links (
  id            uuid primary key default uuid_generate_v4(),
  merchant_id   text not null references merchants(merchant_id) on delete cascade,
  slug          text unique not null,        -- short ID used in URL: /pay/<slug>
  title         text not null,              -- e.g. "Coffee tip jar"
  description   text,                       -- shown on checkout
  amount        numeric(20,6),              -- fixed amount, null = open
  currency      text default 'AUDD',
  is_reusable   boolean default true,       -- true = new session each visit
  is_active     boolean default true,
  success_url   text,                       -- override merchant default
  expiry_minutes integer,                   -- null = never expires (for reusable)
  total_uses    integer default 0,          -- how many times used
  total_volume  numeric(20,6) default 0,    -- total AUDD collected via this link
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

create index if not exists idx_payment_links_merchant on payment_links(merchant_id);
create index if not exists idx_payment_links_slug     on payment_links(slug);

create trigger payment_links_ts before update on payment_links
  for each row execute procedure update_updated_at();

-- ── payment_sessions additions ────────────────────────────
alter table payment_sessions
  add column if not exists payment_link_id uuid references payment_links(id),
  add column if not exists customer_note   text,           -- note from customer on checkout
  add column if not exists amount_received numeric(20,6),  -- actual amount received on-chain
  add column if not exists is_overpaid     boolean default false,
  add column if not exists is_underpaid    boolean default false,
  add column if not exists overpay_amount  numeric(20,6),  -- how much over
  add column if not exists underpay_amount numeric(20,6),  -- how much under
  add column if not exists success_url     text;           -- redirect after confirm

-- ── transactions additions ────────────────────────────────
alter table transactions
  add column if not exists customer_note  text,
  add column if not exists amount_received numeric(20,6),
  add column if not exists is_overpaid    boolean default false,
  add column if not exists is_underpaid   boolean default false;
