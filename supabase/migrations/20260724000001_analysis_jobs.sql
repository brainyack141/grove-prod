begin;

-- Durable plant-analysis jobs for the scan pipeline, replacing the dev server's
-- in-memory job map. Written and read exclusively by the `analysis` Edge Function
-- with the service-role key.
--
-- The table lives in `public` (not `app`) deliberately: PostgREST only exposes
-- `public`, and the Edge Function reaches Postgres through PostgREST with the
-- auto-injected service-role credentials. Keeping `app` unexposed preserves the
-- existing security posture. RLS is enabled with no policies, so anon and
-- authenticated roles cannot touch the table at all.
--
-- `owner_account_id` is the caller's account identifier: today the interim
-- bearer account id, later the Supabase Auth uuid once app sign-in lands.
create table public.analysis_jobs (
    id uuid primary key default gen_random_uuid(),
    owner_account_id text not null,
    client_request_id uuid not null,
    fingerprint text not null,
    status text not null default 'queued'
        check (status in ('queued', 'analysing', 'completed', 'failed', 'cancelled')),
    request jsonb,
    result jsonb,
    message text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- One live (queued/analysing/completed) job per scan attempt; settled failures
-- and cancellations never block an identical retry from starting fresh.
create unique index analysis_jobs_active_dedupe
    on public.analysis_jobs (owner_account_id, client_request_id, fingerprint)
    where status in ('queued', 'analysing', 'completed');

create index analysis_jobs_created_at on public.analysis_jobs (created_at);

alter table public.analysis_jobs enable row level security;

commit;
