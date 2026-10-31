-- Preserve the result attached to a directly logged soil check. Without this,
-- the server could keep the event but the next bootstrap erased the evidence
-- that made it useful.

begin;

alter table app.care_actions
  add column if not exists soil_moisture text
  check (soil_moisture is null or soil_moisture in ('dry', 'comfortable', 'wet'));

commit;
