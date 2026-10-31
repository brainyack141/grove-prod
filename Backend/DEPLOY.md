# Deploying the Grove backend to production

> ## ⚠️ `SUPABASE_DB_URL` is required before any user points at this
>
> App data — plants, care actions, check-ins, friendships, sitting assignments,
> idempotency records and signed uploads — is persisted to PostgreSQL **only
> when `SUPABASE_DB_URL` (or `DATABASE_URL`) is set**. Without it the service
> falls back to process memory for local development, and every account is lost
> on exit.
>
> That fallback must never serve real users. The iOS client treats
> `GET /v1/bootstrap` as authoritative and replaces local state with it
> wholesale, so an instance that came back empty after a restart would **delete
> every user's entire Grove on their next sync**.
>
> Two safeguards exist, and neither replaces setting the variable:
>
> - `GET /health` reports `"storage": "postgres"` or `"storage": "memory"`.
>   **Gate your deploy on `storage == "postgres"`.**
> - The client refuses a bootstrap reporting no plants while the device still
>   has some (`GroveStore.replace(with:)` returns `false`, sync reports "needs
>   attention"), turning a silent wipe into a visible error. It cannot protect a
>   user whose local Grove is legitimately empty at that moment.
>
> Apply `supabase/migrations/` before first boot — including
> `20260724000002_sync_persistence.sql`, which adds the sync-contract columns,
> the idempotency table and the upload table.

> **Current production path (July 2026): Supabase Edge Functions.** Plant analysis
> analysis, species search, and the Botanist coach are served by
> `supabase/functions/analysis`, `supabase/functions/species`, and
> `supabase/functions/botanist`, with durable analysis jobs in Postgres
> (`public.analysis_jobs`). Deploy with
> `supabase functions deploy analysis species api botanist legal sit` and set secrets with
> `supabase secrets set GEMINI_API_KEY=… GROVE_APP_KEY=…`.
> The app's Release builds bake `GROVE_ANALYSIS_BASE_URL`
> (`https://<project-ref>.supabase.co/functions/v1/`) via `.env.production`.
> This Node server remains for local development only (`scripts/dev-phone.sh`);
> the container instructions below are an unused alternative.

This turns the local dev server into an always-on, HTTPS, public API that the iPhone
app can reach from anywhere (including cellular) — no same-Wi-Fi requirement.

## What runs where

- The **backend** (this folder) is a stateless-ish Node service. It talks to Google
  Gemini for plant analysis and stores app data.
- The **app** points at the backend via the `GROVE_SYNC_URL` and `GROVE_ANALYSIS_URL`
  build settings (baked into `Info.plist` as `GroveSyncURL` and `GroveAnalysisURL`),
  which come from the gitignored `Config/Secrets.xcconfig` or the release scripts.

## Steps only you can do (accounts + secrets)

Claude cannot create hosting accounts, enter your credentials, or handle your raw
Gemini key. These four steps are yours:

1. **Pick a container host** — Fly.io, Render, or Railway (all run the `Dockerfile`).
   Vercel is *not* suitable: this is a stateful long-poll server, not serverless.
2. **Create the app / service** on that host, pointed at this `Backend/` folder.
3. **Set secrets** on the host:
   - `GEMINI_API_KEY` = your Google Gemini key (required)
   - `GROVE_APP_KEY`  = any long random string (recommended — see "Locking it down")
   - `PUBLIC_BASE_URL` = your service's https URL, once known (recommended)
4. **Deploy**, then give Claude the resulting URL so the app can be pointed at it.

### Fly.io (concrete example)

```bash
cd Backend
fly launch --no-deploy            # or keep fly.toml and export FLY_APP=<your-app>
fly secrets set GEMINI_API_KEY=YOUR_KEY GROVE_APP_KEY=$(openssl rand -hex 24)
fly deploy
fly secrets set PUBLIC_BASE_URL="https://<your-app>.fly.dev"   # then: fly deploy
curl https://<your-app>.fly.dev/health                          # {"status":"ok",...}
```

### Render / Railway

Point a new **Web Service** at this repo with root directory `Backend/`, runtime
Docker. Add the same environment variables in the dashboard. Deploy. Health path: `/health`.

## Runtime configuration (read by `server.mjs`)

| Variable          | Required | Purpose                                                        |
|-------------------|----------|----------------------------------------------------------------|
| `GEMINI_API_KEY`  | yes      | Google Gemini key. In local dev it falls back to the macOS Keychain. |
| `SUPABASE_DB_URL` | recommended | Supabase Postgres connection string (transaction pooler). Without it the server runs memory-only. |
| `PORT`            | no       | Listen port (default 8080; most hosts set this for you).       |
| `HOST`            | no       | Bind address (default `0.0.0.0`).                              |
| `PUBLIC_BASE_URL` | recommended | HTTPS origin clients use, e.g. media upload URLs. Falls back to request headers. |
| `GROVE_APP_KEY`   | recommended | If set, every `/v1` request must send `X-Grove-App-Key: <value>`. |

## Supabase

The relational schema lives in `supabase/migrations/` at the repo root and is deployed to
the Supabase project **Grove** (`<project-ref>`; link it once with
`supabase link --project-ref <project-ref>`).

```bash
supabase db push          # apply pending migrations to the linked project
supabase migration list --linked   # compare local and remote migration history
```

Botanist v2 must be deployed in this order:

1. Apply `20260730000001_botanist_intelligence.sql`.
2. Apply `20260801000002_botanist_photo_advice.sql`,
   `20260803000001_botanist_vision_threads.sql`, and
   `20260803000002_botanist_hardening.sql`. The latter two add provider
   provenance, bounded visual evidence, and atomic request-id claims; deploy them
   before contract-v7 code because the health gate also requires the hardened
   evidence status and fail-closed app identification.
3. Deploy the `botanist`, `api`, and `legal` Edge Functions. The API deletion
   path removes replay claims with the rest of an account, and the legal page
   must describe the same provider flow before it is enabled.
4. Leave `BOTANIST_V2_ROLLOUT_PERCENT=0` and
   `BOTANIST_VISION_ROLLOUT_PERCENT=0` while running the text and photo contract
   suites plus the live evaluation.
5. Set `BOTANIST_V2_ENABLED=true` and `BOTANIST_VISION_ENABLED=true` only in an internal/staging environment, or
   leave it unset in production and increase the stable rollout percentage
   gradually.
6. Watch structured `botanist_answer` logs for responder model, attachment
   count, reused-photo status, latency, route, verification, source count and
   provider failures before each increase.

`BOTANIST_V2_ENABLED=false` is the emergency stop. When unset, the rollout
percentage deterministically assigns an account to a cohort, so the same person
does not jump between v1 and v2 on successive questions. Gemini remains the
image-analysis provider in both versions.

`BOTANIST_VISION_ENABLED=false` is the separate photo-response rollback. It
returns photo questions to the contract-v5 Gemini-scan-summary-to-Gemini-text
path without changing text conversations or requiring an app update. Keep that path
for one complete app release after the vision cohort reaches 100%, then remove
it once quality, latency and replay metrics are stable.

### Contract 8: the free allowance moves to the server

Until contract 8, the three-questions-a-day allowance existed only in the app,
and the gateway believed the client's `safetyOnly` flag when it reported the
allowance was spent. A client that never set that flag was served up to the
abuse ceiling of paid answers. Deploy in this order:

1. Apply `20260804000001_botanist_server_quota.sql`. It adds the entitlement
   cache, the usage read, and schema contract 8.
2. Set `REVENUECAT_SECRET_KEY` to a RevenueCat **secret** (`sk_…`) key. This is a
   server secret and must never be the public `appl_…` SDK key the app ships.
3. Deploy the `botanist` and `api` Edge Functions.
4. Only then archive a contract-8 client. `scripts/check-production-gateway.sh`
   enforces this and will refuse a release against a contract-7 gateway.

| Variable | Required | Meaning |
| --- | --- | --- |
| `REVENUECAT_SECRET_KEY` | for metering | Verifies the `premium` entitlement against the same opaque account UUID the app logs in with. **Unset means nothing is metered**, which is the correct pre-launch state and the wrong production state. |
| `BOTANIST_EARLY_ACCESS` | no | `true` lifts the allowance for everyone without claiming they are subscribers. This replaces the app's old inference that an empty catalogue meant early access, so the switch cannot be faked by a client or left on by an old binary. |

Verification fails closed: an account Grove cannot vouch for is metered at three
questions, never zero. A subscriber verified within the grace window keeps
premium through a RevenueCat outage, because an outage is not a cancellation and
the free tier's three questions are served either way. Deterministic safety
answers stay outside both the allowance and the ceiling, and are answered before
the entitlement is resolved so an emergency never waits on RevenueCat.

Watch `entitlementSource` on `botanist_answer` logs after enabling. A steady
stream of `unverified` means RevenueCat is not answering and paying users are
being metered.

### Scan gateway: order matters

`20260801000001_analysis_scale.sql`,
`20260802000003_onboarding_guest_analysis.sql`, and the paid Edge Functions must
go out in that order. The second migration records a retention-only anonymous
purpose, classifies paid-gateway identities from server-owned Auth/account rows,
adds atomic first-scan job creation, and requires the 30-day cleanup schedule.
Deploying the new client before it means signed-out scans fail closed with a
saved-photo retry instead of running without their strict ceiling.

1. Apply `20260801000001_analysis_scale.sql`. It drops `analysis_jobs.request`
   (job scratch data, never read, deleted within the hour either way), adds the
   `analysis_usage` ceiling, and attempts to schedule the sweep on pg_cron. This
   scale migration alone tolerates pg_cron being unavailable; the onboarding
   migration in step 3 deliberately does not.
2. Set `ANALYSIS_ALLOW_LEGACY_BEARER=true` **if any build that predates the JWT
   change is still in a tester's hands.** Those builds send a bare account id,
   and the new function rejects it.
3. Apply `20260802000003_onboarding_guest_analysis.sql`. It must fail if pg_cron
   cannot actively schedule `grove-sweep-analysis-jobs`; do not bypass that
   failure. Confirm `anonymous_auth_purposes`, `analysis_guest_scans`,
   `analysis_guest_global_usage`, and `analysis_identity_class(uuid)` exist,
   the service-role grants are present, and the cron job is active.
4. Deploy the `analysis`, `api`, `botanist`, and `legal` Edge Functions together.
   Botanist now requires a provisioned account and rejects every anonymous Auth
   credential regardless of signup metadata. The legal page contains the
   pre-account photo disclosure and describes account-only Ari advice storage.
5. Ship the app build whose analysis client sends `analysisBearerToken()` for
   scans. Only a provider/email account JWT may be sent to the Botanist; a
   device-only or onboarding anonymous credential must not be used for Ari.
6. Before enabling the onboarding scan, `supabase secrets unset
   ANALYSIS_ALLOW_LEGACY_BEARER`. Confirm with `GET /analysis/health`, which
   reports `legacyBearersAllowed: false`. **This is a release gate.** Leaving it
   on defeats the ceiling because a caller holding the app key can mint a fresh
   account id per request and never hit a limit.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANALYSIS_DAILY_CEILING` | `80` | Scans per account per UTC day. An abuse guard, deliberately far above real use — the product's free-scan meter is a separate, client-side thing. |
| `ANALYSIS_GUEST_DAILY_CEILING` | `3` | One first-plant capture plus up to two retakes per anonymous Auth identity per UTC day, regardless of claimed purpose. The guest job transaction fails closed if unavailable. |
| `ANALYSIS_GUEST_MAX_ATTEMPTS_PER_SCAN` | `3` | Provider attempts for the same stable guest scan id and photo fingerprint; duplicate concurrent POSTs return the existing job without incrementing it. |
| `ANALYSIS_GUEST_GLOBAL_DAILY_ATTEMPT_CEILING` | `250` | Project-wide guest provider-attempt reservations per UTC day. Each guest job disables internal Gemini retries so one reservation is at most one paid attempt. |
| `ANALYSIS_ALLOW_LEGACY_BEARER` | unset (off) | Transitional only; see above. |
| `GEMINI_MAX_ATTEMPTS` | `2` | Provider attempts per scan. Raising this risks the worker outliving the Edge Function wall clock, which strands jobs. |

> **`supabase config push` pushes the whole of `supabase/config.toml`, not just the section
> you edited.** That file starts life as the CLI's *local development* template, so pushing
> it will happily overwrite the linked project's auth settings (email confirmations, OTP
> length, MFA, `site_url`) with local defaults. Always preview first — `printf 'n\n' |
> supabase config push` prints the full diff and answers "no" — and only push once the diff
> contains nothing but your intended change.

The CLI is already linked, and it provisions its own short-lived login role, so migrations
need no database password. The **server** does: copy `Backend/.env.example` to
`Backend/.env.local` and set `SUPABASE_DB_URL` from Dashboard → Connect → Transaction
pooler (reset the database password under Database → Database password if it was never
saved). `GET /health` reports `"database": "connected" | "unavailable" | "not_configured"`
along with the number of tables found in the `app` schema.

Every account-scoped query should go through `database.withAccount(accountID, ...)`, which
sets the transaction-local `app.account_id` that the schema's `app.current_account_id()`
and RLS policies read.

## Locking it down (`GROVE_APP_KEY`)

The app key is a caller gate, not a secret — it is baked into every binary at
build time, sent as `X-Grove-App-Key`, and anyone willing to read the binary has
it. It keeps casual traffic off a public URL; it does not identify anybody.

That is why the two Edge Functions that cost money per request — `botanist` and
`analysis` — verify a real Supabase Auth token on top of it. Botanist additionally
requires the server-provisioned `app.accounts` row and fails closed when its
`botanist_usage` counter is unavailable. Analysis meters provisioned accounts in
`analysis_usage` and every anonymous identity through the fail-closed guest scan
tables. Anything new that spends provider budget should do the same rather than
relying on the app key alone. The dev server in `Backend/` still accepts
`dev:<account-id>` bearers; it is local-only and must never be exposed.

Signed-out first scans use Supabase anonymous Auth. Verify in the hosted Auth
settings that anonymous sign-ins are enabled and rate-limited; the checked-in
local configuration is 30 new anonymous users per IP per hour, but
`supabase/config.toml` does not prove the linked project's value. The per-user
ceiling limits ordinary retries, while the global reservation ceiling bounds
provider spend when a hostile caller mints fresh anonymous subjects. Anonymous
signup metadata is descriptive only: even `purpose=botanist` remains a guest and
cannot enter Botanist. Keep `ANALYSIS_ALLOW_LEGACY_BEARER` off: a legacy bare UUID
has no verified anonymous classification and bypasses both guest controls.

`/health` stays open for the platform's health checks.

## Pointing the app at production

Copy `.env.example` (repo root) to `.env.production` and fill in:

```bash
GROVE_ANALYSIS_BASE_URL="https://<project-ref>.supabase.co/functions/v1/"
GROVE_API_BASE_URL="https://<your-sync-host>/v1/"      # note the trailing /v1/
GROVE_APP_KEY="<same value you set on the host>"       # required for Release builds
```

The release scripts pass these to `xcodebuild` as the `GROVE_ANALYSIS_URL`,
`GROVE_SYNC_URL` and `GROVE_APP_KEY` build settings. No server endpoint is
committed to the repository.

Then:

- `scripts/prod-phone.sh` — Release build on the connected iPhone against production
  (the pre-submission smoke test).
- `scripts/archive-appstore.sh` — archive + export a signed `.ipa` for App Store
  Connect (upload via Xcode Organizer or `altool`).

For plain Xcode / `xcodebuild` runs (Debug included), the key and the gateway URLs
come from `Config/Secrets.xcconfig`, which is gitignored: copy
`Config/Secrets.example.xcconfig` and set `GROVE_APP_KEY`, `GROVE_ANALYSIS_URL` and
`GROVE_SYNC_URL`. None of them is compiled into the source; without one the app logs
`config error: <SETTING> is not set` and leaves the affected gateway clients off.
CI reads them from the repository secrets of the same names.

Release builds hard-fail without https `GROVE_ANALYSIS_URL` and `GROVE_SYNC_URL` and a `GROVE_APP_KEY`
(so a fake-analysis fallback can never ship), and a build phase strips the dev-only
local-networking Info.plist keys, since production is real HTTPS.

## Known limitations of this stage

- **State is still in-memory.** The Supabase schema is deployed and the server can connect
  to it, but the request handlers still read and write the in-process `accounts` map, so
  app data (plants, profile, etc.) resets on redeploy. The app is offline-first and keeps
  its own local copy, so this is fine for TestFlight / soft launch. Moving the handlers
  onto Postgres is the remaining Stage 2 work.
- **RLS policies are incomplete.** The schema enables row-level security everywhere, but
  several tables (`groves`, `grove_memberships`, `spaces`, `media_assets`, `scans`,
  `health_assessments`, `friendships`, `sitting_assignments`, `activity_events`) have
  select-only policies and no insert/update policy. Today the server connects as the table
  owner, which bypasses RLS, so writes work — but RLS cannot be forced until the write
  policies exist.
- **No per-user identity yet.** Stage 3 adds real Sign in with Apple.
