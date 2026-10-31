-- Plant sitting that travels as a link.
--
-- `app.sitting_assignments` hands plants to another Grove account, which is the
-- wrong shape for how people actually arrange this: they ask a neighbour, in
-- person, the week before they fly, and that neighbour will not create an
-- account to water a fern. An invite resolves to a plain web page instead.
--
-- Two rules the shape enforces rather than documents:
--
--   1. The raw token is never stored. Only its SHA-256 lands here, so a dump of
--      this table cannot be used to open anybody's care sheet — the same
--      reasoning as a password digest. The token exists in the clear exactly
--      once, in the response to the call that mints it.
--   2. The link dies on its own. `ends_at` is checked on every read, so an
--      owner who never revokes anything still stops sharing when they get home.

create table if not exists app.sitting_invites (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references app.accounts(id) on delete cascade,
    grove_id uuid not null references app.groves(id) on delete cascade,
    -- SHA-256 of the token, hex. Unique so a (vanishingly unlikely) collision
    -- is a write error rather than two invites one link can open.
    token_hash text not null unique,
    -- What the owner calls the sitter. Never rendered on the public page: it is
    -- a label for the owner's own list.
    label text not null default 'Plant sitter',
    starts_at timestamptz not null,
    ends_at timestamptz not null,
    -- False makes the page read-only: the sitter sees what is due and cannot
    -- tick it off.
    can_log_care boolean not null default true,
    created_at timestamptz not null default now(),
    revoked_at timestamptz,
    last_opened_at timestamptz,
    open_count integer not null default 0,
    check (ends_at > starts_at)
);

create table if not exists app.sitting_invite_plants (
    invite_id uuid not null references app.sitting_invites(id) on delete cascade,
    plant_id uuid not null references app.plants(id) on delete cascade,
    primary key (invite_id, plant_id)
);

create index if not exists sitting_invites_owner_idx
    on app.sitting_invites(owner_account_id, ends_at desc);

-- Care logged by a sitter holding a link. Kept out of `care_actions`'
-- `performed_by_account_id`, which references a real account and would have to
-- be made nullable-with-meaning to carry "someone with a link did this".
create table if not exists app.sitting_invite_care_log (
    id uuid primary key default gen_random_uuid(),
    invite_id uuid not null references app.sitting_invites(id) on delete cascade,
    care_action_id uuid not null references app.care_actions(id) on delete cascade,
    logged_at timestamptz not null default now(),
    unique (invite_id, care_action_id)
);

alter table app.sitting_invites enable row level security;
alter table app.sitting_invite_plants enable row level security;
alter table app.sitting_invite_care_log enable row level security;

-- Only the owner, and only ever through their own account. The public care
-- sheet does not authenticate as anybody, so it runs as the service role and
-- these policies are what keep every *other* path honest.
create policy sitting_invites_owner_all on app.sitting_invites
    for all
    using (owner_account_id = current_setting('app.account_id', true)::uuid)
    with check (owner_account_id = current_setting('app.account_id', true)::uuid);

create policy sitting_invite_plants_owner_all on app.sitting_invite_plants
    for all
    using (
        exists (
            select 1 from app.sitting_invites invite
            where invite.id = sitting_invite_plants.invite_id
              and invite.owner_account_id = current_setting('app.account_id', true)::uuid
        )
    )
    with check (
        exists (
            select 1 from app.sitting_invites invite
            where invite.id = sitting_invite_plants.invite_id
              and invite.owner_account_id = current_setting('app.account_id', true)::uuid
        )
    );

create policy sitting_invite_care_log_owner_read on app.sitting_invite_care_log
    for select
    using (
        exists (
            select 1 from app.sitting_invites invite
            where invite.id = sitting_invite_care_log.invite_id
              and invite.owner_account_id = current_setting('app.account_id', true)::uuid
        )
    );
