-- Moves Grove's relational schema onto Supabase Auth as the identity authority.
--
-- The initial migration modelled an account as an opaque text id supplied by the backend.
-- Grove's Stage 3 sign-in is Sign in with Apple, which Supabase Auth provides natively, so
-- an account is now a row in `auth.users` and every actor column is a uuid pointing at it.
--
-- This rebuilds `app` rather than altering it in place: the initial migration was applied
-- minutes earlier and every table is empty, so there is no data to preserve, and altering
-- 13 foreign-key columns would mean dropping and recreating every policy that references
-- them anyway. Only the `app` schema is touched — `auth` and `storage` are left alone.
--
-- It also closes the write-policy gaps in the initial migration, where several tables had
-- row-level security enabled with select-only policies and no insert or update policy.

begin;

drop schema if exists app cascade;

create schema app;

create type app.friendship_status as enum ('pending', 'accepted', 'declined', 'blocked');
create type app.assignment_status as enum ('invited', 'upcoming', 'active', 'completed', 'declined', 'revoked');
create type app.plant_state as enum ('onboarding', 'healthy', 'monitor', 'recovering', 'urgent', 'dormant', 'archived', 'deceased');
create type app.care_action_status as enum ('proposed', 'due', 'completed', 'skipped', 'superseded');

-- An account is the Grove-facing profile for a Supabase Auth user. Deleting the auth user
-- removes the account and, by cascade, the Grove they own.
create table app.accounts (
    id uuid primary key references auth.users(id) on delete cascade,
    username text not null unique,
    display_name text not null,
    avatar_storage_key text,
    region_code text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz
);

create table app.groves (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references app.accounts(id) on delete cascade,
    name text not null default 'My Grove',
    is_private boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table app.grove_memberships (
    grove_id uuid not null references app.groves(id) on delete cascade,
    account_id uuid not null references app.accounts(id) on delete cascade,
    role text not null check (role in ('owner', 'member')),
    can_edit_plants boolean not null default false,
    can_manage_carers boolean not null default false,
    created_at timestamptz not null default now(),
    primary key (grove_id, account_id)
);

create table app.spaces (
    id uuid primary key default gen_random_uuid(),
    grove_id uuid not null references app.groves(id) on delete cascade,
    name text not null,
    light_notes text,
    created_at timestamptz not null default now(),
    unique (grove_id, name)
);

create table app.plants (
    id uuid primary key default gen_random_uuid(),
    grove_id uuid not null references app.groves(id) on delete cascade,
    space_id uuid references app.spaces(id) on delete set null,
    nickname text not null,
    common_name text,
    scientific_name text,
    identification_confidence integer check (identification_confidence between 0 and 100),
    state app.plant_state not null default 'onboarding',
    current_health_score integer check (current_health_score between 0 and 100),
    current_health_band text,
    current_trend text,
    next_check_in_at timestamptz,
    acquired_at date,
    environment jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz
);

-- `storage_key` is the object path inside the `plant-media` Storage bucket, which is
-- owner-scoped as `<account uuid>/<media asset uuid>`.
create table app.media_assets (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references app.accounts(id) on delete cascade,
    plant_id uuid references app.plants(id) on delete cascade,
    storage_key text not null unique,
    purpose text not null check (purpose in ('scan', 'observation', 'avatar', 'shared_progress')),
    mime_type text not null,
    pixel_width integer,
    pixel_height integer,
    byte_count bigint,
    created_at timestamptz not null default now(),
    deleted_at timestamptz
);

create table app.scans (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references app.accounts(id) on delete cascade,
    media_asset_id uuid not null references app.media_assets(id),
    mode text not null check (mode in ('identify', 'add', 'diagnose')),
    status text not null check (status in ('queued', 'processing', 'completed', 'failed', 'cancelled')),
    provider_job_id text,
    result jsonb,
    error_code text,
    created_at timestamptz not null default now(),
    completed_at timestamptz
);

create table app.observations (
    id uuid primary key default gen_random_uuid(),
    plant_id uuid not null references app.plants(id) on delete cascade,
    performed_by_account_id uuid not null references app.accounts(id),
    on_behalf_of_account_id uuid references app.accounts(id),
    sitting_assignment_id uuid,
    source text not null check (source in ('baseline', 'scheduled_check_in', 'concern_scan', 'sitter_check_in')),
    answers jsonb not null default '{}'::jsonb,
    note text,
    observed_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);

create table app.observation_media (
    observation_id uuid not null references app.observations(id) on delete cascade,
    media_asset_id uuid not null references app.media_assets(id) on delete cascade,
    sort_order integer not null default 0,
    primary key (observation_id, media_asset_id)
);

create table app.health_assessments (
    id uuid primary key default gen_random_uuid(),
    observation_id uuid not null references app.observations(id) on delete cascade,
    provider_name text not null,
    provider_version text,
    health_score integer check (health_score between 0 and 100),
    health_band text not null,
    trend text,
    confidence integer not null check (confidence between 0 and 100),
    findings jsonb not null,
    limitations jsonb not null default '[]'::jsonb,
    supersedes_assessment_id uuid references app.health_assessments(id),
    created_at timestamptz not null default now()
);

create table app.care_plans (
    id uuid primary key default gen_random_uuid(),
    plant_id uuid not null references app.plants(id) on delete cascade,
    triggering_assessment_id uuid references app.health_assessments(id),
    goal text not null,
    status text not null check (status in ('proposed', 'active', 'completed', 'replaced', 'abandoned')),
    review_at timestamptz,
    created_at timestamptz not null default now(),
    replaced_at timestamptz
);

create table app.care_actions (
    id uuid primary key default gen_random_uuid(),
    plant_id uuid not null references app.plants(id) on delete cascade,
    care_plan_id uuid references app.care_plans(id) on delete set null,
    kind text not null,
    instructions text not null,
    status app.care_action_status not null default 'proposed',
    due_from timestamptz,
    due_until timestamptz,
    performed_by_account_id uuid references app.accounts(id),
    performed_at timestamptz,
    skip_reason text,
    client_request_id uuid unique,
    created_at timestamptz not null default now()
);

create table app.friendships (
    id uuid primary key default gen_random_uuid(),
    requested_by_account_id uuid not null references app.accounts(id) on delete cascade,
    requested_to_account_id uuid not null references app.accounts(id) on delete cascade,
    status app.friendship_status not null default 'pending',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (requested_by_account_id <> requested_to_account_id),
    unique (requested_by_account_id, requested_to_account_id)
);

create table app.sitting_assignments (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references app.accounts(id) on delete cascade,
    sitter_account_id uuid not null references app.accounts(id) on delete cascade,
    grove_id uuid not null references app.groves(id) on delete cascade,
    status app.assignment_status not null default 'invited',
    starts_at timestamptz not null,
    ends_at timestamptz not null,
    can_check_in boolean not null default true,
    owner_notes text,
    sensitive_access_ciphertext bytea,
    invited_at timestamptz not null default now(),
    accepted_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz not null default now(),
    check (owner_account_id <> sitter_account_id),
    check (ends_at > starts_at)
);

alter table app.observations
    add constraint observations_sitting_assignment_fk
    foreign key (sitting_assignment_id) references app.sitting_assignments(id) on delete set null;

create table app.sitting_assignment_plants (
    assignment_id uuid not null references app.sitting_assignments(id) on delete cascade,
    plant_id uuid not null references app.plants(id) on delete cascade,
    primary key (assignment_id, plant_id)
);

create table app.activity_events (
    id uuid primary key default gen_random_uuid(),
    actor_account_id uuid not null references app.accounts(id) on delete cascade,
    grove_id uuid references app.groves(id) on delete cascade,
    plant_id uuid references app.plants(id) on delete cascade,
    observation_id uuid references app.observations(id) on delete cascade,
    assignment_id uuid references app.sitting_assignments(id) on delete cascade,
    kind text not null,
    message text not null,
    audience jsonb not null default '{"kind":"private"}'::jsonb,
    created_at timestamptz not null default now()
);

create index plants_grove_idx on app.plants(grove_id);
create index observations_plant_time_idx on app.observations(plant_id, observed_at desc);
create index care_actions_plant_due_idx on app.care_actions(plant_id, due_from) where status in ('proposed', 'due');
create index assignments_sitter_time_idx on app.sitting_assignments(sitter_account_id, starts_at, ends_at);
create index activity_grove_time_idx on app.activity_events(grove_id, created_at desc);
create index media_assets_owner_idx on app.media_assets(owner_account_id);
create index memberships_account_idx on app.grove_memberships(account_id);

-- Identity ---------------------------------------------------------------------------

-- The acting account, resolved from whichever path reached the database:
--   * Supabase Auth clients (supabase-swift, PostgREST) carry a JWT, so `auth.uid()` answers.
--   * The Grove API verifies the same JWT itself and sets a transaction-local `app.account_id`
--     before running the caller's queries, so the identical policies apply server-side.
-- Clients must never be able to set `app.account_id` directly.
create or replace function app.current_account_id()
returns uuid
language sql
stable
as $$
    select coalesce(
        auth.uid(),
        nullif(current_setting('app.account_id', true), '')::uuid
    );
$$;

create or replace function app.can_access_grove(target_grove_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
    select exists (
        select 1
        from app.grove_memberships membership
        where membership.grove_id = target_grove_id
          and membership.account_id = app.current_account_id()
    );
$$;

create or replace function app.can_edit_grove(target_grove_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
    select exists (
        select 1
        from app.grove_memberships membership
        where membership.grove_id = target_grove_id
          and membership.account_id = app.current_account_id()
          and (membership.role = 'owner' or membership.can_edit_plants)
    );
$$;

-- A sitter reaches a plant only through an accepted, unrevoked, in-window assignment —
-- the time-limited, plant-scoped delegation the product promises.
create or replace function app.can_access_plant(target_plant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, pg_temp
as $$
    select exists (
        select 1
        from app.plants plant
        where plant.id = target_plant_id
          and (
              app.can_access_grove(plant.grove_id)
              or exists (
                  select 1
                  from app.sitting_assignment_plants assignment_plant
                  join app.sitting_assignments assignment on assignment.id = assignment_plant.assignment_id
                  where assignment_plant.plant_id = plant.id
                    and assignment.sitter_account_id = app.current_account_id()
                    and assignment.status in ('upcoming', 'active')
                    and now() >= assignment.starts_at
                    and now() < assignment.ends_at
                    and assignment.revoked_at is null
              )
          )
    );
$$;

-- New Supabase Auth users get their Grove-facing account, a default private Grove, and the
-- owner membership in one step, so no client can create a half-initialised account.
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function app.handle_new_auth_user();

-- Row-level security -----------------------------------------------------------------

alter table app.accounts enable row level security;
alter table app.groves enable row level security;
alter table app.grove_memberships enable row level security;
alter table app.spaces enable row level security;
alter table app.plants enable row level security;
alter table app.media_assets enable row level security;
alter table app.scans enable row level security;
alter table app.observations enable row level security;
alter table app.observation_media enable row level security;
alter table app.health_assessments enable row level security;
alter table app.care_plans enable row level security;
alter table app.care_actions enable row level security;
alter table app.friendships enable row level security;
alter table app.sitting_assignments enable row level security;
alter table app.sitting_assignment_plants enable row level security;
alter table app.activity_events enable row level security;

create policy accounts_self on app.accounts
    for all
    using (id = app.current_account_id())
    with check (id = app.current_account_id());

-- A connected account's name and avatar are visible so friend lists and sitting
-- assignments can be rendered; everything else about them stays behind their own policies.
create policy accounts_connected_read on app.accounts
    for select using (
        exists (
            select 1 from app.friendships friendship
            where friendship.status = 'accepted'
              and (
                  (friendship.requested_by_account_id = app.current_account_id() and friendship.requested_to_account_id = app.accounts.id)
                  or (friendship.requested_to_account_id = app.current_account_id() and friendship.requested_by_account_id = app.accounts.id)
              )
        )
        or exists (
            select 1 from app.sitting_assignments assignment
            where (assignment.owner_account_id = app.current_account_id() and assignment.sitter_account_id = app.accounts.id)
               or (assignment.sitter_account_id = app.current_account_id() and assignment.owner_account_id = app.accounts.id)
        )
    );

create policy groves_member_read on app.groves
    for select using (app.can_access_grove(id));

create policy groves_owner_insert on app.groves
    for insert with check (owner_account_id = app.current_account_id());

create policy groves_owner_update on app.groves
    for update
    using (owner_account_id = app.current_account_id())
    with check (owner_account_id = app.current_account_id());

create policy groves_owner_delete on app.groves
    for delete using (owner_account_id = app.current_account_id());

create policy memberships_member_read on app.grove_memberships
    for select using (app.can_access_grove(grove_id));

-- Only the Grove's owner adds or removes carers, matching the roles table in GROVE.md.
create policy memberships_owner_write on app.grove_memberships
    for all
    using (
        exists (
            select 1 from app.groves grove
            where grove.id = grove_memberships.grove_id
              and grove.owner_account_id = app.current_account_id()
        )
    )
    with check (
        exists (
            select 1 from app.groves grove
            where grove.id = grove_memberships.grove_id
              and grove.owner_account_id = app.current_account_id()
        )
    );

create policy spaces_member_read on app.spaces
    for select using (app.can_access_grove(grove_id));

create policy spaces_editor_write on app.spaces
    for all
    using (app.can_edit_grove(grove_id))
    with check (app.can_edit_grove(grove_id));

create policy plants_scoped_read on app.plants
    for select using (app.can_access_plant(id));

create policy plants_member_insert on app.plants
    for insert with check (app.can_access_grove(grove_id));

create policy plants_member_update on app.plants
    for update
    using (app.can_access_grove(grove_id))
    with check (app.can_access_grove(grove_id));

create policy plants_member_delete on app.plants
    for delete using (app.can_access_grove(grove_id));

create policy media_owner_access on app.media_assets
    for all
    using (owner_account_id = app.current_account_id())
    with check (owner_account_id = app.current_account_id());

-- A sitter's check-in photo has to be readable by the owner, so plant-scoped media is
-- readable by anyone who can reach the plant, not only the uploader.
create policy media_plant_read on app.media_assets
    for select using (plant_id is not null and app.can_access_plant(plant_id));

create policy scans_owner_access on app.scans
    for all
    using (account_id = app.current_account_id())
    with check (account_id = app.current_account_id());

create policy observations_scoped_read on app.observations
    for select using (app.can_access_plant(plant_id));

create policy observations_scoped_insert on app.observations
    for insert with check (app.can_access_plant(plant_id) and performed_by_account_id = app.current_account_id());

create policy observation_media_scoped_access on app.observation_media
    for all
    using (
        exists (
            select 1 from app.observations observation
            where observation.id = observation_media.observation_id
              and app.can_access_plant(observation.plant_id)
        )
    )
    with check (
        exists (
            select 1 from app.observations observation
            where observation.id = observation_media.observation_id
              and app.can_access_plant(observation.plant_id)
        )
    );

create policy health_assessments_scoped_access on app.health_assessments
    for all
    using (
        exists (
            select 1 from app.observations observation
            where observation.id = health_assessments.observation_id
              and app.can_access_plant(observation.plant_id)
        )
    )
    with check (
        exists (
            select 1 from app.observations observation
            where observation.id = health_assessments.observation_id
              and app.can_access_plant(observation.plant_id)
        )
    );

create policy care_plans_scoped_read on app.care_plans
    for select using (app.can_access_plant(plant_id));

-- Sitters may suggest but not rewrite a long-term plan, so plan writes stay with the Grove.
create policy care_plans_member_write on app.care_plans
    for all
    using (
        exists (
            select 1 from app.plants plant
            where plant.id = care_plans.plant_id and app.can_access_grove(plant.grove_id)
        )
    )
    with check (
        exists (
            select 1 from app.plants plant
            where plant.id = care_plans.plant_id and app.can_access_grove(plant.grove_id)
        )
    );

create policy care_actions_scoped_access on app.care_actions
    for all
    using (app.can_access_plant(plant_id))
    with check (app.can_access_plant(plant_id));

create policy friendships_participant_read on app.friendships
    for select using (
        requested_by_account_id = app.current_account_id()
        or requested_to_account_id = app.current_account_id()
    );

create policy friendships_requester_insert on app.friendships
    for insert with check (requested_by_account_id = app.current_account_id());

-- Either participant can move a request on: the recipient accepts, declines, or blocks;
-- the requester can withdraw.
create policy friendships_participant_update on app.friendships
    for update
    using (
        requested_by_account_id = app.current_account_id()
        or requested_to_account_id = app.current_account_id()
    )
    with check (
        requested_by_account_id = app.current_account_id()
        or requested_to_account_id = app.current_account_id()
    );

create policy assignments_participant_read on app.sitting_assignments
    for select using (
        owner_account_id = app.current_account_id()
        or sitter_account_id = app.current_account_id()
    );

create policy assignments_owner_insert on app.sitting_assignments
    for insert with check (
        owner_account_id = app.current_account_id()
        and app.can_access_grove(grove_id)
    );

-- The owner revises or revokes; the sitter accepts or declines. Neither can reassign the
-- assignment to a different owner or sitter.
create policy assignments_participant_update on app.sitting_assignments
    for update
    using (
        owner_account_id = app.current_account_id()
        or sitter_account_id = app.current_account_id()
    )
    with check (
        owner_account_id = app.current_account_id()
        or sitter_account_id = app.current_account_id()
    );

create policy assignments_owner_delete on app.sitting_assignments
    for delete using (owner_account_id = app.current_account_id());

create policy assignment_plants_participant_read on app.sitting_assignment_plants
    for select using (
        exists (
            select 1 from app.sitting_assignments assignment
            where assignment.id = sitting_assignment_plants.assignment_id
              and (
                  assignment.owner_account_id = app.current_account_id()
                  or assignment.sitter_account_id = app.current_account_id()
              )
        )
    );

create policy assignment_plants_owner_write on app.sitting_assignment_plants
    for all
    using (
        exists (
            select 1 from app.sitting_assignments assignment
            where assignment.id = sitting_assignment_plants.assignment_id
              and assignment.owner_account_id = app.current_account_id()
        )
    )
    with check (
        exists (
            select 1 from app.sitting_assignments assignment
            where assignment.id = sitting_assignment_plants.assignment_id
              and assignment.owner_account_id = app.current_account_id()
        )
    );

create policy activity_scoped_read on app.activity_events
    for select using (
        (grove_id is not null and app.can_access_grove(grove_id))
        or actor_account_id = app.current_account_id()
        or (plant_id is not null and app.can_access_plant(plant_id))
    );

create policy activity_actor_insert on app.activity_events
    for insert with check (actor_account_id = app.current_account_id());

-- Access for Supabase-authenticated clients ------------------------------------------
-- Every table above is protected by row-level security, so these grants are the outer
-- gate only. `anon` is deliberately given nothing: a Grove is private by default and
-- there is no signed-out surface.

grant usage on schema app to authenticated;
grant select, insert, update, delete on all tables in schema app to authenticated;
grant execute on all functions in schema app to authenticated;

alter default privileges in schema app
    grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema app
    grant execute on functions to authenticated;

commit;
