begin;

alter table app.accounts
    add column if not exists location_country_code text,
    add column if not exists location_time_zone_identifier text;

-- Sitting windows are chosen in the grove's timezone, not whatever timezone
-- the owner's phone happens to enter while travelling. Existing links predate
-- this metadata and retain their already-materialised UTC boundaries.
alter table app.sitting_invites
    add column if not exists time_zone_identifier text not null default 'UTC';

alter table app.sitting_assignments
    add column if not exists time_zone_identifier text not null default 'UTC';

alter table app.device_tokens
    add column if not exists sitting_updates_enabled boolean not null default true;

commit;
