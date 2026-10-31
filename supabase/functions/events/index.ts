// Grove's diagnostics sink.
//
//   POST /events        record a batch of funnel events
//   GET  /events/health  unauthenticated probe
//
// Gated on the shared app key rather than a JWT, because the events worth having
// happen *before* an account exists — the point of the onboarding funnel is to
// see where people leave during sign-up. The app key is a caller gate, not a
// secret; it ships in every binary. The ceilings below are what actually keeps
// the table from being filled by whoever reads it out of the binary.
//
// Nothing here identifies a person. The client sends a random per-install id and
// a small map of string parameters; there is no account id, no device id, and no
// IP address recorded. If you add a field, check it against the "Diagnostics"
// section of the privacy policy in `supabase/functions/legal/index.ts` — the two
// must stay true to each other.

import postgres from "npm:postgres";

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// One flush from one install. Anything larger is a bug or an attack, and the
// client's own buffer is far below this.
const maxEventsPerBatch = 50;
const maxNameLength = 64;
const maxParamKeys = 12;
const maxParamValueLength = 256;

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  ssl: "require",
  prepare: false,
  max: 2,
  idle_timeout: 20,
  connect_timeout: 10
});

function json(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

function failure(status: number, message: string): Response {
  return json(status, { message });
}

function scheduleBackground(work: Promise<unknown>) {
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(work);
}

/// Keeps only string→string pairs, bounded in count and length. Anything else
/// the client sends is dropped rather than stored, so a client bug cannot put
/// free text of unknown provenance into the table.
function sanitizedParams(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const cleaned: Record<string, string> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (Object.keys(cleaned).length >= maxParamKeys) break;
    if (typeof raw !== "string") continue;
    if (!key || key.length > maxNameLength) continue;
    cleaned[key] = raw.slice(0, maxParamValueLength);
  }
  return cleaned;
}

/// Clamps a client timestamp into a believable window. Device clocks are wrong
/// often enough that an unclamped value would put events in 1970 or far in the
/// future, quietly ruining every funnel query run afterwards.
function occurredAt(value: unknown): Date {
  const now = Date.now();
  const parsed = typeof value === "string" ? Date.parse(value) : NaN;
  if (Number.isNaN(parsed)) return new Date(now);
  const weekAgo = now - 7 * 86_400_000;
  const hourAhead = now + 3_600_000;
  return new Date(Math.min(Math.max(parsed, weekAgo), hourAhead));
}

async function record(body: Record<string, unknown>): Promise<Response> {
  const installID = String(body.installID ?? "").toLowerCase();
  if (!uuidPattern.test(installID)) return failure(422, "A valid install id is required.");

  const incoming = Array.isArray(body.events) ? body.events.slice(0, maxEventsPerBatch) : [];
  const rows = incoming.flatMap((entry) => {
    const event = (entry ?? {}) as Record<string, unknown>;
    const name = String(event.name ?? "").slice(0, maxNameLength);
    if (!name) return [];
    // Keys are read back out by the `select` below, so they stay camelCase.
    return [{
      name,
      params: sanitizedParams(event.params),
      occurredAt: occurredAt(event.occurredAt).toISOString()
    }];
  });

  // An empty batch is a success: the client has nothing to say and should drop
  // its buffer rather than retry forever.
  //
  // One statement, one parameter. postgres.js only applies its JSON serializer
  // when a parameter carries an explicit `::jsonb` cast hint, and the
  // bulk-insert helper has no way to express that per column. The batch is
  // wrapped in an *object* rather than passed as a bare array because the
  // driver would send an array as a Postgres array, not as JSON — the same
  // `${object}::jsonb` idiom the sync API uses everywhere else.
  if (!rows.length) return json(202, { accepted: 0 });

  const inserted = await sql`
      insert into public.analytics_events (install_id, name, params, occurred_at)
      select
        ${installID}::uuid,
        entry->>'name',
        coalesce(entry->'params', '{}'::jsonb),
        (entry->>'occurredAt')::timestamptz
      from jsonb_array_elements((${sql.json({ events: rows })}::jsonb)->'events') as entry
      returning id`;

  // Counted from `returning`, not from `rows.length`. If the jsonb parameter
  // ever arrives double-encoded, `->'events'` yields NULL,
  // `jsonb_array_elements` expands to no rows, and the insert quietly writes
  // nothing — reporting the intended count would hide exactly that.
  return json(202, { accepted: inserted.length });
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("events") + 1);

  if (request.method === "GET" && route[0] === "health") {
    return json(200, { status: "ok", service: "grove-events" });
  }

  const appKey = Deno.env.get("GROVE_APP_KEY");
  if (appKey && request.headers.get("x-grove-app-key") !== appKey) {
    return failure(401, "App identification is missing or invalid.");
  }

  if (request.method === "POST" && route.length === 0) {
    let body: Record<string, unknown>;
    try {
      const text = await request.text();
      body = text ? JSON.parse(text) : {};
    } catch {
      return failure(400, "Invalid request.");
    }
    try {
      // Cheap and rare: honours the 12-month retention promise without a cron.
      if (Math.random() < 0.01) scheduleBackground(sql`select public.sweep_analytics_events()`);
      return await record(body);
    } catch (caught) {
      console.error("events function error", caught);
      // Diagnostics must never be the reason a user's app misbehaves. The
      // client discards the batch on any 2xx and retries on 5xx; a failure here
      // is ours to notice in logs, not theirs to see.
      return failure(503, "Diagnostics are temporarily unavailable.");
    }
  }

  return failure(404, "Route not found.");
});
