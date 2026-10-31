-- Where a push is actually sent.
--
-- Grove's notifications were entirely local until now, which meant the app
-- could only ever tell someone about their *own* schedule. Everything that
-- happens because another person acted — a friend request, a sitter logging
-- care while the owner is abroad — was silent until the owner next opened the
-- app, which for a sitting update is exactly the fortnight they are not opening
-- it.
--
-- Three rules the shape enforces rather than documents:
--
--   1. A token belongs to one account at a time. The unique constraint is on
--      the token, not on (account, token), so signing a second account into the
--      same phone *moves* the row instead of fanning that phone out to two
--      accounts. Shared and hand-me-down phones are the normal case, not the
--      edge case, and the failure mode is showing one person another person's
--      notifications.
--   2. The environment travels with the token. A sandbox token sent to the
--      production APNs host fails with no signal the app can see, so which host
--      to use is recorded when the token is registered rather than guessed at
--      send time.
--   3. Rows are disposable. `last_seen_at` and the 410-prune in `apns.ts` are
--      what stop this table growing into a slow outage, where most of a send
--      fan-out is spent on tokens that stopped existing months ago.

create table if not exists app.device_tokens (
    -- The APNs device token, hex. Not a secret in the password sense, but it
    -- addresses a specific phone, so it is never returned by any read endpoint.
    token text primary key,
    account_id uuid not null references app.accounts(id) on delete cascade,
    environment text not null default 'production'
        check (environment in ('production', 'sandbox')),
    created_at timestamptz not null default now(),
    -- Bumped on every re-registration, which the app does on each launch. A
    -- token that has not been seen in months belongs to an app that was
    -- deleted without ever reaching the sign-out path.
    last_seen_at timestamptz not null default now()
);

-- Every send starts by fanning out from an account.
create index if not exists device_tokens_account_idx
    on app.device_tokens (account_id);

alter table app.device_tokens enable row level security;

-- No policies, deliberately. The API function holds the service role and is the
-- only thing that reads or writes this table; a client that could list tokens
-- could address another person's phone directly.
