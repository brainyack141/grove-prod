begin;

-- Per-account daily counter for the botanist coach, written only by the
-- `botanist` Edge Function with the service-role key.
--
-- This is an abuse guard, not the product's free-question meter. The app key
-- ships inside every binary, so anyone who reads it could otherwise point a
-- script at the coach and spend the DeepSeek budget. The product meter (how
-- many questions a free account gets before the premium wall) lives on the
-- client where it can be shown honestly; this ceiling sits far above it and
-- only ever catches abuse or a client stuck in a retry loop.
--
-- Same placement rationale as `analysis_jobs`: `public` so the service-role
-- client can reach it, RLS enabled with no policies so anon and authenticated
-- roles cannot touch it at all.
create table public.botanist_usage (
    account_id text not null,
    day date not null default (now() at time zone 'utc')::date,
    asks integer not null default 0,
    updated_at timestamptz not null default now(),
    primary key (account_id, day)
);

create index botanist_usage_day on public.botanist_usage (day);

alter table public.botanist_usage enable row level security;

-- Counts one ask and reports whether it is allowed, atomically. Read-then-write
-- from the function would let concurrent requests share a stale count, which is
-- exactly the case a rate limit exists to stop.
--
-- A rejected ask still increments: the counter is a spend signal, and letting it
-- climb keeps a hammering caller rejected rather than freeing a slot per second.
-- Returns the new count, or -1 when the day's ceiling is already spent.
create function public.botanist_record_ask(p_account_id text, p_daily_limit integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    used integer;
begin
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

-- Only the service role (which bypasses grants) should ever call this.
revoke all on function public.botanist_record_ask(text, integer) from public;
revoke all on function public.botanist_record_ask(text, integer) from anon;
revoke all on function public.botanist_record_ask(text, integer) from authenticated;

commit;
