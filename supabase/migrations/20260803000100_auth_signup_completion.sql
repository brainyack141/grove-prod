begin;

-- The native Apple/Google id-token grant creates an auth.users row whether the
-- person tapped "Sign up" or "I already have a Grove". A creation timestamp
-- can identify that first request, but it cannot identify the orphan on the
-- next sign-in: by then it looks exactly like a real, empty account.
--
-- Keep the product decision as server-owned state instead. Existing accounts
-- predate this distinction and are real by definition, so backfill them. New
-- trigger-provisioned accounts remain incomplete until the app explicitly
-- accepts signup (or an older client reaches bootstrap; see the API function).
alter table app.accounts
    add column if not exists signup_completed_at timestamptz,
    add column if not exists signup_completion_claim_id uuid;

update app.accounts
set signup_completed_at = coalesce(signup_completed_at, created_at, now())
where signup_completed_at is null;

-- A user JWT previously had INSERT/UPDATE/DELETE on app.accounts through the
-- broad historical table grant plus an accounts_self FOR ALL policy. That
-- would let a caller bypass the API and set signup_completed_at directly.
-- Account writes now go through the scoped API and security-definer RPCs only.
revoke select, insert, update, delete on table app.accounts from authenticated;
grant select (id, username, display_name, avatar_storage_key)
    on table app.accounts to authenticated;

drop policy if exists accounts_self on app.accounts;
drop policy if exists accounts_self_read on app.accounts;
create policy accounts_self_read on app.accounts
    for select
    using (id = app.current_account_id());

-- Keep new/changed profile rows inside the contract even if a future server
-- path forgets the API validation. NOT VALID avoids making rollout depend on
-- the shape of historical profiles while still enforcing every new write.
alter table app.accounts
    add constraint accounts_username_contract
    check (username ~ '^[a-z0-9_]{3,24}$')
    not valid;

alter table app.accounts
    add constraint accounts_display_name_contract
    check (
        char_length(display_name) between 1 and 80
        and display_name !~ '[[:cntrl:]]'
        and position(chr(8234) in display_name) = 0
        and position(chr(8235) in display_name) = 0
        and position(chr(8236) in display_name) = 0
        and position(chr(8237) in display_name) = 0
        and position(chr(8238) in display_name) = 0
        and position(chr(8294) in display_name) = 0
        and position(chr(8295) in display_name) = 0
        and position(chr(8296) in display_name) = 0
        and position(chr(8297) in display_name) = 0
    )
    not valid;

-- Provider metadata is untrusted input to this Auth trigger. Normalise it
-- before provisioning so an oversized/control-character name cannot poison a
-- profile and use a 64-bit UUID suffix to make same-name collisions remote.
create or replace function app.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
    new_grove_id uuid;
    chosen_username text;
    chosen_display_name text;
begin
    -- Preserve the strict anonymous boundary established by the onboarding
    -- analysis migration: only a literal false provisions a Grove account.
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
    chosen_username := left(chosen_username, 7) || '_' || left(replace(new.id::text, '-', ''), 16);

    chosen_display_name := translate(
        coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), 'Gardener'),
        chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238)
            || chr(8294) || chr(8295) || chr(8296) || chr(8297),
        ''
    );
    chosen_display_name := regexp_replace(chosen_display_name, '[[:cntrl:]]+', '', 'g');
    chosen_display_name := regexp_replace(btrim(chosen_display_name), '[[:space:]]+', ' ', 'g');
    chosen_display_name := left(chosen_display_name, 80);
    if chosen_display_name = '' then
        chosen_display_name := 'Gardener';
    end if;

    insert into app.accounts (id, username, display_name)
    values (new.id, chosen_username, chosen_display_name);

    insert into app.groves (owner_account_id)
    values (new.id)
    returning id into new_grove_id;

    insert into app.grove_memberships (grove_id, account_id, role, can_edit_plants, can_manage_carers)
    values (new_grove_id, new.id, 'owner', true, true);

    return new;
end;
$$;

create or replace function public.grove_signup_completed()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
    select coalesce(
        (
            select account.signup_completed_at is not null
            from app.accounts account
            where account.id = auth.uid()
              and account.deleted_at is null
        ),
        false
    )
$$;

create or replace function public.grove_complete_signup(p_claim_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    claimed_by_caller boolean;
begin
    if p_claim_id is null then
        return null;
    end if;

    update app.accounts
    set signup_completed_at = now(),
        signup_completion_claim_id = p_claim_id,
        updated_at = now()
    where id = auth.uid()
      and deleted_at is null
      and signup_completed_at is null;
    if found then
        return true;
    end if;

    -- A retry whose response was lost may reclaim the onboarding data only when
    -- its durable random claim won the original transition. A different claim
    -- is another device and must discard its stale local handoff. Legacy and
    -- backfilled completions have a null claim, so they also return false.
    select account.signup_completion_claim_id = p_claim_id
    into claimed_by_caller
    from app.accounts account
    where account.id = auth.uid()
      and account.deleted_at is null;

    if not found then
        -- No live account includes anonymous analysis identities.
        return null;
    end if;
    return coalesce(claimed_by_caller, false);
end;
$$;

revoke all on function public.grove_signup_completed() from public;
revoke all on function public.grove_signup_completed() from anon;
revoke all on function public.grove_complete_signup(uuid) from public;
revoke all on function public.grove_complete_signup(uuid) from anon;
grant execute on function public.grove_signup_completed() to authenticated;
grant execute on function public.grove_complete_signup(uuid) to authenticated;

commit;
