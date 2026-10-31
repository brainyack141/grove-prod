begin;

-- Anonymous signup is public, so its metadata can describe retention purpose
-- but can never authorize a paid surface. Signed-out onboarding and legacy
-- device-only analysis both receive the same strict budget; Botanist is limited
-- to a provisioned account verified below.
create table public.anonymous_auth_purposes (
    user_id uuid primary key references auth.users(id) on delete cascade,
    purpose text not null check (purpose in ('onboarding_scan', 'unclassified')),
    created_at timestamptz not null default now()
);

alter table public.anonymous_auth_purposes enable row level security;
revoke all on public.anonymous_auth_purposes from public;
revoke all on public.anonymous_auth_purposes from anon;
revoke all on public.anonymous_auth_purposes from authenticated;
grant select on public.anonymous_auth_purposes to service_role;

-- Existing anonymous identities are classified for cleanup only. Even a prior
-- caller-declared Botanist value is unclassified; public metadata is not proof.
insert into public.anonymous_auth_purposes (user_id, purpose, created_at)
select
    id,
    case raw_user_meta_data ->> 'purpose'
        when 'onboarding_scan' then 'onboarding_scan'
        else 'unclassified'
    end,
    created_at
from auth.users
where is_anonymous is not false
on conflict (user_id) do nothing;

create or replace function app.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
    new_grove_id uuid;
    chosen_username text;
begin
    -- Only a literal false may enter account provisioning. A missing/unknown
    -- Auth classification is retained as an unprivileged identity, never
    -- promoted into app.accounts by a fail-open boolean default.
    if new.is_anonymous is not false then
        insert into public.anonymous_auth_purposes (user_id, purpose, created_at)
        values (
            new.id,
            case new.raw_user_meta_data ->> 'purpose'
                when 'onboarding_scan' then 'onboarding_scan'
                else 'unclassified'
            end,
            new.created_at
        )
        -- Creation purpose is immutable and descriptive only. No public value
        -- here grants Botanist or a larger analysis ceiling.
        on conflict (user_id) do nothing;
        return new;
    end if;

    chosen_username := regexp_replace(
        lower(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1), 'gardener')),
        '[^a-z0-9_]', '', 'g'
    );
    if length(chosen_username) < 3 then
        chosen_username := 'gardener';
    end if;
    chosen_username := left(chosen_username, 16) || '_' || left(replace(new.id::text, '-', ''), 6);

    insert into app.accounts (id, username, display_name)
    values (
        new.id,
        chosen_username,
        coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), 'Gardener')
    );

    insert into app.groves (owner_account_id)
    values (new.id)
    returning id into new_grove_id;

    insert into app.grove_memberships (grove_id, account_id, role, can_edit_plants, can_manage_carers)
    values (new_grove_id, new.id, 'owner', true, true);

    return new;
end;
$$;

-- Paid gateways classify a verified Auth subject from server-owned rows, not
-- from caller metadata and not from a possibly omitted JSON `is_anonymous`
-- field. A provider Auth user is an account only after provisioning created the
-- matching app.accounts row; every anonymous Auth row stays anonymous.
create function public.analysis_identity_class(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog
as $$
    select case
        when users.is_anonymous is true then 'anonymous'
        when users.is_anonymous is false
             and exists (
                 select 1 from app.accounts accounts where accounts.id = users.id
             ) then 'account'
        else 'unclassified'
    end
    from auth.users users
    where users.id = p_user_id
$$;

revoke all on function public.analysis_identity_class(uuid) from public;
revoke all on function public.analysis_identity_class(uuid) from anon;
revoke all on function public.analysis_identity_class(uuid) from authenticated;
grant execute on function public.analysis_identity_class(uuid) to service_role;

-- A guest is limited to a bounded set of distinct first-plant captures (the
-- initial photo plus retakes), not raw HTTP attempts. The app
-- retries a stable `client_request_id` after a lost response or provider fault;
-- counting each retry as a new free scan would strand a legitimate first photo.
-- Attempts are still bounded so one failing request cannot spend forever.
create table public.analysis_guest_scans (
    account_id uuid not null references auth.users(id) on delete cascade,
    day date not null default (now() at time zone 'utc')::date,
    client_request_id uuid not null,
    fingerprint text not null,
    attempts integer not null default 1 check (attempts > 0),
    updated_at timestamptz not null default now(),
    primary key (account_id, day, client_request_id, fingerprint)
);

create index analysis_guest_scans_day on public.analysis_guest_scans (day);
alter table public.analysis_guest_scans enable row level security;
revoke all on public.analysis_guest_scans from public;
revoke all on public.analysis_guest_scans from anon;
revoke all on public.analysis_guest_scans from authenticated;

-- A second, project-wide guard bounds total guest provider spend even when a
-- hostile caller mints many anonymous Auth identities. It counts reservations,
-- not successful responses: failing closed can under-spend but never over-spend.
create table public.analysis_guest_global_usage (
    day date primary key default (now() at time zone 'utc')::date,
    reserved_provider_attempts integer not null default 0
        check (reserved_provider_attempts >= 0),
    updated_at timestamptz not null default now()
);

alter table public.analysis_guest_global_usage enable row level security;
revoke all on public.analysis_guest_global_usage from public;
revoke all on public.analysis_guest_global_usage from anon;
revoke all on public.analysis_guest_global_usage from authenticated;

-- Quota reservation and durable job creation are one transaction. This matters
-- for the exact retry that mobile networks produce: two concurrent copies of a
-- POST must return the same live job and consume one attempt, not reserve twice
-- before racing on `analysis_jobs_active_dedupe`.
--
-- Decisions are `created`, `existing`, `daily_limited`, `attempts_limited`, or
-- `global_limited`. A created/existing decision always carries the public job
-- status object under `job`; every other shape is a function contract failure.
create function public.analysis_create_guest_job(
    p_account_id uuid,
    p_client_request_id uuid,
    p_fingerprint text,
    p_daily_limit integer,
    p_max_attempts integer,
    p_global_daily_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    current_day date := (now() at time zone 'utc')::date;
    existing_job public.analysis_jobs%rowtype;
    created_job public.analysis_jobs%rowtype;
    used_attempts integer;
    distinct_scans integer;
    global_attempts integer;
    reservation_exists boolean;
begin
    if p_account_id is null
       or p_client_request_id is null
       or nullif(p_fingerprint, '') is null
       or p_fingerprint !~ '^[0-9a-f]{64}$'
       or p_daily_limit is null
       or p_daily_limit < 1
       or p_max_attempts is null
       or p_max_attempts < 1
       or p_global_daily_limit is null
       or p_global_daily_limit < 1 then
        raise exception 'invalid guest analysis job request';
    end if;

    -- The global lock is deliberately first and shared by every guest job for a
    -- UTC day. It makes the global ceiling exact and also serialises the much
    -- smaller per-identity decision, avoiding a second lock and lock ordering.
    perform pg_advisory_xact_lock(
        hashtextextended('grove:guest-analysis:' || current_day::text, 0)
    );

    select jobs.* into existing_job
    from public.analysis_jobs jobs
    where jobs.owner_account_id = p_account_id::text
      and jobs.client_request_id = p_client_request_id
      and jobs.fingerprint = p_fingerprint
      and jobs.status in ('queued', 'analysing', 'completed')
    limit 1;

    if found then
        return jsonb_build_object(
            'decision', 'existing',
            'job', jsonb_build_object(
                'id', existing_job.id,
                'status', existing_job.status,
                'created_at', existing_job.created_at,
                'updated_at', existing_job.updated_at,
                'result', existing_job.result,
                'message', existing_job.message
            )
        );
    end if;

    select attempts into used_attempts
    from public.analysis_guest_scans
    where account_id = p_account_id
      and day = current_day
      and client_request_id = p_client_request_id
      and fingerprint = p_fingerprint;
    reservation_exists := found;

    if reservation_exists then
        if used_attempts >= p_max_attempts then
            return jsonb_build_object('decision', 'attempts_limited');
        end if;
    else
        select count(*) into distinct_scans
        from public.analysis_guest_scans
        where account_id = p_account_id and day = current_day;
        if distinct_scans >= p_daily_limit then
            return jsonb_build_object('decision', 'daily_limited');
        end if;
    end if;

    insert into public.analysis_guest_global_usage (
        day, reserved_provider_attempts
    ) values (
        current_day, 0
    ) on conflict (day) do nothing;

    select reserved_provider_attempts into global_attempts
    from public.analysis_guest_global_usage
    where day = current_day
    for update;

    if global_attempts >= p_global_daily_limit then
        return jsonb_build_object('decision', 'global_limited');
    end if;

    if reservation_exists then
        update public.analysis_guest_scans
        set attempts = attempts + 1,
            updated_at = now()
        where account_id = p_account_id
          and day = current_day
          and client_request_id = p_client_request_id
          and fingerprint = p_fingerprint;
    else
        insert into public.analysis_guest_scans (
            account_id, day, client_request_id, fingerprint, attempts
        ) values (
            p_account_id, current_day, p_client_request_id, p_fingerprint, 1
        );
    end if;

    update public.analysis_guest_global_usage
    set reserved_provider_attempts = reserved_provider_attempts + 1,
        updated_at = now()
    where day = current_day;

    insert into public.analysis_jobs (
        owner_account_id, client_request_id, fingerprint, status
    ) values (
        p_account_id::text, p_client_request_id, p_fingerprint, 'queued'
    ) returning * into created_job;

    return jsonb_build_object(
        'decision', 'created',
        'job', jsonb_build_object(
            'id', created_job.id,
            'status', created_job.status,
            'created_at', created_job.created_at,
            'updated_at', created_job.updated_at,
            'result', created_job.result,
            'message', created_job.message
        )
    );
end;
$$;

revoke all on function public.analysis_create_guest_job(uuid, uuid, text, integer, integer, integer) from public;
revoke all on function public.analysis_create_guest_job(uuid, uuid, text, integer, integer, integer) from anon;
revoke all on function public.analysis_create_guest_job(uuid, uuid, text, integer, integer, integer) from authenticated;
grant execute on function public.analysis_create_guest_job(uuid, uuid, text, integer, integer, integer) to service_role;

-- Extend the existing analysis sweep. Abandoned onboarding identities carry no
-- Grove account, but their refresh credentials and quota subject must not live
-- forever: after 30 days the server removes the Auth user and its cascading
-- purpose/reservation rows. Active job metadata already has a one-day maximum.
create or replace function public.sweep_analysis_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.analysis_jobs
        where status not in ('queued', 'analysing')
          and created_at < now() - interval '1 hour';

    delete from public.analysis_jobs
        where created_at < now() - interval '1 day';

    delete from public.analysis_usage
        where day < (now() at time zone 'utc')::date - 60;

    delete from public.analysis_guest_scans
        where day < (now() at time zone 'utc')::date - 60;

    delete from public.analysis_guest_global_usage
        where day < (now() at time zone 'utc')::date - 60;

    delete from public.analysis_jobs jobs
    using public.anonymous_auth_purposes purposes, auth.users users
    where purposes.user_id = users.id
      and users.is_anonymous is not false
      and users.created_at < now() - interval '30 days'
      and jobs.owner_account_id = users.id::text;

    delete from public.analysis_usage usage
    using public.anonymous_auth_purposes purposes, auth.users users
    where purposes.user_id = users.id
      and users.is_anonymous is not false
      and users.created_at < now() - interval '30 days'
      and usage.account_id = users.id::text;

    -- Botanist now requires a provisioned account. Remove anything an anonymous
    -- credential wrote before that gate existed so deleting its Auth identity
    -- does not orphan text-keyed data.
    delete from public.botanist_advice advice
    using public.anonymous_auth_purposes purposes, auth.users users
    where purposes.user_id = users.id
      and users.is_anonymous is not false
      and users.created_at < now() - interval '30 days'
      and advice.account_id = users.id::text;

    delete from public.botanist_usage usage
    using public.anonymous_auth_purposes purposes, auth.users users
    where purposes.user_id = users.id
      and users.is_anonymous is not false
      and users.created_at < now() - interval '30 days'
      and usage.account_id = users.id::text;

    delete from auth.users users
    using public.anonymous_auth_purposes purposes
    where purposes.user_id = users.id
      and users.is_anonymous is not false
      and users.created_at < now() - interval '30 days';
end;
$$;

revoke all on function public.sweep_analysis_jobs() from public;
revoke all on function public.sweep_analysis_jobs() from anon;
revoke all on function public.sweep_analysis_jobs() from authenticated;
grant execute on function public.sweep_analysis_jobs() to service_role;

-- Earlier migrations intentionally removed public execution but relied on the
-- hosted project's default service grants. Make the production dependency
-- explicit while this migration is touching the same call path.
grant execute on function public.analysis_record_scan(text, integer) to service_role;

-- Repair older migrations that relied on hosted default privileges. The Edge
-- clients use service-role PostgREST calls: bypassing RLS does not substitute
-- for table/function grants on every PostgreSQL installation.
grant select, insert, update, delete on public.analysis_jobs to service_role;
grant select, insert, update, delete on public.botanist_usage to service_role;
grant select, insert, update, delete on public.botanist_advice to service_role;

create or replace function public.botanist_record_ask(
    p_account_id text,
    p_daily_limit integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    used integer;
begin
    if nullif(p_account_id, '') is null
       or p_daily_limit is null
       or p_daily_limit < 1 then
        raise exception 'invalid botanist usage request';
    end if;

    insert into public.botanist_usage (account_id, day, asks)
    values (p_account_id, (now() at time zone 'utc')::date, 1)
    on conflict (account_id, day) do update
        set asks = botanist_usage.asks + 1,
            updated_at = now()
    returning asks into used;

    if used > p_daily_limit then
        return -1;
    end if;
    return used;
end;
$$;

revoke all on function public.botanist_record_ask(text, integer) from public;
revoke all on function public.botanist_record_ask(text, integer) from anon;
revoke all on function public.botanist_record_ask(text, integer) from authenticated;
grant execute on function public.botanist_record_ask(text, integer) to service_role;

-- Guest identity retention is a privacy promise, not optional housekeeping.
-- The earlier scale migration attempted to enable pg_cron but tolerated failure;
-- onboarding cannot. Abort unless its scheduling API is present and the job is
-- active. (`auth-stub.sql` supplies a faithful in-memory catalogue in CI.)
do $$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is null
       or to_regprocedure('cron.unschedule(text)') is null then
        raise exception 'pg_cron is required for onboarding guest retention';
    end if;

    if exists (select 1 from cron.job where jobname = 'grove-sweep-analysis-jobs') then
        perform cron.unschedule('grove-sweep-analysis-jobs');
    end if;

    perform cron.schedule(
        'grove-sweep-analysis-jobs',
        '*/15 * * * *',
        'select public.sweep_analysis_jobs()'
    );

    if not exists (
        select 1
        from cron.job
        where jobname = 'grove-sweep-analysis-jobs'
          and active
    ) then
        raise exception 'grove-sweep-analysis-jobs must be actively scheduled';
    end if;
end $$;

commit;
