// The page a plant sitter opens.
//
//   GET  /sit/:token        the care sheet
//   POST /sit/:token        tick one task off (form post, then redirect)
//   GET  /sit/health        unauthenticated probe
//
// This is the only surface in Grove with no account behind it, and the design
// follows from that:
//
//   * **The token is the whole authorisation.** 256 bits from the CSPRNG,
//     stored only as a SHA-256 digest, matched here by hashing what arrived.
//     A wrong token and an expired one give the same answer, so the page never
//     confirms that a token exists.
//   * **It scopes to plants, not to a grove.** Every query joins through
//     `sitting_invite_plants`, so the sheet cannot widen to the rest of the
//     collection even if the owner adds plants mid-trip.
//   * **No JavaScript.** Ticking a task is a form POST followed by a redirect.
//     A neighbour on a six-year-old Android in a kitchen doorway gets the same
//     page as anybody else, and there is no script that could leak the token
//     to a third party.
//   * **It ends by itself.** `ends_at` is checked on every request, so an owner
//     who never revokes anything still stops sharing when they get home.

import postgres from "npm:postgres";
import { type PushPayload, sendPush } from "../_shared/apns.ts";

const htmlHeaders = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
};
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  ssl: "require",
  prepare: false,
  max: 2,
  idle_timeout: 20,
  connect_timeout: 10
});

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

function jsonbValue(value: unknown): Row {
  if (typeof value === "string") {
    try { return JSON.parse(value); } catch { return {}; }
  }
  return (value as Row) ?? {};
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function boundedForm(request: Request, maximumBytes = 16_384): Promise<URLSearchParams> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/x-www-form-urlencoded")) {
    throw new RangeError("Unsupported form encoding");
  }
  if (!request.body) return new URLSearchParams();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteCount += value.byteLength;
    if (byteCount > maximumBytes) {
      await reader.cancel();
      throw new RangeError("Form too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new URLSearchParams(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

/// Everything interpolated into the page goes through this. The nicknames and
/// instructions are user-written, and this page is served to third parties.
function escapeHTML(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDate(value: unknown, timeZone = "UTC"): string {
  const date = value instanceof Date ? value : new Date(String(value));
  if (!Number.isFinite(date.getTime())) return "";
  try {
    return date.toLocaleDateString("en-GB", { day: "numeric", month: "long", timeZone });
  } catch {
    return date.toLocaleDateString("en-GB", { day: "numeric", month: "long", timeZone: "UTC" });
  }
}

const careTitles: Record<string, string> = {
  water: "Water",
  inspectSoil: "Check the soil",
  inspect_soil: "Check the soil",
  rotate: "Turn it a quarter",
  prune: "Prune",
  treat: "Treat",
  checkIn: "Look it over",
  check_in: "Look it over",
  repot: "Repot",
  fertilise: "Feed"
};

function careTitle(kind: string): string {
  return careTitles[kind] ?? "Care";
}

// ---------------------------------------------------------------------------
// Pages

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<!-- A referrer would carry the token to whatever the sitter taps next. -->
<meta name="referrer" content="no-referrer">
<title>${escapeHTML(title)}</title>
<style>
  :root {
    --canvas: #F4F1E8;
    --surface: #FCFBF7;
    --ink: #14130F;
    --muted: #6E6B60;
    --line: #E6E2D7;
    --accent: #2C6B1C;
    --soft: #E4EFDB;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --canvas: #16150F;
      --surface: #201E18;
      --ink: #F4F2EC;
      --muted: #A6A296;
      --line: #322F28;
      --accent: #8FD46E;
      --soft: #1E2A16;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 24px 18px 56px;
    background: var(--canvas);
    color: var(--ink);
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    -webkit-text-size-adjust: 100%;
  }
  main { max-width: 34rem; margin: 0 auto; }
  h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 6px; }
  .lede { color: var(--muted); margin: 0 0 28px; }
  .card {
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 20px;
    padding: 18px;
    margin-bottom: 16px;
  }
  .card h2 { font-size: 1.1rem; margin: 0 0 2px; }
  .where { color: var(--muted); font-size: 0.9rem; margin: 0 0 14px; }
  .task {
    display: flex;
    align-items: center;
    gap: 12px;
    border-top: 1px solid var(--line);
    padding: 12px 0 0;
    margin-top: 12px;
  }
  .task:first-of-type { border-top: 0; margin-top: 0; padding-top: 0; }
  .task-copy { flex: 1; min-width: 0; }
  .task-title { font-weight: 600; }
  .task-detail { color: var(--muted); font-size: 0.92rem; }
  .done-badge { color: var(--accent); font-weight: 700; font-size: 0.9rem; white-space: nowrap; }
  button {
    font: inherit;
    font-weight: 700;
    color: var(--accent);
    background: var(--soft);
    border: 0;
    border-radius: 999px;
    padding: 10px 16px;
    cursor: pointer;
    white-space: nowrap;
  }
  textarea {
    width: 100%;
    min-height: 7rem;
    resize: vertical;
    margin: 10px 0;
    padding: 12px;
    color: var(--ink);
    background: var(--canvas);
    border: 1px solid var(--line);
    border-radius: 12px;
    font: inherit;
  }
  .nothing { color: var(--muted); font-size: 0.95rem; }
  footer { color: var(--muted); font-size: 0.85rem; margin-top: 28px; }
</style>
</head>
<body><main>${body}</main></body>
</html>`,
    { status, headers: htmlHeaders }
  );
}

/// One answer for "no such link", "revoked", and "the trip is over", so the
/// page never tells a stranger which of the three they found.
function gonePage(): Response {
  return page(
    "Link finished",
    `<h1>This link has finished</h1>
     <p class="lede">Plant-sitting links stop working when the trip they were made for ends. If you think you still need it, ask whoever sent it to you for a new one.</p>`,
    404
  );
}

// ---------------------------------------------------------------------------
// Data

async function inviteForToken(token: string): Promise<Row | undefined> {
  const tokenHash = await sha256Hex(token);
  const [invite] = await sql`
      select invite.*, account.display_name as owner_name
      from app.sitting_invites invite
      join app.accounts account on account.id = invite.owner_account_id
      where invite.token_hash = ${tokenHash}`;
  if (!invite) return undefined;
  if (invite.revoked_at) return undefined;
  const now = Date.now();
  // The owner chose both boundaries. Before the start this row is returned only
  // so the acknowledgement page can record that the sitter received the link;
  // the care sheet itself stays hidden until `starts_at`. A hidden day of grace
  // after the end would make "stops working on the end date" untrue. Whole-day
  // normalisation happens in the app, so this exact end instant includes the
  // owner's final calendar day.
  if (now > new Date(invite.ends_at).getTime()) return undefined;
  return invite;
}

async function sheetFor(invite: Row): Promise<{ plants: Row[]; tasks: Row[] }> {
  const plants = await sql`
      select plant.id, plant.nickname, plant.common_name, plant.presentation
      from app.plants plant
      join app.sitting_invite_plants scope on scope.plant_id = plant.id
      where scope.invite_id = ${invite.id} and plant.archived_at is null
      order by plant.nickname`;

  // Only what falls inside the trip, and only what is still outstanding —
  // plus anything the sitter themselves ticked off, so the page can show
  // their own work back to them.
  const tasks = await sql`
      select action.id, action.plant_id, action.kind, action.instructions,
             action.due_from, action.status,
             log.logged_at as sitter_logged_at
      from app.care_actions action
      join app.sitting_invite_plants scope on scope.plant_id = action.plant_id
      left join app.sitting_invite_care_log log
             on log.care_action_id = action.id and log.invite_id = ${invite.id}
      where scope.invite_id = ${invite.id}
        and action.status in ('proposed', 'due', 'completed')
        and coalesce(action.due_from, now()) <= ${invite.ends_at}
        and (action.status <> 'completed' or log.id is not null)
      order by action.due_from nulls last`;

  return { plants, tasks };
}

// ---------------------------------------------------------------------------
// Rendering

function renderSheet(invite: Row, plants: Row[], tasks: Row[]): Response {
  const owner = String(invite.owner_name ?? "").trim().split(/\s+/)[0] || "Someone";
  const timeZone = String(invite.time_zone_identifier ?? "UTC");
  const until = formatDate(invite.ends_at, timeZone);

  const cards = plants.map((plant) => {
    const presentation = jsonbValue(plant.presentation);
    const mine = tasks.filter((task) => task.plant_id === plant.id);
    const rows = mine.length
      ? mine.map((task) => renderTask(task, invite.can_log_care, plant.nickname, timeZone)).join("")
      : `<p class="nothing">Nothing due while ${escapeHTML(owner)} is away. Just keep an eye on it.</p>`;
    return `<section class="card">
      <h2>${escapeHTML(plant.nickname)}</h2>
      <p class="where">${escapeHTML(presentation.location ?? "Somewhere in the house")}${
        plant.common_name ? ` · ${escapeHTML(plant.common_name)}` : ""
      }</p>
      ${rows}
    </section>`;
  }).join("");

  return page(
    `${owner}'s plants`,
    `<h1>${escapeHTML(owner)}'s plants</h1>
     <p class="lede">Thanks for looking after ${plants.length === 1 ? "this one" : "these"} until ${escapeHTML(until)}.</p>
     ${invite.owner_notes ? `<section class="card"><h2>Handover note</h2><p>${escapeHTML(invite.owner_notes)}</p></section>` : ""}
     ${cards || `<section class="card"><p class="nothing">There is nothing on this link any more.</p></section>`}
     <section class="card">
       <h2>Need to tell ${escapeHTML(owner)} something?</h2>
       <p class="nothing">Leave a short note or concern. Grove will notify them without claiming who wrote it.</p>
       <form method="post">
         <textarea name="sitterNote" maxlength="500" required aria-label="Note for ${escapeHTML(owner)}" placeholder="For example: the fern still feels very wet, so I left it alone."></textarea>
         <button type="submit">Send note</button>
       </form>
     </section>
     <footer>Sent from Grove. This page only shows the plants ${escapeHTML(owner)} picked, and stops working after ${escapeHTML(until)}.</footer>`
  );
}

function upcomingPage(invite: Row): Response {
  const owner = String(invite.owner_name ?? "").trim().split(/\s+/)[0] || "Someone";
  const timeZone = String(invite.time_zone_identifier ?? "UTC");
  const starts = formatDate(invite.starts_at, timeZone);
  return page(
    "Sitting link received",
    `<h1>You're all set</h1>
     <p class="lede">${escapeHTML(owner)}'s plant-care sheet will open here on ${escapeHTML(starts)}. Nothing about their plants is shown before then.</p>
     <section class="card"><p class="nothing">You can close this page. Grove has told ${escapeHTML(owner)} that their link was opened.</p></section>`
  );
}

function renderTask(task: Row, canLogCare: boolean, plantNickname: string, timeZone: string): string {
  const title = escapeHTML(careTitle(String(task.kind)));
  const detail = escapeHTML(task.instructions ?? "");
  if (task.sitter_logged_at) {
    return `<div class="task">
      <div class="task-copy">
        <div class="task-title">${title}</div>
        <div class="task-detail">${detail}</div>
      </div>
      <div class="done-badge">Done ✓</div>
    </div>`;
  }
  // A guided check-in needs photos, answers and a health assessment. The plain
  // web sheet can show that it is due, but a single Done button must not close
  // it without producing any of that evidence.
  const isGuidedCheckIn = ["checkIn", "check_in"].includes(String(task.kind));
  const dueAt = task.due_from ? new Date(task.due_from).getTime() : Date.now();
  const isDue = Number.isFinite(dueAt) && dueAt <= Date.now();
  const action = canLogCare && !isGuidedCheckIn && isDue
    ? `<form method="post"><input type="hidden" name="careActionID" value="${escapeHTML(task.id)}"><button type="submit" aria-label="Mark ${title} for ${escapeHTML(plantNickname)} done">Done</button></form>`
    : !isDue
      ? `<div class="done-badge">Due ${escapeHTML(formatDate(task.due_from, timeZone))}</div>`
      : "";
  return `<div class="task">
    <div class="task-copy">
      <div class="task-title">${title}</div>
      <div class="task-detail">${detail}</div>
    </div>
    ${action}
  </div>`;
}

// ---------------------------------------------------------------------------
// Ticking a task off

async function logCare(invite: Row, careActionID: string): Promise<Row | undefined> {
  if (!invite.can_log_care) return undefined;
  return await sql.begin(async (tx) => {
    // The join is the authorisation: an id that is not on this link updates
    // nothing, whatever it belongs to.
    const [action] = await tx`
        update app.care_actions action
        set status = 'completed', performed_at = now()
        from app.sitting_invite_plants scope
        join app.plants plant on plant.id = scope.plant_id
        where scope.invite_id = ${invite.id}
          and scope.plant_id = action.plant_id
          and action.id = ${careActionID}
          and action.status in ('proposed', 'due')
          and action.kind not in ('checkIn', 'check_in')
          and coalesce(action.due_from, now()) <= now()
          and coalesce(action.due_from, now()) <= ${invite.ends_at}
        returning action.id, action.plant_id, action.kind, plant.nickname`;
    if (!action) return undefined;
    // A bearer proves possession of the URL, not the opener's identity. The
    // label is the owner's private reminder and may name a friend, but a
    // forwarded link must never make Grove swear that friend did the work.
    await tx`
        insert into app.sitting_invite_care_log (invite_id, care_action_id)
        values (${invite.id}, ${action.id})
        on conflict do nothing`;
    await tx`
        insert into app.activity_events (
          actor_account_id, grove_id, plant_id, kind, message,
          actor_name, actor_initials
        )
        values (
          ${null}, ${invite.grove_id}, ${action.plant_id}, 'sitterCare',
          ${`looked after ${action.nickname} via the sitting link`},
          ${"A plant sitter"},
          ${"PS"}
        )`;
    return action;
  });
}

async function notifyOwner(accountID: string, payload: PushPayload): Promise<void> {
  try {
    const devices = await sql<{ token: string; environment: string }[]>`
        select token, environment from app.device_tokens
        where account_id = ${accountID} and sitting_updates_enabled = true`;
    const dead = await sendPush(devices, payload);
    if (dead.length) {
      await sql`delete from app.device_tokens where token = any(${dead}::text[])`;
    }
  } catch (caught) {
    console.error("sit push failed", caught);
  }
}

async function logSitterNote(invite: Row, rawNote: string): Promise<boolean> {
  const note = [...rawNote
    .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/gu, " ")
    .trim()]
    .slice(0, 500)
    .join("");
  if (!note) return false;
  return await sql.begin(async (tx) => {
    const [{ recent_count: recentCount }] = await tx`
        select count(*)::int as recent_count
        from app.activity_events
        where grove_id = ${invite.grove_id}
          and actor_account_id is null
          and actor_name = 'A plant sitter'
          and kind = 'sitterCare'
          and created_at >= now() - interval '1 hour'`;
    if (Number(recentCount) >= 20) return false;
    await tx`
        insert into app.activity_events (
          actor_account_id, grove_id, kind, message, actor_name, actor_initials
        ) values (
          ${null}, ${invite.grove_id}, 'sitterCare', ${`left a note: ${note}`},
          ${"A plant sitter"}, ${"PS"}
        )`;
    return true;
  });
}

async function recordInviteOpen(invite: Row): Promise<void> {
  const [opened] = await sql`
      update app.sitting_invites
      set last_opened_at = now(), open_count = open_count + 1
      where id = ${invite.id}
      returning open_count`;
  if (Number(opened?.open_count) === 1) {
    await notifyOwner(invite.owner_account_id, {
      title: "Your sitting link was opened",
      body: "Someone has opened the plant-care sheet for your trip.",
      openTab: "today"
    });
  }
}

// ---------------------------------------------------------------------------
// Router

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const route = segments.slice(segments.lastIndexOf("sit") + 1);

  if (request.method === "GET" && route[0] === "health") {
    return new Response(JSON.stringify({ status: "ok", service: "grove-sit" }), {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8" }
    });
  }

  const token = route[0] ?? "";
  // Shaped like a base64url 32-byte value; anything else is not worth a query.
  if (!/^[A-Za-z0-9_-]{40,64}$/.test(token)) return gonePage();

  try {
    const invite = await inviteForToken(token);
    if (!invite) return gonePage();
    const hasStarted = Date.now() >= new Date(invite.starts_at).getTime();

    if (!hasStarted) {
      if (request.method === "GET") {
        await recordInviteOpen(invite);
        return upcomingPage(invite);
      }
      if (request.method === "POST") {
        return new Response(null, {
          status: 303,
          headers: { ...htmlHeaders, location: url.pathname }
        });
      }
    }

    if (request.method === "POST") {
      const contentLength = Number(request.headers.get("content-length") ?? 0);
      if (Number.isFinite(contentLength) && contentLength > 16_384) {
        return page("Note too long", `<h1>That note is too long</h1><p class="lede">Keep it under 500 characters and try again.</p>`, 413);
      }
      let form: URLSearchParams;
      try {
        form = await boundedForm(request);
      } catch {
        return page("Note too long", `<h1>That form couldn't be sent</h1><p class="lede">Keep notes under 500 characters and try again.</p>`, 413);
      }
      const careActionID = String(form.get("careActionID") ?? "");
      if (uuidPattern.test(careActionID)) {
        const action = await logCare(invite, careActionID);
        if (action) {
          await notifyOwner(invite.owner_account_id, {
            title: `${action.nickname} was looked after`,
            body: `A plant sitter marked ${careTitle(String(action.kind)).toLowerCase()} as done.`,
            openTab: "today"
          });
        }
      } else {
        const saved = await logSitterNote(invite, String(form.get("sitterNote") ?? ""));
        if (saved) {
          await notifyOwner(invite.owner_account_id, {
            title: "Your plant sitter left a note",
            body: "Open Grove to read their update.",
            openTab: "today"
          });
        }
      }
      // POST-redirect-GET, so a refresh after ticking does not re-submit and
      // the token stays out of the browser's form-resubmission dialog.
      return new Response(null, {
        status: 303,
        headers: { ...htmlHeaders, location: url.pathname }
      });
    }

    if (request.method !== "GET") {
      return new Response("Method not allowed", { status: 405, headers: htmlHeaders });
    }

    await recordInviteOpen(invite);

    const { plants, tasks } = await sheetFor(invite);
    return renderSheet(invite, plants, tasks);
  } catch (caught) {
    console.error("sit function error", caught);
    return page(
      "Not right now",
      `<h1>This page isn't loading</h1>
       <p class="lede">Something went wrong at our end. Try again in a minute. The plants will be fine.</p>`,
      503
    );
  }
});
