begin;

-- Scale work for the scan pipeline, in three parts: stop storing scan photos in
-- Postgres, give scans the same abuse ceiling the botanist already has, and move
-- job housekeeping off the request path.

-- 1. Drop the evidence column.
--
-- `analysis_jobs.request` held the whole validated request — including up to
-- four base64 photos, ~11 MB at the accepted ceiling. It was written on insert,
-- nulled on settle, and never read: the worker already has the request in
-- memory, and no other worker ever picks up an abandoned job. Storing it made
-- every status update rewrite a multi-megabyte TOASTed row, and made every
-- client poll drag that row back out of the database.
alter table public.analysis_jobs drop column if exists request;

-- 2. Per-account daily scan ceiling.
--
-- Same shape and same reasoning as `botanist_usage`: the app key ships in every
-- binary, so without a counter anyone who reads it out could point a script at
-- the scan gateway and spend the Gemini budget. This is an abuse ceiling, not
-- the product's free-scan meter — it sits far above what any real gardener does
-- in a day and only ever catches a script or a client stuck in a retry loop.
create table public.analysis_usage (
    account_id text not null,
    day date not null default (now() at time zone 'utc')::date,
    scans integer not null default 0,
    updated_at timestamptz not null default now(),
    primary key (account_id, day)
);

create index analysis_usage_day on public.analysis_usage (day);

alter table public.analysis_usage enable row level security;

-- Counts one scan and reports whether it is allowed, atomically — a
-- read-then-write from the function would let concurrent scans share a stale
-- count, which is the exact case a ceiling exists to stop.
--
-- A rejected scan still increments, so a hammering caller stays rejected rather
-- than freeing a slot every time the clock ticks. Returns the new count, or -1
-- when the day's ceiling is already spent.
create function public.analysis_record_scan(p_account_id text, p_daily_limit integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    used integer;
begin
    insert into public.analysis_usage (account_id, day, scans)
    values (p_account_id, (now() at time zone 'utc')::date, 1)
    on conflict (account_id, day) do update
        set scans = analysis_usage.scans + 1,
            updated_at = now()
    returning scans into used;

    if used > p_daily_limit then
        return -1;
    end if;
    return used;
end;
$$;

-- Only the service role (which bypasses grants) should ever call this.
revoke all on function public.analysis_record_scan(text, integer) from public;
revoke all on function public.analysis_record_scan(text, integer) from anon;
revoke all on function public.analysis_record_scan(text, integer) from authenticated;

-- 3. Housekeeping on a schedule rather than on every scan.
--
-- The Edge Function used to run both DELETEs inline on every job creation. That
-- is the same work repeated thousands of times a day on the one request path a
-- user is actually waiting behind.
create function public.sweep_analysis_jobs()
returns void
language sql
security definer
set search_path = public
as $$
    -- Settled jobs are useful for about an hour of client resumption; anything
    -- older, or anything somehow still live after a day, goes.
    delete from public.analysis_jobs
        where status not in ('queued', 'analysing')
          and created_at < now() - interval '1 hour';

    delete from public.analysis_jobs
        where created_at < now() - interval '1 day';

    -- Usage counters are an abuse signal, not analytics. Two months is plenty
    -- to investigate a spike with.
    delete from public.analysis_usage
        where day < (now() at time zone 'utc')::date - 60;
$$;

revoke all on function public.sweep_analysis_jobs() from public;
revoke all on function public.sweep_analysis_jobs() from anon;
revoke all on function public.sweep_analysis_jobs() from authenticated;

-- Schedule it if the project allows pg_cron. This is deliberately best-effort:
-- a project without the extension must still accept this migration, because the
-- Edge Function keeps a sampled fallback sweep for exactly that case.
do $$
begin
    create extension if not exists pg_cron with schema extensions;

    if exists (select 1 from cron.job where jobname = 'grove-sweep-analysis-jobs') then
        perform cron.unschedule('grove-sweep-analysis-jobs');
    end if;

    perform cron.schedule(
        'grove-sweep-analysis-jobs',
        '*/15 * * * *',
        'select public.sweep_analysis_jobs()'
    );
exception when others then
    raise notice 'pg_cron unavailable (%); the analysis function will sweep on a sampled fallback instead.', sqlerrm;
end $$;

commit;
