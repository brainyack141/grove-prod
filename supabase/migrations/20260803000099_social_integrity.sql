begin;

-- Detect an idempotency key reused for different request bytes. Without the
-- fingerprint, a key collision on friend invitations replayed the first
-- gardener's success as the answer to a different username.
alter table public.api_idempotency
    add column if not exists request_hash text,
    add column if not exists claim_id uuid;

alter table app.idempotency_keys
    add column if not exists request_hash text,
    add column if not exists claim_id uuid;

-- A person using a tokenised sitting link has no Grove account.  Keeping the
-- owner's id in actor_account_id made the owner's feed classify that sitter's
-- care as self-authored.  The named attribution columns already model external
-- actors; allow the foreign key to be absent when that is what happened.
alter table app.activity_events
    alter column actor_account_id drop not null;

-- One relationship per pair, regardless of who asked first.  The original
-- constraint was directional, so two simultaneous requests (A -> B and B -> A)
-- could both commit and later become two accepted friendships.  Keep the most
-- privacy-protective/current row if production already contains such a pair,
-- then make the unordered pair unique.
with ranked as (
    select id,
           row_number() over (
               partition by least(requested_by_account_id, requested_to_account_id),
                            greatest(requested_by_account_id, requested_to_account_id)
               order by
                   case status
                       when 'blocked' then 5
                       when 'accepted' then 4
                       when 'pending' then 3
                       when 'declined' then 2
                       when 'withdrawn' then 1
                   end desc,
                   updated_at desc,
                   created_at desc,
                   id
           ) as position
      from app.friendships
     where requested_to_account_id is not null
)
delete from app.friendships friendship
 using ranked duplicate
 where friendship.id = duplicate.id
   and duplicate.position > 1;

create unique index if not exists friendships_unordered_pair_idx
    on app.friendships (
        least(requested_by_account_id, requested_to_account_id),
        greatest(requested_by_account_id, requested_to_account_id)
    )
    where requested_to_account_id is not null;

-- Count invitation *attempts*, not only rows that happened to resolve to a
-- real account. Counting friendships allowed an authenticated client to probe
-- an unlimited number of nonexistent usernames because every miss left no
-- row. The request id keeps a network retry from consuming the allowance
-- twice, while also preventing one id from being reused to probe many names.
create table if not exists app.friend_invitation_attempts (
    requested_by_account_id uuid not null references app.accounts(id) on delete cascade,
    request_id uuid not null,
    attempted_username text not null,
    attempted_at timestamptz not null default now(),
    primary key (requested_by_account_id, request_id)
);

create index if not exists friend_invitation_attempts_recent_idx
    on app.friend_invitation_attempts (requested_by_account_id, attempted_at desc);

alter table app.friend_invitation_attempts enable row level security;

-- Sitting-link creation is now capped at 100 outstanding links per owner. Keep
-- existing data inside that invariant too: before the cap, a scripted client
-- could create an unbounded set that no bounded bootstrap could safely return.
-- Retain the newest 100 and revoke only excess, still-live capabilities.
with ranked_live_links as (
    select id,
           row_number() over (
               partition by owner_account_id
               order by created_at desc, id
           ) as position
      from app.sitting_invites
     where revoked_at is null
       and ends_at >= now()
)
update app.sitting_invites invite
   set revoked_at = now()
  from ranked_live_links ranked
 where invite.id = ranked.id
   and ranked.position > 100;

-- The iOS app mutates social data through the authenticated API function.  The
-- old RLS write policies also exposed the raw tables to authenticated clients:
-- a requester could insert an already-accepted friendship, either participant
-- could rewrite both identities, and a sitter could extend their own access or
-- attach a different plant.  Reads stay participant/owner scoped; all writes
-- now go through the API's checked state machine (the database connection used
-- by the Edge Functions is the service role and bypasses RLS).
drop policy if exists friendships_requester_insert on app.friendships;
drop policy if exists friendships_participant_update on app.friendships;

-- Revocation and expiry must close metadata access too, not only plant rows.
-- The original participant policies let a former sitter keep selecting the
-- assignment (including owner notes / encrypted access material) and its
-- plant-id mapping forever. Owners retain their own history; sitters see an
-- invitation or live assignment only until it ends or is revoked. Actual plant
-- access remains stricter (`app.can_access_plant` also requires the window to
-- have started).
--
-- Remove cross-account reads of app.accounts completely. A row policy grants
-- the whole row, not merely the display name its old comment promised, so an
-- accepted friend could query region/location and every future profile column
-- through PostgREST. The checked API already resolves the bounded identity
-- fields needed by friend lists and handovers under its service role.
drop policy if exists accounts_connected_read on app.accounts;

drop policy if exists assignments_owner_insert on app.sitting_assignments;
drop policy if exists assignments_participant_update on app.sitting_assignments;
drop policy if exists assignments_owner_delete on app.sitting_assignments;
drop policy if exists assignments_participant_read on app.sitting_assignments;
create policy assignments_participant_read on app.sitting_assignments
    for select
    using (
        owner_account_id = app.current_account_id()
        or (
            sitter_account_id = app.current_account_id()
            and status in ('invited', 'upcoming', 'active')
            and revoked_at is null
            and now() < ends_at
        )
    );

drop policy if exists assignment_plants_owner_write on app.sitting_assignment_plants;
drop policy if exists assignment_plants_participant_read on app.sitting_assignment_plants;
create policy assignment_plants_participant_read on app.sitting_assignment_plants
    for select
    using (
        exists (
            select 1 from app.sitting_assignments assignment
             where assignment.id = sitting_assignment_plants.assignment_id
               and (
                    assignment.owner_account_id = app.current_account_id()
                 or (
                        assignment.sitter_account_id = app.current_account_id()
                    and assignment.status in ('invited', 'upcoming', 'active')
                    and assignment.revoked_at is null
                    and now() < assignment.ends_at
                 )
               )
        )
    );

drop policy if exists sitting_invites_owner_all on app.sitting_invites;
create policy sitting_invites_owner_read on app.sitting_invites
    for select
    using (owner_account_id = app.current_account_id());

drop policy if exists sitting_invite_plants_owner_all on app.sitting_invite_plants;
create policy sitting_invite_plants_owner_read on app.sitting_invite_plants
    for select
    using (
        exists (
            select 1
              from app.sitting_invites invite
             where invite.id = sitting_invite_plants.invite_id
               and invite.owner_account_id = app.current_account_id()
        )
    );

-- A delegated plant made several adjacent FOR ALL policies reachable by a
-- sitter. That let a raw authenticated client delete tasks, rewrite health
-- assessments or observation media, bypass can_check_in, and inject activity
-- into another Grove. The app already sends these changes through the checked
-- API, so keep the same scoped reads while closing every raw write path.
drop policy if exists observations_scoped_insert on app.observations;

drop policy if exists observation_media_scoped_access on app.observation_media;
create policy observation_media_scoped_read on app.observation_media
    for select
    using (
        exists (
            select 1
              from app.observations observation
             where observation.id = observation_media.observation_id
               and app.can_access_plant(observation.plant_id)
        )
    );

drop policy if exists health_assessments_scoped_access on app.health_assessments;
create policy health_assessments_scoped_read on app.health_assessments
    for select
    using (
        exists (
            select 1
              from app.observations observation
             where observation.id = health_assessments.observation_id
               and app.can_access_plant(observation.plant_id)
        )
    );

drop policy if exists care_actions_scoped_access on app.care_actions;
create policy care_actions_scoped_read on app.care_actions
    for select
    using (app.can_access_plant(plant_id));

drop policy if exists activity_actor_insert on app.activity_events;

-- Defence in depth for both handover kinds.  Even the service must not be able
-- to widen an assignment or link to a plant outside the Grove named by its
-- parent row; this was previously enforced only by one API query.
create or replace function app.enforce_assignment_plant_scope()
returns trigger
language plpgsql
set search_path = pg_catalog, app
as $$
begin
    if not exists (
        select 1
          from app.sitting_assignments assignment
          join app.plants plant on plant.id = new.plant_id
         where assignment.id = new.assignment_id
           and assignment.grove_id = plant.grove_id
    ) then
        raise exception 'Sitting assignment plants must belong to the assigned Grove'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

drop trigger if exists sitting_assignment_plant_scope on app.sitting_assignment_plants;
create trigger sitting_assignment_plant_scope
before insert or update on app.sitting_assignment_plants
for each row execute function app.enforce_assignment_plant_scope();

create or replace function app.enforce_invite_plant_scope()
returns trigger
language plpgsql
set search_path = pg_catalog, app
as $$
begin
    if not exists (
        select 1
          from app.sitting_invites invite
          join app.plants plant on plant.id = new.plant_id
         where invite.id = new.invite_id
           and invite.grove_id = plant.grove_id
    ) then
        raise exception 'Sitting-link plants must belong to the linked Grove'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

drop trigger if exists sitting_invite_plant_scope on app.sitting_invite_plants;
create trigger sitting_invite_plant_scope
before insert or update on app.sitting_invite_plants
for each row execute function app.enforce_invite_plant_scope();

commit;
