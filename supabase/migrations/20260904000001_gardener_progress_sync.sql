-- Keep Journey progress with the Grove account rather than only in one
-- iPhone's UserDefaults snapshot. The state is deliberately one JSON document:
-- streak count, last-tend day, shields, XP, badges, quests and opened rewards
-- form one consistency boundary and are written together by the client.

begin;

alter table app.accounts
  add column if not exists gardener_progress jsonb,
  add column if not exists gardener_progress_updated_at timestamptz;

commit;
