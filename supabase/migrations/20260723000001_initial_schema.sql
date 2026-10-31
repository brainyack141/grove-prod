begin;

create extension if not exists pgcrypto;

create schema if not exists app;

create type app.friendship_status as enum ('pending', 'accepted', 'declined', 'blocked');
create type app.assignment_status as enum ('invited', 'upcoming', 'active', 'completed', 'declined', 'revoked');
create type app.plant_state as enum ('onboarding', 'healthy', 'monitor', 'recovering', 'urgent', 'dormant', 'archived', 'deceased');
create type app.care_action_status as enum ('proposed', 'due', 'completed', 'skipped', 'superseded');

create table app.accounts (
    id text primary key,
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
    owner_account_id text not null references app.accounts(id),
    name text not null default 'My Grove',
    is_private boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table app.grove_memberships (
    grove_id uuid not null references app.groves(id) on delete cascade,
    account_id text not null references app.accounts(id) on delete cascade,
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

create table app.media_assets (
    id uuid primary key default gen_random_uuid(),
    owner_account_id text not null references app.accounts(id),
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
    account_id text not null references app.accounts(id) on delete cascade,
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
    performed_by_account_id text not null references app.accounts(id),
    on_behalf_of_account_id text references app.accounts(id),
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
    performed_by_account_id text references app.accounts(id),
    performed_at timestamptz,
    skip_reason text,
    client_request_id uuid unique,
    created_at timestamptz not null default now()
);

create table app.friendships (
    id uuid primary key default gen_random_uuid(),
    requested_by_account_id text not null references app.accounts(id) on delete cascade,
    requested_to_account_id text not null references app.accounts(id) on delete cascade,
    status app.friendship_status not null default 'pending',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (requested_by_account_id <> requested_to_account_id),
    unique (requested_by_account_id, requested_to_account_id)
);

create table app.sitting_assignments (
    id uuid primary key default gen_random_uuid(),
    owner_account_id text not null references app.accounts(id),
    sitter_account_id text not null references app.accounts(id),
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
    actor_account_id text not null references app.accounts(id),
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

create or replace function app.current_account_id()
returns text
language sql
stable
as $$
    select nullif(current_setting('app.account_id', true), '');
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
    using (id = app.current_account_id())
    with check (id = app.current_account_id());

create policy groves_member_read on app.groves
    for select using (app.can_access_grove(id));

create policy groves_owner_update on app.groves
    for update
    using (owner_account_id = app.current_account_id())
    with check (owner_account_id = app.current_account_id());

create policy memberships_member_read on app.grove_memberships
    for select using (app.can_access_grove(grove_id));

create policy spaces_member_read on app.spaces
    for select using (app.can_access_grove(grove_id));

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

create policy observations_scoped_read on app.observations
    for select using (app.can_access_plant(plant_id));

create policy observations_scoped_insert on app.observations
    for insert with check (app.can_access_plant(plant_id) and performed_by_account_id = app.current_account_id());

create policy care_plans_scoped_read on app.care_plans
    for select using (app.can_access_plant(plant_id));

create policy care_plans_member_write on app.care_plans
    for all
    using (
        exists (
            select 1 from app.plants plant
            where plant.id = plant_id and app.can_access_grove(plant.grove_id)
        )
    )
    with check (
        exists (
            select 1 from app.plants plant
            where plant.id = plant_id and app.can_access_grove(plant.grove_id)
        )
    );

create policy care_actions_scoped_access on app.care_actions
    using (app.can_access_plant(plant_id))
    with check (app.can_access_plant(plant_id));

create policy assignments_participant_read on app.sitting_assignments
    for select using (owner_account_id = app.current_account_id() or sitter_account_id = app.current_account_id());

create policy assignment_plants_participant_access on app.sitting_assignment_plants
    using (
        exists (
            select 1 from app.sitting_assignments assignment
            where assignment.id = assignment_id
              and (assignment.owner_account_id = app.current_account_id() or assignment.sitter_account_id = app.current_account_id())
        )
    );

create policy friendships_participant_read on app.friendships
    for select using (requested_by_account_id = app.current_account_id() or requested_to_account_id = app.current_account_id());

create policy activity_scoped_access on app.activity_events
    for select using (
        (grove_id is not null and app.can_access_grove(grove_id))
        or actor_account_id = app.current_account_id()
        or (plant_id is not null and app.can_access_plant(plant_id))
    );

commit;
