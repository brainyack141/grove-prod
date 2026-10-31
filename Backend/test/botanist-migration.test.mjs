import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationURL = new URL(
  "../../supabase/migrations/20260730000001_botanist_intelligence.sql",
  import.meta.url
);
const authenticatedGuestsMigrationURL = new URL(
  "../../supabase/migrations/20260730000002_botanist_authenticated_guests.sql",
  import.meta.url
);
const photoAdviceMigrationURL = new URL(
  "../../supabase/migrations/20260801000002_botanist_photo_advice.sql",
  import.meta.url
);
const visionThreadsMigrationURL = new URL(
  "../../supabase/migrations/20260803000001_botanist_vision_threads.sql",
  import.meta.url
);
const hardeningMigrationURL = new URL(
  "../../supabase/migrations/20260803000002_botanist_hardening.sql",
  import.meta.url
);
const geminiProviderMigrationURL = new URL(
  "../../supabase/migrations/20260830000001_gemini_botanist_provider.sql",
  import.meta.url
);
const botanistGatewayURL = new URL(
  "../../supabase/functions/botanist/index.ts",
  import.meta.url
);
const premiumStoreURL = new URL("../../Grove/GrovePremiumStore.swift", import.meta.url);
const rootViewURL = new URL("../../Grove/RootView.swift", import.meta.url);
const edgeAPIURL = new URL(
  "../../supabase/functions/api/index.ts",
  import.meta.url
);

test("Botanist memory migration stores outcomes without raw prompt data", async () => {
  const sql = await readFile(migrationURL, "utf8");
  assert.match(sql, /create table public\.botanist_advice/i);
  assert.match(sql, /\bhelpful boolean\b/i);
  assert.match(sql, /\bplant_outcome text\b/i);
  assert.match(sql, /enable row level security/i);
  assert.match(sql, /revoke all on public\.botanist_advice from anon/i);
  assert.match(sql, /revoke all on public\.botanist_advice from authenticated/i);
  assert.doesNotMatch(sql, /^\s*(question|conversation|plant_context|scan_context)\s+/im);
});

test("the historical anonymous Auth path does not provision synced Grove accounts", async () => {
  const sql = await readFile(authenticatedGuestsMigrationURL, "utf8");
  assert.match(sql, /create or replace function app\.handle_new_auth_user/i);
  assert.match(sql, /if coalesce\(new\.is_anonymous,\s*false\) then\s+return new;/i);
  assert.match(sql, /insert into app\.accounts/i);
});

test("photo-backed Botanist advice can retain its route and verification provenance", async () => {
  const sql = await readFile(photoAdviceMigrationURL, "utf8");
  assert.match(sql, /route_tier in \([^)]*'photo_identity'/is);
  assert.match(sql, /verification_status in \([^)]*'photo_scan'/is);
});

test("new Botanist advice defaults to Gemini without rewriting historical provenance", async () => {
  const sql = await readFile(geminiProviderMigrationURL, "utf8");
  assert.match(sql, /alter column provider set default 'google_gemini'/i);
  assert.doesNotMatch(sql, /update\s+public\.botanist_advice/i);
});

test("vision-thread requests are replay-safe without storing raw conversations or photos", async () => {
  const sql = await readFile(visionThreadsMigrationURL, "utf8");
  assert.match(sql, /add column if not exists provider text/i);
  assert.match(sql, /request_id uuid/i);
  assert.match(sql, /create table public\.botanist_requests/i);
  assert.match(sql, /create function public\.botanist_claim_request/i);
  assert.match(sql, /existing_claimed_at < now\(\) - interval '3 minutes'/i);
  assert.match(sql, /existing_state = 'limited'[\s\S]*existing_claimed_at at time zone 'utc'/i);
  assert.match(sql, /create unique index if not exists botanist_advice_account_request_idx/i);
  assert.match(sql, /enable row level security/i);
  assert.match(sql, /revoke all on public\.botanist_requests from authenticated/i);
  assert.match(sql, /grant select, insert, update, delete on public\.botanist_requests to service_role/i);
  assert.match(sql, /grant execute on function public\.botanist_claim_request\(text, uuid, integer\) to service_role/i);
  assert.match(sql, /grant execute on function public\.botanist_complete_request\(text, uuid, uuid\) to service_role/i);
  assert.match(sql, /grant execute on function public\.botanist_release_request\(text, uuid\) to service_role/i);
  assert.doesNotMatch(sql, /^\s*(question|conversation|plant_context|photo|image_bytes)\s+/im);
});

test("safe evidence-boundary answers persist and denied UUID spam is not retained", async () => {
  const sql = await readFile(hardeningMigrationURL, "utf8");
  assert.match(sql, /verification_status in \([^)]*'evidence_boundary'/is);
  assert.match(
    sql,
    /if used < 0 then\s+delete from public\.botanist_requests[\s\S]*?return 'limited'/i
  );
  const saturatedPreflight = sql.indexOf("if coalesce(used, 0) > p_daily_limit");
  const requestInsert = sql.indexOf("insert into public.botanist_requests");
  assert.ok(saturatedPreflight >= 0 && saturatedPreflight < requestInsert);
  assert.match(sql, /select id into existing_advice[\s\S]*if found then return 'completed'/i);
  assert.match(
    sql,
    /if existing_claimed_at < now\(\) - interval '3 minutes' then[\s\S]*botanist_record_ask[\s\S]*set state = 'limited'/i
  );
  assert.match(sql, /botanist_requests_completed_at_idx/i);
  assert.match(sql, /botanist_requests_unfinished_claimed_at_idx/i);
  assert.match(sql, /least\([\s\S]*botanist_usage\.asks::bigint \+ 1[\s\S]*p_daily_limit::bigint \+ 1/i);
  assert.match(sql, /p_daily_limit < 1 or p_daily_limit > 1000000/i);
  assert.match(
    sql,
    /botanist_require_live_account[\s\S]*from app\.accounts[\s\S]*for key share/i
  );
  assert.match(
    sql,
    /after delete on app\.accounts[\s\S]*botanist_purge_deleted_account/i
  );
  for (const table of ["botanist_requests", "botanist_advice", "botanist_usage"]) {
    assert.match(sql, new RegExp(`delete from public\\.${table} where account_id = old\\.id::text`, "i"));
  }
  assert.match(sql, /botanist_schema_contract_version[\s\S]*select 7/i);
});

test("the gateway keeps deterministic safety available and fails closed without its app key", async () => {
  const source = await readFile(botanistGatewayURL, "utf8");
  assert.match(source, /const botanistContractVersion = 8/);
  assert.match(source, /database\.rpc\("botanist_schema_contract_version"\)/);
  const safety = source.indexOf("const safety = policyResult(botanistSafetyFallback");
  const safetyResponse = source.indexOf("return immediateSafetyResponse(safety)");
  const safetyOnlyRefusal = source.indexOf("if (payload.safetyOnly && plan.metered)");
  const requestClaim = source.indexOf("if (payload.requestID)");
  const providerConfiguration = source.indexOf("if (!Deno.env.get(\"GEMINI_API_KEY\"))");
  assert.ok(safety >= 0);
  assert.ok(safetyResponse > safety);
  assert.ok(safetyOnlyRefusal > safetyResponse);
  assert.ok(requestClaim > safetyOnlyRefusal);
  assert.ok(providerConfiguration > safetyResponse);
  // Deterministic safety must stay ahead of everything that can cost or refuse,
  // including the entitlement lookup: an emergency answer cannot wait on
  // RevenueCat, and must not be withheld when RevenueCat is down.
  assert.ok(source.indexOf("const plan = await askPlan(owner)") > safetyResponse);
  assert.match(source, /if \(!appKey\) \{[\s\S]*return failure\(503, "Ari is not configured\."\)/);
  assert.match(source, /botanistPhotoContext\(analysis, \{\s*includesCurrentTurnPhoto,/s);
  assert.doesNotMatch(source, /\.update\(update\)\s*\.update\(update\)/);
  assert.match(source, /sweepOldBotanistState[\s\S]*from\("botanist_requests"\)/);
  assert.doesNotMatch(source, /console\.(?:error|warn)\([^\n]*providerDetail/);
});

test("RevenueCat is identified with the same signed-in account used by Botanist", async () => {
  const [premium, root] = await Promise.all([
    readFile(premiumStoreURL, "utf8"),
    readFile(rootViewURL, "utf8")
  ]);
  assert.match(premium, /func activate\(accountID: String\) async/);
  assert.match(premium, /Purchases\.shared\.logIn\(normalized\)/);
  assert.match(premium, /Purchases\.shared\.logOut\(\)/);
  assert.match(premium, /revenueCatIdentityIsCurrent/);
  assert.match(premium, /hasPremium = false[\s\S]*Purchases\.shared\.logIn/s);
  assert.match(root, /premium\.activate\(accountID: userSession\.accountID\)/);
  assert.match(root, /premium\.deactivate\(\)/);
});

test("account deletion removes Botanist request claims as well as advice", async () => {
  const source = await readFile(edgeAPIURL, "utf8");
  const requestDelete = source.indexOf("delete from public.botanist_requests where account_id");
  const adviceDelete = source.indexOf("delete from public.botanist_advice where account_id");
  assert.ok(requestDelete >= 0);
  assert.ok(adviceDelete > requestDelete);
  // The entitlement cache is account data too. The account-delete trigger also
  // purges it, but this path erases the text-keyed service tables explicitly and
  // leaving one out is how a deleted account keeps a row nobody looks for.
  assert.ok(source.indexOf("delete from public.botanist_entitlements where account_id") > adviceDelete);
});
