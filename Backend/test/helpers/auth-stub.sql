-- Minimal stand-in for the Supabase-managed `auth` schema, for tests and CI.
--
-- `20260723000002_supabase_auth_identity.sql` makes an account a uuid
-- referencing `auth.users` and installs the `on_auth_user_created` trigger that
-- provisions the account, its Grove and its membership. Supabase provides that
-- table in a real project; a plain PostgreSQL has to stand it up so the
-- migrations apply and the trigger has something to fire on.
--
-- Only the columns the trigger reads are modelled. This file is a test fixture
-- and is deliberately not a migration.
-- Supabase's built-in roles, which the migrations grant privileges to.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
    id uuid primary key default gen_random_uuid(),
    email text,
    raw_user_meta_data jsonb not null default '{}'::jsonb,
    raw_app_meta_data jsonb not null default '{}'::jsonb,
    is_anonymous boolean not null default false,
    created_at timestamptz not null default now()
);

-- Keep an existing developer database upgradeable when this fixture is rerun.
-- `create table if not exists` does not add newly required Auth columns.
alter table auth.users
    add column if not exists raw_app_meta_data jsonb not null default '{}'::jsonb,
    add column if not exists is_anonymous boolean not null default false;

-- `auth.uid()` is what the RLS policies resolve the current actor through.
-- Supabase derives it from the request JWT; here it reads the same GUC the
-- service sets in `createGroveDatabase().withAccount`.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.account_id', true), '')::uuid
$$;

-- Minimal pg_cron catalogue for migration and cleanup-contract tests. Production
-- must have the real extension; the onboarding migration verifies the same
-- schedule API and active job invariant before it commits.
create schema if not exists cron;

create table if not exists cron.job (
    jobid bigserial primary key,
    jobname text not null unique,
    schedule text not null,
    command text not null,
    active boolean not null default true
);

create or replace function cron.schedule(
    requested_name text,
    requested_schedule text,
    requested_command text
)
returns bigint
language plpgsql
as $$
declare
    scheduled_job_id bigint;
begin
    insert into cron.job (jobname, schedule, command, active)
    values (requested_name, requested_schedule, requested_command, true)
    on conflict (jobname) do update
        set schedule = excluded.schedule,
            command = excluded.command,
            active = true
    returning jobid into scheduled_job_id;
    return scheduled_job_id;
end;
$$;

create or replace function cron.unschedule(requested_name text)
returns boolean
language plpgsql
as $$
declare
    removed integer;
begin
    delete from cron.job where jobname = requested_name;
    get diagnostics removed = row_count;
    return removed > 0;
end;
$$;

-- Supabase Storage, for the media-bucket migration.
create schema if not exists storage;

create table if not exists storage.buckets (
    id text primary key,
    name text not null,
    public boolean not null default false,
    file_size_limit bigint,
    allowed_mime_types text[],
    created_at timestamptz not null default now()
);

create table if not exists storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets(id),
    name text not null,
    owner uuid,
    metadata jsonb,
    created_at timestamptz not null default now()
);
