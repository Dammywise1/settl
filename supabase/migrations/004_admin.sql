-- ═══════════════════════════════════════════════════════════
--  SETTL Phase 6 — Admin
--  Run in Supabase SQL editor
-- ═══════════════════════════════════════════════════════════

-- Add is_admin flag to users table
alter table users
  add column if not exists is_admin boolean default false;

-- Index for fast admin lookup
create index if not exists idx_users_admin on users(is_admin) where is_admin = true;

-- To make yourself admin, run:
-- update users set is_admin = true where email = 'your@email.com';

-- ── Admin activity log ────────────────────────────────────
-- Tracks every action taken by admin for audit trail
create table if not exists admin_logs (
  id           uuid primary key default uuid_generate_v4(),
  admin_id     uuid references users(id),
  admin_email  text,
  action       text not null,   -- 'deactivate_merchant' | 'update_fee' | 'update_treasury' | 'view_merchant'
  target_id    text,            -- merchant_id or other target
  details      jsonb,           -- extra context
  created_at   timestamptz default now()
);

create index if not exists idx_admin_logs_created on admin_logs(created_at desc);
create index if not exists idx_admin_logs_admin   on admin_logs(admin_id);
