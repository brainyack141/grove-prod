begin;

-- Onboarding funnel events, written only by the `events` Edge Function with the
-- service-role key.
--
-- Placement follows `botanist_usage` and `analysis_jobs`: `public` so the
-- service-role client can reach it, RLS enabled with no policies so `anon` and
-- `authenticated` can never read or write it. Nothing in the app reads these
-- back; they exist to be queried in Studio.
--
-- Deliberately *not* in `app`, and deliberately not keyed to an account. Most of
-- these events happen before an account exists — the whole point is to see where
-- people leave during sign-up — so the only identity available is a random id
-- the install generates for itself. It is not derived from the device, not
-- shared with any other system, and resets when the app is reinstalled. Keeping
-- it out of `app` also keeps it outside every bootstrap query, so a funnel event
-- can never leak into a user's own snapshot.
create table public.analytics_events (
    id bigint generated always as identity primary key,
    -- Random per-install id from the client. Not a device identifier, and not
    -- joined to anything: it exists so one person's six screens read as one
    -- funnel rather than six unrelated events.
    install_id uuid not null,
    name text not null,
    params jsonb not null default '{}'::jsonb,
    -- When it happened on the device. Events are batched and may arrive late or
    -- out of order, so the client's clock is what any funnel query must use.
    occurred_at timestamptz not null,
    received_at timestamptz not null default now()
);

create index analytics_events_name_occurred on public.analytics_events (name, occurred_at desc);
create index analytics_events_install on public.analytics_events (install_id, occurred_at);

alter table public.analytics_events enable row level security;

-- The privacy policy promises diagnostics are deleted after 12 months. Nothing
-- schedules this; the `events` function calls it occasionally, the same way the
-- API sweeps its idempotency table.
create function public.sweep_analytics_events()
returns void
language sql
security definer
set search_path = public
as $$
    delete from public.analytics_events where received_at < now() - interval '12 months';
$$;

revoke all on function public.sweep_analytics_events() from public;
revoke all on function public.sweep_analytics_events() from anon;
revoke all on function public.sweep_analytics_events() from authenticated;

commit;
