begin;

-- The free-question meter moves from the app to the server.
--
-- Until now the daily allowance existed only in `AskSession`, and the gateway
-- believed the client's `safetyOnly` flag when it said the allowance was spent.
-- A client that simply never set that flag received the abuse ceiling's worth of
-- paid provider answers. The counter (`botanist_usage`) was already server-side
-- and already keyed on the UTC day; what was missing was a server-side answer to
-- "which limit applies to this account", which is what this migration adds.

-- The last entitlement verdict RevenueCat gave for an account.
--
-- A cache, never a source of truth: the gateway re-verifies on a short interval
-- and only reads this table when RevenueCat cannot be reached. It stores no
-- receipt, price, or transaction — just whether the account was paying and when
-- that was last checked.
create table if not exists public.botanist_entitlements (
    account_id text primary key,
    premium boolean not null default false,
    expires_at timestamptz,
    source text not null default 'unverified',
    checked_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.botanist_entitlements enable row level security;
revoke all on public.botanist_entitlements from public;
revoke all on public.botanist_entitlements from anon;
revoke all on public.botanist_entitlements from authenticated;
grant select, insert, update, delete on public.botanist_entitlements to service_role;

-- Same deletion race the other Botanist tables close: text account ids do not
-- cascade from app.accounts, so the insert requires a live account row and the
-- account's deletion purges this cache in the same transaction.
drop trigger if exists botanist_entitlements_live_account on public.botanist_entitlements;
create trigger botanist_entitlements_live_account
before insert on public.botanist_entitlements
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
  delete from public.botanist_entitlements where account_id = old.id::text;
  return old;
end;
$$;

revoke all on function public.botanist_purge_deleted_account() from public;
revoke all on function public.botanist_purge_deleted_account() from anon;
revoke all on function public.botanist_purge_deleted_account() from authenticated;

-- Reads the cached verdict. Returns no row rather than a fabricated free one,
-- so the gateway can tell "never verified" from "verified and not paying".
create or replace function public.botanist_entitlement(p_account_id text)
returns table (premium boolean, expires_at timestamptz, source text, checked_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select e.premium, e.expires_at, e.source, e.checked_at
  from public.botanist_entitlements e
  where e.account_id = nullif(btrim(p_account_id), '')
$$;

revoke all on function public.botanist_entitlement(text) from public;
revoke all on function public.botanist_entitlement(text) from anon;
revoke all on function public.botanist_entitlement(text) from authenticated;
grant execute on function public.botanist_entitlement(text) to service_role;

-- Stores a fresh verdict. Only ever called with something RevenueCat actually
-- said, so the caller cannot cache its own fail-closed guess and then read that
-- guess back as if it were verified.
create or replace function public.botanist_store_entitlement(
  p_account_id text,
  p_premium boolean,
  p_expires_at timestamptz,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if nullif(btrim(p_account_id), '') is null
     or p_premium is null
     or nullif(btrim(coalesce(p_source, '')), '') is null then
    raise exception 'invalid botanist entitlement record';
  end if;

  insert into public.botanist_entitlements (account_id, premium, expires_at, source, checked_at, updated_at)
  values (p_account_id, p_premium, p_expires_at, left(btrim(p_source), 40), now(), now())
  on conflict (account_id) do update
    set premium = excluded.premium,
        expires_at = excluded.expires_at,
        source = excluded.source,
        checked_at = excluded.checked_at,
        updated_at = now();
end;
$$;

revoke all on function public.botanist_store_entitlement(text, boolean, timestamptz, text) from public;
revoke all on function public.botanist_store_entitlement(text, boolean, timestamptz, text) from anon;
revoke all on function public.botanist_store_entitlement(text, boolean, timestamptz, text) from authenticated;
grant execute on function public.botanist_store_entitlement(text, boolean, timestamptz, text) to service_role;

-- Today's count, so a successful answer can tell the app exactly how many free
-- questions remain. `botanist_record_ask` returns this on the direct path, but
-- `botanist_claim_request` returns a claim state, and the app must not have to
-- infer the number it displays.
create or replace function public.botanist_asks_today(p_account_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select u.asks
    from public.botanist_usage u
    where u.account_id = nullif(btrim(p_account_id), '')
      and u.day = (now() at time zone 'utc')::date
  ), 0)
$$;

revoke all on function public.botanist_asks_today(text) from public;
revoke all on function public.botanist_asks_today(text) from anon;
revoke all on function public.botanist_asks_today(text) from authenticated;
grant execute on function public.botanist_asks_today(text) to service_role;

-- Contract 8 is "the daily allowance is enforced server-side". A client that
-- shows a free-question count it did not get from the server must not be
-- released against a gateway or schema that cannot supply one.
create or replace function public.botanist_schema_contract_version()
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$ select 8 $$;

revoke all on function public.botanist_schema_contract_version() from public;
revoke all on function public.botanist_schema_contract_version() from anon;
revoke all on function public.botanist_schema_contract_version() from authenticated;
grant execute on function public.botanist_schema_contract_version() to service_role;

commit;
