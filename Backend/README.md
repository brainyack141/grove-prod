# Grove Backend Foundation

This directory defines the server-side data and permission boundary required by `APP_PLAN.md`. It is intentionally provider-neutral PostgreSQL: it can be applied to a managed Postgres service or a Grove-operated API without leaking provider SDK types into the iOS app.

## Request identity

For each authenticated transaction, the API must set the verified account subject before executing user queries:

```sql
set local app.account_id = '<verified-account-id>';
```

The value must come from a validated server-side access token. Clients must never be allowed to set it directly.

Row-level security then uses `app.current_account_id()` and `app.can_access_plant(...)` to enforce ownership, Grove membership, and active plant-sitting assignments.

## Migration order

Migrations live at the repo root in `supabase/migrations/` and are applied to the linked
Supabase project with `supabase db push` (see [DEPLOY.md](DEPLOY.md)).

1. `20260723000001_initial_schema.sql`
2. `20260730000001_botanist_intelligence.sql`

## Runnable development API

The Node service in this folder implements the current iOS contract in memory for local integration work. It is not a production persistence substitute; the PostgreSQL schema remains the production authority. `supabase-db.mjs` holds the Supabase connection the handlers will move onto.

```sh
cd Backend
npm test
npm start
```

The normal Debug iOS build now targets this local API by default so plant scans exercise Gemini rather than fixture analysis. Launch with `-GroveUseFixtureAnalysis` only for deterministic UI tests or offline previews. A Release archive must provide the `GROVE_API_BASE_URL` build setting with the deployed HTTPS `/v1/` endpoint.

### Gemini credential

The Gemini credential is server-only. The iOS target must call Grove's authenticated API and must never contain or receive the shared provider credential.

- Local macOS development reads the credential from the `nz.co.thinkingai.Grove.gemini-api-key` Keychain item for account `nz.co.thinkingai.Grove`.
- Deployed environments must provide `GEMINI_API_KEY` through the hosting platform's encrypted secret manager.
- Production deliberately does not fall back to the developer's macOS Keychain and fails at startup when the deployment secret is absent.
- Never put the credential in an `.xcconfig`, plist, source file, CI log, or committed `.env` file.

The repository ignores `.env` variants as an additional safeguard. Prefer the host's secret-injection facility over an environment file.

### Gemini Botanist evaluation

The production Botanist runs in the Supabase `botanist` Edge Function. Its shared
client and contract tests live here so the provider boundary can be verified with
the rest of the backend:

```sh
npm test
GEMINI_API_KEY="…" npm run eval:botanist
GEMINI_API_KEY="…" npm run eval:botanist:vision
```

The versioned evaluation contains 50 text cases covering routine care,
missing-information clarification, longitudinal outcomes, prompt injection,
possible ingestion, toxicity, and chemical treatment. The contract suite also
fully Gemini-powered responder, multi-photo continuity, deterministic identity
rendering and bounded second-pass review of complex advice. A single case can be rerun with
`npm run eval:botanist -- <case-id>`.
The live vision evaluation sends a checked-in plant fixture through Gemini,
checks direct identity, conservative symptom handling and an identical-photo
comparison, then runs the same Gemini review used by production. A single
vision case can be rerun with `npm run eval:botanist:vision -- <case-id>`.

Production Botanist access requires a verified Supabase Auth user with the
server-provisioned `app.accounts` row. Anonymous signup is public, so neither an
onboarding identity nor a device-only identity can authorize Ari by declaring a
purpose in user metadata. The usage counter is part of the paid boundary and
fails closed if its RPC contract is unavailable or malformed.

Botanist v2 retrieves a small source-controlled pack of reviewed
university-extension and regulator summaries, routes routine questions through a
fast structured path, and separately reviews diagnostic or conflicting cases
before returning them. Text-only and photo conversations both use Gemini 3.7
Flash; for a photo thread, the model writing the answer sees the pixels. A
complex answer is reviewed in a second bounded Gemini request. Stable
user-message request ids prevent retries from spending or recording twice. The response includes source links and a durable advice id. Feedback sent
to `POST /botanist/advice/:id/outcome` becomes plant-specific outcome memory for
later questions without storing the raw conversation or plant context.

Development authentication uses `Authorization: Bearer dev:<account-id>`. Accounts, idempotency responses, signed upload permissions, and media bytes are isolated in memory and reset when the process exits.

Implemented development routes:

- `GET /health` and `GET /v1/bootstrap`
- authenticated `POST /v1/analysis`, backed by Gemini structured output
- authenticated resumable `POST /v1/analysis/jobs` plus account-scoped job polling/cancellation
- authenticated `GET /v1/species/search?q=...`, backed by the stable GBIF taxonomic catalogue
- profile, plant, check-in, friendship, sitting, and care-action mutations
- signed media negotiation, binary `PUT`, checksum validation, and completion
- per-account idempotency replay

### Plant-analysis request boundary

The resumable job path accepts one to four completed, account-owned signed-media asset IDs after authentication. The synchronous compatibility route can still accept inline JPEG/PNG evidence for development callers. Evidence is stage-specific: identify requires `wholePlant`, add requires `wholePlant` and `leaf`, and diagnose requires `wholePlant` and `symptom`. A capture stage may appear only once.

Signed uploads verify MIME type, declared byte count, SHA-256 integrity, expiry, account ownership, and semantic reuse of the local media UUID. The gateway then matches the JPEG/PNG byte signature and enforces 2 MiB per analysis image and 8 MiB combined evidence. Inline compatibility requests retain a 12 MiB HTTP body ceiling. Region, existing-plant context, and up to three diagnostic answers are length-bounded before they reach the model. Provider instructions treat all supplied field values as untrusted data rather than executable prompt content.

Gemini requests have a 45-second deadline and make two attempts, retrying HTTP 429/503 after a jittered backoff that honours `Retry-After` up to five seconds. The attempt count is deliberately low: the production caller is an Edge Function worker with a wall clock it must settle inside, and a third full-deadline attempt could outlive the instance — leaving a job with no outcome, which the app experiences as a hang rather than a failure. Invalid evidence returns `422`, an oversized body returns `413`, a provider deadline returns `504`, and other temporary provider failures return a user-safe `503`. Provider billing, credential, and raw diagnostic details are retained only in server-side error objects and are never returned to the app.

The deployed gateway (`supabase/functions/analysis`) adds what a shared, paid
endpoint needs at scale: a verified Supabase Auth bearer rather than a
self-asserted account id, a per-account ceiling for provider accounts, and an
atomic per-identity plus project-wide attempt ceiling for every anonymous Auth
identity. Job rows carry state only — never photos — so a poll costs a few
hundred bytes, and required pg_cron housekeeping removes abandoned guest
identities. Anonymous signup metadata is retained only as a cleanup label and
never grants Botanist access or a larger scan budget. A resumed live job never
consumes another provider reservation.

The response is reconstructed from the declared Grove schema rather than passed through verbatim: identifiers and strings are bounded, unknown fields are removed, arrays are capped, confidence and follow-up values are clamped, and low-confidence results retain explicit unknown/abstention guidance.

The iOS client submits a persisted scan UUID with each job. The development server combines that UUID with an evidence fingerprint, so an app retry or relaunch resumes the same account-scoped job while a changed photo or answer creates a new one. Raw image evidence is released from the in-memory job after completion, failure, or cancellation. Production must persist this job/idempotency state durably rather than relying on process memory.

## Required production server capabilities still to implement

- Sign in with Apple authorization-code exchange and token refresh
- Object-storage signed upload/download URLs
- Persist the implemented HTTP contract against PostgreSQL and object storage
- Durable idempotency-key persistence and replay responses
- Durable asynchronous identification/assessment jobs backed by PostgreSQL/object storage (the development API and iOS polling/resume contract are implemented in memory)
- Push token registration and notification fan-out
- Data export, deletion, audit, moderation, and operational tooling

The iOS request and DTO boundary lives in `Grove/APIClient.swift`, `Grove/GroveRemoteRepository.swift`, and `Grove/MediaUploadService.swift`. The client already implements signed-upload negotiation, object upload with SHA-256 integrity metadata, completion acknowledgement, ordered offline delivery, and atomic `/v1/bootstrap` cache replacement; the server must preserve those semantics.

## Storage

App data is persisted to PostgreSQL when `SUPABASE_DB_URL` (or `DATABASE_URL`)
is configured — accounts, groves, plants, care actions, observations and their
health assessments, activity, friendships, sitting assignments, idempotency
replay records and signed upload permissions all live in the `app` schema from
`supabase/migrations/`.

Without that variable the service falls back to process memory for local
development only. `GET /health` reports which mode it is in as
`"storage": "postgres" | "memory"`. **Gate deploys on `postgres`** — see the
warning at the top of `DEPLOY.md` for why an in-memory instance is worse than
no sync at all.

An account is a Supabase Auth identity: `app.accounts.id` is a uuid referencing
`auth.users`, provisioned by the `on_auth_user_created` trigger. The service
never creates accounts — an unknown bearer gets a 401 rather than a new Grove.

Run the durability tests against a real database:

```
createdb grove
# Supabase supplies auth.users, auth.uid(), storage.buckets, pg_cron and the
# anon/authenticated/service_role roles; the test fixture supplies compatible
# Auth/Storage/cron catalogues for plain PostgreSQL.
psql -d grove -f Backend/test/helpers/auth-stub.sql
for f in supabase/migrations/*.sql; do psql -d grove -v ON_ERROR_STOP=1 -f "$f"; done
GROVE_TEST_DATABASE_URL="postgres://…/grove" npm test
```

The database suites skip without that variable. CI always supplies it and
applies every migration, including concurrent guest-job and cleanup invariants.
