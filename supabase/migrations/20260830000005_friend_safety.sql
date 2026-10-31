-- Safety reports are server-mediated. A report identifies the account being
-- reported, keeps the relationship that supplied the context when it still
-- exists, and is idempotent per reporter request.

begin;

-- Grove no longer advertises a discovery mode. Connections expose only name
-- and username; plant access is always an explicit sitting capability.
update app.groves set is_private = true where is_private is false;

alter table app.sitting_invites
  add column if not exists recipient_account_id uuid references app.accounts(id) on delete set null;

create index if not exists sitting_invites_recipient_idx
  on app.sitting_invites (owner_account_id, recipient_account_id)
  where recipient_account_id is not null and revoked_at is null;

create table if not exists app.friend_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_account_id uuid not null references app.accounts(id) on delete cascade,
  reported_account_id uuid not null references app.accounts(id) on delete cascade,
  friendship_id uuid references app.friendships(id) on delete set null,
  reason text not null check (
    reason in ('harassment', 'impersonation', 'spam', 'inappropriateProfile', 'other')
  ),
  details text check (details is null or char_length(details) <= 1000),
  client_request_id uuid not null,
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  check (reporter_account_id <> reported_account_id),
  unique (reporter_account_id, client_request_id)
);

create index if not exists friend_reports_status_created_idx
  on app.friend_reports (status, created_at desc);

create index if not exists friend_reports_reported_account_idx
  on app.friend_reports (reported_account_id, created_at desc);

alter table app.friend_reports enable row level security;

-- The Edge API writes through its server connection after authenticating and
-- validating the reporter. Raw app clients cannot read reports, discover who
-- reported whom, alter moderation state, or bypass the atomic block.
revoke all on table app.friend_reports from public, anon, authenticated;

commit;
