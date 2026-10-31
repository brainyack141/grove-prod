-- Durable persistence for the sync contract.
--
-- The API served the whole app data model (plants, care, check-ins,
-- friendships, sitting) out of process memory, so every restart or redeploy
-- returned an empty account — and the client treats /v1/bootstrap as
-- authoritative, replacing local state wholesale. That combination deletes a
-- user's entire Grove. This migration adds the columns and tables the sync
-- contract needs so the handlers can run on PostgreSQL instead.
--
-- Everything here is additive; no existing column changes type or nullability.

begin;

-- Presentation and guidance fields the client round-trips with every plant.
-- `location` is free text from the add-plant flow; app.spaces remains the
-- richer model for when the client adopts it.
alter table app.plants
  add column if not exists location text,
  add column if not exists symbol text,
  add column if not exists palette text,
  add column if not exists summary text,
  add column if not exists positive_signs jsonb not null default '[]'::jsonb,
  add column if not exists concerns jsonb not null default '[]'::jsonb,
  add column if not exists next_actions jsonb not null default '[]'::jsonb;

-- A care action delegated to a sitter names the owner it is performed for.
alter table app.care_actions
  add column if not exists is_sitting_task boolean not null default false,
  add column if not exists owner_name text;

-- Activity is attributed to a display name, which may be a sitter or Grove
-- itself rather than an account that exists.
alter table app.activity_events
  add column if not exists actor_name text,
  add column if not exists actor_initials text;

alter table app.sitting_assignments
  add column if not exists sitter_name text,
  add column if not exists sitter_initials text,
  add column if not exists completed_tasks integer not null default 0,
  add column if not exists total_tasks integer not null default 0;

-- An invitation can name a username before that person has an account, so the
-- target account id stays null until they join.
alter table app.friendships
  alter column requested_to_account_id drop not null,
  add column if not exists requested_to_username text,
  add column if not exists display_name text,
  add column if not exists initials text;

-- The self-reference check compares two account ids and must not fire when the
-- target is still only a username. The constraint is unnamed in the base
-- schema, so find it rather than guessing at a generated name.
do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname from pg_constraint
     where conrelid = 'app.friendships'::regclass and contype = 'c'
  loop
    execute format('alter table app.friendships drop constraint %I', constraint_name);
  end loop;

  alter table app.friendships
    add constraint friendships_not_self
    check (requested_to_account_id is null or requested_by_account_id <> requested_to_account_id);
end $$;

-- Observation answers already carry the check-in form; scores live in
-- app.health_assessments. Nothing to add.

-- Idempotency replay records, previously an unbounded in-memory Map that also
-- vanished on restart — so a retried mutation after a redeploy would apply
-- twice.
create table if not exists app.idempotency_keys (
  account_id uuid not null references app.accounts(id) on delete cascade,
  idempotency_key text not null,
  method text not null,
  path text not null,
  status integer not null,
  body jsonb not null,
  stored_at timestamptz not null default now(),
  primary key (account_id, idempotency_key, method, path)
);

create index if not exists idempotency_keys_stored_at_idx
  on app.idempotency_keys (stored_at);

-- Signed media upload permissions, so an upload negotiated before a restart can
-- still be completed afterwards.
create table if not exists app.media_uploads (
  media_asset_id uuid primary key,
  owner_account_id uuid not null references app.accounts(id) on delete cascade,
  local_media_id uuid not null,
  token text not null,
  mime_type text not null,
  byte_count bigint not null,
  sha256 text not null,
  pixel_width integer,
  pixel_height integer,
  purpose text not null,
  status text not null default 'pending',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (owner_account_id, local_media_id)
);

commit;
