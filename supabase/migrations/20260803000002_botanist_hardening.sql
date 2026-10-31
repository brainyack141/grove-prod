begin;

-- The evidence boundary is a successful, deliberately conservative result. The
-- Edge Function has emitted this status since Botanist v2, but the advice-table
-- check omitted it, turning a safe clarification into a persistence failure and
-- a 503 for every replay-safe app request.
alter table public.botanist_advice
  drop constraint if exists botanist_advice_verification_status_check;

alter table public.botanist_advice
  add constraint botanist_advice_verification_status_check
  check (verification_status in (
    'not_required',
    'policy_override',
    'approve',
    'revise',
    'withhold',
    'withheld',
    'photo_scan',
    'evidence_boundary'
  ));

-- Botanist tables deliberately use text account ids and therefore do not
-- cascade from app.accounts. Close the deletion race in both directions:
-- inserts lock and require the live account row, while deleting that row
-- purges every detached Botanist record in the same database transaction.
create or replace function public.botanist_require_live_account()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
begin
  perform 1
  from app.accounts
  where id::text = new.account_id
  for key share;
  if not found then
    raise foreign_key_violation using message = 'Botanist account no longer exists';
  end if;
  return new;
end;
$$;

revoke all on function public.botanist_require_live_account() from public;
revoke all on function public.botanist_require_live_account() from anon;
revoke all on function public.botanist_require_live_account() from authenticated;

drop trigger if exists botanist_advice_live_account on public.botanist_advice;
create trigger botanist_advice_live_account
before insert on public.botanist_advice
for each row execute function public.botanist_require_live_account();

drop trigger if exists botanist_usage_live_account on public.botanist_usage;
create trigger botanist_usage_live_account
before insert on public.botanist_usage
for each row execute function public.botanist_require_live_account();

drop trigger if exists botanist_requests_live_account on public.botanist_requests;
create trigger botanist_requests_live_account
before insert on public.botanist_requests
for each row execute function public.botanist_require_live_account();

create or replace function public.botanist_purge_deleted_account()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
begin
  delete from public.botanist_requests where account_id = old.id::text;
  delete from public.botanist_advice where account_id = old.id::text;
  delete from public.botanist_usage where account_id = old.id::text;
  return old;
end;
$$;

revoke all on function public.botanist_purge_deleted_account() from public;
revoke all on function public.botanist_purge_deleted_account() from anon;
revoke all on function public.botanist_purge_deleted_account() from authenticated;

drop trigger if exists botanist_purge_on_account_delete on app.accounts;
create trigger botanist_purge_on_account_delete
after delete on app.accounts
for each row execute function public.botanist_purge_deleted_account();

-- Saturate the abuse counter at limit + 1. Rejected calls still stay rejected,
-- but a script cannot drive the integer upward forever after the useful ceiling
-- has already been crossed.
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
  if nullif(btrim(p_account_id), '') is null
     or p_daily_limit is null
     or p_daily_limit < 1
     or p_daily_limit > 1000000 then
    raise exception 'invalid botanist usage request';
  end if;

  insert into public.botanist_usage (account_id, day, asks)
  values (p_account_id, (now() at time zone 'utc')::date, 1)
  on conflict (account_id, day) do update
    set asks = least(
          public.botanist_usage.asks::bigint + 1,
          p_daily_limit::bigint + 1
        )::integer,
        updated_at = now()
  returning asks into used;

  if used > p_daily_limit then return -1; end if;
  return used;
end;
$$;

revoke all on function public.botanist_record_ask(text, integer) from public;
revoke all on function public.botanist_record_ask(text, integer) from anon;
revoke all on function public.botanist_record_ask(text, integer) from authenticated;
grant execute on function public.botanist_record_ask(text, integer) to service_role;

-- Request claims coordinate active workers; the durable replay record is
-- botanist_advice. These partial indexes keep bounded cleanup cheap without
-- bloating the primary account/request lookup.
create index if not exists botanist_requests_completed_at_idx
  on public.botanist_requests (completed_at)
  where state = 'completed';

create index if not exists botanist_requests_unfinished_claimed_at_idx
  on public.botanist_requests (claimed_at)
  where state <> 'completed';

-- A caller over the daily abuse ceiling can supply a fresh request UUID on every
-- attempt. Persisting each rejected UUID made a zero-provider-cost hammer grow
-- botanist_requests without bound. Once the saturated counter says the ceiling
-- is spent, new UUIDs return before inserting at all; a race at the boundary is
-- deleted before returning. Historical limited rows keep their next-day behaviour.
create or replace function public.botanist_claim_request(
  p_account_id text,
  p_request_id uuid,
  p_daily_limit integer
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_count integer;
  existing_state text;
  existing_claimed_at timestamptz;
  existing_advice uuid;
  used integer;
begin
  if p_account_id is null or btrim(p_account_id) = ''
     or p_request_id is null
     or p_daily_limit is null or p_daily_limit < 1 or p_daily_limit > 1000000 then
    raise exception 'invalid Botanist request claim';
  end if;

  loop
    -- Resolve a replay before consulting today's ceiling. A completed answer
    -- costs nothing to replay, and an abandoned in-flight request retains its
    -- original claim rather than creating another provider-spend count.
    existing_state := null;
    existing_claimed_at := null;
    existing_advice := null;
    select state, claimed_at, advice_id
    into existing_state, existing_claimed_at, existing_advice
    from public.botanist_requests
    where account_id = p_account_id and request_id = p_request_id
    for update;

    if found then
      if existing_state = 'completed' then return 'completed'; end if;
      if existing_state = 'limited' then
        if (existing_claimed_at at time zone 'utc')::date
           < (now() at time zone 'utc')::date then
          used := public.botanist_record_ask(p_account_id, p_daily_limit);
          if used < 0 then
            update public.botanist_requests
            set claimed_at = now()
            where account_id = p_account_id and request_id = p_request_id;
            return 'limited';
          end if;
          update public.botanist_requests
          set state = 'processing', claimed_at = now()
          where account_id = p_account_id and request_id = p_request_id;
          return 'claimed';
        end if;
        return 'limited';
      end if;

      if existing_advice is null then
        select id into existing_advice
        from public.botanist_advice
        where account_id = p_account_id and request_id = p_request_id;
        if existing_advice is not null then
          update public.botanist_requests
          set state = 'completed', advice_id = existing_advice, completed_at = now()
          where account_id = p_account_id and request_id = p_request_id;
          return 'completed';
        end if;
      end if;

      if existing_claimed_at < now() - interval '3 minutes' then
        -- A stale worker may have died after spending provider tokens. A retry
        -- is useful, but it is still another provider execution and must count
        -- toward the abuse ceiling; otherwise one UUID can be reclaimed every
        -- three minutes forever without advancing botanist_usage.
        used := public.botanist_record_ask(p_account_id, p_daily_limit);
        if used < 0 then
          update public.botanist_requests
          set state = 'limited', claimed_at = now()
          where account_id = p_account_id and request_id = p_request_id;
          return 'limited';
        end if;
        update public.botanist_requests
        set claimed_at = now()
        where account_id = p_account_id and request_id = p_request_id;
        return 'claimed';
      end if;
      return 'processing';
    end if;

    -- Completed claim rows are short-lived coordination state. The advice row
    -- is the durable replay source, so cleanup can remove an old claim without
    -- making the same stable request UUID run a provider again.
    select id into existing_advice
    from public.botanist_advice
    where account_id = p_account_id and request_id = p_request_id;
    if found then return 'completed'; end if;

    used := null;
    select asks into used
    from public.botanist_usage
    where account_id = p_account_id
      and day = (now() at time zone 'utc')::date;
    if coalesce(used, 0) > p_daily_limit then return 'limited'; end if;

    insert into public.botanist_requests (account_id, request_id, state)
    values (p_account_id, p_request_id, 'processing')
    on conflict do nothing;
    get diagnostics inserted_count = row_count;
    if inserted_count = 0 then
      -- Another worker inserted the same UUID after the unlocked lookup. Loop
      -- once more and resolve its now-durable state under the row lock.
      continue;
    end if;

    used := public.botanist_record_ask(p_account_id, p_daily_limit);
    if used < 0 then
      delete from public.botanist_requests
      where account_id = p_account_id and request_id = p_request_id;
      return 'limited';
    end if;
    return 'claimed';
  end loop;
end;
$$;

revoke all on function public.botanist_claim_request(text, uuid, integer) from public;
revoke all on function public.botanist_claim_request(text, uuid, integer) from anon;
revoke all on function public.botanist_claim_request(text, uuid, integer) from authenticated;
grant execute on function public.botanist_claim_request(text, uuid, integer) to service_role;

-- The release probe must distinguish "new Edge code" from "new Edge code on
-- the old schema". Because this marker is created at the end of this atomic
-- transaction, returning 7 proves every constraint, trigger and function above
-- committed together.
create or replace function public.botanist_schema_contract_version()
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$ select 7 $$;

revoke all on function public.botanist_schema_contract_version() from public;
revoke all on function public.botanist_schema_contract_version() from anon;
revoke all on function public.botanist_schema_contract_version() from authenticated;
grant execute on function public.botanist_schema_contract_version() to service_role;

commit;
