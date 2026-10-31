// Grove plant-analysis gateway on Supabase Edge Functions.
//
// Speaks the same job contract as the local dev server (`Backend/server.mjs`):
//   POST   /analysis/jobs        create (or resume) an analysis job   → 202
//   GET    /analysis/jobs/:id    poll job state                       → 200/202
//   DELETE /analysis/jobs/:id    cancel a job the user abandoned      → 200
//   GET    /analysis/health      unauthenticated health probe         → 200
//
// Jobs persist in `public.analysis_jobs` (service-role only, RLS locked), so
// they survive instance recycling — polling clients can resume after retries.
// Gemini work runs in the background via EdgeRuntime.waitUntil while the client
// polls; a poll-side watchdog settles any job whose worker died.
//
// Scale notes, because all three are easy to undo by accident:
//   * Photos never touch Postgres. The worker holds the request in memory and
//     the row carries only job state, so a poll costs a few hundred bytes
//     instead of the megabytes of base64 the scan was submitted with.
//   * Selects name their columns. `select("*")` on this table was what made a
//     poll expensive, and it would be again the moment a large column returns.
//   * The worker settles itself before the runtime's wall clock can kill it,
//     so the watchdog only ever catches a genuinely dead instance.

import { createClient } from "npm:@supabase/supabase-js@2";
import {
  createGeminiPlantAnalysisClient,
  GeminiProviderError,
  GeminiRequestTimeoutError
} from "../_shared/gemini-plant-analysis.mjs";
import { sanitizePlantAnalysis } from "../_shared/analysis-safety.mjs";
import {
  analysisIdentityForUser,
  usesGuestAnalysisQuota
} from "../_shared/analysis-identity.mjs";
import {
  guestJobDecisionIsLimited,
  parseGuestJobDecision
} from "../_shared/analysis-guest-job.mjs";
import {
  AnalysisRequestValidationError,
  validatePlantAnalysisRequest
} from "../_shared/analysis-request-validation.mjs";

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const liveStatuses = ["queued", "analysing", "completed"];
const defaultGeminiModel = "gemini-3.7-flash";
const defaultGeminiThinkingLevel = "low";

function configuredGeminiModel(): string {
  return Deno.env.get("GEMINI_MODEL") || defaultGeminiModel;
}

function configuredGeminiThinkingLevel(): string {
  return Deno.env.get("GEMINI_THINKING_LEVEL") || defaultGeminiThinkingLevel;
}

// Everything the client is ever shown. Never widen this to `*`: the row is
// cheap to read only because nothing large is in this list.
const jobColumns = "id,status,created_at,updated_at,result,message";

// The worker gives up here and writes its own failure, comfortably inside the
// Edge Function wall clock (150s by default) so it is never killed mid-flight.
const workerBudgetMilliseconds = 105_000;
// Only a genuinely dead instance can leave a job live past this, so the poller
// settles it. Must stay above `workerBudgetMilliseconds` or the watchdog would
// fail jobs that are still legitimately working.
const stuckJobMilliseconds = 120_000;

// An abuse ceiling, not the product's scan meter — far above a real gardener's
// day (cataloguing a whole collection in one sitting is maybe 30) and low
// enough that a script with a scraped app key cannot run up the Gemini bill.
const defaultDailyScanCeiling = 80;
// Every anonymous identity gets one onboarding capture plus two bounded retakes
// per UTC day. Descriptive signup metadata never raises this ceiling.
// The same logical scan may retry a bounded number of times after a provider or
// transport failure without silently consuming a second photo.
const defaultGuestDailyScanCeiling = 3;
const defaultGuestAttemptsPerScan = 3;
// Project-wide reserved provider attempts. Every anonymous analysis job uses a
// one-attempt Gemini client, so the SQL reservation and paid request are the
// same budget unit. This remains a backstop when identities are minted afresh.
const defaultGuestGlobalDailyAttemptCeiling = 250;

// Housekeeping runs from required pg_cron every 15 minutes. This sampled call
// is defense in depth if an operational issue delays the schedule.
const fallbackSweepProbability = 0.02;

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } }
);

function json(status: number, value: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { ...jsonHeaders, ...headers } });
}

function failure(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json(status, { message }, headers);
}

function numericSetting(name: string, fallback: number): number {
  const value = Number(Deno.env.get(name));
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function publicJob(row: Record<string, unknown>) {
  return {
    id: row.id,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    result: row.result,
    message: row.message
  };
}

function publicAnalysisFailure(error: unknown): string {
  if (error instanceof GeminiRequestTimeoutError) {
    return "Plant analysis timed out. Try again with the saved photos.";
  }
  return "Plant analysis is temporarily unavailable. Try again with the saved photos.";
}

// Keep provider diagnostics in the private function log without ever logging
// the request, its user context or its photo bytes. The public job remains
// deliberately generic, but an invalid model parameter must be distinguishable
// from an outage when production is being repaired.
function logAnalysisFailure(error: unknown) {
  if (error instanceof GeminiProviderError) {
    console.error("plant analysis provider failed", {
      status: error.status,
      detail: String(error.providerDetail ?? "").slice(0, 500)
    });
    return;
  }
  console.error("plant analysis failed", {
    name: error instanceof Error ? error.name : typeof error,
    message: error instanceof Error ? error.message : "Unknown analysis failure"
  });
}

// ── Identity ────────────────────────────────────────────────────────────────
//
// The scan gateway spends money, so it verifies a real Supabase Auth token the
// way the botanist does, rather than trusting whatever account id the caller
// typed. The shared app key is only a caller gate — it ships in every binary.
//
// Verification is a network call to GoTrue, and a single scan polls a dozen
// times, so verified tokens are cached in the isolate for their remaining life
// (capped, and never past the token's own expiry).

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type AnalysisIdentity = {
  accountID: string;
  kind: "account" | "onboarding_guest" | "legacy";
  anonymousPurpose: string | null;
};

const verifiedTokens = new Map<string, { identity: AnalysisIdentity; expiresAt: number }>();
const verifiedTokenCacheLimit = 500;
const verifiedTokenCacheMilliseconds = 5 * 60_000;

// Reads `sub` and `exp` without trusting them. Used only to bound how long a
// token that GoTrue *has* verified stays cached.
function unverifiedClaims(token: string): { sub?: string; exp?: number } {
  try {
    const payload = token.split(".")[1];
    if (!payload) return {};
    const normalised = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalised.padEnd(Math.ceil(normalised.length / 4) * 4, "=");
    return JSON.parse(atob(padded)) ?? {};
  } catch {
    return {};
  }
}

function rememberVerifiedToken(token: string, identity: AnalysisIdentity) {
  const claims = unverifiedClaims(token);
  const tokenExpiry = typeof claims.exp === "number" ? claims.exp * 1000 : Number.POSITIVE_INFINITY;
  const expiresAt = Math.min(Date.now() + verifiedTokenCacheMilliseconds, tokenExpiry);
  if (expiresAt <= Date.now()) return;
  if (verifiedTokens.size >= verifiedTokenCacheLimit) {
    // Insertion-ordered: dropping the oldest entry is enough to bound memory.
    const oldest = verifiedTokens.keys().next();
    if (!oldest.done) verifiedTokens.delete(oldest.value);
  }
  verifiedTokens.set(token, { identity, expiresAt });
}

// Transitional escape hatch for builds already in testers' hands, which send a
// bare account id rather than a Supabase JWT. Turn `ANALYSIS_ALLOW_LEGACY_BEARER`
// off as soon as those builds are gone — while it is on, the daily ceiling is
// the only thing standing between a scraped app key and the Gemini bill.
function legacyBearersAllowed(): boolean {
  return ["1", "true", "yes", "on"].includes(
    (Deno.env.get("ANALYSIS_ALLOW_LEGACY_BEARER") ?? "").toLowerCase()
  );
}

async function authenticatedIdentity(request: Request): Promise<AnalysisIdentity | undefined> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return undefined;
  const token = authorization.slice("Bearer ".length).trim();
  if (!token) return undefined;

  const cached = verifiedTokens.get(token);
  if (cached) {
    if (cached.expiresAt > Date.now()) return cached.identity;
    verifiedTokens.delete(token);
  }

  const { data, error } = await database.auth.getUser(token);
  if (!error && data.user) {
    const { data: registeredClass, error: classError } = await database.rpc(
      "analysis_identity_class",
      { p_user_id: data.user.id }
    );
    if (classError || !["account", "anonymous"].includes(registeredClass)) {
      console.error("analysis identity class unavailable", classError?.message ?? "invalid class");
      return undefined;
    }
    let registeredPurpose: string | null = null;
    if (registeredClass === "anonymous") {
      const { data: registration, error: registrationError } = await database
        .from("anonymous_auth_purposes")
        .select("purpose")
        .eq("user_id", data.user.id)
        .maybeSingle();
      if (registrationError) {
        // Classification failure must never widen an anonymous user's spend.
        // `analysisIdentityForUser` treats a missing purpose as onboarding.
        console.error("analysis anonymous purpose unavailable", registrationError.message);
      } else {
        registeredPurpose = typeof registration?.purpose === "string"
          ? registration.purpose
          : null;
      }
    }
    const identity = analysisIdentityForUser(
      data.user,
      registeredPurpose,
      registeredClass
    ) as AnalysisIdentity | null;
    if (!identity) return undefined;
    rememberVerifiedToken(token, identity);
    return identity;
  }

  if (legacyBearersAllowed()) {
    const id = token.startsWith("dev:") ? token.slice(4) : token;
    if (uuidPattern.test(id)) {
      return {
        accountID: id.toLowerCase(),
        kind: "legacy",
        anonymousPurpose: null
      };
    }
  }
  console.warn("analysis bearer rejected", error?.message ?? "missing user");
  return undefined;
}

// ── Work ────────────────────────────────────────────────────────────────────

function scheduleBackground(work: Promise<unknown>) {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(work);
  }
}

async function settle(jobID: string, patch: Record<string, unknown>) {
  await database
    .from("analysis_jobs")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("id", jobID)
    .eq("status", "analysing");
}

// Guarantees the worker writes its own outcome. Without this a job whose
// instance is reclaimed sits `analysing` until the watchdog notices, and the
// person holding the phone waits out the whole client deadline for it.
function withBudget<Value>(work: Promise<Value>, milliseconds: number): Promise<Value> {
  let timer: number | undefined;
  const budget = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new GeminiRequestTimeoutError("Plant analysis exceeded its time budget.")),
      milliseconds
    );
  });
  return Promise.race([work, budget]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  }) as Promise<Value>;
}

async function processJob(jobID: string, request: unknown, maximumAttempts?: number) {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    await database
      .from("analysis_jobs")
      .update({
        status: "failed",
        message: "Plant analysis is not configured.",
        updated_at: new Date().toISOString()
      })
      .eq("id", jobID)
      .in("status", ["queued", "analysing"]);
    return;
  }
  // Claim the job, and stop if there was nothing to claim: the user cancelled
  // it, or another instance already has it. Either way, calling Gemini here
  // would spend a scan whose answer nobody can ever see.
  const { data: claimed, error: claimError } = await database
    .from("analysis_jobs")
    .update({ status: "analysing", updated_at: new Date().toISOString() })
    .eq("id", jobID)
    .eq("status", "queued")
    .select("id")
    .maybeSingle();
  if (claimError || !claimed) return;

  try {
    const model = configuredGeminiModel();
    const analysisClient = maximumAttempts == null
      ? createGeminiPlantAnalysisClient({ apiKey, model })
      : createGeminiPlantAnalysisClient({ apiKey, model, maximumAttempts });
    const result = await withBudget(analysisClient.analyse(request), workerBudgetMilliseconds);
    await settle(jobID, { status: "completed", result: sanitizePlantAnalysis(result, request) });
  } catch (analysisError) {
    logAnalysisFailure(analysisError);
    await settle(jobID, { status: "failed", message: publicAnalysisFailure(analysisError) });
  }
}

async function sweepOldJobs() {
  const { error } = await database.rpc("sweep_analysis_jobs");
  if (error) console.error("analysis sweep failed", error.message);
}

type ScanAllowance = "allowed" | "limited" | "unavailable";

// Provider accounts retain the high abuse ceiling, but the counter still
// fails closed. If the RPC or its grants disappear during a partial deploy,
// allowing every request would turn that deployment fault into unbounded paid
// model usage.
async function accountScanAllowance(identity: AnalysisIdentity): Promise<ScanAllowance> {
  const { data, error } = await database.rpc("analysis_record_scan", {
    p_account_id: identity.accountID,
    p_daily_limit: numericSetting("ANALYSIS_DAILY_CEILING", defaultDailyScanCeiling)
  });
  if (error) {
    console.error("analysis usage counter unavailable", error);
    return "unavailable";
  }
  if (typeof data !== "number" || !Number.isInteger(data)) {
    console.error("analysis usage counter returned an invalid contract");
    return "unavailable";
  }
  return data >= 0 ? "allowed" : "limited";
}

async function createOrResumeGuestJob(
  identity: AnalysisIdentity,
  body: Record<string, unknown>,
  fingerprint: string
): Promise<Response> {
  const { data, error } = await database.rpc("analysis_create_guest_job", {
    p_account_id: identity.accountID,
    p_client_request_id: body.clientRequestID,
    p_fingerprint: fingerprint,
    p_daily_limit: numericSetting("ANALYSIS_GUEST_DAILY_CEILING", defaultGuestDailyScanCeiling),
    p_max_attempts: numericSetting("ANALYSIS_GUEST_MAX_ATTEMPTS_PER_SCAN", defaultGuestAttemptsPerScan),
    p_global_daily_limit: numericSetting(
      "ANALYSIS_GUEST_GLOBAL_DAILY_ATTEMPT_CEILING",
      defaultGuestGlobalDailyAttemptCeiling
    )
  });
  if (error) {
    console.error("analysis guest job reservation unavailable", error);
    return failure(503, "Plant analysis is temporarily unavailable. Your photo is saved. Try again shortly.");
  }

  const resolution = parseGuestJobDecision(data);
  if (resolution.decision === "unavailable") {
    console.error("analysis guest job reservation returned an invalid contract");
    return failure(503, "Plant analysis is temporarily unavailable. Your photo is saved. Try again shortly.");
  }
  if (guestJobDecisionIsLimited(resolution.decision)) {
    return failure(
      429,
      "Guest scans have reached today's safety limit. Your photo is saved. Try again tomorrow.",
      { "retry-after": "3600" }
    );
  }

  const job = resolution.job as Record<string, unknown>;
  if (resolution.decision === "created") {
    // One SQL reservation equals one possible provider attempt. Guest retries
    // happen as new durable jobs, so the global cap is exact and fail-closed.
    scheduleBackground(processJob(job.id as string, body, 1));
    if (Math.random() < fallbackSweepProbability) scheduleBackground(sweepOldJobs());
  }
  return json(job.status === "completed" ? 200 : 202, publicJob(job));
}

async function fingerprintOf(body: unknown): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(body)));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function liveJobMatching(owner: string, clientRequestID: string, fingerprint: string) {
  const { data } = await database
    .from("analysis_jobs")
    .select(jobColumns)
    .eq("owner_account_id", owner)
    .eq("client_request_id", clientRequestID)
    .eq("fingerprint", fingerprint)
    .in("status", liveStatuses)
    .maybeSingle();
  return data;
}

async function createJob(request: Request, identity: AnalysisIdentity): Promise<Response> {
  const owner = identity.accountID;
  let body;
  try {
    body = validatePlantAnalysisRequest(await request.json());
  } catch (validationError) {
    if (validationError instanceof AnalysisRequestValidationError) {
      return failure(422, validationError.message);
    }
    return failure(400, "Invalid request.");
  }
  if (!body.clientRequestID) return failure(422, "Client request id is required for an analysis job.");
  if (!Deno.env.get("GEMINI_API_KEY")) return failure(503, "Plant analysis is not configured.");

  const fingerprint = await fingerprintOf(body);
  if (usesGuestAnalysisQuota(identity)) {
    return await createOrResumeGuestJob(identity, body, fingerprint);
  }

  // A resumed job is the same scan the client already paid for — an app relaunch
  // or a lost response must not cost the account another scan.
  const existing = await liveJobMatching(owner, body.clientRequestID, fingerprint);
  if (existing) {
    return json(existing.status === "completed" ? 200 : 202, publicJob(existing));
  }

  const allowance = await accountScanAllowance(identity);
  if (allowance === "unavailable") {
    return failure(503, "Plant analysis is temporarily unavailable. Your photo is saved. Try again shortly.");
  }
  if (allowance === "limited") {
    return failure(
      429,
      "You've used today's scans. Your photos are saved. Try again tomorrow.",
      { "retry-after": "3600" }
    );
  }

  const { data: created, error: insertError } = await database
    .from("analysis_jobs")
    .insert({
      owner_account_id: owner,
      client_request_id: body.clientRequestID,
      fingerprint,
      status: "queued"
    })
    .select(jobColumns)
    .single();
  if (insertError || !created) {
    // Unique-index race with a concurrent identical create: return that job.
    const raced = await liveJobMatching(owner, body.clientRequestID, fingerprint);
    if (raced) return json(raced.status === "completed" ? 200 : 202, publicJob(raced));
    console.error("analysis job insert failed", insertError?.message);
    return failure(500, "The analysis job could not be created. Please retry.");
  }

  // The photos stay here, in the worker's memory, and are never written down.
  scheduleBackground(processJob(created.id as string, body));
  if (Math.random() < fallbackSweepProbability) scheduleBackground(sweepOldJobs());
  return json(202, publicJob(created));
}

async function readJob(jobID: string, owner: string): Promise<Response> {
  const { data: job } = await database
    .from("analysis_jobs")
    .select(jobColumns)
    .eq("id", jobID)
    .eq("owner_account_id", owner)
    .maybeSingle();
  if (!job) return failure(404, "Analysis job not found.");

  // Watchdog: an instance can be reclaimed mid-analysis, and nothing else would
  // ever settle that job. The worker's own budget expires first, so reaching
  // here means the instance really is gone.
  if (["queued", "analysing"].includes(job.status as string)
    && Date.now() - new Date(job.created_at as string).getTime() > stuckJobMilliseconds) {
    const { data: settled } = await database
      .from("analysis_jobs")
      .update({
        status: "failed",
        message: "Plant analysis timed out. Try again with the saved photos.",
        updated_at: new Date().toISOString()
      })
      .eq("id", jobID)
      .in("status", ["queued", "analysing"])
      .select(jobColumns)
      .maybeSingle();
    if (settled) return json(202, publicJob(settled));
  }

  return json(job.status === "completed" ? 200 : 202, publicJob(job));
}

async function cancelJob(jobID: string, owner: string): Promise<Response> {
  await database
    .from("analysis_jobs")
    .update({ status: "cancelled", updated_at: new Date().toISOString() })
    .eq("id", jobID)
    .eq("owner_account_id", owner)
    .in("status", ["queued", "analysing"]);
  const { data: job } = await database
    .from("analysis_jobs")
    .select(jobColumns)
    .eq("id", jobID)
    .eq("owner_account_id", owner)
    .maybeSingle();
  if (!job) return failure(404, "Analysis job not found.");
  return json(200, publicJob(job));
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  // Route relative to the function slug so gateway path prefixes never matter.
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("analysis") + 1);

  if (request.method === "GET" && route[0] === "health") {
    return json(200, {
      status: "ok",
      service: "grove-analysis",
      geminiConfigured: Boolean(Deno.env.get("GEMINI_API_KEY")),
      model: configuredGeminiModel(),
      thinkingLevel: configuredGeminiThinkingLevel(),
      legacyBearersAllowed: legacyBearersAllowed()
    });
  }

  const appKey = Deno.env.get("GROVE_APP_KEY");
  if (appKey && request.headers.get("x-grove-app-key") !== appKey) {
    return failure(401, "App identification is missing or invalid.");
  }
  const identity = await authenticatedIdentity(request);
  if (!identity) return failure(401, "A bearer token is required.");
  const owner = identity.accountID;

  try {
    if (route[0] !== "jobs") return failure(404, "Route not found.");
    if (request.method === "POST" && route.length === 1) return await createJob(request, identity);
    const jobID = route[1]?.toLowerCase();
    if (jobID && uuidPattern.test(jobID)) {
      if (request.method === "GET") return await readJob(jobID, owner);
      if (request.method === "DELETE") return await cancelJob(jobID, owner);
    }
    return failure(404, "Route not found.");
  } catch (caught) {
    console.error("analysis function error", caught);
    return failure(500, "Plant analysis is temporarily unavailable. Try again with the saved photos.");
  }
});
