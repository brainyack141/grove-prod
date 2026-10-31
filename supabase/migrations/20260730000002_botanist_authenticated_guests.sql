begin;

-- Local/demo Groves use anonymous Supabase Auth only to obtain an unforgeable
-- Botanist identity. They remain device-only accounts and must not receive the
-- full synced-account rows that Apple, Google and email users are provisioned.
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
    if coalesce(new.is_anonymous, false) then
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

commit;
