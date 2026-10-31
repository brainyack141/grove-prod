import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL(
  "../../supabase/migrations/20260802000003_onboarding_guest_analysis.sql",
  import.meta.url
), "utf8");
const analysisFunction = readFileSync(new URL(
  "../../supabase/functions/analysis/index.ts",
  import.meta.url
), "utf8");
const botanistFunction = readFileSync(new URL(
  "../../supabase/functions/botanist/index.ts",
  import.meta.url
), "utf8");
const deployGuide = readFileSync(new URL("../DEPLOY.md", import.meta.url), "utf8");
const legalFunction = readFileSync(new URL(
  "../../supabase/functions/legal/index.ts",
  import.meta.url
), "utf8");

test("guest quota reservation and job insertion share one locked SQL function", () => {
  assert.match(migration, /create function public\.analysis_create_guest_job/i);
  assert.match(migration, /pg_advisory_xact_lock/i);
  assert.match(migration, /insert into public\.analysis_jobs/i);
  assert.doesNotMatch(migration, /create function public\.analysis_reserve_guest_scan/i);
  assert.match(analysisFunction, /database\.rpc\("analysis_create_guest_job"/);
  assert.doesNotMatch(analysisFunction, /database\.rpc\("analysis_reserve_guest_scan"/);
});

test("guest analysis has a project-wide provider-attempt reservation ceiling", () => {
  assert.match(migration, /create table public\.analysis_guest_global_usage/i);
  assert.match(migration, /p_global_daily_limit integer/i);
  assert.match(migration, /'decision', 'global_limited'/i);
  assert.match(analysisFunction, /ANALYSIS_GUEST_GLOBAL_DAILY_ATTEMPT_CEILING/);
  assert.match(analysisFunction, /processJob\(job\.id as string, body, 1\)/);
});

test("every anonymous purpose uses three bounded onboarding captures", () => {
  assert.match(analysisFunction, /const defaultGuestDailyScanCeiling = 3/);
  assert.match(analysisFunction, /usesGuestAnalysisQuota\(identity\)/);
});

test("scan and Botanist health contracts report Gemini 3.7 Flash", () => {
  for (const source of [analysisFunction, botanistFunction]) {
    assert.match(source, /"gemini-3\.7-flash"/);
    assert.match(source, /model:\s*configuredGemini/i);
  }
  assert.match(analysisFunction, /createGeminiPlantAnalysisClient\(\{ apiKey, model/);
  assert.doesNotMatch(botanistFunction, /DEEPSEEK_API_KEY|api\.deepseek\.com/i);
});

test("paid counter contracts do not coerce null into an allowance", () => {
  assert.match(analysisFunction, /typeof data !== "number" \|\| !Number\.isInteger\(data\)/);
  assert.doesNotMatch(analysisFunction, /Number\(data\) >= 0/);
  assert.match(botanistFunction, /typeof data !== "number" \|\| !Number\.isInteger\(data\)/);
  assert.doesNotMatch(botanistFunction, /Number\(data\) >= 0/);
  assert.match(
    analysisFunction,
    /if \(error\) \{[\s\S]{0,180}return "unavailable";/,
    "A broken paid-scan counter must fail closed rather than permit unbounded provider calls"
  );
});

test("Botanist requires a server-provisioned account, regardless of anonymous metadata", () => {
  assert.match(migration, /create function public\.analysis_identity_class/i);
  assert.match(migration, /exists \([\s\S]*from app\.accounts/i);
  assert.match(migration, /when users\.is_anonymous is true then 'anonymous'/i);
  assert.match(migration, /if new\.is_anonymous is not false then/i);
  assert.match(botanistFunction, /database\.rpc\(\s*"analysis_identity_class"/);
  assert.match(botanistFunction, /canUseBotanist\(identity\)/);
  assert.doesNotMatch(botanistFunction, /from\("anonymous_auth_purposes"\)/);
  assert.doesNotMatch(migration, /when 'botanist' then 'botanist'/i);
});

test("guest SQL rejects null limits and malformed fingerprints", () => {
  for (const parameter of ["p_daily_limit", "p_max_attempts", "p_global_daily_limit"]) {
    assert.match(migration, new RegExp(`${parameter} is null`, "i"));
  }
  assert.match(migration, /p_fingerprint !~ '\^\[0-9a-f\]\{64\}\$'/i);
});

test("service-role permissions for every paid runtime dependency are explicit", () => {
  assert.match(migration, /grant execute on function public\.analysis_identity_class\(uuid\) to service_role/i);
  assert.match(migration, /grant execute on function public\.analysis_create_guest_job\([^)]+\) to service_role/i);
  assert.match(migration, /grant execute on function public\.analysis_record_scan\(text, integer\) to service_role/i);
  assert.match(migration, /grant execute on function public\.botanist_record_ask\(text, integer\) to service_role/i);
  assert.match(migration, /grant select, insert, update, delete on public\.analysis_jobs to service_role/i);
  assert.match(migration, /grant select, insert, update, delete on public\.botanist_usage to service_role/i);
  assert.match(migration, /grant select, insert, update, delete on public\.botanist_advice to service_role/i);
});

test("the onboarding migration requires an active 30-day cleanup schedule", () => {
  assert.match(migration, /to_regprocedure\('cron\.schedule\(text,text,text\)'\)/i);
  assert.match(migration, /raise exception 'pg_cron is required for onboarding guest retention'/i);
  assert.match(migration, /where jobname = 'grove-sweep-analysis-jobs'[\s\S]*and active/i);
  assert.match(migration, /raise exception 'grove-sweep-analysis-jobs must be actively scheduled'/i);
  assert.doesNotMatch(migration, /pg_cron unavailable/i);
});

test("release guidance deploys every changed boundary and documents the global cap", () => {
  assert.match(deployGuide, /Deploy the `analysis`, `api`, `botanist`, and `legal` Edge Functions together/);
  assert.match(deployGuide, /ANALYSIS_GUEST_GLOBAL_DAILY_ATTEMPT_CEILING/);
  assert.match(deployGuide, /legacyBearersAllowed: false/);
  assert.match(deployGuide, /Botanist now requires a provisioned account/);
  assert.match(legalFunction, /Anonymous first-scan and\s+device-only identifiers cannot use Ari/);
  assert.match(legalFunction, /scheduled for deletion once it is\s+30 days old/);
});
