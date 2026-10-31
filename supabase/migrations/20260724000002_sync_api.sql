-- Production data-sync support for the `api` Edge Function.
--
-- The iOS sync contract (`/v1/bootstrap`, plants, check-ins, care actions, profile,
-- friendships, sitting, signed media) moves off the in-memory dev server onto the
-- relational schema. This migration adds the few fields the app syncs that had no
-- relational home yet, plus the idempotency-replay table the API uses to make
-- mutation retries safe.

begin;

-- Profile fields the app syncs but the schema did not yet store: measurement
-- preference and the single Grove-wide location pin.
alter table app.accounts
    add column if not exists uses_metric_system boolean not null default true,
    add column if not exists latitude double precision,
    add column if not exists longitude double precision,
    add column if not exists location_label text;

-- Client presentation payload (free-text location, artwork symbol/palette, summary,
-- positive signs, concerns, next actions) that is owned by the app rather than the
-- assessment pipeline. Kept as one jsonb value so the canonical health columns stay
-- the single source of truth for scores and bands.
alter table app.plants
    add column if not exists presentation jsonb not null default '{}'::jsonb;

-- Signed-upload lifecycle: a media asset is created 'pending' when the upload is
-- negotiated and becomes 'ready' once the bytes land in Storage and the checksum
-- matches. `local_media_id` is the client's stable id for the photo, making upload
-- negotiation semantically idempotent per owner.
alter table app.media_assets
    add column if not exists local_media_id uuid,
    add column if not exists sha256 text,
    add column if not exists status text not null default 'pending'
        check (status in ('pending', 'ready'));

create unique index if not exists media_assets_owner_local_media_idx
    on app.media_assets (owner_account_id, local_media_id)
    where local_media_id is not null;

-- Mutation idempotency replay for the sync API, mirroring the dev server's map.
-- Lives in `public` because the Edge Function reaches it with service credentials;
-- RLS is enabled with no policies so clients can never touch it.
create table if not exists public.api_idempotency (
    account_id uuid not null,
    cache_key text not null,
    status integer not null,
    body jsonb,
    stored_at timestamptz not null default now(),
    primary key (account_id, cache_key)
);

create index if not exists api_idempotency_stored_at on public.api_idempotency (stored_at);

alter table public.api_idempotency enable row level security;

commit;
