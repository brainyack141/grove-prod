// Grove production data-sync API on Supabase Edge Functions.
//
// Speaks the same `/v1` contract as the local dev server (`Backend/server.mjs`),
// but backed by the relational schema in `app` (supabase/migrations) and Supabase
// Storage instead of process memory:
//
//   GET    /api/health                      unauthenticated health probe
//   GET    /api/v1/bootstrap                full account snapshot
//   DELETE /api/v1/account                  delete auth identity + all Grove data
//   PATCH  /api/v1/profile                  profile + Grove privacy + location
//   PATCH  /api/v1/journey-progress         streak, XP, badges and Journey state
//   POST   /api/v1/plants                   adopt a plant (idempotent by client id)
//   POST   /api/v1/plants/:id/delete        remove an owned plant
//   POST   /api/v1/plants/:id/check-ins     record a check-in
//   POST   /api/v1/care-actions             record care performed outside a task
//   PATCH  /api/v1/care-actions/:id         complete / snooze a care task
//   POST   /api/v1/care-actions/:id/delete  undo directly recorded care
//   POST   /api/v1/friendships/invitations  invite a friend by username
//   POST   /api/v1/friendships/:id/respond  accept or decline an invitation
//   POST   /api/v1/friendships/:id/withdraw take back an invitation you sent
//   POST   /api/v1/friendships/:id/block     block a connected account
//   POST   /api/v1/friendships/:id/report    report and block an account
//   POST   /api/v1/sitting-assignments      create a plant-sitting assignment
//   POST   /api/v1/sitting-invites          mint a shareable sitting link
//   POST   /api/v1/sitting-invites/:id/revoke  stop a sitting link opening
//   POST   /api/v1/media/uploads            negotiate a signed Storage upload
//   POST   /api/v1/media/:id/complete       verify checksum, mark media ready
//   POST   /api/v1/devices                  register this phone for push
//   DELETE /api/v1/devices/:token           stop sending push to this phone
//
// Identity: callers present a Supabase Auth JWT. Local-only accounts (guest and
// demo) never sync — the iOS factory only builds a sync client for Supabase-backed
// sessions. Every transaction sets `app.account_id` so the row-level policies in
// the schema apply to API queries exactly as they do to direct PostgREST access,
// and every query is additionally scoped to the verified account explicitly.
//
// Dates: the iOS client decodes ISO8601 *without* fractional seconds, so every
// emitted timestamp goes through `iso()`.

import { createClient } from "npm:@supabase/supabase-js@2";
import postgres from "npm:postgres";
import {
  AccountDeletionFailure,
  deleteAccountData
} from "../_shared/account-deletion.mjs";
import {
  bootstrapHistoryLimit,
  windowRows
} from "../_shared/bootstrap-history.mjs";
import { type PushPayload, sendPush } from "../_shared/apns.ts";

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const mediaBucket = "plant-media";
const usernamePattern = /^[a-z0-9_]{3,24}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const healthBands = ["thriving", "healthy", "monitor", "attention", "urgent"];
const careKinds = [
  "checkIn", "inspectSoil", "water", "fertilise", "rotate", "cleanLeaves",
  "treat", "prune", "repot", "relocate", "monitor"
];
const clientAssignmentStatuses = ["invited", "upcoming", "active", "completed", "declined", "revoked"];
const friendReportReasons = new Set(["harassment", "impersonation", "spam", "inappropriateProfile", "other"]);
const blockedProfileWords = new Set([
  "cunt", "faggot", "fag", "kike", "nigger", "nigga", "retard", "whore"
]);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } }
);

// Transaction pooler connection; `prepare: false` because the pooler cannot serve
// prepared statements. Kept tiny — each edge instance is short-lived.
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  ssl: "require",
  prepare: false,
  max: 2,
  idle_timeout: 20,
  connect_timeout: 10
});

function iso(value: unknown = new Date()): string {
  const date = value instanceof Date ? value : new Date(String(value));
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function json(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

function failure(status: number, message: string): Response {
  return json(status, { message });
}

function containsBlockedProfileLanguage(value: string): boolean {
  const words = value.normalize("NFKC").toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
  return words.some((word) => blockedProfileWords.has(word));
}

class RequestBodyTooLargeError extends Error {}

async function boundedRequestText(request: Request, maximumBytes = 1_000_000): Promise<string> {
  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new RequestBodyTooLargeError();
  }
  if (!request.body) return "";

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteCount += value.byteLength;
    if (byteCount > maximumBytes) {
      await reader.cancel();
      throw new RequestBodyTooLargeError();
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function lower(id: unknown): string {
  return String(id ?? "").toLowerCase();
}

function initialsOf(name: string): string {
  const parts = String(name ?? "").trim().split(/\s+/).filter(Boolean);
  const initials = parts.slice(0, 2).map((part) => part[0]).join("").toUpperCase();
  return initials || "G";
}

function bandTitle(band: string): string {
  switch (band) {
    case "thriving": return "Thriving";
    case "healthy": return "Healthy";
    case "monitor": return "Keep an eye on it";
    case "attention": return "Needs attention";
    case "urgent": return "Urgent";
    default: return "Healthy";
  }
}

function healthBandForScore(score: number): string {
  if (score >= 90) return "thriving";
  if (score >= 75) return "healthy";
  if (score >= 55) return "monitor";
  if (score >= 30) return "attention";
  return "urgent";
}

function plantStateFor(band: string): string {
  switch (band) {
    case "thriving":
    case "healthy": return "healthy";
    case "monitor": return "monitor";
    case "attention": return "recovering";
    case "urgent": return "urgent";
    default: return "healthy";
  }
}

function clientLifecycle(state: unknown): string {
  switch (state) {
    case "dormant": return "dormant";
    case "archived": return "archived";
    case "deceased": return "deceased";
    default: return "active";
  }
}

function serverLifecycle(lifecycle: unknown, band: string): string {
  switch (lifecycle) {
    case "dormant": return "dormant";
    case "archived": return "archived";
    case "deceased": return "deceased";
    default: return plantStateFor(band);
  }
}

function daysFromNow(days: number): Date {
  return new Date(Date.now() + days * 86_400_000);
}

function clampFollowUpDays(value: unknown): number {
  const days = Number.isFinite(Number(value)) ? Number(value) : 14;
  return Math.min(Math.max(Math.round(days), 1), 30);
}

function validTimeZoneIdentifier(value: unknown): string {
  const identifier = String(value ?? "UTC").trim().slice(0, 128) || "UTC";
  try {
    new Intl.DateTimeFormat("en", { timeZone: identifier }).format(new Date());
    return identifier;
  } catch {
    return "UTC";
  }
}

function carePlanActions(value: unknown): Row[] {
  const plan = jsonbValue(value);
  if (!Array.isArray(plan.actions)) return [];
  const seen = new Set<string>();
  return plan.actions.flatMap((raw: unknown) => {
    const action = jsonbValue(raw);
    const id = lower(action.id);
    const instruction = String(action.instruction ?? "").trim().slice(0, 2_000);
    if (!uuidPattern.test(id) || seen.has(id) || !careKinds.includes(action.kind) || !instruction) return [];
    seen.add(id);
    const dueFrom = action.dueFrom && Number.isFinite(new Date(action.dueFrom).getTime())
      ? new Date(action.dueFrom)
      : null;
    const dueUntil = action.dueUntil && Number.isFinite(new Date(action.dueUntil).getTime())
      ? new Date(action.dueUntil)
      : null;
    const completedAt = action.completedAt && Number.isFinite(new Date(action.completedAt).getTime())
      ? new Date(action.completedAt)
      : null;
    const status = ["proposed", "due", "completed", "skipped"].includes(action.state)
      ? action.state
      : "proposed";
    return [{ id, kind: action.kind, instruction, dueFrom, dueUntil, completedAt, status }];
  }).slice(0, 100);
}

async function syncCarePlanActions(tx: Tx, plantID: string, previousPlan: unknown, nextPlan: unknown): Promise<void> {
  const previous = carePlanActions(previousPlan);
  const next = carePlanActions(nextPlan);
  const nextIDs = new Set(next.map((action) => action.id));
  const removedIDs = previous.map((action) => action.id).filter((id) => !nextIDs.has(id));

  for (const action of next) {
    await tx`
        insert into app.care_actions (
          id, plant_id, kind, instructions, status, due_from, due_until, performed_at
        ) values (
          ${action.id}, ${plantID}, ${action.kind}, ${action.instruction},
          ${action.status}::app.care_action_status, ${action.dueFrom}, ${action.dueUntil},
          ${action.status === "completed" ? action.completedAt ?? new Date() : null}
        )
        on conflict (id) do update
        set kind = excluded.kind,
            instructions = excluded.instructions,
            status = case
              when app.care_actions.status = 'completed' then app.care_actions.status
              else excluded.status
            end,
            due_from = excluded.due_from,
            due_until = excluded.due_until,
            performed_at = case
              when app.care_actions.status = 'completed' then app.care_actions.performed_at
              else excluded.performed_at
            end
        where app.care_actions.plant_id = ${plantID}`;
  }

  if (removedIDs.length) {
    await tx`
        update app.care_actions
        set status = 'superseded'
        where plant_id = ${plantID}
          and id = any(${removedIDs}::uuid[])
          and status in ('proposed', 'due')`;
  }
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
type Tx = postgres.TransactionSql;

// jsonb columns can surface as raw strings depending on the driver/pooler
// combination, so every jsonb read goes through this.
function jsonbValue(value: unknown): Row {
  if (typeof value === "string") {
    try { return JSON.parse(value); } catch { return {}; }
  }
  return (value as Row) ?? {};
}

function jsonArray(value: unknown): unknown[] {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed : [];
    } catch { return []; }
  }
  return Array.isArray(value) ? value : [];
}

/// Journey state is not an authority boundary, but accepting an arbitrary
/// megabyte-shaped value into every bootstrap is still a reliability hazard.
/// Validate the shipped document's containers and bounded scalar fields while
/// retaining unknown keys so a newer client never loses forward-compatible
/// progress through an older API instance.
function validGardenerProgress(value: unknown): Row | undefined {
  const progress = jsonbValue(value);
  if (!value || Array.isArray(value) || typeof value !== "object") return undefined;

  const integerFields = [
    "xp", "currentStreak", "longestStreak", "streakShields", "lastShieldStreak",
    "questCheckIns", "questCareLogged", "questLessons", "questPlantsAdded"
  ];
  for (const field of integerFields) {
    const candidate = Number(progress[field] ?? 0);
    if (!Number.isSafeInteger(candidate) || candidate < 0 || candidate > 1_000_000_000) {
      return undefined;
    }
  }

  const setFields = [
    "completedMilestoneIDs", "completedInteractiveIDs", "unlockedBadgeIDs",
    "openedChestIDs", "keepsakeIDs", "discoveredLandmarkIDs", "claimedQuestIDs"
  ];
  for (const field of setFields) {
    const values = progress[field] ?? [];
    if (!Array.isArray(values) || values.length > 5_000
        || values.some((item) => typeof item !== "string" || item.length > 160)) {
      return undefined;
    }
  }

  for (const field of ["lastTendDay", "lastRefresherXPDay", "questDay"]) {
    if (progress[field] != null && Number.isNaN(new Date(progress[field]).valueOf())) return undefined;
  }
  const badgeDates = progress.unlockedBadgeDates ?? {};
  if (!badgeDates || Array.isArray(badgeDates) || typeof badgeDates !== "object"
      || Object.keys(badgeDates).length > 5_000
      || Object.entries(badgeDates).some(([key, date]) =>
        key.length > 160 || Number.isNaN(new Date(String(date)).valueOf()))) {
    return undefined;
  }
  return progress;
}

function safeIndicatorReadings(value: unknown): Row[] {
  const orderedKinds = ["moisture", "light", "foliage", "posture", "growth", "care"];
  const kinds = new Set(orderedKinds);
  const levels = new Set(["measured", "observed", "estimated", "unavailable"]);
  const sources = new Set([
    "ownerReport", "photoAnalysis", "speciesGuide", "careHistory",
    "sensor", "legacyInference", "none"
  ]);
  const seen = new Set<string>();
  const byKind = new Map<string, Row>();
  const recordedAt = iso();
  for (const raw of jsonArray(value).slice(0, 12)) {
    const reading = raw as Row;
    const kind = String(reading?.kind ?? "");
    if (!kinds.has(kind) || seen.has(kind)) continue;
    seen.add(kind);
    const rawScore = Number(reading.score);
    const rawConfidence = Number(reading.confidence);
    let evidenceLevel = levels.has(reading.evidenceLevel) ? String(reading.evidenceLevel) : "unavailable";
    let source = sources.has(reading.source) ? String(reading.source) : "none";
    // Source owns the evidence label. This makes it impossible for a synced
    // owner report or guide calculation to be upgraded to an instrument
    // measurement by malformed or stale client data.
    if (source === "sensor") evidenceLevel = "measured";
    else if (source === "ownerReport" || source === "photoAnalysis") evidenceLevel = "observed";
    else if (["speciesGuide", "careHistory", "legacyInference"].includes(source)) evidenceLevel = "estimated";
    else {
      source = "none";
      evidenceLevel = "unavailable";
    }
    const unavailable = evidenceLevel === "unavailable";
    const score = unavailable || reading.score == null || !Number.isFinite(rawScore)
      ? null
      : Math.min(Math.max(Math.round(rawScore), 0), 100);
    const confidence = unavailable || reading.confidence == null || !Number.isFinite(rawConfidence)
      ? null
      : Math.min(Math.max(Math.round(rawConfidence), 0), 100);
    const measuredAt = new Date(reading.measuredAt);
    const validUntil = reading.validUntil == null ? null : new Date(reading.validUntil);
    byKind.set(kind, {
      kind,
      value: unavailable ? "unavailable" : String(reading.value ?? "unavailable").slice(0, 80),
      score,
      status: String(reading.status ?? (unavailable ? "Not read" : "Recorded")).slice(0, 120),
      detail: String(reading.detail ?? "").slice(0, 800),
      evidenceLevel,
      source,
      confidence,
      evidence: unavailable
        ? []
        : jsonArray(reading.evidence).map((item) => String(item).slice(0, 220)).slice(0, 5),
      measuredAt: Number.isNaN(measuredAt.valueOf()) ? recordedAt : iso(measuredAt),
      validUntil: validUntil == null || Number.isNaN(validUntil.valueOf()) ? null : iso(validUntil),
      algorithmVersion: String(reading.algorithmVersion ?? "unknown").slice(0, 100)
    });
  }
  return orderedKinds.map((kind) => byKind.get(kind) ?? ({
    kind,
    value: "unavailable",
    score: null,
    status: "Not read",
    detail: "No evidence was recorded for this indicator.",
    evidenceLevel: "unavailable",
    source: "none",
    confidence: null,
    evidence: [],
    measuredAt: recordedAt,
    validUntil: null,
    algorithmVersion: "unknown"
  }));
}

function checkInFrequencyDays(value: unknown): number | null {
  const days = Number(value);
  return Number.isInteger(days) && days >= 1 && days <= 30 ? days : null;
}

function clientPlant(row: Row): Row {
  const presentation = jsonbValue(row.presentation);
  const environment = jsonbValue(row.environment);
  return {
    id: row.id,
    nickname: row.nickname,
    species: row.common_name ?? "Unknown plant",
    scientificName: row.scientific_name ?? "Species uncertain",
    canonicalTaxonID: presentation.canonicalTaxonID ?? null,
    identityConfirmation: presentation.identityConfirmation ?? null,
    location: presentation.location ?? "Unassigned",
    lightPlacement: environment.lightPlacement ?? null,
    growingConditions: environment.growingConditions ?? null,
    healthScore: row.current_health_score ?? 70,
    healthBand: healthBands.includes(row.current_health_band) ? row.current_health_band : "monitor",
    trend: row.current_trend ?? "baseline",
    confidence: presentation.assessmentConfidence ?? row.identification_confidence ?? 0,
    identificationConfidence: row.identification_confidence ?? null,
    nextCheckIn: iso(row.next_check_in_at ?? daysFromNow(14)),
    symbol: presentation.symbol ?? "leaf.fill",
    palette: presentation.palette ?? "fern",
    summary: presentation.summary ?? "Baseline saved.",
    positiveSigns: presentation.positiveSigns ?? [],
    concerns: presentation.concerns ?? [],
    nextActions: presentation.nextActions ?? [],
    lifecycleState: clientLifecycle(row.state),
    acquiredAt: row.acquired_at ? iso(row.acquired_at) : null,
    notes: presentation.notes ?? null,
    environmentReadings: environment.readings ?? null,
    carePlan: presentation.carePlan ?? null,
    carePlanHistory: presentation.carePlanHistory ?? null,
    assessmentDate: presentation.assessmentDate ? iso(presentation.assessmentDate) : iso(row.updated_at),
    assessmentSource: presentation.assessmentSource ?? "imported",
    healthIndicatorReadings: Array.isArray(presentation.healthIndicatorReadings)
      ? safeIndicatorReadings(presentation.healthIndicatorReadings)
      : null,
    checkInFrequencyDays: checkInFrequencyDays(presentation.checkInFrequencyDays)
  };
}

function clientPlantWithCareActions(row: Row, careActions: Row[]): Row {
  const plant = clientPlant(row);
  const plan = jsonbValue(plant.carePlan);
  if (!Array.isArray(plan.actions)) return plant;
  const actionByID = new Map(
    careActions.filter((action) => action.plant_id === row.id).map((action) => [action.id, action])
  );
  const actions = plan.actions.map((raw: unknown) => {
    const action = jsonbValue(raw);
    const materialized = actionByID.get(lower(action.id));
    if (!materialized || materialized.status !== "completed") return action;
    return {
      ...action,
      state: "completed",
      completedAt: materialized.performed_at ? iso(materialized.performed_at) : action.completedAt ?? iso()
    };
  });
  plant.carePlan = { ...plan, actions };
  plant.nextActions = actions
    .filter((action: Row) => action.state === "proposed" || action.state === "due")
    .map((action: Row) => action.instruction);
  return plant;
}

function clientCareTask(row: Row): Row {
  const isSittingTask = row.is_sitting_task === true || row.completed_via_sitting_link === true;
  return {
    id: row.id,
    plantID: row.plant_id,
    kind: row.kind,
    dueDate: iso(row.due_from ?? row.created_at),
    detail: row.instructions,
    isCompleted: row.status === "completed",
    isSittingTask,
    ownerName: row.owner_name ?? (row.completed_via_sitting_link === true ? "A plant sitter" : null),
    soilMoisture: ["dry", "comfortable", "wet"].includes(row.soil_moisture) ? row.soil_moisture : null,
    completedAt: row.performed_at ? iso(row.performed_at) : null
  };
}

function clientAssignment(
  row: Row,
  plantIDs: string[],
  sitter: Row | undefined,
  owner?: Row,
  viewerAccountID?: string
): Row {
  const sitterName = sitter?.display_name ?? "Plant sitter";
  return {
    id: row.id,
    sitterName,
    sitterInitials: initialsOf(sitterName),
    startDate: iso(row.starts_at),
    endDate: iso(row.ends_at),
    plantIDs,
    status: clientAssignmentStatuses.includes(row.status) ? row.status : "completed",
    completedTasks: row.completed_tasks ?? 0,
    totalTasks: row.total_tasks ?? Math.max(1, plantIDs.length * 2),
    // Stored on insert but never returned, so the permission the owner chose
    // vanished from their own copy of the assignment on the next bootstrap.
    canCheckIn: row.can_check_in !== false,
    canLogCare: row.can_log_care !== false,
    ownerNotes: row.owner_notes ?? null,
    timeZoneIdentifier: validTimeZoneIdentifier(row.time_zone_identifier),
    ownerName: owner?.display_name ?? null,
    isIncoming: viewerAccountID != null && row.sitter_account_id === viewerAccountID
  };
}

function clientSittingPlant(row: Row): Row {
  const plant = clientPlant(row);
  return {
    id: plant.id,
    nickname: plant.nickname,
    species: plant.species,
    symbol: plant.symbol,
    palette: plant.palette,
    healthBand: plant.healthBand
  };
}

function clientSittingInvite(row: Row): Row {
  return {
    id: row.id,
    sitterLabel: row.label,
    startDate: iso(row.starts_at),
    endDate: iso(row.ends_at),
    plantIDs: row.plant_ids ?? [],
    canLogCare: row.can_log_care !== false,
    ownerNotes: row.owner_notes ?? null,
    timeZoneIdentifier: validTimeZoneIdentifier(row.time_zone_identifier),
    shareURL: null,
    createdAt: iso(row.created_at),
    revokedAt: row.revoked_at ? iso(row.revoked_at) : null,
    lastOpenedAt: row.last_opened_at ? iso(row.last_opened_at) : null,
    openCount: Number(row.open_count ?? 0),
    completedCareCount: Number(row.completed_care_count ?? 0),
    wasMinted: true
  };
}

function clientProfile(account: Row, friendCount: number, isPrivate: boolean): Row {
  const location = account.latitude != null && account.longitude != null && account.location_label
    ? {
        latitude: Number(account.latitude),
        longitude: Number(account.longitude),
        label: account.location_label,
        countryCode: account.location_country_code ?? null,
        timeZoneIdentifier: account.location_time_zone_identifier ?? null
      }
    : null;
  return {
    name: account.display_name,
    username: account.username,
    initials: initialsOf(account.display_name),
    friendCount,
    regionCode: account.region_code,
    usesMetricSystem: account.uses_metric_system ?? true,
    isPrivate,
    location
  };
}

function clientInvitation(row: Row, me: string, other: Row | undefined): Row {
  const outgoing = row.requested_by_account_id === me;
  const name = other?.display_name ?? `@${other?.username ?? "gardener"}`;
  return {
    id: row.id,
    accountID: outgoing ? row.requested_to_account_id : row.requested_by_account_id,
    name,
    username: other?.username ?? "gardener",
    initials: initialsOf(name),
    direction: outgoing ? "outgoing" : "incoming",
    createdAt: iso(row.created_at)
  };
}

async function sha256Hex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

// 256 bits, base64url. The only defence the public care sheet has is that this
// cannot be guessed, so it comes from the CSPRNG and is never shortened.
function mintSittingToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

// Where a sitting link points. Overridable so a custom domain can front the
// `sit` function without the app needing to know.
function sittingLinkURL(token: string): string {
  const base = Deno.env.get("GROVE_SIT_BASE_URL")
    ?? `${Deno.env.get("SUPABASE_URL")}/functions/v1/sit`;
  return `${base.replace(/\/+$/, "")}/${token}`;
}

// The acting account for this transaction: RLS policies read `app.account_id`
// (transaction-local, so pooled connections never leak scope across requests).
function withAccount<T>(accountID: string, work: (tx: Tx) => Promise<T>): Promise<T> {
  return sql.begin(async (tx) => {
    await tx`select set_config('app.account_id', ${accountID}, true)`;
    return work(tx as Tx);
  }) as Promise<T>;
}

async function verifiedAccountID(request: Request): Promise<string | undefined> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return undefined;
  const token = authorization.slice("Bearer ".length).trim();
  if (!token) return undefined;
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user?.id) return undefined;
  return data.user.id;
}

function scheduleBackground(work: Promise<unknown>) {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(work);
}

// ---------------------------------------------------------------------------
// Push
//
// Grove's own notifications were entirely local before this, which meant the
// app could only tell someone about their own schedule. Everything below is the
// other half: the things that happen because *another person* acted, which the
// owner otherwise would not learn about until they next opened the app.
//
// Copy follows the same three rules as the local reminders (see
// `NotificationService.swift` and COPY.md): name the plant, never instruct a
// blind watering, and never scold. A push is a lock screen like any other.

/// Sends to every device an account has registered, and forgets the ones Apple
/// says are gone.
///
/// Never throws. Callers hand this to `scheduleBackground`, so a failure here
/// is invisible to the mutation that triggered it — which is the point: nobody
/// accepting a friend request should see an error because Apple was slow.
async function notify(accountID: string, payload: PushPayload): Promise<void> {
  try {
    const devices = await sql<{ token: string; environment: string }[]>`
        select token, environment from app.device_tokens where account_id = ${accountID}`;
    const dead = await sendPush(devices, payload);
    if (dead.length) {
      await sql`delete from app.device_tokens where token = any(${dead}::text[])`;
    }
  } catch (caught) {
    console.error("push: notify failed", caught);
  }
}

/// What one gardener is called on another gardener's lock screen.
async function displayNameOf(accountID: string): Promise<string> {
  try {
    const [account] = await sql`select display_name from app.accounts where id = ${accountID}`;
    return String(account?.display_name ?? "A gardener");
  } catch {
    return "A gardener";
  }
}

/// Records the token this phone can be reached at.
///
/// Upserts on the token rather than the pair, so signing a second account into
/// the same iPhone moves the row instead of leaving that phone subscribed to
/// both. Hand-me-down and shared phones are ordinary, and the failure mode is
/// showing one person another person's notifications.
async function registerDevice(me: string, body: Row): Promise<Response> {
  const token = String(body.token ?? "").trim().toLowerCase();
  if (!/^[0-9a-f]{16,200}$/.test(token)) return failure(422, "That device token could not be read.");
  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const sittingUpdatesEnabled = body.sittingUpdatesEnabled !== false;
  await sql`
      insert into app.device_tokens (token, account_id, environment, sitting_updates_enabled)
      values (${token}, ${me}, ${environment}, ${sittingUpdatesEnabled})
      on conflict (token) do update
      set account_id = excluded.account_id,
          environment = excluded.environment,
          sitting_updates_enabled = excluded.sitting_updates_enabled,
          last_seen_at = now()`;
  return json(200, {});
}

/// Stops sending to this phone. Scoped to the caller so one account cannot
/// unregister another's device, and a token that is already gone is a success —
/// the client calls this during sign-out and must not be blocked by it.
async function unregisterDevice(me: string, tokenRaw: string): Promise<Response> {
  const token = tokenRaw.trim().toLowerCase();
  await sql`delete from app.device_tokens where token = ${token} and account_id = ${me}`;
  return json(200, {});
}

// ---------------------------------------------------------------------------
// Bootstrap

async function bootstrap(me: string): Promise<Response> {
  const snapshot = await withAccount(me, async (tx) => {
    // Compatibility for clients released before signup completion became an
    // explicit server-owned boundary. Reaching authenticated bootstrap means
    // that client already accepted signup and established this account; a
    // wrong-door identity is held while signed out and never reaches here.
    await tx`
      update app.accounts
      set signup_completed_at = coalesce(signup_completed_at, now())
      where id = ${me} and signup_completed_at is null`;
    const [account] = await tx`select * from app.accounts where id = ${me}`;
    if (!account) return undefined;

    const memberships = await tx`select grove_id, role from app.grove_memberships where account_id = ${me}`;
    const groveIDs = memberships.map((row: Row) => row.grove_id);
    const [ownGrove] = await tx`select id, is_private from app.groves where owner_account_id = ${me} limit 1`;

    const plants = groveIDs.length
      ? await tx`
          select * from app.plants
          where grove_id = any(${groveIDs}::uuid[]) and archived_at is null
          order by created_at desc`
      : [];
    const plantIDs = plants.map((row: Row) => row.id);

    // Open care is what makes Today work, so it is never truncated — an
    // account's proposed/due actions are naturally bounded. Completed care is
    // history and is sent as a newest-first window; the extra row is a
    // completeness sentinel. Ordering the old combined query oldest-first with
    // a cap dropped the *newest* rows, including currently-due tasks.
    const openTasks = plantIDs.length
      ? await tx`
          select action.*,
                 exists (
                   select 1 from app.sitting_invite_care_log log
                   where log.care_action_id = action.id
                 ) as completed_via_sitting_link
          from app.care_actions action
          where action.plant_id = any(${plantIDs}::uuid[])
            and action.status in ('proposed', 'due')
          order by action.due_from asc nulls last`
      : [];
    const completedTaskRows = plantIDs.length
      ? await tx`
          select action.*,
                 exists (
                   select 1 from app.sitting_invite_care_log log
                   where log.care_action_id = action.id
                 ) as completed_via_sitting_link
          from app.care_actions action
          where action.plant_id = any(${plantIDs}::uuid[])
            and action.status = 'completed'
          order by coalesce(action.performed_at, action.due_from) desc nulls last
          limit ${bootstrapHistoryLimit + 1}`
      : [];
    const completedTasks = windowRows(completedTaskRows);
    const tasks = [...openTasks, ...completedTasks.rows];

    const activity = await tx`
        select * from app.activity_events
        where actor_account_id = ${me}
           or (grove_id is not null and grove_id = any(${groveIDs}::uuid[]))
        order by created_at desc
        limit 200`;

    const assignments = await tx`
        select * from app.sitting_assignments
        where owner_account_id = ${me}
           or (
                sitter_account_id = ${me}
            and status in ('invited', 'upcoming', 'active')
            and revoked_at is null
            and ends_at > now()
           )
        order by created_at desc
        limit 100`;
    const sittingInvites = await tx`
        select invite.*, coalesce(
                 (select array_agg(scope.plant_id order by scope.plant_id)
                    from app.sitting_invite_plants scope
                   where scope.invite_id = invite.id),
                 '{}'
               ) as plant_ids,
               (select count(*)::int
                  from app.sitting_invite_care_log care_log
                 where care_log.invite_id = invite.id) as completed_care_count
          from app.sitting_invites invite
         where invite.owner_account_id = ${me}
         order by (invite.revoked_at is null and invite.ends_at >= now()) desc,
                  coalesce(invite.revoked_at, invite.created_at) desc
         limit 500`;
    const assignmentIDs = assignments.map((row: Row) => row.id);
    const assignmentPlants = assignmentIDs.length
      ? await tx`select assignment_id, plant_id from app.sitting_assignment_plants where assignment_id = any(${assignmentIDs}::uuid[])`
      : [];
    const participantIDs = [...new Set(assignments.flatMap((row: Row) => [
      row.sitter_account_id,
      row.owner_account_id
    ]))];
    const assignmentParticipants = participantIDs.length
      ? await tx`select id, display_name from app.accounts where id = any(${participantIDs}::uuid[])`
      : [];

    // An accepted account handover exposes a small care dashboard only while
    // its real window is active. It deliberately does not reuse `clientPlant`'s
    // full owner record: a sitter needs identity, health and the assigned care,
    // not private notes, history, environment readings or diagnosis detail.
    const activeIncomingAssignmentIDs = assignments
      .filter((row: Row) => row.sitter_account_id === me
        && ["upcoming", "active"].includes(row.status)
        && row.revoked_at == null
        && new Date(row.starts_at).getTime() <= Date.now()
        && new Date(row.ends_at).getTime() > Date.now())
      .map((row: Row) => row.id);
    const sittingPlants = activeIncomingAssignmentIDs.length
      ? await tx`
          select distinct on (plant.id) plant.*
          from app.plants plant
          join app.sitting_assignment_plants scope on scope.plant_id = plant.id
          where scope.assignment_id = any(${activeIncomingAssignmentIDs}::uuid[])
            and plant.archived_at is null
          order by plant.id, plant.updated_at desc`
      : [];
    const sittingTasks = activeIncomingAssignmentIDs.length
      ? await tx`
          select distinct on (action.id) action.*, true as is_sitting_task,
                 owner.display_name as owner_name
          from app.care_actions action
          join app.sitting_assignment_plants scope on scope.plant_id = action.plant_id
          join app.sitting_assignments assignment on assignment.id = scope.assignment_id
          join app.accounts owner on owner.id = assignment.owner_account_id
          where assignment.id = any(${activeIncomingAssignmentIDs}::uuid[])
            and assignment.can_log_care = true
            and (
              action.status in ('proposed', 'due')
              or (
                action.status = 'completed'
                and action.performed_by_account_id = ${me}
                and action.performed_at >= assignment.starts_at
              )
            )
            and coalesce(action.due_from, now()) <= assignment.ends_at
            and (action.kind not in ('checkIn', 'check_in') or assignment.can_check_in = true)
          order by action.id, action.due_from asc nulls last
          limit 500`
      : [];

    const observationRows = plantIDs.length
      ? await tx`
          select observation.*, actor.display_name as actor_display_name,
                 assessment.provider_name as assessment_provider_name,
                 assessment.provider_version as assessment_provider_version,
                 assessment.confidence as assessment_confidence,
                 assessment.findings as assessment_findings,
                 assessment.limitations as assessment_limitations
          from app.observations observation
          left join app.accounts actor on actor.id = observation.performed_by_account_id
          left join lateral (
            select provider_name, provider_version, confidence, findings, limitations
            from app.health_assessments
            where observation_id = observation.id
            order by created_at desc
            limit 1
          ) assessment on true
          where observation.plant_id = any(${plantIDs}::uuid[])
          order by observation.observed_at desc
          limit ${bootstrapHistoryLimit + 1}`
      : [];
    const observationWindow = windowRows(observationRows);
    const observations = observationWindow.rows;
    const observationIDs = observations.map((row: Row) => row.id);
    const observationMedia = observationIDs.length
      ? await tx`
          select om.observation_id, asset.storage_key
          from app.observation_media om
          join app.media_assets asset on asset.id = om.media_asset_id
          where om.observation_id = any(${observationIDs}::uuid[])
            and asset.deleted_at is null and asset.status = 'ready'
          order by om.sort_order asc`
      : [];

    const friendships = await tx`
        select * from app.friendships
        where status in ('accepted', 'pending')
          and (requested_by_account_id = ${me} or requested_to_account_id = ${me})`;
    const counterpartIDs = friendships.map((row: Row) =>
      row.requested_by_account_id === me ? row.requested_to_account_id : row.requested_by_account_id
    );
    const counterparts = counterpartIDs.length
      ? await tx`select id, username, display_name, updated_at from app.accounts where id = any(${counterpartIDs}::uuid[])`
      : [];

    return {
      account, ownGrove, plants, tasks,
      tasksComplete: completedTasks.complete,
      activity, assignments, assignmentPlants,
      assignmentParticipants, sittingPlants, sittingTasks, sittingInvites,
      observations,
      observationsComplete: observationWindow.complete,
      observationMedia, friendships, counterparts
    };
  });

  if (!snapshot) {
    return failure(503, "Your account is still being set up. Try again in a moment.");
  }

  // Time-limited signed URLs for observation photos, one Storage call for all.
  const photoByObservation = new Map<string, string>();
  const storageKeys = [...new Set(snapshot.observationMedia.map((row: Row) => row.storage_key as string))];
  if (storageKeys.length) {
    const { data: signed } = await supabase.storage.from(mediaBucket).createSignedUrls(storageKeys, 7 * 24 * 3600);
    const urlByKey = new Map<string, string>();
    signed?.forEach((entry, index) => {
      if (entry?.signedUrl) urlByKey.set(storageKeys[index], entry.signedUrl);
    });
    for (const row of snapshot.observationMedia as Row[]) {
      if (!photoByObservation.has(row.observation_id) && urlByKey.has(row.storage_key)) {
        photoByObservation.set(row.observation_id, urlByKey.get(row.storage_key)!);
      }
    }
  }

  const counterpartByID = new Map<string, Row>((snapshot.counterparts as Row[]).map((row) => [row.id, row]));
  const participantByID = new Map<string, Row>(
    (snapshot.assignmentParticipants as Row[]).map((row) => [row.id, row])
  );
  const plantIDsByAssignment = new Map<string, string[]>();
  for (const row of snapshot.assignmentPlants as Row[]) {
    const list = plantIDsByAssignment.get(row.assignment_id) ?? [];
    list.push(row.plant_id);
    plantIDsByAssignment.set(row.assignment_id, list);
  }

  const accepted = (snapshot.friendships as Row[]).filter((row) => row.status === "accepted");
  const friends = accepted.flatMap((row) => {
    const otherID = row.requested_by_account_id === me ? row.requested_to_account_id : row.requested_by_account_id;
    const other = counterpartByID.get(otherID);
    if (!other) return [];
    return [{
      id: otherID,
      name: other.display_name,
      username: other.username,
      initials: initialsOf(other.display_name),
      sharedPlantCount: 0,
      lastActiveAt: iso(other.updated_at),
      sharedPlants: []
    }];
  });

  const friendInvitations = (snapshot.friendships as Row[])
    .filter((row) => row.status === "pending")
    .map((row) => {
      const otherID = row.requested_by_account_id === me ? row.requested_to_account_id : row.requested_by_account_id;
      return clientInvitation(row, me, counterpartByID.get(otherID));
    });

  const observations = (snapshot.observations as Row[]).map((row) => {
    const answers = jsonbValue(row.answers);
    const findings = jsonbValue(row.assessment_findings);
    const score = Number(answers.score ?? 70);
    return {
      id: row.id,
      plantID: row.plant_id,
      createdAt: iso(row.observed_at),
      previousScore: Number(answers.previousScore ?? score),
      score,
      band: healthBands.includes(answers.band) ? answers.band : "monitor",
      note: row.note ?? "",
      appearance: ["better", "same", "worse"].includes(answers.appearance) ? answers.appearance : "same",
      soilMoisture: ["dry", "comfortable", "wet"].includes(answers.soilMoisture) ? answers.soilMoisture : "comfortable",
      hasNewGrowth: answers.hasNewGrowth === true,
      photoURL: photoByObservation.get(row.id) ?? null,
      actorName: row.performed_by_account_id === me ? "You" : (row.actor_display_name ?? "A plant sitter"),
      isEstimated: answers.isEstimated === true || findings.isEstimated === true,
      confidence: row.assessment_confidence ?? answers.confidence ?? null,
      actionability: findings.actionability ?? answers.actionability ?? null,
      assessmentAvailable: findings.assessmentAvailable ?? answers.assessmentAvailable ?? null,
      analysisVersion: row.assessment_provider_version ?? answers.analysisVersion ?? null,
      providerName: row.assessment_provider_name ?? answers.providerName ?? null,
      limitations: jsonArray(row.assessment_limitations).length
        ? jsonArray(row.assessment_limitations)
        : jsonArray(answers.limitations),
      referenceObservationID: findings.referenceObservationID ?? answers.referenceObservationID ?? null,
      indicatorReadings: safeIndicatorReadings(
        findings.indicatorReadings ?? answers.indicatorReadings
      )
    };
  });

  return json(200, {
    profile: clientProfile(snapshot.account, friends.length, snapshot.ownGrove?.is_private ?? true),
    gardener: snapshot.account.gardener_progress == null
      ? null
      : jsonbValue(snapshot.account.gardener_progress),
    gardenerUpdatedAt: snapshot.account.gardener_progress_updated_at == null
      ? null
      : iso(snapshot.account.gardener_progress_updated_at),
    plants: (snapshot.plants as Row[]).map((row) =>
      clientPlantWithCareActions(row, snapshot.tasks as Row[])
    ),
    tasks: (snapshot.tasks as Row[]).map(clientCareTask),
    activity: (snapshot.activity as Row[]).map((row) => {
      // Public sitting links have no Grove account. Their rows keep a null
      // account id plus the sitter label. An ordinary self-authored row may
      // still carry the owner's display name; that must remain viewer-relative
      // "You" or it would light the Updates badge for the user's own action.
      const externalActor = !row.actor_account_id && Boolean(row.actor_name);
      const actorName = externalActor
        ? row.actor_name
        : (row.actor_account_id === me
          ? "You"
          : (row.actor_name ?? counterpartByID.get(row.actor_account_id)?.display_name ?? "A gardener"));
      return {
        id: row.id,
        kind: row.kind,
        actorName,
        actorInitials: externalActor
          ? (row.actor_initials ?? initialsOf(row.actor_name))
          : (row.actor_account_id === me
            ? initialsOf(snapshot.account.display_name)
            : (row.actor_initials ?? initialsOf(actorName))),
        message: row.message,
        plantID: row.plant_id,
        timestamp: iso(row.created_at)
      };
    }),
    assignments: (snapshot.assignments as Row[]).map((row) =>
      clientAssignment(
        row,
        plantIDsByAssignment.get(row.id) ?? [],
        participantByID.get(row.sitter_account_id),
        participantByID.get(row.owner_account_id),
        me
      )
    ),
    sittingPlants: (snapshot.sittingPlants as Row[]).map(clientSittingPlant),
    sittingTasks: (snapshot.sittingTasks as Row[]).map(clientCareTask),
    sittingInvites: (snapshot.sittingInvites as Row[]).map(clientSittingInvite),
    observations,
    diagnoses: (snapshot.plants as Row[]).flatMap((row) => {
      const saved = jsonbValue(row.presentation).diagnoses;
      return Array.isArray(saved) ? saved : [];
    }),
    friends,
    friendInvitations,
    // Whether each history list above is the complete set or only its newest
    // window. The client keeps local rows the window omitted when false.
    tasksComplete: snapshot.tasksComplete,
    observationsComplete: snapshot.observationsComplete,
    serverTime: iso()
  });
}

// ---------------------------------------------------------------------------
// Mutations

async function createPlant(me: string, body: Row): Promise<Response> {
  const plantID = lower(body.clientPlantID);
  if (!uuidPattern.test(plantID) || !body.nickname) {
    return failure(422, "Plant ID and nickname are required.");
  }
  const identification = body.analysis?.identification ?? {};
  const condition = body.analysis?.condition ?? {};
  const client = body.plant ?? {};
  const followUpDays = clampFollowUpDays(condition.followUpDays);
  const band = healthBands.includes(client.healthBand)
    ? client.healthBand
    : (healthBands.includes(condition.healthBand) ? condition.healthBand : "healthy");

  const result = await withAccount(me, async (tx) => {
    const [existing] = await tx`select * from app.plants where id = ${plantID}`;
    if (existing) {
      const [existingMembership] = await tx`
          select 1 from app.grove_memberships
          where grove_id = ${existing.grove_id} and account_id = ${me}`;
      return existingMembership ? { status: 200, plant: existing } : { status: 409 };
    }

    const [membership] = await tx`
        select membership.grove_id
        from app.grove_memberships membership
        join app.groves grove on grove.id = membership.grove_id
        where membership.account_id = ${me} and grove.owner_account_id = ${me}
        limit 1`;
    if (!membership) return { status: 503 };

    const nextCheckIn = client.nextCheckIn ? new Date(client.nextCheckIn) : daysFromNow(followUpDays);
    const presentation = {
      location: client.location ?? body.location ?? "Unassigned",
      symbol: client.symbol ?? "leaf.fill",
      palette: client.palette ?? "fern",
      summary: client.summary ?? condition.summary ?? "Baseline saved.",
      positiveSigns: client.positiveSigns ?? condition.positiveSigns ?? [],
      concerns: client.concerns ?? condition.concerns ?? [],
      nextActions: client.nextActions ?? condition.nextActions ?? [],
      notes: client.notes ?? null,
      carePlan: client.carePlan ?? null,
      carePlanHistory: client.carePlanHistory ?? [],
      assessmentConfidence: client.confidence ?? condition.confidence ?? 0,
      assessmentDate: client.assessmentDate ?? new Date().toISOString(),
      assessmentSource: client.assessmentSource ?? "baselinePhoto",
      canonicalTaxonID: client.canonicalTaxonID ?? identification.canonicalTaxonID ?? null,
      identityConfirmation: client.identityConfirmation ?? identification.identityConfirmation
        ?? (identification.isUnknown ? "unknown" : "photoMatch"),
      healthIndicatorReadings: safeIndicatorReadings(client.healthIndicatorReadings),
      checkInFrequencyDays: checkInFrequencyDays(client.checkInFrequencyDays)
    };
    const environment = {
      lightPlacement: client.lightPlacement ?? null,
      growingConditions: client.growingConditions ?? null,
      readings: client.environmentReadings ?? []
    };
    const [plant] = await tx`
        insert into app.plants (
          id, grove_id, nickname, common_name, scientific_name, identification_confidence,
          state, current_health_score, current_health_band, current_trend, next_check_in_at,
          acquired_at, environment, presentation
        ) values (
          ${plantID}, ${membership.grove_id}, ${client.nickname ?? body.nickname},
          ${client.species ?? identification.commonName ?? "Unknown plant"},
          ${client.scientificName ?? identification.scientificName ?? "Species uncertain"},
          ${Math.min(Math.max(Number(client.identificationConfidence ?? identification.confidence ?? 0), 0), 100)},
          ${serverLifecycle(client.lifecycleState, band)},
          ${Math.min(Math.max(Number(client.healthScore ?? condition.healthScore ?? 70), 0), 100)},
          ${band}, ${client.trend ?? "baseline"}, ${nextCheckIn},
          ${client.acquiredAt ? new Date(client.acquiredAt) : new Date()},
          ${environment}::jsonb, ${presentation}::jsonb
        )
        returning *`;

    await tx`
        insert into app.care_actions (plant_id, kind, instructions, status, due_from)
        values (${plantID}, ${"checkIn"}, ${"Take a new photo and compare it with today’s baseline."}, ${"due"}, ${nextCheckIn})`;
    await syncCarePlanActions(tx, plantID, null, client.carePlan);

    if (uuidPattern.test(lower(body.mediaDraftID))) {
      await tx`
          update app.media_assets set plant_id = ${plantID}
          where owner_account_id = ${me} and local_media_id = ${lower(body.mediaDraftID)}`;
    }
    return { status: 201, plant };
  });

  if (result.status === 409) return failure(409, "That plant already exists on another account.");
  if (result.status === 503) return failure(503, "Your account is still being set up. Try again in a moment.");
  return json(result.status, clientPlant(result.plant));
}

async function updatePlant(me: string, plantIDRaw: string, body: Row): Promise<Response> {
  const plantID = lower(plantIDRaw);
  const client = body.plant ?? {};
  if (!uuidPattern.test(plantID) || lower(client.id) !== plantID) {
    return failure(422, "Plant identity does not match this record.");
  }

  const result = await withAccount(me, async (tx) => {
    const [existing] = await tx`
        select plant.* from app.plants plant
        join app.grove_memberships membership on membership.grove_id = plant.grove_id
        where plant.id = ${plantID} and membership.account_id = ${me}`;
    if (!existing) return undefined;

    const band = healthBands.includes(client.healthBand) ? client.healthBand : "monitor";
    const presentation: Row = {
      ...jsonbValue(existing.presentation),
      location: client.location ?? "Unassigned",
      symbol: client.symbol ?? "leaf.fill",
      palette: client.palette ?? "fern",
      summary: client.summary ?? "",
      positiveSigns: client.positiveSigns ?? [],
      concerns: client.concerns ?? [],
      nextActions: client.nextActions ?? [],
      notes: client.notes ?? null,
      carePlan: client.carePlan ?? null,
      carePlanHistory: client.carePlanHistory ?? [],
      assessmentConfidence: Math.min(Math.max(Number(client.confidence ?? 0), 0), 100),
      assessmentDate: client.assessmentDate ?? new Date().toISOString(),
      assessmentSource: client.assessmentSource ?? "imported",
      canonicalTaxonID: client.canonicalTaxonID ?? jsonbValue(existing.presentation).canonicalTaxonID ?? null,
      identityConfirmation: client.identityConfirmation
        ?? jsonbValue(existing.presentation).identityConfirmation ?? "unknown",
      healthIndicatorReadings: safeIndicatorReadings(client.healthIndicatorReadings),
      checkInFrequencyDays: checkInFrequencyDays(client.checkInFrequencyDays)
    };
    if (Array.isArray(body.diagnoses)) {
      presentation.diagnoses = body.diagnoses.map((diagnosis: Row) => ({ ...diagnosis, photoURL: null }));
    }
    const environment = {
      ...jsonbValue(existing.environment),
      lightPlacement: client.lightPlacement ?? null,
      growingConditions: client.growingConditions ?? null,
      readings: client.environmentReadings ?? []
    };
    const [updated] = await tx`
        update app.plants
        set nickname = ${String(client.nickname ?? existing.nickname).slice(0, 200)},
            common_name = ${client.species ?? null},
            scientific_name = ${client.scientificName ?? null},
            identification_confidence = ${client.identificationConfidence ?? null},
            state = ${serverLifecycle(client.lifecycleState, band)},
            current_health_score = ${Math.min(Math.max(Number(client.healthScore ?? 70), 0), 100)},
            current_health_band = ${band},
            current_trend = ${client.trend ?? "baseline"},
            next_check_in_at = ${client.nextCheckIn ? new Date(client.nextCheckIn) : existing.next_check_in_at},
            acquired_at = ${client.acquiredAt ? new Date(client.acquiredAt) : null},
            environment = ${environment}::jsonb,
            presentation = ${presentation}::jsonb,
            updated_at = now()
        where id = ${plantID}
        returning *`;
    await syncCarePlanActions(
      tx,
      plantID,
      jsonbValue(existing.presentation).carePlan,
      client.carePlan
    );
    return updated;
  });

  if (!result) return failure(404, "Plant not found.");
  return json(200, clientPlant(result));
}

async function deletePlant(me: string, plantIDRaw: string): Promise<Response> {
  const plantID = lower(plantIDRaw);
  if (!uuidPattern.test(plantID)) return failure(404, "Plant not found.");

  const result = await withAccount(me, async (tx) => {
    const assets = await tx`
        select asset.id, asset.storage_key from app.media_assets asset
        join app.plants plant on plant.id = asset.plant_id
        join app.groves grove on grove.id = plant.grove_id
        where plant.id = ${plantID} and grove.owner_account_id = ${me}`;
    if (assets.length) {
      const assetIDs = assets.map((asset: Row) => asset.id);
      await tx`delete from app.scans where media_asset_id = any(${assetIDs}::uuid[])`;
    }
    await tx`
        delete from app.plants plant using app.groves grove
        where plant.id = ${plantID} and plant.grove_id = grove.id
          and grove.owner_account_id = ${me}`;
    await tx`
        update app.sitting_invites invite
        set revoked_at = coalesce(invite.revoked_at, now())
        where invite.owner_account_id = ${me}
          and invite.revoked_at is null
          and not exists (
            select 1 from app.sitting_invite_plants scope
            where scope.invite_id = invite.id
          )`;
    return assets.map((asset: Row) => asset.storage_key as string);
  });

  // Database ownership and every relational reference are already gone. Object
  // storage cleanup is best-effort and idempotent; a failed remove must never
  // resurrect the plant or block retrying the mutation.
  if (result?.length) await supabase.storage.from(mediaBucket).remove(result);
  return json(200, {});
}

async function createCheckIn(me: string, plantIDRaw: string, body: Row): Promise<Response> {
  const plantID = lower(plantIDRaw);
  const requestedScore = Math.min(Math.max(Math.round(Number(body.score ?? 0)), 0), 100);
  const note = String(body.note ?? "").slice(0, 2000);
  const clientRequestID = lower(body.clientRequestID);
  const mediaDraftID = uuidPattern.test(lower(body.mediaDraftID)) ? lower(body.mediaDraftID) : undefined;
  const isEstimated = body.isEstimated === true;
  const actionability = ["actionable", "provisional", "insufficientEvidence"].includes(body.actionability)
    ? body.actionability
    : null;
  const assessmentAvailable = body.assessmentAvailable !== false;
  const appliesToPlant = body.appliesToPlant !== false
    && !isEstimated
    && assessmentAvailable
    && (actionability == null || actionability === "actionable");
  const confidence = Math.min(Math.max(Math.round(Number(body.confidence ?? 0)), 0), 100);
  const indicatorReadings = safeIndicatorReadings(body.indicatorReadings);
  const followUpDays = clampFollowUpDays(body.followUpDays ?? (appliesToPlant ? 14 : 3));
  // Mirrors the origin device: its local observation id is the photo's media id.
  const observationID = mediaDraftID ?? (uuidPattern.test(clientRequestID) ? clientRequestID : crypto.randomUUID());

  const result = await withAccount(me, async (tx) => {
    const [plant] = await tx`
        select plant.* from app.plants plant
        join app.grove_memberships membership on membership.grove_id = plant.grove_id
        where plant.id = ${plantID} and membership.account_id = ${me}`;
    if (!plant) return { status: 404 };

    const previousScore = plant.current_health_score ?? 70;
    const score = appliesToPlant ? requestedScore : previousScore;
    const band = appliesToPlant
      ? healthBandForScore(score)
      : (healthBands.includes(plant.current_health_band) ? plant.current_health_band : healthBandForScore(previousScore));
    const change = score - previousScore;
    const trend = appliesToPlant
      ? (Math.abs(change) < 3 ? "stable" : change > 0 ? "improving" : "declining")
      : (plant.current_trend ?? "stable");
    const nextCheckIn = daysFromNow(followUpDays);
    const presentationPatch: Row = { healthIndicatorReadings: indicatorReadings };
    if (appliesToPlant) {
      presentationPatch.summary = note;
      presentationPatch.assessmentConfidence = confidence;
      presentationPatch.assessmentDate = new Date().toISOString();
      presentationPatch.assessmentSource = "checkInPhoto";
    }

    const [updated] = await tx`
        update app.plants
        set current_health_score = ${score},
            current_health_band = ${band},
            current_trend = ${trend},
            state = ${appliesToPlant ? plantStateFor(band) : plant.state},
            next_check_in_at = ${nextCheckIn},
            presentation = presentation || ${presentationPatch}::jsonb,
            updated_at = now()
        where id = ${plantID}
        returning *`;

    await tx`
        update app.care_actions
        set status = 'completed', performed_by_account_id = ${me}, performed_at = now()
        where plant_id = ${plantID} and kind = 'checkIn' and status in ('proposed', 'due')`;
    await tx`
        insert into app.care_actions (plant_id, kind, instructions, status, due_from)
        values (${plantID}, ${"checkIn"}, ${"Take a new photo and compare it with the last check-in."}, ${"due"}, ${nextCheckIn})`;

    const answers = {
      previousScore,
      score,
      band,
      appearance: ["better", "same", "worse"].includes(body.appearance) ? body.appearance : "same",
      soilMoisture: ["dry", "comfortable", "wet"].includes(body.soilMoisture) ? body.soilMoisture : "comfortable",
      hasNewGrowth: body.hasNewGrowth === true,
      isEstimated,
      appliesToPlant,
      confidence,
      actionability,
      assessmentAvailable,
      analysisVersion: body.analysisVersion ?? null,
      providerName: body.providerName ?? null,
      limitations: jsonArray(body.limitations).map((item) => String(item).slice(0, 240)).slice(0, 6),
      followUpDays,
      referenceObservationID: uuidPattern.test(lower(body.referenceObservationID))
        ? lower(body.referenceObservationID)
        : null,
      indicatorReadings
    };
    await tx`
        insert into app.observations (id, plant_id, performed_by_account_id, source, answers, note)
        values (${observationID}, ${plantID}, ${me}, ${"scheduled_check_in"}, ${answers}::jsonb, ${note})
        on conflict (id) do nothing`;

    const findings = {
      indicatorReadings,
      actionability,
      assessmentAvailable,
      isEstimated,
      appliesToPlant,
      referenceObservationID: answers.referenceObservationID
    };
    await tx`
        insert into app.health_assessments (
          observation_id, provider_name, provider_version, health_score,
          health_band, trend, confidence, findings, limitations
        )
        select ${observationID}, ${String(body.providerName ?? (isEstimated ? "Grove owner observation" : "Grove check-in")).slice(0, 120)},
               ${body.analysisVersion ? String(body.analysisVersion).slice(0, 100) : null},
               ${appliesToPlant ? score : null}, ${band}, ${trend}, ${confidence},
               ${findings}::jsonb, ${answers.limitations}::jsonb
        where not exists (
          select 1 from app.health_assessments where observation_id = ${observationID}
        )`;

    if (mediaDraftID) {
      const [asset] = await tx`
          update app.media_assets set plant_id = ${plantID}
          where owner_account_id = ${me} and local_media_id = ${mediaDraftID}
          returning id`;
      if (asset) {
        await tx`
            insert into app.observation_media (observation_id, media_asset_id)
            values (${observationID}, ${asset.id})
            on conflict do nothing`;
      }
    }

    await tx`
        insert into app.activity_events (actor_account_id, grove_id, plant_id, observation_id, kind, message)
        values (${me}, ${plant.grove_id}, ${plantID}, ${observationID}, ${"improvement"},
                ${appliesToPlant
                  ? `checked in. Now ${bandTitle(band).toLowerCase()} at ${score}%`
                  : "checked in. Notes saved, health score unchanged"})`;

    return { status: 200, plant: updated };
  });

  if (result.status === 404) return failure(404, "Plant not found.");
  return json(200, clientPlant(result.plant));
}

async function updateCareTask(me: string, taskIDRaw: string, body: Row): Promise<Response> {
  const taskID = lower(taskIDRaw);
  if (!uuidPattern.test(taskID)) return failure(404, "Care task not found.");
  const outcome = body.outcome === "snoozed" ? "snoozed" : body.outcome === "completed" ? "completed" : undefined;
  if (!outcome) return failure(422, "The care update must be completed or snoozed.");

  const result = await withAccount(me, async (tx) => {
    const [action] = await tx`
        select action.*, plant.nickname as plant_nickname,
               grove.owner_account_id as owner_account_id,
               owner.display_name as owner_name,
               membership.account_id is not null as is_owner_member,
               sitter_assignment.id as sitter_assignment_id
        from app.care_actions action
        join app.plants plant on plant.id = action.plant_id
        join app.groves grove on grove.id = plant.grove_id
        join app.accounts owner on owner.id = grove.owner_account_id
        left join app.grove_memberships membership
          on membership.grove_id = plant.grove_id and membership.account_id = ${me}
        left join lateral (
          select assignment.id
          from app.sitting_assignment_plants scope
          join app.sitting_assignments assignment on assignment.id = scope.assignment_id
          where scope.plant_id = plant.id
            and assignment.sitter_account_id = ${me}
            and assignment.status in ('upcoming', 'active')
            and assignment.can_log_care = true
            and assignment.revoked_at is null
            and now() >= assignment.starts_at
            and now() < assignment.ends_at
            and action.status in ('proposed', 'due')
            and coalesce(action.due_from, now()) <= assignment.ends_at
            and (action.kind not in ('checkIn', 'check_in') or assignment.can_check_in = true)
          limit 1
        ) sitter_assignment on true
        where action.id = ${taskID}
          and (membership.account_id is not null or sitter_assignment.id is not null)`;
    if (!action) return { status: 404 };
    if (outcome === "snoozed" && action.sitter_assignment_id != null && action.is_owner_member !== true) {
      return { status: 403 };
    }

    if (outcome === "completed") {
      const [updated] = await tx`
          update app.care_actions
          set status = 'completed', performed_by_account_id = ${me},
              performed_at = ${body.occurredAt ? new Date(body.occurredAt) : new Date()}
          where id = ${taskID}
          returning *`;
      return {
        status: 200,
        action: updated,
        ownerAccountID: action.owner_account_id,
        plantNickname: action.plant_nickname,
        plantID: action.plant_id,
        kind: action.kind,
        isSittingTask: action.sitter_assignment_id != null && action.is_owner_member !== true,
        ownerName: action.owner_name
      };
    }
    const [updated] = await tx`
        update app.care_actions
        set status = 'due',
            due_from = ${body.rescheduledFor ? new Date(body.rescheduledFor) : action.due_from},
            skip_reason = ${body.reason ?? null},
            performed_at = null, performed_by_account_id = null
        where id = ${taskID}
        returning *`;
    return { status: 200, action: updated };
  });

  if (result.status === 404) return failure(404, "Care task not found.");
  if (result.status === 403) return failure(403, "Only the plant owner can move this task to another day.");
  // The one push an owner most wants and could never get: their sitter actually
  // did the thing, while they are somewhere without their plants. Only when
  // somebody *else* logged it — an owner ticking off their own task does not
  // need telling.
  if (result.ownerAccountID && result.ownerAccountID !== me) {
    scheduleBackground(
      displayNameOf(me).then((name) =>
        notify(result.ownerAccountID, {
          title: `${name} looked after ${result.plantNickname}`,
          body: `${careVerb(result.kind)}, logged just now. It's on ${result.plantNickname}'s timeline.`,
          openTab: "today",
          plantID: result.plantID,
          threadID: `grove.plant.${result.plantID}`
        })
      )
    );
  }
  return json(200, clientCareTask({
    ...result.action,
    is_sitting_task: result.isSittingTask === true,
    owner_name: result.ownerName ?? null
  }));
}

async function createCareEvent(me: string, body: Row): Promise<Response> {
  const task = body.task ?? {};
  const taskID = lower(task.id);
  const plantID = lower(task.plantID);
  const clientRequestID = lower(body.clientRequestID);
  const kind = String(task.kind ?? "");
  if (!uuidPattern.test(taskID) || !uuidPattern.test(plantID) || !uuidPattern.test(clientRequestID)
      || !careKinds.includes(kind) || kind === "checkIn") {
    return failure(422, "The care event is invalid.");
  }
  const moisture = ["dry", "comfortable", "wet"].includes(task.soilMoisture)
    ? task.soilMoisture
    : null;
  const occurredAt = task.completedAt ? new Date(task.completedAt) : new Date();
  if (Number.isNaN(occurredAt.getTime())) return failure(422, "The care date is invalid.");

  const result = await withAccount(me, async (tx) => {
    const [plant] = await tx`
        select plant.id, plant.grove_id, plant.nickname from app.plants plant
        join app.grove_memberships membership on membership.grove_id = plant.grove_id
        where plant.id = ${plantID} and membership.account_id = ${me}`;
    if (!plant) return undefined;

    const [existing] = await tx`select * from app.care_actions where id = ${taskID}`;
    if (existing) return existing.plant_id === plantID ? existing : { conflict: true };

    const [created] = await tx`
        insert into app.care_actions (
          id, plant_id, kind, instructions, status, due_from,
          performed_by_account_id, performed_at, client_request_id, soil_moisture
        ) values (
          ${taskID}, ${plantID}, ${kind}, ${String(task.detail ?? "Care logged directly in Grove.").slice(0, 2000)},
          'completed', ${occurredAt}, ${me}, ${occurredAt}, ${clientRequestID}, ${moisture}
        ) returning *`;
    await tx`
        insert into app.activity_events (
          id, actor_account_id, grove_id, plant_id, kind, message
        ) values (
          ${taskID}, ${me}, ${plant.grove_id}, ${plantID}, 'milestone', ${`logged ${careVerb(kind).toLowerCase()}`}
        ) on conflict (id) do nothing`;
    return created;
  });

  if (!result) return failure(404, "Plant not found.");
  if (result.conflict) return failure(409, "That care event belongs to another plant.");
  return json(201, clientCareTask(result));
}

async function deleteCareEvent(me: string, taskIDRaw: string): Promise<Response> {
  const taskID = lower(taskIDRaw);
  if (!uuidPattern.test(taskID)) return json(200, {});
  await withAccount(me, async (tx) => {
    const [event] = await tx`
        select action.id from app.care_actions action
        join app.plants plant on plant.id = action.plant_id
        join app.groves grove on grove.id = plant.grove_id
        join app.grove_memberships membership on membership.grove_id = plant.grove_id
        where action.id = ${taskID} and membership.account_id = ${me}
          and action.status = 'completed' and action.care_plan_id is null
          and action.client_request_id is not null
          and (action.performed_by_account_id = ${me} or grove.owner_account_id = ${me})`;
    if (!event) return;
    await tx`delete from app.activity_events where id = ${taskID}`;
    await tx`delete from app.care_actions where id = ${taskID}`;
  });
  return json(200, {});
}

/// What a sitter did, in the owner's language. Never phrased as an instruction:
/// this is a record of care that already happened.
function careVerb(kind: string): string {
  switch (kind) {
    case "water": return "Watered";
    case "check_in":
    case "checkIn": return "Took a check-in photo";
    case "inspect_soil":
    case "inspectSoil": return "Checked the soil";
    case "treat": return "Carried on the treatment";
    case "prune": return "Did some tidying";
    case "rotate": return "Gave it a quarter turn";
    default: return "Logged some care";
  }
}

async function updateProfile(me: string, body: Row): Promise<Response> {
  const username = String(body.username ?? "");
  if (!usernamePattern.test(username)) {
    return failure(422, "Username must contain 3–24 lowercase letters, numbers, or underscores.");
  }
  const displayName = String(body.displayName ?? "").trim() || "Gardener";
  if (/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/u.test(displayName)) {
    return failure(422, "Display name contains unsupported formatting characters.");
  }
  if ([...displayName].length > 80) {
    return failure(422, "Display name must be 80 characters or fewer.");
  }
  if (containsBlockedProfileLanguage(displayName)) {
    return failure(422, "Choose a display name that is respectful to other gardeners.");
  }
  // Silence about location is not a request to forget it. Only the location
  // picker speaks for the pin; every other profile edit — name, username,
  // units, privacy — leaves these fields off the body, and writing null for
  // them regardless dropped the saved grove, which the next bootstrap then
  // cleared on the phone as well. Absent means unchanged; present decides.
  const sentLocation = body.latitude !== undefined
    || body.longitude !== undefined
    || body.locationLabel !== undefined
    || body.locationCountryCode !== undefined
    || body.locationTimeZoneIdentifier !== undefined;
  // A real boolean: it is interpolated as a SQL `case when` condition, and the
  // label string itself is not one Postgres reads as true.
  const hasLocation = body.latitude != null && body.longitude != null && Boolean(body.locationLabel);
  const rawLocationCountryCode = typeof body.locationCountryCode === "string"
    ? body.locationCountryCode.trim().toUpperCase()
    : "";
  const locationCountryCode = /^[A-Z]{2}$/.test(rawLocationCountryCode)
    ? rawLocationCountryCode
    : null;
  const locationTimeZoneIdentifier = body.locationTimeZoneIdentifier !== undefined
    ? validTimeZoneIdentifier(body.locationTimeZoneIdentifier)
    : null;

  try {
    const result = await withAccount(me, async (tx) => {
      if (sentLocation) {
        await tx`
          update app.accounts
          set latitude = ${hasLocation ? Number(body.latitude) : null},
              longitude = ${hasLocation ? Number(body.longitude) : null},
              location_label = ${hasLocation ? String(body.locationLabel) : null},
              location_country_code = case
                when ${hasLocation} then coalesce(${locationCountryCode}, location_country_code)
                else null
              end,
              location_time_zone_identifier = case
                when ${hasLocation} then coalesce(${locationTimeZoneIdentifier}, location_time_zone_identifier)
                else null
              end
          where id = ${me}`;
      }
      const [account] = await tx`
          update app.accounts
          set username = ${username},
              display_name = ${displayName},
              region_code = ${body.regionCode ?? null},
              uses_metric_system = ${body.usesMetricSystem !== false},
              updated_at = now()
          where id = ${me}
          returning *`;
      if (!account) return undefined;
      await tx`update app.groves set is_private = true, updated_at = now() where owner_account_id = ${me}`;
      const [{ count }] = await tx`
          select count(*)::int as count from app.friendships
          where status = 'accepted' and (requested_by_account_id = ${me} or requested_to_account_id = ${me})`;
      return { account, friendCount: count };
    });
    if (!result) return failure(503, "Your account is still being set up. Try again in a moment.");
    return json(200, clientProfile(result.account, result.friendCount, true));
  } catch (caught) {
    if ((caught as { code?: string }).code === "23505") {
      return failure(422, "That username is already taken. Choose another and try again.");
    }
    throw caught;
  }
}

async function updateGardenerProgress(me: string, body: Row): Promise<Response> {
  const gardener = validGardenerProgress(body.gardener);
  const updatedAt = new Date(body.updatedAt);
  if (!gardener || Number.isNaN(updatedAt.valueOf())) {
    return failure(422, "That Journey progress could not be read.");
  }

  const result = await withAccount(me, async (tx) => {
    const [account] = await tx`
      update app.accounts
         set gardener_progress = ${gardener}::jsonb,
             gardener_progress_updated_at = ${updatedAt}
       where id = ${me}
         and (
           gardener_progress_updated_at is null
           or gardener_progress_updated_at <= ${updatedAt}
         )
       returning gardener_progress, gardener_progress_updated_at`;
    if (account) return account;
    const [existing] = await tx`
      select gardener_progress, gardener_progress_updated_at
        from app.accounts where id = ${me}`;
    return existing;
  });
  if (!result?.gardener_progress || !result.gardener_progress_updated_at) {
    return failure(503, "Your account is still being set up. Try again in a moment.");
  }
  return json(200, {
    gardener: jsonbValue(result.gardener_progress),
    updatedAt: iso(result.gardener_progress_updated_at)
  });
}

async function recordFriendActivity(
  tx: Tx,
  eventID: string,
  actorAccountID: string,
  audienceAccountID: string,
  message: string
): Promise<void> {
  const [actor] = await tx`select display_name from app.accounts where id = ${actorAccountID}`;
  const [audienceGrove] = await tx`select id from app.groves where owner_account_id = ${audienceAccountID}`;
  if (!actor || !audienceGrove) return;
  const actorName = String(actor.display_name ?? "A gardener");
  await tx`
      insert into app.activity_events (
        id, actor_account_id, grove_id, kind, message, actor_name, actor_initials
      ) values (
        ${eventID}, ${actorAccountID}, ${audienceGrove.id}, 'friendship', ${message},
        ${actorName}, ${initialsOf(actorName)}
      ) on conflict (id) do nothing`;
}

async function createFriendInvitation(me: string, body: Row): Promise<Response> {
  const username = String(body.username ?? "").toLowerCase();
  if (!usernamePattern.test(username)) return failure(422, "Enter a valid username to invite.");
  const invitationID = uuidPattern.test(lower(body.clientRequestID)) ? lower(body.clientRequestID) : crypto.randomUUID();
  const activityEventID = uuidPattern.test(lower(body.activityEventID ?? body.clientRequestID))
    ? lower(body.activityEventID ?? body.clientRequestID)
    : crypto.randomUUID();

  const result = await withAccount(me, async (tx) => {
    const [actor] = await tx`select id from app.accounts where id = ${me} for key share`;
    if (!actor) {
      return { status: 503, message: "Your account is still being set up. Try again in a moment." };
    }
    // Serialize the account's allowance. Checking and then recording without
    // this lock lets a burst of concurrent probes all observe count 29.
    await tx`select pg_advisory_xact_lock(hashtextextended(${`friend-invite-rate:${me}`}, 0))`;
    const [priorAttempt] = await tx`
        select attempted_username from app.friend_invitation_attempts
        where requested_by_account_id = ${me} and request_id = ${invitationID}`;
    if (priorAttempt && priorAttempt.attempted_username !== username) {
      return { status: 409, message: "That request id was already used for a different invitation." };
    }
    if (!priorAttempt) {
      await tx`
          delete from app.friend_invitation_attempts
          where requested_by_account_id = ${me}
            and attempted_at < now() - interval '7 days'`;
      const [{ recent_count: recentCount }] = await tx`
          select count(*)::int as recent_count
          from app.friend_invitation_attempts
          where requested_by_account_id = ${me}
            and attempted_at >= now() - interval '24 hours'`;
      if (Number(recentCount) >= 30) {
        return { status: 429, message: "That's a lot of invitations for one day. Try again tomorrow." };
      }
      await tx`
          insert into app.friend_invitation_attempts (
            requested_by_account_id, request_id, attempted_username
          ) values (${me}, ${invitationID}, ${username})`;
    }

    const [target] = await tx`
        select id, username, display_name from app.accounts
        where username = ${username}
        for key share`;
    if (!target) return { status: 422, message: "No gardener with that username has joined Grove yet." };
    if (target.id === me) return { status: 422, message: "You cannot invite yourself." };

    // The unordered-pair index is the final guard, but serialising this pair
    // makes the losing side of simultaneous A -> B / B -> A requests receive a
    // useful state-machine answer instead of a unique-constraint 503.
    const pairKey = `friendship:${[me, target.id].sort().join(":")}`;
    await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;

    const createdResult = async (friendship: Row) => {
      await recordFriendActivity(
        tx,
        activityEventID,
        me,
        target.id,
        "sent a trusted-person invitation"
      );
      return { status: 201, friendship, target };
    };

    const [existing] = await tx`
        select * from app.friendships
        where (requested_by_account_id = ${me} and requested_to_account_id = ${target.id})
           or (requested_by_account_id = ${target.id} and requested_to_account_id = ${me})`;
    // A row already exists for this pair, in one direction or the other. What
    // may happen next depends on whose request it was and how it ended: the one
    // thing that must never happen is a "no" quietly becoming a "pending" again.
    if (existing) {
      const iAmRequester = existing.requested_by_account_id === me;
      if (existing.status === "accepted") {
        return { status: 422, message: "You two are already connected." };
      }
      if (existing.status === "blocked") {
        return { status: 422, message: "That invitation could not be sent." };
      }
      if (existing.status === "pending") {
        // Replays of the same send land here, and must succeed.
        if (iAmRequester) return { status: 200, friendship: existing, target };
        return { status: 422, message: "They invited you first. Answer their request instead." };
      }
      if (iAmRequester) {
        // Declined. They said no, and asking again is not this button's job.
        if (existing.status !== "withdrawn") {
          return { status: 422, message: "That invitation has already been answered." };
        }
        // Without a cooldown, send -> withdraw -> send is an unlimited push
        // notification loop against one person.
        if (Date.now() - new Date(existing.updated_at).getTime() < 60 * 60 * 1000) {
          return { status: 429, message: "You just cancelled that invitation. Give it an hour before sending it again." };
        }
        const [reopened] = await tx`
            update app.friendships
            set status = 'pending'::app.friendship_status,
                created_at = now(), updated_at = now()
            where id = ${existing.id}
            returning *`;
        return await createdResult(reopened);
      }
      // Their request to this account is finished (declined here, or taken back
      // there). Reuse the one unordered relationship row with its direction
      // reversed; a second row is exactly how duplicate friendships used to be
      // created.
      const [reversed] = await tx`
          update app.friendships
          set requested_by_account_id = ${me},
              requested_to_account_id = ${target.id},
              status = 'pending'::app.friendship_status,
              created_at = now(), updated_at = now()
          where id = ${existing.id}
          returning *`;
      return await createdResult(reversed);
    }

    const [created] = await tx`
        insert into app.friendships (id, requested_by_account_id, requested_to_account_id, status)
        values (${invitationID}, ${me}, ${target.id}, 'pending')
        returning *`;
    return await createdResult(created);
  });

  if (!result.friendship) return failure(result.status, result.message ?? "That invitation could not be created.");
  // Only on a genuinely new invitation. A 200 here is a replay of a send that
  // already happened, and pushing again would be the same request arriving
  // twice on the recipient's lock screen.
  if (result.status === 201) {
    scheduleBackground(
      displayNameOf(me).then((name) =>
        notify(result.target.id, {
          title: `${name} wants to connect on Grove`,
          body: "Accept to keep them handy when you make an explicit plant-sitting link.",
          openTab: "friends"
        })
      )
    );
  }
  return json(result.status, clientInvitation(result.friendship, me, result.target));
}

// Accept or decline an invitation someone sent *to* this account.
//
// Only the recipient may respond. Raw table writes are denied too, but this
// check keeps the service's state transition explicit under its service role.
//
// Replays are answered rather than refused. The client queues this mutation and
// retries it, so a request whose response was lost must not wedge the queue —
// a row already in the state being asked for is a success, not a conflict.
async function respondToFriendInvitation(me: string, invitationID: string, body: Row): Promise<Response> {
  if (!uuidPattern.test(invitationID)) return failure(404, "That invitation no longer exists.");
  if (typeof body.accept !== "boolean") return failure(422, "Choose whether to accept or decline this invitation.");
  const accept = body.accept === true;
  const target = accept ? "accepted" : "declined";
  const activityEventID = uuidPattern.test(lower(body.activityEventID ?? body.clientRequestID))
    ? lower(body.activityEventID ?? body.clientRequestID)
    : crypto.randomUUID();

  const result = await withAccount(me, async (tx) => {
    const [friendship] = await tx`select * from app.friendships where id = ${invitationID}`;
    if (!friendship) return { status: 404, message: "That invitation no longer exists." };
    if (friendship.requested_to_account_id !== me) {
      return { status: 403, message: "Only the gardener who received an invitation can answer it." };
    }
    if (friendship.status === target) return { status: 200, friendship };
    if (friendship.status !== "pending") {
      return { status: 409, message: "This invitation was already answered on another device." };
    }
    const [updated] = await tx`
        update app.friendships
        set status = ${target}::app.friendship_status, updated_at = now()
        where id = ${invitationID} and status = 'pending'
        returning *`;
    if (!updated) {
      const [settled] = await tx`select * from app.friendships where id = ${invitationID}`;
      if (settled?.status === target) return { status: 200, friendship: settled };
      return { status: 409, message: "This invitation was already answered on another device." };
    }
    if (accept) {
      await recordFriendActivity(
        tx,
        activityEventID,
        me,
        updated.requested_by_account_id,
        "accepted a trusted-person invitation"
      );
    }
    return { status: 200, friendship: updated, changed: true };
  });

  if (!result.friendship) return failure(result.status, result.message ?? "That invitation could not be answered.");
  // `changed` separates a real answer from a replay, which both return 200.
  // Only the person who asked hears about it, and only about a yes: a decline
  // is a quiet no, not a notification.
  if (result.changed && accept) {
    scheduleBackground(
      displayNameOf(me).then((name) =>
        notify(result.friendship.requested_by_account_id, {
          title: `${name} said yes`,
          body: "You're connected. Plant access still happens only through an explicit sitting link.",
          openTab: "friends"
        })
      )
    );
  }
  return json(200, {});
}

// Take back an invitation this account sent.
//
// Only the requester may. Raw table writes are denied too, but this check keeps
// the service's state transition explicit and protects service-role execution.
//
// Replays are answered rather than refused, for the same reason `respond`
// answers them: the client queues this and retries it, so a row already
// withdrawn is a success.
async function withdrawFriendInvitation(me: string, invitationID: string): Promise<Response> {
  if (!uuidPattern.test(invitationID)) return failure(404, "That invitation no longer exists.");

  const result = await withAccount(me, async (tx) => {
    const [friendship] = await tx`select * from app.friendships where id = ${invitationID}`;
    if (!friendship) return { status: 404, message: "That invitation no longer exists." };
    if (friendship.requested_by_account_id !== me) {
      return { status: 403, message: "Only the gardener who sent an invitation can take it back." };
    }
    if (friendship.status === "withdrawn") return { status: 200, friendship };
    if (friendship.status !== "pending") {
      return { status: 409, message: "That invitation was already answered on another device." };
    }
    const [updated] = await tx`
        update app.friendships
        set status = 'withdrawn'::app.friendship_status, updated_at = now()
        where id = ${invitationID} and status = 'pending'
        returning *`;
    if (!updated) {
      const [settled] = await tx`select * from app.friendships where id = ${invitationID}`;
      if (settled?.status === "withdrawn") return { status: 200, friendship: settled };
      return { status: 409, message: "That invitation was already answered on another device." };
    }
    return { status: 200, friendship: updated };
  });

  if (!result.friendship) return failure(result.status, result.message ?? "That invitation could not be taken back.");
  return json(200, {});
}

// Ends an accepted connection and any legacy account-based care delegation
// between the pair. Keep the relationship row as a declined tombstone, with
// the removed account in the requester position: otherwise deleting it lets
// that account immediately send a fresh invitation (and another push) after
// being removed. The remover can still choose to reconnect later by reversing
// the row through the normal invitation state machine. Sitting links are
// separate capabilities and stay under the owner's explicit per-link revoke
// controls.
async function removeFriend(me: string, friendIDRaw: string): Promise<Response> {
  const friendID = lower(friendIDRaw);
  if (!uuidPattern.test(friendID) || friendID === me) return json(200, {});

  await withAccount(me, async (tx) => {
    const pairKey = `friendship:${[me, friendID].sort().join(":")}`;
    await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;
    await tx`
        update app.friendships
        set requested_by_account_id = ${friendID},
            requested_to_account_id = ${me},
            status = 'declined'::app.friendship_status,
            updated_at = now()
        where status in ('accepted', 'pending')
          and ((requested_by_account_id = ${me} and requested_to_account_id = ${friendID})
            or (requested_by_account_id = ${friendID} and requested_to_account_id = ${me}))`;
    await tx`
        update app.sitting_assignments
        set status = 'revoked'::app.assignment_status,
            revoked_at = coalesce(revoked_at, now())
        where status in ('invited', 'upcoming', 'active')
          and ((owner_account_id = ${me} and sitter_account_id = ${friendID})
            or (owner_account_id = ${friendID} and sitter_account_id = ${me}))`;
  });
  return json(200, {});
}

async function blockPair(tx: Tx, me: string, friendID: string): Promise<Row | undefined> {
  const pairKey = `friendship:${[me, friendID].sort().join(":")}`;
  await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;
  const [friend] = await tx`select id from app.accounts where id = ${friendID}`;
  if (!friend) return undefined;
  const [existing] = await tx`
      select * from app.friendships
      where (requested_by_account_id = ${me} and requested_to_account_id = ${friendID})
         or (requested_by_account_id = ${friendID} and requested_to_account_id = ${me})`;
  if (existing) {
    const [blocked] = await tx`
        update app.friendships
        set requested_by_account_id = ${friendID}, requested_to_account_id = ${me},
            status = 'blocked'::app.friendship_status, updated_at = now()
        where id = ${existing.id}
        returning *`;
    return blocked;
  }
  const [blocked] = await tx`
      insert into app.friendships (
        id, requested_by_account_id, requested_to_account_id, status
      ) values (
        ${crypto.randomUUID()}, ${friendID}, ${me}, 'blocked'
      ) returning *`;
  return blocked;
}

async function revokeLegacyFriendAccess(tx: Tx, me: string, friendID: string): Promise<void> {
  await tx`
      update app.sitting_assignments
      set status = 'revoked'::app.assignment_status,
          revoked_at = coalesce(revoked_at, now())
      where status in ('invited', 'upcoming', 'active')
        and ((owner_account_id = ${me} and sitter_account_id = ${friendID})
          or (owner_account_id = ${friendID} and sitter_account_id = ${me}))`;
  await tx`
      update app.sitting_invites
      set revoked_at = coalesce(revoked_at, now())
      where owner_account_id = ${me}
        and recipient_account_id = ${friendID}
        and revoked_at is null`;
}

async function blockFriend(me: string, friendIDRaw: string): Promise<Response> {
  const friendID = lower(friendIDRaw);
  if (!uuidPattern.test(friendID) || friendID === me) {
    return failure(422, "That account could not be blocked.");
  }
  const blocked = await withAccount(me, async (tx) => {
    const relationship = await blockPair(tx, me, friendID);
    if (!relationship) return false;
    await revokeLegacyFriendAccess(tx, me, friendID);
    return true;
  });
  return blocked ? json(200, {}) : failure(404, "That account no longer exists.");
}

async function reportFriend(me: string, friendIDRaw: string, body: Row): Promise<Response> {
  const friendID = lower(friendIDRaw);
  const reason = String(body.reason ?? "");
  const details = String(body.details ?? "").trim();
  const clientRequestID = lower(body.clientRequestID);
  if (!uuidPattern.test(friendID) || friendID === me) {
    return failure(422, "That account could not be reported.");
  }
  if (!friendReportReasons.has(reason)) return failure(422, "Choose why you're reporting this account.");
  if ([...details].length > 1_000) return failure(422, "Report details must be 1,000 characters or fewer.");
  if (!uuidPattern.test(clientRequestID)) return failure(422, "That report could not be identified.");

  const reported = await withAccount(me, async (tx) => {
    const relationship = await blockPair(tx, me, friendID);
    if (!relationship) return false;
    await tx`
        insert into app.friend_reports (
          id, reporter_account_id, reported_account_id, friendship_id,
          reason, details, client_request_id
        ) values (
          ${clientRequestID}, ${me}, ${friendID}, ${relationship.id},
          ${reason}, ${details || null}, ${clientRequestID}
        ) on conflict (reporter_account_id, client_request_id) do nothing`;
    await revokeLegacyFriendAccess(tx, me, friendID);
    return true;
  });
  return reported ? json(200, {}) : failure(404, "That account no longer exists.");
}

async function createSittingAssignment(me: string, body: Row): Promise<Response> {
  const sitterID = lower(body.sitterAccountID);
  if (!uuidPattern.test(sitterID)) {
    return failure(422, "Choose a trusted friend with a Grove account to sit your plants.");
  }
  if (sitterID === me) return failure(422, "You cannot sit your own Grove.");
  if (body.canCheckIn !== undefined && typeof body.canCheckIn !== "boolean") {
    return failure(422, "The check-in permission must be on or off.");
  }
  if (body.canLogCare !== undefined && typeof body.canLogCare !== "boolean") {
    return failure(422, "The care permission must be on or off.");
  }
  const ownerNotes = String(body.ownerNotes ?? "").trim();
  if (ownerNotes.length > 4_000) return failure(422, "Keep the plant-care handover under 4,000 characters.");
  const rawPlantIDs: string[] = Array.isArray(body.plantIDs) ? body.plantIDs.map(lower) : [];
  if (rawPlantIDs.length > 100) return failure(422, "A sitting assignment can include at most 100 plants.");
  if (rawPlantIDs.some((id) => !uuidPattern.test(id))) {
    return failure(422, "Every plant in a sitting assignment must have a valid id.");
  }
  const plantIDs = [...new Set(rawPlantIDs)];
  if (!plantIDs.length) return failure(422, "Choose at least one plant for the sitting assignment.");
  const startsAt = new Date(body.startDate);
  const endsAt = new Date(body.endDate);
  if (!Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) || !(startsAt.getTime() < endsAt.getTime())) {
    return failure(422, "The sitting window must end after it starts.");
  }
  if (endsAt.getTime() <= Date.now()) return failure(422, "A sitting assignment must end in the future.");
  if (endsAt.getTime() - startsAt.getTime() > 180 * 86_400_000) {
    return failure(422, "A sitting assignment can cover at most six months.");
  }
  const timeZoneIdentifier = validTimeZoneIdentifier(body.timeZoneIdentifier);
  const assignmentID = uuidPattern.test(lower(body.clientRequestID)) ? lower(body.clientRequestID) : crypto.randomUUID();
  const activityEventID = uuidPattern.test(lower(body.activityEventID)) ? lower(body.activityEventID) : assignmentID;

  const result = await withAccount(me, async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${`sitting-assignment:${assignmentID}`}, 0))`;
    const [sitter] = await tx`select id, display_name from app.accounts where id = ${sitterID}`;
    if (!sitter) return { status: 422, message: "That person does not have a Grove account yet." };
    const [friendship] = await tx`
        select id from app.friendships
        where status = 'accepted'
          and ((requested_by_account_id = ${me} and requested_to_account_id = ${sitterID})
            or (requested_by_account_id = ${sitterID} and requested_to_account_id = ${me}))`;
    if (!friendship) return { status: 422, message: "Only a trusted person can receive an in-app handover." };
    const [grove] = await tx`select id from app.groves where owner_account_id = ${me} limit 1`;
    if (!grove) return { status: 503, message: "Your account is still being set up. Try again in a moment." };
    const [owner] = await tx`select id, display_name from app.accounts where id = ${me}`;

    const owned = await tx`
        select plant.id from app.plants plant
        where plant.id = any(${plantIDs}::uuid[]) and plant.grove_id = ${grove.id}`;
    if (owned.length !== plantIDs.length) {
      return { status: 422, message: "Only plants from your own Grove can be included." };
    }

    const [existing] = await tx`select * from app.sitting_assignments where id = ${assignmentID}`;
    if (existing) {
      if (existing.owner_account_id !== me) return { status: 409, message: "This changed on another device. Refresh and try again." };
      const scoped = await tx`
          select plant_id from app.sitting_assignment_plants
          where assignment_id = ${assignmentID}
          order by plant_id`;
      const existingPlantIDs = scoped.map((row: Row) => row.plant_id).sort();
      const sameRequest = existing.sitter_account_id === sitterID
        && existing.grove_id === grove.id
        && new Date(existing.starts_at).getTime() === startsAt.getTime()
        && new Date(existing.ends_at).getTime() === endsAt.getTime()
        && (existing.can_check_in !== false) === (body.canCheckIn !== false)
        && (existing.can_log_care !== false) === (body.canLogCare !== false)
        && String(existing.owner_notes ?? "") === ownerNotes
        && validTimeZoneIdentifier(existing.time_zone_identifier) === timeZoneIdentifier
        && JSON.stringify(existingPlantIDs) === JSON.stringify([...plantIDs].sort());
      if (!sameRequest) return { status: 409, message: "That handover id was already used for different details. Make a new one." };
      return { status: 200, assignment: existing, sitter, owner, plantIDs: existingPlantIDs };
    }

    const [assignment] = await tx`
        insert into app.sitting_assignments (
          id, owner_account_id, sitter_account_id, grove_id, status, starts_at, ends_at,
          can_check_in, can_log_care, owner_notes,
          sitter_name, sitter_initials, completed_tasks, total_tasks,
          time_zone_identifier
        )
        values (
          ${assignmentID}, ${me}, ${sitterID}, ${grove.id}, 'invited', ${startsAt}, ${endsAt},
          ${body.canCheckIn !== false}, ${body.canLogCare !== false}, ${ownerNotes || null},
          ${sitter.display_name}, ${initialsOf(sitter.display_name)},
          0, ${Math.max(1, plantIDs.length * 2)}, ${timeZoneIdentifier}
        )
        returning *`;
    for (const plantID of plantIDs) {
      await tx`insert into app.sitting_assignment_plants (assignment_id, plant_id) values (${assignmentID}, ${plantID}) on conflict do nothing`;
    }
    const ownerName = owner?.display_name ?? "A gardener";
    const plantCount = `${plantIDs.length} ${plantIDs.length === 1 ? "plant" : "plants"}`;
    await tx`
        insert into app.activity_events (
          id, actor_account_id, grove_id, assignment_id, kind, message,
          actor_name, actor_initials
        ) values (
          ${activityEventID}, ${me}, ${grove.id}, ${assignmentID}, 'assignment',
          ${`invited ${sitter.display_name} to care for ${plantCount}`},
          ${ownerName}, ${initialsOf(ownerName)}
        )
        on conflict (id) do nothing`;
    return { status: 201, assignment, sitter, owner, plantIDs };
  });

  if (!result.assignment) return failure(result.status, result.message ?? "That assignment could not be created.");
  // The sitter is being handed responsibility for something alive, by someone
  // who is probably about to be unreachable. 201 only — a 200 is a replay of an
  // assignment they have already been told about.
  if (result.status === 201) {
    const count = plantIDs.length;
    scheduleBackground(
      displayNameOf(me).then((name) =>
        notify(sitterID, {
          title: `${name} asked you to sit their plants`,
          body: `${count} ${count === 1 ? "plant" : "plants"} from ${startsAt.toLocaleDateString("en-NZ", { day: "numeric", month: "short" })}. Everything they need is in the app.`,
          openTab: "friends",
          openRoute: "sitting"
        })
      )
    );
  }
  return json(result.status, clientAssignment(
    result.assignment,
    result.plantIDs ?? plantIDs,
    result.sitter,
    result.owner,
    me
  ));
}

async function respondToSittingAssignment(
  me: string,
  assignmentIDRaw: string,
  body: Row
): Promise<Response> {
  const assignmentID = lower(assignmentIDRaw);
  if (!uuidPattern.test(assignmentID)) return failure(404, "That sitting invitation no longer exists.");
  if (typeof body.accept !== "boolean") return failure(422, "Choose whether to accept or decline this invitation.");
  const eventID = uuidPattern.test(lower(body.clientRequestID)) ? lower(body.clientRequestID) : crypto.randomUUID();

  const result = await withAccount(me, async (tx) => {
    const [current] = await tx`
        select * from app.sitting_assignments
        where id = ${assignmentID} and sitter_account_id = ${me}
        for update`;
    if (!current) return { status: 404, message: "That sitting invitation no longer exists." };
    if (current.revoked_at != null || current.status === "revoked") {
      return { status: 409, message: "The owner has already withdrawn this invitation." };
    }
    if (new Date(current.ends_at).getTime() <= Date.now()) {
      return { status: 409, message: "That sitting window has already ended." };
    }
    if (current.status !== "invited") {
      const alreadyAccepted = ["upcoming", "active"].includes(current.status);
      if (alreadyAccepted === body.accept) {
        const plants = await tx`select plant_id from app.sitting_assignment_plants where assignment_id = ${assignmentID}`;
        const [owner] = await tx`select id, display_name from app.accounts where id = ${current.owner_account_id}`;
        const [sitter] = await tx`select id, display_name from app.accounts where id = ${me}`;
        return { status: 200, assignment: current, owner, sitter, plantIDs: plants.map((row: Row) => row.plant_id), changed: false };
      }
      return { status: 409, message: "This invitation has already been answered." };
    }

    const nextStatus = body.accept
      ? (new Date(current.starts_at).getTime() <= Date.now() ? "active" : "upcoming")
      : "declined";
    const [assignment] = await tx`
        update app.sitting_assignments
        set status = ${nextStatus},
            accepted_at = ${body.accept ? new Date() : null}
        where id = ${assignmentID}
        returning *`;
    const plants = await tx`select plant_id from app.sitting_assignment_plants where assignment_id = ${assignmentID}`;
    const [owner] = await tx`select id, display_name from app.accounts where id = ${assignment.owner_account_id}`;
    const [sitter] = await tx`select id, display_name from app.accounts where id = ${me}`;
    await tx`
        insert into app.activity_events (
          id, actor_account_id, grove_id, assignment_id, kind, message,
          actor_name, actor_initials
        ) values (
          ${eventID}, ${me}, ${assignment.grove_id}, ${assignmentID}, 'assignment',
          ${body.accept ? "accepted the plant-sitting handover" : "declined the plant-sitting handover"},
          ${sitter?.display_name ?? "A gardener"}, ${initialsOf(sitter?.display_name ?? "A gardener")}
        ) on conflict (id) do nothing`;
    return { status: 200, assignment, owner, sitter, plantIDs: plants.map((row: Row) => row.plant_id), changed: true };
  });

  if (!result.assignment) return failure(result.status, result.message ?? "That invitation could not be answered.");
  if (result.changed) {
    const sitterName = result.sitter?.display_name ?? "Your sitter";
    scheduleBackground(notify(result.assignment.owner_account_id, {
      title: body.accept ? `${sitterName} accepted` : `${sitterName} can't sit this time`,
      body: body.accept
        ? "Your account-bound plant handover is ready for the dates you chose."
        : "The handover was declined. Open Grove to arrange someone else.",
      openTab: "friends"
    }));
  }
  return json(200, clientAssignment(
    result.assignment,
    result.plantIDs,
    result.sitter,
    result.owner,
    me
  ));
}

async function revokeSittingAssignment(me: string, assignmentIDRaw: string): Promise<Response> {
  const assignmentID = lower(assignmentIDRaw);
  if (!uuidPattern.test(assignmentID)) return failure(404, "That sitting handover no longer exists.");
  const result = await withAccount(me, async (tx) => {
    const [current] = await tx`
        select * from app.sitting_assignments
        where id = ${assignmentID} and owner_account_id = ${me}
        for update`;
    if (!current) return undefined;
    const [assignment] = await tx`
        update app.sitting_assignments
        set status = 'revoked', revoked_at = coalesce(revoked_at, now())
        where id = ${assignmentID}
        returning *`;
    const plants = await tx`select plant_id from app.sitting_assignment_plants where assignment_id = ${assignmentID}`;
    const [owner] = await tx`select id, display_name from app.accounts where id = ${me}`;
    const [sitter] = await tx`select id, display_name from app.accounts where id = ${assignment.sitter_account_id}`;
    return { assignment, owner, sitter, plantIDs: plants.map((row: Row) => row.plant_id), changed: current.status !== "revoked" };
  });
  if (!result) return failure(404, "That sitting handover no longer exists.");
  if (result.changed) {
    scheduleBackground(notify(result.assignment.sitter_account_id, {
      title: "Plant-sitting handover withdrawn",
      body: "The owner ended this handover. Its plants and care tasks are no longer available.",
      openTab: "friends"
    }));
  }
  return json(200, clientAssignment(
    result.assignment,
    result.plantIDs,
    result.sitter,
    result.owner,
    me
  ));
}

// ---------------------------------------------------------------------------
// Sitting by link

// Mints a link that opens the public care sheet.
//
// The token is returned here and nowhere else, ever: only its digest is stored,
// so neither this API nor a database dump can reproduce it. That is also why
// this route deliberately does not participate in the idempotency cache — that
// table keeps response bodies for 24 hours, and the body contains the token.
// A replayed create therefore fails on the primary key instead, and the client
// says so rather than quietly handing back a link it cannot verify.
async function createSittingInvite(me: string, body: Row): Promise<Response> {
  const inviteID = uuidPattern.test(lower(body.inviteID)) ? lower(body.inviteID) : crypto.randomUUID();
  const rawPlantIDs: string[] = Array.isArray(body.plantIDs) ? body.plantIDs.map(lower) : [];
  if (rawPlantIDs.length > 100) return failure(422, "A sitting link can include at most 100 plants.");
  if (rawPlantIDs.some((id) => !uuidPattern.test(id))) {
    return failure(422, "Every plant on a sitting link must have a valid id.");
  }
  const plantIDs = [...new Set(rawPlantIDs)];
  if (!plantIDs.length) return failure(422, "Choose at least one plant for the sitting link.");
  if (body.canLogCare !== undefined && typeof body.canLogCare !== "boolean") {
    return failure(422, "The care permission must be on or off.");
  }
  const startsAt = new Date(body.startDate);
  const endsAt = new Date(body.endDate);
  if (!Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime())) {
    return failure(422, "Those dates could not be read.");
  }
  if (!(startsAt.getTime() < endsAt.getTime())) {
    return failure(422, "The sitting window must end after it starts.");
  }
  if (endsAt.getTime() <= Date.now()) return failure(422, "A sitting link must end in the future.");
  // A link that outlives the season it was made for is a standing invitation
  // nobody remembers issuing.
  if (endsAt.getTime() - startsAt.getTime() > 180 * 86_400_000) {
    return failure(422, "A sitting link can cover at most six months.");
  }
  const label = String(body.label ?? "").trim().slice(0, 60) || "Plant sitter";
  const canLogCare = body.canLogCare !== false;
  const rawOwnerNotes = String(body.ownerNotes ?? "").trim();
  if ([...rawOwnerNotes].length > 4000) return failure(422, "The handover note can be at most 4,000 characters.");
  const ownerNotes = rawOwnerNotes || null;
  const timeZoneIdentifier = validTimeZoneIdentifier(body.timeZoneIdentifier);
  const recipientAccountID = body.recipientAccountID == null ? null : lower(body.recipientAccountID);
  if (recipientAccountID !== null && (!uuidPattern.test(recipientAccountID) || recipientAccountID === me)) {
    return failure(422, "That trusted person could not be identified.");
  }

  const token = mintSittingToken();
  // Creation and resolution both hash the token's UTF-8 bytes. The helper also
  // accepts raw bytes for media checksums, so neither caller can accidentally
  // hand Web Crypto the wrong input type.
  const tokenHash = await sha256Hex(token);

  const result = await withAccount(me, async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${`sitting-invite:${inviteID}`}, 0))`;
    const [grove] = await tx`select id from app.groves where owner_account_id = ${me} limit 1`;
    if (!grove) return { status: 503, message: "Your account is still being set up. Try again in a moment." };

    const owned = await tx`
        select plant.id from app.plants plant
        where plant.id = any(${plantIDs}::uuid[]) and plant.grove_id = ${grove.id}`;
    if (owned.length !== plantIDs.length) {
      return { status: 422, message: "Only plants from your own Grove can go on a link." };
    }
    if (recipientAccountID) {
      const [friendship] = await tx`
          select id from app.friendships
          where status = 'accepted'
            and ((requested_by_account_id = ${me} and requested_to_account_id = ${recipientAccountID})
              or (requested_by_account_id = ${recipientAccountID} and requested_to_account_id = ${me}))`;
      if (!friendship) return { status: 422, message: "That person is no longer connected to your Grove." };
    }

    const [existing] = await tx`select id from app.sitting_invites where id = ${inviteID}`;
    if (existing) {
      return { status: 409, message: "That link was already made. Make a new one to share again." };
    }

    await tx`select pg_advisory_xact_lock(hashtextextended(${`sitting-invite-rate:${me}`}, 0))`;
    const [{ outstanding_count: outstandingCount }] = await tx`
        select count(*)::int as outstanding_count
          from app.sitting_invites
         where owner_account_id = ${me}
           and revoked_at is null
           and ends_at >= now()`;
    if (Number(outstandingCount) >= 100) {
      return { status: 429, message: "Revoke an old sitting link before making another." };
    }
    const [{ recent_count: recentCount }] = await tx`
        select count(*)::int as recent_count
          from app.sitting_invites
         where owner_account_id = ${me}
           and created_at >= now() - interval '24 hours'`;
    if (Number(recentCount) >= 100) {
      return { status: 429, message: "You have made too many sitting links today. Try again tomorrow." };
    }

    const [invite] = await tx`
        insert into app.sitting_invites (
          id, owner_account_id, grove_id, token_hash, label, starts_at, ends_at,
          can_log_care, owner_notes, time_zone_identifier, recipient_account_id
        ) values (
          ${inviteID}, ${me}, ${grove.id}, ${tokenHash}, ${label}, ${startsAt}, ${endsAt},
          ${canLogCare}, ${ownerNotes}, ${timeZoneIdentifier}, ${recipientAccountID}
        )
        returning *`;
    for (const plantID of plantIDs) {
      await tx`insert into app.sitting_invite_plants (invite_id, plant_id) values (${inviteID}, ${plantID}) on conflict do nothing`;
    }
    return { status: 201, invite };
  });

  if (!result.invite) return failure(result.status, result.message ?? "That link could not be made.");
  return json(201, {
    id: result.invite.id,
    url: sittingLinkURL(token),
    expiresAt: iso(result.invite.ends_at)
  });
}

async function revokeSittingInvite(me: string, inviteIDRaw: string): Promise<Response> {
  const inviteID = lower(inviteIDRaw);
  if (!uuidPattern.test(inviteID)) return failure(404, "That link no longer exists.");
  const revoked = await withAccount(me, async (tx) => {
    const [row] = await tx`
        update app.sitting_invites
        set revoked_at = coalesce(revoked_at, now())
        where id = ${inviteID} and owner_account_id = ${me}
        returning id, revoked_at`;
    return row;
  });
  // Already gone counts as done — revoking is the one call that must never
  // fail for having already worked.
  if (!revoked) return failure(404, "That link no longer exists.");
  return json(200, { id: revoked.id, revokedAt: iso(revoked.revoked_at) });
}

// ---------------------------------------------------------------------------
// Media

async function negotiateMediaUpload(me: string, body: Row): Promise<Response> {
  const localMediaID = lower(body.localMediaID);
  if (!uuidPattern.test(localMediaID)) return failure(422, "Local media id must be a UUID.");
  if (!["image/jpeg", "image/png"].includes(body.mimeType)) return failure(422, "Media must be JPEG or PNG.");
  const byteCount = Number(body.byteCount);
  if (!Number.isInteger(byteCount) || byteCount < 1 || byteCount > 8 * 1024 * 1024) {
    return failure(422, "Media byte count is outside the supported range.");
  }
  if (!/^[0-9a-f]{64}$/i.test(body.sha256 ?? "")) return failure(422, "Media checksum is invalid.");
  const purpose = ["scan", "observation", "avatar", "shared_progress"].includes(body.purpose) ? body.purpose : "observation";
  const sha256 = String(body.sha256).toLowerCase();

  const result = await withAccount(me, async (tx) => {
    const [existing] = await tx`
        select * from app.media_assets
        where owner_account_id = ${me} and local_media_id = ${localMediaID}`;
    if (existing) {
      if (existing.sha256 !== sha256 || Number(existing.byte_count) !== byteCount || existing.mime_type !== body.mimeType) {
        return { status: 409 };
      }
      return { status: 200, asset: existing };
    }
    const assetID = crypto.randomUUID();
    const [created] = await tx`
        insert into app.media_assets (
          id, owner_account_id, storage_key, purpose, mime_type,
          pixel_width, pixel_height, byte_count, local_media_id, sha256, status
        ) values (
          ${assetID}, ${me}, ${`${me}/${assetID}`}, ${purpose}, ${body.mimeType},
          ${Number(body.pixelWidth) || null}, ${Number(body.pixelHeight) || null},
          ${byteCount}, ${localMediaID}, ${sha256}, 'pending'
        )
        returning *`;
    return { status: 201, asset: created };
  });

  if (result.status === 409) return failure(409, "Local media id was already used for different content.");
  const { data: signed, error } = await supabase.storage
    .from(mediaBucket)
    .createSignedUploadUrl(result.asset.storage_key, { upsert: true });
  if (error || !signed?.signedUrl) {
    return failure(503, "Photo storage is temporarily unavailable. Retry sync shortly.");
  }
  return json(result.status, {
    mediaAssetID: result.asset.id,
    uploadURL: signed.signedUrl,
    headers: {},
    expiresAt: iso(new Date(Date.now() + 2 * 3600_000))
  });
}

async function completeMediaUpload(me: string, assetIDRaw: string, body: Row): Promise<Response> {
  const assetID = lower(assetIDRaw);
  if (!uuidPattern.test(assetID)) return failure(404, "Media upload not found.");

  const asset = await withAccount(me, async (tx) => {
    const [row] = await tx`
        select * from app.media_assets where id = ${assetID} and owner_account_id = ${me}`;
    return row;
  });
  if (!asset) return failure(404, "Media upload not found.");
  if (asset.status === "ready") {
    return json(200, { mediaAssetID: asset.id, status: "ready" });
  }

  const { data: blob, error } = await supabase.storage.from(mediaBucket).download(asset.storage_key);
  if (error || !blob) {
    return failure(422, "The uploaded photo has not arrived yet. Retry sync to send it again.");
  }
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const checksum = await sha256Hex(bytes);
  if (bytes.byteLength !== Number(asset.byte_count) || checksum !== asset.sha256 || checksum !== String(body.sha256 ?? "").toLowerCase()) {
    return failure(422, "Uploaded media checksum does not match.");
  }

  await withAccount(me, async (tx) => {
    await tx`update app.media_assets set status = 'ready' where id = ${assetID} and owner_account_id = ${me}`;
  });
  return json(200, { mediaAssetID: asset.id, status: "ready" });
}

// ---------------------------------------------------------------------------
// Idempotency replay

type IdempotencyClaim = {
  claimID?: string;
  response?: Response;
  wait?: boolean;
};

async function claimIdempotency(me: string, cacheKey: string, requestHash: string): Promise<IdempotencyClaim> {
  return await sql.begin(async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${`api-idempotency:${me}`}, 0))`;
    const [row] = await tx`
        select status, body, request_hash, claim_id,
               stored_at < now() - interval '15 minutes' as stale
          from public.api_idempotency
         where account_id = ${me} and cache_key = ${cacheKey}
         for update`;

    const claimID = crypto.randomUUID();
    if (!row) {
      await tx`
          insert into public.api_idempotency
              (account_id, cache_key, request_hash, claim_id, status, body)
          values (${me}, ${cacheKey}, ${requestHash}, ${claimID}, 102, '{}'::jsonb)`;
      return { claimID };
    }

    // A process that died after reserving a key must not pin that mutation
    // forever. The claim id prevents the old worker from completing over a
    // replacement if it unexpectedly comes back after the lease expires.
    if (Number(row.status) === 102 && row.stale === true) {
      await tx`
          update public.api_idempotency
             set request_hash = ${requestHash}, claim_id = ${claimID},
                 status = 102, body = '{}'::jsonb, stored_at = now()
           where account_id = ${me} and cache_key = ${cacheKey}`;
      return { claimID };
    }
    if (!row.request_hash || row.request_hash !== requestHash) {
      return { response: failure(409, "That request key was already used for different details.") };
    }
    if (Number(row.status) === 102) return { wait: true };
    return { response: json(Number(row.status), jsonbValue(row.body)) };
  });
}

async function remember(
  me: string,
  cacheKey: string,
  requestHash: string,
  claimID: string,
  response: Response
): Promise<Response> {
  const succeeded = response.status >= 200 && response.status < 300;
  const body = succeeded ? await response.clone().json() : undefined;
  await sql.begin(async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${`api-idempotency:${me}`}, 0))`;
    if (succeeded) {
      await tx`
          update public.api_idempotency
             set status = ${response.status}, body = ${body}::jsonb, stored_at = now()
           where account_id = ${me} and cache_key = ${cacheKey}
             and request_hash = ${requestHash} and claim_id = ${claimID}`;
    } else {
      await tx`
          delete from public.api_idempotency
           where account_id = ${me} and cache_key = ${cacheKey}
             and status = 102 and request_hash = ${requestHash} and claim_id = ${claimID}`;
    }
    // A client can choose this header. Bound replay storage per account so
    // rotating keys against successful friend requests cannot grow the table.
    await tx`
        delete from public.api_idempotency stored
        where stored.account_id = ${me}
          and stored.cache_key in (
            select cache_key from public.api_idempotency
             where account_id = ${me}
             order by stored_at desc, cache_key
             offset 1000
          )`;
  });
  return response;
}

async function abandonIdempotency(
  me: string,
  cacheKey: string,
  requestHash: string,
  claimID: string
): Promise<void> {
  await sql`
      delete from public.api_idempotency
       where account_id = ${me} and cache_key = ${cacheKey}
         and status = 102 and request_hash = ${requestHash} and claim_id = ${claimID}`;
}

async function idempotent(
  me: string,
  cacheKey: string | undefined,
  requestHash: string,
  operation: () => Promise<Response>
): Promise<Response> {
  if (!cacheKey) return await operation();

  for (let attempt = 0; attempt < 21; attempt += 1) {
    const claim = await claimIdempotency(me, cacheKey, requestHash);
    if (claim.response) return claim.response;
    if (claim.claimID) {
      let response: Response;
      try {
        response = await operation();
      } catch (caught) {
        try {
          await abandonIdempotency(me, cacheKey, requestHash, claim.claimID);
        } catch (cleanupError) {
          console.error("could not abandon idempotency claim", cleanupError);
        }
        throw caught;
      }
      try {
        return await remember(me, cacheKey, requestHash, claim.claimID, response);
      } catch (completionError) {
        // The mutation has already committed. Return its real response instead
        // of manufacturing a retry that could apply it twice. The live claim
        // remains a short lease if the replay row could not be completed.
        console.error("could not complete idempotency claim", completionError);
        return response;
      }
    }
    if (attempt < 20) await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return failure(503, "That change is still being saved. Grove will retry it shortly.");
}

async function sweepIdempotency() {
  await sql`delete from public.api_idempotency where stored_at < now() - interval '24 hours'`;
}

async function deleteAccount(me: string): Promise<Response> {
  try {
    await deleteAccountData({
      accountID: me,
      loadStoragePaths: async () => {
        // Query tracked keys and also page the owner folder. The latter catches
        // an object whose database write was interrupted, while pagination
        // avoids silently abandoning everything after photo 1,000.
        const tracked = await sql`
          select storage_key from app.media_assets where owner_account_id = ${me}
          union
          select avatar_storage_key as storage_key from app.accounts
          where id = ${me} and avatar_storage_key is not null
        `;
        const paths = tracked.map((row) => String(row.storage_key));
        for (let offset = 0; ; ) {
          const { data, error } = await supabase.storage
            .from(mediaBucket)
            .list(me, { limit: 1_000, offset, sortBy: { column: "name", order: "asc" } });
          if (error) throw error;
          const objects = data ?? [];
          paths.push(...objects
            .filter((object) => object.name && object.name !== ".emptyFolderPlaceholder")
            .map((object) => `${me}/${object.name}`));
          if (objects.length < 1_000) break;
          offset += objects.length;
        }
        return paths;
      },
      removeStoragePaths: async (paths: string[]) => {
        const { error } = await supabase.storage.from(mediaBucket).remove(paths);
        if (error) throw error;
      },
      cleanDetachedData: async () => {
        // Most app rows cascade from auth.users → app.accounts → the owned
        // Grove. These three actor references intentionally do not: a sitter
        // can contribute to someone else's Grove. Remove/anonymise those
        // references first, and explicitly erase service tables that use text
        // account ids rather than foreign keys.
        await sql.begin(async (tx) => {
          await tx`delete from app.observations where performed_by_account_id = ${me}`;
          await tx`update app.observations set on_behalf_of_account_id = null where on_behalf_of_account_id = ${me}`;
          await tx`update app.care_actions set performed_by_account_id = null where performed_by_account_id = ${me}`;
          await tx`delete from public.api_idempotency where account_id = ${me}`;
          await tx`delete from public.analysis_jobs where owner_account_id = ${me}`;
          await tx`delete from public.analysis_usage where account_id = ${me}`;
          await tx`delete from public.botanist_usage where account_id = ${me}`;
          await tx`delete from public.botanist_requests where account_id = ${me}`;
          await tx`delete from public.botanist_advice where account_id = ${me}`;
          await tx`delete from public.botanist_entitlements where account_id = ${me}`;
        });
      },
      deleteIdentity: async () => {
        const { error } = await supabase.auth.admin.deleteUser(me);
        if (error) throw error;
      }
    });
    return json(200, { deleted: true });
  } catch (error) {
    const stage = error instanceof AccountDeletionFailure ? error.stage : "identity";
    if (stage === "storage-list" || stage === "storage-scope") {
      return failure(503, "Grove couldn't inspect your stored photos. Nothing was deleted; try again.");
    }
    if (stage === "storage-remove") {
      return failure(503, "Grove couldn't finish removing your stored photos. Your account is still active; try again.");
    }
    return failure(503, "Grove couldn't delete your account completely. Your account is still active; try again.");
  }
}

// ---------------------------------------------------------------------------
// Router

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("api") + 1);

  if (request.method === "GET" && route[0] === "health") {
    try {
      // pg_catalog rather than information_schema: those views join and
      // permission-filter the whole catalog, which cost this probe seconds and
      // made the release preflight's 10s budget flaky. These are index lookups
      // on the same facts.
      const [row] = await sql`
          select
            (
              select count(*)
              from pg_class table_entry
              join pg_namespace schema_entry on schema_entry.oid = table_entry.relnamespace
              where schema_entry.nspname = 'app'
                and table_entry.relkind in ('r', 'p', 'v', 'f')
            ) as app_table_count,
            (
              select count(*)
              from pg_attribute column_entry
              where column_entry.attrelid = to_regclass('app.accounts')
                and column_entry.attname in ('signup_completed_at', 'signup_completion_claim_id')
                and column_entry.attnum > 0
                and not column_entry.attisdropped
            ) = 2
            and to_regprocedure('public.grove_signup_completed()') is not null
            and to_regprocedure('public.grove_complete_signup(uuid)') is not null
              as signup_completion_ready`;
      return json(200, {
        status: "ok",
        service: "grove-api",
        database: "connected",
        appTableCount: Number(row.app_table_count),
        signupCompletionReady: row.signup_completion_ready === true
      });
    } catch {
      return json(200, {
        status: "ok",
        service: "grove-api",
        database: "unavailable",
        signupCompletionReady: false
      });
    }
  }

  const appKey = Deno.env.get("GROVE_APP_KEY");
  if (appKey && request.headers.get("x-grove-app-key") !== appKey) {
    return failure(401, "App identification is missing or invalid.");
  }
  const me = await verifiedAccountID(request);
  if (!me) return failure(401, "A bearer token is required.");

  if (route[0] !== "v1") return failure(404, "Route not found.");
  const path = route.slice(1);

  try {
    if (request.method === "GET" && path[0] === "bootstrap") {
      return await bootstrap(me);
    }
    if (request.method === "DELETE" && path[0] === "account" && path.length === 1) {
      return await deleteAccount(me);
    }

    let body: Row = {};
    let requestText = "";
    if (request.method !== "GET") {
      try {
        requestText = await boundedRequestText(request);
        const parsed = requestText ? JSON.parse(requestText) : {};
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
          return failure(400, "Request body must be a JSON object.");
        }
        body = parsed;
      } catch (caught) {
        if (caught instanceof RequestBodyTooLargeError) return failure(413, "Request is too large.");
        return failure(400, "Invalid request.");
      }
    }

    // Mutations below replay through the idempotency table when a bounded key
    // is sent. Hashing the body turns key reuse with different details into a
    // conflict instead of replaying an unrelated friend invitation response.
    const rawIdempotencyKey = request.method === "GET" ? undefined : request.headers.get("idempotency-key")?.trim();
    if (rawIdempotencyKey && !/^[a-z0-9._:-]{1,128}$/i.test(rawIdempotencyKey)) {
      return failure(422, "Idempotency key is invalid.");
    }
    const idempotencyKey = rawIdempotencyKey;
    const requestHash = await sha256Hex(requestText);
    const cacheKey = idempotencyKey ? `${request.method}:${path.join("/").toLowerCase()}:${idempotencyKey}` : undefined;
    if (cacheKey && Math.random() < 0.05) scheduleBackground(sweepIdempotency());
    const finish = (operation: () => Promise<Response>) =>
      idempotent(me, cacheKey, requestHash, operation);

    if (request.method === "POST" && path[0] === "devices" && path.length === 1) {
      return await finish(() => registerDevice(me, body));
    }
    if (request.method === "DELETE" && path[0] === "devices" && path.length === 2) {
      return await finish(() => unregisterDevice(me, path[1]));
    }
    if (request.method === "PATCH" && path[0] === "profile" && path.length === 1) {
      return await finish(() => updateProfile(me, body));
    }
    if (request.method === "PATCH" && path[0] === "journey-progress" && path.length === 1) {
      return await finish(() => updateGardenerProgress(me, body));
    }
    if (request.method === "POST" && path[0] === "plants" && path.length === 1) {
      return await finish(() => createPlant(me, body));
    }
    if (request.method === "PATCH" && path[0] === "plants" && path.length === 2) {
      return await finish(() => updatePlant(me, path[1], body));
    }
    if (request.method === "POST" && path[0] === "plants" && path[2] === "delete" && path.length === 3) {
      return await finish(() => deletePlant(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "plants" && path[2] === "check-ins" && path.length === 3) {
      return await finish(() => createCheckIn(me, path[1], body));
    }
    if (request.method === "PATCH" && path[0] === "care-actions" && path.length === 2) {
      return await finish(() => updateCareTask(me, path[1], body));
    }
    if (request.method === "POST" && path[0] === "care-actions" && path.length === 1) {
      return await finish(() => createCareEvent(me, body));
    }
    if (request.method === "POST" && path[0] === "care-actions" && path[2] === "delete" && path.length === 3) {
      return await finish(() => deleteCareEvent(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[1] === "invitations" && path.length === 2) {
      return await finish(() => createFriendInvitation(me, body));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[2] === "respond" && path.length === 3) {
      return await finish(() => respondToFriendInvitation(me, path[1], body));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[2] === "withdraw" && path.length === 3) {
      return await finish(() => withdrawFriendInvitation(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[2] === "remove" && path.length === 3) {
      return await finish(() => removeFriend(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[2] === "block" && path.length === 3) {
      return await finish(() => blockFriend(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "friendships" && path[2] === "report" && path.length === 3) {
      return await finish(() => reportFriend(me, path[1], body));
    }
    if (request.method === "POST" && path[0] === "sitting-assignments" && path.length === 1) {
      return await finish(() => createSittingAssignment(me, body));
    }
    if (request.method === "POST" && path[0] === "sitting-assignments" && path[2] === "respond" && path.length === 3) {
      return await finish(() => respondToSittingAssignment(me, path[1], body));
    }
    if (request.method === "POST" && path[0] === "sitting-assignments" && path[2] === "revoke" && path.length === 3) {
      return await finish(() => revokeSittingAssignment(me, path[1]));
    }
    // Not wrapped in `finish`: the idempotency cache stores response bodies,
    // and this one carries the token in the clear. See `createSittingInvite`.
    if (request.method === "POST" && path[0] === "sitting-invites" && path.length === 1) {
      return await createSittingInvite(me, body);
    }
    if (request.method === "POST" && path[0] === "sitting-invites" && path[2] === "revoke" && path.length === 3) {
      return await finish(() => revokeSittingInvite(me, path[1]));
    }
    if (request.method === "POST" && path[0] === "media" && path[1] === "uploads" && path.length === 2) {
      return await finish(() => negotiateMediaUpload(me, body));
    }
    if (request.method === "POST" && path[0] === "media" && path[2] === "complete" && path.length === 3) {
      return await finish(() => completeMediaUpload(me, path[1], body));
    }

    return failure(404, "Route not found.");
  } catch (caught) {
    console.error("api function error", caught);
    return failure(503, "Grove’s service is temporarily unavailable. Your changes stay saved on this device.");
  }
});
