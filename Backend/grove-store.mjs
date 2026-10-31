// Durable persistence for the Grove sync contract.
//
// This replaces the in-memory `accounts`/`idempotency`/`uploads` Maps the API
// used to serve every request from. Those Maps reset when the process exits, and
// the iOS client treats `GET /v1/bootstrap` as authoritative — it replaces local
// state wholesale — so a single restart or redeploy would have deleted every
// user's entire Grove on their next sync.
//
// An account is a Supabase Auth identity: `app.accounts.id` is a uuid
// referencing `auth.users`, provisioned by the `on_auth_user_created` trigger.
// This module never creates accounts — see `resolveAccount`.
//
// Ownership is enforced explicitly in each statement (`where owner_account_id =
// …`) rather than by RLS, because the service connects as the schema owner
// rather than as the end user. The RLS policies remain the authority for
// anything connecting through PostgREST or the client libraries.

import { randomUUID } from "node:crypto";

const UPLOAD_TTL_MILLISECONDS = 15 * 60_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CARE_KINDS = new Set([
  "checkIn", "inspectSoil", "water", "fertilise", "rotate", "cleanLeaves",
  "treat", "prune", "repot", "relocate", "monitor"
]);

/// Raised when a bearer resolves to an account Supabase Auth does not know.
export class UnknownAccountError extends Error {
  constructor(accountID) {
    super(`No Grove account exists for ${accountID}.`);
    this.name = "UnknownAccountError";
  }
}

function iso(value) {
  if (!value) return undefined;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

/// A plant's lifecycle state is derived from its health band; the client does
/// not model it directly.
function plantState(band) {
  switch (band) {
    case "urgent":
      return "urgent";
    case "attention":
      return "recovering";
    case "monitor":
      return "monitor";
    case "thriving":
    case "healthy":
      return "healthy";
    default:
      return "onboarding";
  }
}

function healthBandForScore(score) {
  if (score >= 90) return "thriving";
  if (score >= 75) return "healthy";
  if (score >= 55) return "monitor";
  if (score >= 30) return "attention";
  return "urgent";
}

function initialsFor(name) {
  const value = String(name ?? "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
  return value || "GP";
}

function jsonObject(value) {
  if (typeof value === "string") {
    try { return JSON.parse(value); } catch { return {}; }
  }
  return value && typeof value === "object" ? value : {};
}

const INDICATOR_KINDS = ["moisture", "light", "foliage", "posture", "growth", "care"];
const INDICATOR_SOURCES = new Set([
  "ownerReport", "photoAnalysis", "speciesGuide", "careHistory",
  "sensor", "legacyInference", "none"
]);

function indicatorReadings(value) {
  const seen = new Set();
  const byKind = new Map();
  const recordedAt = new Date().toISOString();
  for (const raw of (Array.isArray(value) ? value : []).slice(0, 12)) {
    if (!raw || typeof raw !== "object" || !INDICATOR_KINDS.includes(raw.kind) || seen.has(raw.kind)) continue;
    seen.add(raw.kind);
    let source = INDICATOR_SOURCES.has(raw.source) ? raw.source : "none";
    let evidenceLevel;
    if (source === "sensor") evidenceLevel = "measured";
    else if (source === "ownerReport" || source === "photoAnalysis") evidenceLevel = "observed";
    else if (["speciesGuide", "careHistory", "legacyInference"].includes(source)) evidenceLevel = "estimated";
    else {
      source = "none";
      evidenceLevel = "unavailable";
    }
    const unavailable = evidenceLevel === "unavailable";
    const score = Number(raw.score);
    const confidence = Number(raw.confidence);
    const measuredAt = new Date(raw.measuredAt);
    const validUntil = raw.validUntil == null ? null : new Date(raw.validUntil);
    byKind.set(raw.kind, {
      kind: raw.kind,
      value: unavailable ? "unavailable" : String(raw.value ?? "unavailable").slice(0, 80),
      score: unavailable || raw.score == null || !Number.isFinite(score)
        ? null : Math.min(Math.max(Math.round(score), 0), 100),
      status: String(raw.status ?? (unavailable ? "Not read" : "Recorded")).slice(0, 120),
      detail: String(raw.detail ?? "").slice(0, 800),
      evidenceLevel,
      source,
      confidence: unavailable || raw.confidence == null || !Number.isFinite(confidence)
        ? null : Math.min(Math.max(Math.round(confidence), 0), 100),
      evidence: unavailable
        ? []
        : (Array.isArray(raw.evidence) ? raw.evidence : []).map((item) => String(item).slice(0, 220)).slice(0, 5),
      measuredAt: Number.isNaN(measuredAt.valueOf()) ? recordedAt : measuredAt.toISOString(),
      validUntil: validUntil == null || Number.isNaN(validUntil.valueOf()) ? null : validUntil.toISOString(),
      algorithmVersion: String(raw.algorithmVersion ?? "unknown").slice(0, 100)
    });
  }
  return INDICATOR_KINDS.map((kind) => byKind.get(kind) ?? ({
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

function carePlanActions(value) {
  const plan = jsonObject(value);
  if (!Array.isArray(plan.actions)) return [];
  const seen = new Set();
  return plan.actions.flatMap((raw) => {
    const action = jsonObject(raw);
    const id = String(action.id ?? "").toLowerCase();
    const instruction = String(action.instruction ?? "").trim().slice(0, 2_000);
    if (!UUID_PATTERN.test(id) || seen.has(id) || !CARE_KINDS.has(action.kind) || !instruction) return [];
    seen.add(id);
    const date = (candidate) => candidate && Number.isFinite(new Date(candidate).getTime())
      ? new Date(candidate)
      : null;
    return [{
      id,
      kind: action.kind,
      instruction,
      status: ["proposed", "due", "completed", "skipped"].includes(action.state) ? action.state : "proposed",
      dueFrom: date(action.dueFrom),
      dueUntil: date(action.dueUntil),
      completedAt: date(action.completedAt)
    }];
  }).slice(0, 100);
}

async function syncCarePlanActions(query, plantID, previousPlan, nextPlan) {
  const previous = carePlanActions(previousPlan);
  const next = carePlanActions(nextPlan);
  const nextIDs = new Set(next.map((action) => action.id));
  const removedIDs = previous.map((action) => action.id).filter((id) => !nextIDs.has(id));
  for (const action of next) {
    await query`
      insert into app.care_actions (
        id, plant_id, kind, instructions, status, due_from, due_until, performed_at
      ) values (
        ${action.id}, ${plantID}, ${action.kind}, ${action.instruction}, ${action.status},
        ${action.dueFrom}, ${action.dueUntil},
        ${action.status === "completed" ? action.completedAt ?? new Date() : null}
      )
      on conflict (id) do update
      set kind = excluded.kind,
          instructions = excluded.instructions,
          status = case when app.care_actions.status = 'completed' then app.care_actions.status else excluded.status end,
          due_from = excluded.due_from,
          due_until = excluded.due_until,
          performed_at = case when app.care_actions.status = 'completed' then app.care_actions.performed_at else excluded.performed_at end
      where app.care_actions.plant_id = ${plantID}`;
  }
  if (removedIDs.length) {
    await query`
      update app.care_actions set status = 'superseded'
       where plant_id = ${plantID} and id = any(${removedIDs}::uuid[])
         and status in ('proposed', 'due')`;
  }
}

function clientLifecycle(state) {
  switch (state) {
    case "dormant": return "dormant";
    case "archived": return "archived";
    case "deceased": return "deceased";
    default: return "active";
  }
}

function serverLifecycle(lifecycle, band) {
  switch (lifecycle) {
    case "dormant": return "dormant";
    case "archived": return "archived";
    case "deceased": return "deceased";
    default: return plantState(band);
  }
}

function plantWire(row) {
  const presentation = jsonObject(row.presentation);
  const environment = jsonObject(row.environment);
  return {
    id: row.id,
    nickname: row.nickname,
    species: row.common_name ?? "Unknown plant",
    scientificName: row.scientific_name ?? "Identity uncertain",
    canonicalTaxonID: presentation.canonicalTaxonID ?? undefined,
    identityConfirmation: presentation.identityConfirmation ?? undefined,
    location: presentation.location ?? row.location ?? "",
    lightPlacement: environment.lightPlacement ?? undefined,
    growingConditions: environment.growingConditions ?? undefined,
    healthScore: row.current_health_score ?? 78,
    healthBand: row.current_health_band ?? "healthy",
    trend: row.current_trend ?? "baseline",
    confidence: presentation.assessmentConfidence ?? row.identification_confidence ?? 86,
    identificationConfidence: row.identification_confidence ?? undefined,
    nextCheckIn: iso(row.next_check_in_at) ?? iso(new Date()),
    symbol: presentation.symbol ?? row.symbol ?? "leaf.fill",
    palette: presentation.palette ?? row.palette ?? "fern",
    summary: presentation.summary ?? row.summary ?? "",
    positiveSigns: presentation.positiveSigns ?? row.positive_signs ?? [],
    concerns: presentation.concerns ?? row.concerns ?? [],
    nextActions: presentation.nextActions ?? row.next_actions ?? [],
    lifecycleState: clientLifecycle(row.state),
    acquiredAt: iso(row.acquired_at),
    notes: presentation.notes ?? undefined,
    environmentReadings: environment.readings ?? undefined,
    carePlan: presentation.carePlan ?? undefined,
    carePlanHistory: presentation.carePlanHistory ?? undefined,
    assessmentDate: iso(presentation.assessmentDate ?? row.updated_at),
    assessmentSource: presentation.assessmentSource ?? "imported",
    healthIndicatorReadings: Array.isArray(presentation.healthIndicatorReadings)
      ? indicatorReadings(presentation.healthIndicatorReadings)
      : undefined
  };
}

function plantWireWithCareActions(row, careActions) {
  const plant = plantWire(row);
  const plan = jsonObject(plant.carePlan);
  if (!Array.isArray(plan.actions)) return plant;
  const actionByID = new Map(
    careActions.filter((action) => action.plant_id === row.id).map((action) => [action.id, action])
  );
  const actions = plan.actions.map((raw) => {
    const action = jsonObject(raw);
    const materialized = actionByID.get(String(action.id ?? "").toLowerCase());
    if (!materialized || materialized.status !== "completed") return action;
    return {
      ...action,
      state: "completed",
      completedAt: iso(materialized.performed_at) ?? action.completedAt ?? iso(new Date())
    };
  });
  plant.carePlan = { ...plan, actions };
  plant.nextActions = actions
    .filter((action) => action.state === "proposed" || action.state === "due")
    .map((action) => action.instruction);
  return plant;
}

function taskWire(row) {
  return {
    id: row.id,
    plantID: row.plant_id,
    kind: row.kind,
    dueDate: iso(row.due_from) ?? iso(new Date()),
    detail: row.instructions ?? "",
    isCompleted: row.status === "completed",
    isSittingTask: row.is_sitting_task === true,
    ownerName: row.owner_name ?? undefined,
    soilMoisture: row.soil_moisture ?? undefined,
    completedAt: iso(row.performed_at)
  };
}

// The client writes this exact phrasing for a check-in it has just recorded, and
// the server mirrors the same entry. Keeping the wording identical means a
// bootstrap cannot silently reword an entry the user has already read.
const HEALTH_BAND_TITLES = {
  thriving: "thriving",
  healthy: "healthy",
  monitor: "keep an eye on it",
  attention: "needs attention",
  urgent: "urgent"
};

function bandTitle(band) {
  return HEALTH_BAND_TITLES[band] ?? String(band ?? "healthy");
}

/// Renders an activity row for one reader.
///
/// "You" is resolved per reader rather than stored. It used to be hardcoded at
/// insert time, which is wrong the moment a row has two audiences: a sitter's
/// care lands in the owner's feed, and the owner read it as something they had
/// done themselves.
function activityWire(row, viewerAccountID) {
  const isSelf = row.actor_account_id === viewerAccountID;
  const storedName = String(row.actor_name ?? "").trim();
  return {
    id: row.id,
    kind: row.kind,
    actorName: isSelf ? "You" : storedName || "A trusted person",
    actorInitials: row.actor_initials ?? initialsFor(storedName),
    message: row.message,
    plantID: row.plant_id ?? undefined,
    timestamp: iso(row.created_at)
  };
}

function observationWire(row, viewerAccountID) {
  const answers = row.answers ?? {};
  const findings = jsonObject(row.findings);
  const performedBySelf = row.performed_by_account_id
    ? row.performed_by_account_id === viewerAccountID
    : true;
  return {
    id: row.id,
    plantID: row.plant_id,
    createdAt: iso(row.observed_at) ?? iso(row.created_at),
    previousScore: Number(answers.previousScore ?? row.health_score ?? 0),
    score: Number(row.health_score ?? answers.score ?? 0),
    band: row.health_band ?? "healthy",
    note: row.note ?? "",
    appearance: answers.appearance ?? "same",
    soilMoisture: answers.soilMoisture ?? "comfortable",
    hasNewGrowth: answers.hasNewGrowth === true,
    // Photo bytes live in object storage; the device keeps its own local file
    // reference, so the snapshot never claims a URL the client cannot open.
    photoURL: null,
    // Resolved per reader for the same reason activity is: now that a sitter can
    // record a check-in, a plant's history has to be able to say who did it.
    actorName: performedBySelf ? "You" : String(answers.actorName ?? "").trim() || "A trusted person",
    isEstimated: answers.isEstimated === true || findings.isEstimated === true,
    confidence: row.assessment_confidence ?? answers.confidence ?? undefined,
    actionability: findings.actionability ?? answers.actionability ?? undefined,
    assessmentAvailable: findings.assessmentAvailable ?? answers.assessmentAvailable ?? undefined,
    analysisVersion: row.provider_version ?? answers.analysisVersion ?? undefined,
    providerName: row.provider_name ?? answers.providerName ?? undefined,
    limitations: row.limitations ?? answers.limitations ?? undefined,
    referenceObservationID: findings.referenceObservationID ?? answers.referenceObservationID ?? undefined,
    indicatorReadings: indicatorReadings(findings.indicatorReadings ?? answers.indicatorReadings)
  };
}

function assignmentWire(row, viewerAccountID) {
  return {
    id: row.id,
    sitterName: row.sitter_name ?? row.sitter_account_id,
    sitterInitials: row.sitter_initials ?? initialsFor(row.sitter_name ?? row.sitter_account_id),
    startDate: iso(row.starts_at),
    endDate: iso(row.ends_at),
    plantIDs: row.plant_ids ?? [],
    status: row.status,
    completedTasks: Number(row.completed_tasks ?? 0),
    totalTasks: Number(row.total_tasks ?? 0),
    // Stored on insert but never returned, so the permission the owner chose
    // vanished from their own copy of the assignment on the next bootstrap.
    canCheckIn: row.can_check_in !== false,
    canLogCare: row.can_log_care !== false,
    ownerNotes: row.owner_notes ?? undefined,
    timeZoneIdentifier: row.time_zone_identifier ?? undefined,
    ownerName: row.owner_name ?? undefined,
    isIncoming: viewerAccountID != null && row.sitter_account_id === viewerAccountID
  };
}

function sittingPlantWire(row) {
  const plant = plantWire(row);
  return {
    id: plant.id,
    nickname: plant.nickname,
    species: plant.species,
    symbol: plant.symbol,
    palette: plant.palette,
    healthBand: plant.healthBand
  };
}

function sittingInviteWire(row) {
  return {
    id: row.id,
    sitterLabel: row.label,
    startDate: iso(row.starts_at),
    endDate: iso(row.ends_at),
    plantIDs: row.plant_ids ?? [],
    canLogCare: row.can_log_care !== false,
    ownerNotes: row.owner_notes ?? undefined,
    timeZoneIdentifier: row.time_zone_identifier ?? "UTC",
    shareURL: null,
    createdAt: iso(row.created_at),
    revokedAt: iso(row.revoked_at) ?? null,
    lastOpenedAt: iso(row.last_opened_at) ?? null,
    openCount: Number(row.open_count ?? 0),
    completedCareCount: Number(row.completed_care_count ?? 0),
    wasMinted: true
  };
}

export function createGroveStore(sql) {
  /// Resolves the caller's account and default Grove.
  ///
  /// Deliberately does **not** create accounts. Identity belongs to Supabase
  /// Auth: `app.accounts` is a uuid referencing `auth.users`, and the
  /// `on_auth_user_created` trigger provisions the account, its Grove and its
  /// membership at signup. A service that minted accounts for any bearer it had
  /// not seen before would let an arbitrary token conjure one.
  ///
  /// Returns `undefined` for an unknown account so callers can answer 401
  /// rather than fail a foreign key as a 500. The Grove is created on demand
  /// only for an account that genuinely exists but somehow has none.
  async function resolveAccount(accountID) {
    const [account] = await sql`select id from app.accounts where id = ${accountID}`;
    if (!account) return undefined;

    const [grove] = await sql`
      select id from app.groves where owner_account_id = ${accountID} order by created_at limit 1
    `;
    if (grove) return { id: accountID, groveID: grove.id };

    const [created] = await sql`
      insert into app.groves (owner_account_id, name, is_private)
      values (${accountID}, 'My Grove', true)
      returning id
    `;
    await sql`
      insert into app.grove_memberships (grove_id, account_id, role, can_edit_plants, can_manage_carers)
      values (${created.id}, ${accountID}, 'owner', true, true)
      on conflict do nothing
    `;
    return { id: accountID, groveID: created.id };
  }

  /// Throws a typed error rather than returning undefined, for the many call
  /// sites where an unknown account is simply not a valid request.
  async function requireAccount(accountID) {
    const account = await resolveAccount(accountID);
    if (!account) throw new UnknownAccountError(accountID);
    return account;
  }

  async function profileFor(accountID) {
    const [row] = await sql`
      select a.id, a.username, a.display_name, a.region_code,
             a.latitude, a.longitude, a.location_label,
             a.location_country_code, a.location_time_zone_identifier,
             (select count(*) from app.friendships f
               where f.status = 'accepted'
                 and (f.requested_by_account_id = a.id or f.requested_to_account_id = a.id)) as friend_count,
             (select g.is_private from app.groves g where g.owner_account_id = a.id order by g.created_at limit 1) as is_private
        from app.accounts a
       where a.id = ${accountID}
    `;
    if (!row) return undefined;
    return {
      name: row.display_name,
      username: row.username,
      initials: initialsFor(row.display_name),
      friendCount: Number(row.friend_count ?? 0),
      regionCode: row.region_code ?? "GB",
      usesMetricSystem: true,
      isPrivate: row.is_private !== false,
      location: row.latitude != null && row.longitude != null && row.location_label
        ? {
            latitude: Number(row.latitude),
            longitude: Number(row.longitude),
            label: row.location_label,
            countryCode: row.location_country_code ?? undefined,
            timeZoneIdentifier: row.location_time_zone_identifier ?? undefined
          }
        : undefined
    };
  }

  async function snapshot(accountID) {
    const { groveID } = await requireAccount(accountID);

    const [profile, accountProgress, plants, tasks, activity, observations, assignments, sittingInvites, friends, friendInvitations] =
      await Promise.all([
        profileFor(accountID),
        sql`select gardener_progress, gardener_progress_updated_at from app.accounts where id = ${accountID}`,
        sql`select * from app.plants where grove_id = ${groveID} and archived_at is null order by created_at desc`,
        sql`
          select c.*,
                 exists (
                   select 1 from app.sitting_invite_care_log care_log
                    where care_log.care_action_id = c.id
                 ) as is_sitting_task,
                 case when exists (
                   select 1 from app.sitting_invite_care_log care_log
                    where care_log.care_action_id = c.id
                 ) then 'A plant sitter' end as owner_name
            from app.care_actions c
            join app.plants p on p.id = c.plant_id
           where p.grove_id = ${groveID} and p.archived_at is null
             and c.status in ('proposed', 'due', 'completed')
           order by c.due_from asc nulls last
        `,
        sql`
          select * from app.activity_events
           where grove_id = ${groveID} or actor_account_id = ${accountID}
           order by created_at desc limit 200
        `,
        sql`
          select o.*, h.health_score, h.health_band
            from app.observations o
            join app.plants p on p.id = o.plant_id
            left join lateral (
              select health_score, health_band, confidence as assessment_confidence,
                     provider_name, provider_version, findings, limitations
                from app.health_assessments
               where observation_id = o.id order by created_at desc limit 1
            ) h on true
           where p.grove_id = ${groveID} and p.archived_at is null
           order by o.observed_at desc
        `,
        sql`
          select s.*, owner.display_name as owner_name,
                 sitter.display_name as sitter_name,
                 coalesce(
                   (select array_agg(sp.plant_id) from app.sitting_assignment_plants sp
                     where sp.assignment_id = s.id), '{}'
                 ) as plant_ids
            from app.sitting_assignments s
            join app.accounts owner on owner.id = s.owner_account_id
            join app.accounts sitter on sitter.id = s.sitter_account_id
           where s.owner_account_id = ${accountID}
              or (
                   s.sitter_account_id = ${accountID}
               and s.status in ('invited', 'upcoming', 'active')
               and s.revoked_at is null
               and s.ends_at > now()
              )
           order by s.created_at desc
        `,
        sql`
          select invite.*, coalesce(
                   (select array_agg(scope.plant_id order by scope.plant_id)
                      from app.sitting_invite_plants scope
                     where scope.invite_id = invite.id), '{}'
                 ) as plant_ids
            from app.sitting_invites invite
           where invite.owner_account_id = ${accountID}
           order by (invite.revoked_at is null and invite.ends_at >= now()) desc,
                    coalesce(invite.revoked_at, invite.created_at) desc
           limit 500
        `,
        sql`
          select friendship.*,
                 counterpart.id as counterpart_id,
                 counterpart.display_name as counterpart_display_name,
                 counterpart.username as counterpart_username,
                 counterpart.updated_at as counterpart_updated_at
            from app.friendships friendship
            join app.accounts counterpart
              on counterpart.id = case
                   when friendship.requested_by_account_id = ${accountID}
                     then friendship.requested_to_account_id
                   else friendship.requested_by_account_id
                 end
           where friendship.status = 'accepted'
             and (friendship.requested_by_account_id = ${accountID} or friendship.requested_to_account_id = ${accountID})
           order by friendship.created_at desc
        `,
        sql`
          select friendship.*,
                 counterpart.id as counterpart_id,
                 counterpart.display_name as counterpart_display_name,
                 counterpart.username as counterpart_username,
                 counterpart.updated_at as counterpart_updated_at
            from app.friendships friendship
            join app.accounts counterpart
              on counterpart.id = case
                   when friendship.requested_by_account_id = ${accountID}
                     then friendship.requested_to_account_id
                   else friendship.requested_by_account_id
                 end
           where friendship.status = 'pending'
             and (friendship.requested_by_account_id = ${accountID} or friendship.requested_to_account_id = ${accountID})
           order by friendship.created_at desc
        `
      ]);

    const activeIncomingAssignmentIDs = assignments
      .filter((row) => row.sitter_account_id === accountID
        && ["upcoming", "active"].includes(row.status)
        && row.revoked_at == null
        && new Date(row.starts_at) <= new Date()
        && new Date(row.ends_at) > new Date())
      .map((row) => row.id);
    const sittingPlants = activeIncomingAssignmentIDs.length
      ? await sql`
          select distinct on (plant.id) plant.*
            from app.plants plant
            join app.sitting_assignment_plants scope on scope.plant_id = plant.id
           where scope.assignment_id = any(${activeIncomingAssignmentIDs}::uuid[])
             and plant.archived_at is null
           order by plant.id, plant.updated_at desc`
      : [];
    const sittingTasks = activeIncomingAssignmentIDs.length
      ? await sql`
          select distinct on (action.id) action.*, true as is_sitting_task,
                 owner.display_name as owner_name
            from app.care_actions action
            join app.sitting_assignment_plants scope on scope.plant_id = action.plant_id
            join app.sitting_assignments assignment on assignment.id = scope.assignment_id
            join app.accounts owner on owner.id = assignment.owner_account_id
           where assignment.id = any(${activeIncomingAssignmentIDs}::uuid[])
             and assignment.can_log_care = true
             and action.status in ('proposed', 'due')
             and coalesce(action.due_from, now()) <= assignment.ends_at
             and (action.kind not in ('checkIn', 'check_in') or assignment.can_check_in = true)
           order by action.id, action.due_from asc nulls last`
      : [];

    return {
      profile,
      gardener: accountProgress[0]?.gardener_progress ?? undefined,
      gardenerUpdatedAt: iso(accountProgress[0]?.gardener_progress_updated_at),
      plants: plants.map((row) => plantWireWithCareActions(row, tasks)),
      tasks: tasks.map(taskWire),
      activity: activity.map((row) => activityWire(row, accountID)),
      assignments: assignments.map((row) => assignmentWire(row, accountID)),
      sittingPlants: sittingPlants.map(sittingPlantWire),
      sittingTasks: sittingTasks.map(taskWire),
      sittingInvites: sittingInvites.map(sittingInviteWire),
      observations: observations.map((row) => observationWire(row, accountID)),
      diagnoses: plants.flatMap((row) => {
        const saved = jsonObject(row.presentation).diagnoses;
        return Array.isArray(saved) ? saved : [];
      }),
      friends: friends.map((row) => {
        return {
          id: String(row.counterpart_id),
          name: row.counterpart_display_name,
          username: row.counterpart_username,
          initials: initialsFor(row.counterpart_display_name),
          sharedPlantCount: 0,
          lastActiveAt: iso(row.counterpart_updated_at)
        };
      }),
      friendInvitations: friendInvitations.map((row) => {
        const outgoing = row.requested_by_account_id === accountID;
        return {
          id: row.id,
          accountID: row.counterpart_id,
          name: row.counterpart_display_name,
          username: row.counterpart_username,
          initials: initialsFor(row.counterpart_display_name),
          direction: outgoing ? "outgoing" : "incoming",
          createdAt: iso(row.created_at)
        };
      })
    };
  }

  async function updateProfile(accountID, body) {
    await requireAccount(accountID);
    const sentLocation = body.latitude !== undefined
      || body.longitude !== undefined
      || body.locationLabel !== undefined
      || body.locationCountryCode !== undefined
      || body.locationTimeZoneIdentifier !== undefined;
    // A real boolean: it is interpolated as a SQL `case when` condition, and the
    // label string itself is not one Postgres reads as true.
    const hasLocation = body.latitude != null && body.longitude != null && Boolean(body.locationLabel);
    await sql`
      update app.accounts
         set display_name = ${body.displayName},
             username = ${body.username},
             region_code = ${body.regionCode ?? null},
             latitude = case when ${sentLocation} then ${hasLocation ? Number(body.latitude) : null} else latitude end,
             longitude = case when ${sentLocation} then ${hasLocation ? Number(body.longitude) : null} else longitude end,
             location_label = case when ${sentLocation} then ${hasLocation ? String(body.locationLabel) : null} else location_label end,
             location_country_code = case
               when ${sentLocation && hasLocation} then coalesce(${body.locationCountryCode ?? null}, location_country_code)
               when ${sentLocation} then null
               else location_country_code
             end,
             location_time_zone_identifier = case
               when ${sentLocation && hasLocation} then coalesce(${body.locationTimeZoneIdentifier ?? null}, location_time_zone_identifier)
               when ${sentLocation} then null
               else location_time_zone_identifier
             end,
             updated_at = now()
       where id = ${accountID}
    `;
    await sql`
      update app.groves set is_private = true, updated_at = now()
       where owner_account_id = ${accountID}
    `;
    const profile = await profileFor(accountID);
    return { ...profile, usesMetricSystem: body.usesMetricSystem !== false };
  }

  async function updateGardenerProgress(accountID, body) {
    await requireAccount(accountID);
    const updatedAt = new Date(body.updatedAt);
    const [updated] = await sql`
      update app.accounts
         set gardener_progress = ${sql.json(body.gardener)},
             gardener_progress_updated_at = ${updatedAt}
       where id = ${accountID}
         and (
           gardener_progress_updated_at is null
           or gardener_progress_updated_at <= ${updatedAt}
         )
       returning gardener_progress, gardener_progress_updated_at
    `;
    if (updated) {
      return {
        gardener: updated.gardener_progress,
        updatedAt: iso(updated.gardener_progress_updated_at)
      };
    }
    const [existing] = await sql`
      select gardener_progress, gardener_progress_updated_at
        from app.accounts where id = ${accountID}
    `;
    return {
      gardener: existing.gardener_progress,
      updatedAt: iso(existing.gardener_progress_updated_at)
    };
  }

  async function findPlant(accountID, plantID) {
    const [row] = await sql`
      select p.* from app.plants p
        join app.groves g on g.id = p.grove_id
       where p.id = ${plantID} and g.owner_account_id = ${accountID} and p.archived_at is null
    `;
    return row;
  }

  /// Resolves a plant this account may record care against, and says in what
  /// capacity.
  ///
  /// `findPlant` is owner-only, which is right for editing a plant and wrong for
  /// caring for one: a sitter's check-in 404'd, so the single thing the Updates
  /// feed exists to carry — someone else looking after your plants while you are
  /// away — never reached the owner at all. Sitter access is bounded by the
  /// assignment: only the plants they were handed, only for the length of the
  /// trip, only if they were given check-in permission, and never once the
  /// invitation has been declined or revoked.
  async function findPlantForCare(accountID, plantID) {
    const owned = await findPlant(accountID, plantID);
    if (owned) return { plant: owned, isOwner: true, canCheckIn: true };

    const [sitting] = await sql`
      select p.*, s.can_check_in
        from app.plants p
        join app.sitting_assignment_plants sp on sp.plant_id = p.id
        join app.sitting_assignments s on s.id = sp.assignment_id
       where p.id = ${plantID}
         and p.archived_at is null
         and s.sitter_account_id = ${accountID}
         and s.status in ('upcoming', 'active')
         and s.revoked_at is null
         and s.starts_at <= now()
         and s.ends_at >= now()
       limit 1
    `;
    if (!sitting) return undefined;
    return { plant: sitting, isOwner: false, canCheckIn: sitting.can_check_in !== false };
  }

  /// How an actor should be named in a feed somebody else may be reading.
  ///
  /// Activity rows used to store the literal 'You' with initials 'YO' for every
  /// actor, which is unreadable to any other member of the grove and overwrote
  /// the reader's own initials after a sync.
  async function actorIdentity(accountID) {
    const [row] = await sql`
      select display_name, username from app.accounts where id = ${accountID}
    `;
    const name = String(row?.display_name ?? "").trim()
      || String(row?.username ?? "").trim()
      || "A trusted person";
    return { name, initials: initialsFor(name) };
  }

  async function recordFriendActivity(query, eventID, actorAccountID, audienceAccountID, message) {
    const [actor] = await query`select display_name from app.accounts where id = ${actorAccountID}`;
    const [audienceGrove] = await query`select id from app.groves where owner_account_id = ${audienceAccountID}`;
    if (!actor || !audienceGrove) return;
    const actorName = String(actor.display_name ?? "A gardener");
    await query`
      insert into app.activity_events (
        id, actor_account_id, grove_id, kind, message, actor_name, actor_initials
      ) values (
        ${eventID}, ${actorAccountID}, ${audienceGrove.id}, 'friendship', ${message},
        ${actorName}, ${initialsFor(actorName)}
      ) on conflict (id) do nothing
    `;
  }

  async function createPlant(accountID, body) {
    const { groveID } = await requireAccount(accountID);
    const existing = await findPlant(accountID, body.clientPlantID);
    if (existing) return { created: false, plant: plantWire(existing) };

    const clientPlant = body.plant ?? {};
    const condition = body.analysis?.condition ?? {};
    const identification = body.analysis?.identification ?? {};
    const followUpDays = Math.min(Math.max(condition.followUpDays ?? 14, 1), 30);
    const band = clientPlant.healthBand ?? condition.healthBand ?? "healthy";
    const presentation = {
      location: clientPlant.location ?? body.location ?? "",
      symbol: clientPlant.symbol ?? "leaf.fill",
      palette: clientPlant.palette ?? "fern",
      summary: clientPlant.summary ?? condition.summary ?? "",
      positiveSigns: clientPlant.positiveSigns ?? condition.positiveSigns ?? [],
      concerns: clientPlant.concerns ?? condition.concerns ?? [],
      nextActions: clientPlant.nextActions ?? condition.nextActions ?? [],
      notes: clientPlant.notes ?? null,
      carePlan: clientPlant.carePlan ?? null,
      carePlanHistory: clientPlant.carePlanHistory ?? [],
      assessmentConfidence: clientPlant.confidence ?? condition.confidence ?? 86,
      assessmentDate: clientPlant.assessmentDate ?? new Date().toISOString(),
      assessmentSource: clientPlant.assessmentSource ?? "baselinePhoto",
      canonicalTaxonID: clientPlant.canonicalTaxonID ?? identification.canonicalTaxonID ?? null,
      identityConfirmation: clientPlant.identityConfirmation ?? identification.identityConfirmation
        ?? (identification.isUnknown ? "unknown" : "photoMatch"),
      healthIndicatorReadings: indicatorReadings(clientPlant.healthIndicatorReadings)
    };
    const environment = {
      lightPlacement: clientPlant.lightPlacement ?? null,
      growingConditions: clientPlant.growingConditions ?? null,
      readings: clientPlant.environmentReadings ?? []
    };

    const [row] = await sql`
      insert into app.plants (
        id, grove_id, nickname, common_name, scientific_name, identification_confidence,
        state, current_health_score, current_health_band, current_trend, next_check_in_at,
        environment, location, symbol, palette, summary, positive_signs, concerns, next_actions
      ) values (
        ${body.clientPlantID}, ${groveID}, ${body.nickname},
        ${clientPlant.species ?? identification.commonName ?? null}, ${clientPlant.scientificName ?? identification.scientificName ?? null},
        ${clientPlant.identificationConfidence ?? identification.confidence ?? null},
        ${serverLifecycle(clientPlant.lifecycleState, band)}, ${clientPlant.healthScore ?? condition.healthScore ?? 78}, ${band}, ${clientPlant.trend ?? 'baseline'},
        ${clientPlant.nextCheckIn ? new Date(clientPlant.nextCheckIn) : new Date(Date.now() + followUpDays * 86_400_000)},
        ${sql.json(environment)}, ${clientPlant.location ?? body.location ?? null}, ${clientPlant.symbol ?? 'leaf.fill'}, ${clientPlant.palette ?? 'fern'},
        ${condition.summary ?? null},
        ${sql.json(condition.positiveSigns ?? [])},
        ${sql.json(condition.concerns ?? [])},
        ${sql.json(condition.nextActions ?? [])}
      )
      returning *
    `;
    const [presented] = await sql`
      update app.plants
         set presentation = ${sql.json(presentation)},
             acquired_at = ${clientPlant.acquiredAt ? new Date(clientPlant.acquiredAt) : new Date()}
       where id = ${row.id}
       returning *
    `;

    // The plant's first check-in, so the care queue is never empty for a plant
    // the user just adopted.
    await sql`
      insert into app.care_actions (plant_id, kind, instructions, status, due_from)
      values (
        ${row.id}, 'checkIn',
        'Take a new photo and compare it with today''s baseline.',
        'due', ${row.next_check_in_at}
      )
    `;
    await syncCarePlanActions(sql, row.id, null, clientPlant.carePlan);
    return { created: true, plant: plantWire(presented) };
  }

  async function updatePlant(accountID, plantID, body) {
    const existing = await findPlant(accountID, plantID);
    if (!existing) return undefined;
    const plant = body.plant ?? {};
    if (String(plant.id ?? "").toLowerCase() !== String(plantID).toLowerCase()) return { conflict: true };
    const presentation = {
      ...jsonObject(existing.presentation),
      location: plant.location ?? "",
      symbol: plant.symbol ?? "leaf.fill",
      palette: plant.palette ?? "fern",
      summary: plant.summary ?? "",
      positiveSigns: plant.positiveSigns ?? [],
      concerns: plant.concerns ?? [],
      nextActions: plant.nextActions ?? [],
      notes: plant.notes ?? null,
      carePlan: plant.carePlan ?? null,
      carePlanHistory: plant.carePlanHistory ?? [],
      assessmentConfidence: plant.confidence ?? 0,
      assessmentDate: plant.assessmentDate ?? new Date().toISOString(),
      assessmentSource: plant.assessmentSource ?? "imported",
      canonicalTaxonID: plant.canonicalTaxonID ?? jsonObject(existing.presentation).canonicalTaxonID ?? null,
      identityConfirmation: plant.identityConfirmation
        ?? jsonObject(existing.presentation).identityConfirmation ?? "unknown",
      healthIndicatorReadings: indicatorReadings(plant.healthIndicatorReadings)
    };
    if (Array.isArray(body.diagnoses)) {
      presentation.diagnoses = body.diagnoses.map((diagnosis) => ({ ...diagnosis, photoURL: null }));
    }
    const environment = {
      ...jsonObject(existing.environment),
      lightPlacement: plant.lightPlacement ?? null,
      growingConditions: plant.growingConditions ?? null,
      readings: plant.environmentReadings ?? []
    };
    const [updated] = await sql`
      update app.plants
         set nickname = ${plant.nickname},
             common_name = ${plant.species ?? null},
             scientific_name = ${plant.scientificName ?? null},
             identification_confidence = ${plant.identificationConfidence ?? null},
             state = ${serverLifecycle(plant.lifecycleState, plant.healthBand)},
             current_health_score = ${plant.healthScore},
             current_health_band = ${plant.healthBand},
             current_trend = ${plant.trend},
             next_check_in_at = ${new Date(plant.nextCheckIn)},
             acquired_at = ${plant.acquiredAt ? new Date(plant.acquiredAt) : null},
             location = ${plant.location ?? null},
             environment = ${sql.json(environment)},
             presentation = ${sql.json(presentation)},
             summary = ${plant.summary ?? null},
             positive_signs = ${sql.json(plant.positiveSigns ?? [])},
             concerns = ${sql.json(plant.concerns ?? [])},
             next_actions = ${sql.json(plant.nextActions ?? [])},
             updated_at = now()
       where id = ${plantID}
       returning *
    `;
    await syncCarePlanActions(sql, plantID, jsonObject(existing.presentation).carePlan, plant.carePlan);
    return plantWire(updated);
  }

  async function deletePlant(accountID, plantID) {
    await requireAccount(accountID);
    return sql.begin(async (tx) => {
      const assets = await tx`
        select asset.id from app.media_assets asset
          join app.plants plant on plant.id = asset.plant_id
          join app.groves grove on grove.id = plant.grove_id
         where plant.id = ${plantID} and grove.owner_account_id = ${accountID}`;
      if (assets.length) {
        await tx`delete from app.scans where media_asset_id = any(${assets.map((asset) => asset.id)}::uuid[])`;
      }
      const removed = await tx`
        delete from app.plants plant using app.groves grove
         where plant.id = ${plantID} and plant.grove_id = grove.id
           and grove.owner_account_id = ${accountID}
        returning plant.id`;
      await tx`
        update app.sitting_invites invite
           set revoked_at = coalesce(invite.revoked_at, now())
         where invite.owner_account_id = ${accountID}
           and invite.revoked_at is null
           and not exists (
             select 1 from app.sitting_invite_plants scope where scope.invite_id = invite.id
           )`;
      return removed.length > 0;
    });
  }

  async function recordCheckIn(accountID, plantID, body) {
    const access = await findPlantForCare(accountID, plantID);
    if (!access) return undefined;
    // A sitter the owner trusted with care but not with check-ins is a real
    // configuration, not an error: say so rather than 404ing a plant they can
    // plainly see.
    if (!access.canCheckIn) return { forbidden: true };
    const plant = access.plant;
    const actor = await actorIdentity(accountID);

    const previousScore = plant.current_health_score ?? 0;
    const isEstimated = body.isEstimated === true;
    const assessmentAvailable = body.assessmentAvailable !== false;
    const actionability = ["actionable", "provisional", "insufficientEvidence"].includes(body.actionability)
      ? body.actionability
      : null;
    const appliesToPlant = body.appliesToPlant !== false
      && !isEstimated
      && assessmentAvailable
      && (actionability == null || actionability === "actionable");
    const requestedScore = Math.min(Math.max(Number(body.score ?? previousScore), 0), 100);
    const score = appliesToPlant ? requestedScore : previousScore;
    const band = appliesToPlant
      ? healthBandForScore(score)
      : (plant.current_health_band ?? healthBandForScore(previousScore));
    const change = score - previousScore;
    const trend = appliesToPlant
      ? (Math.abs(change) < 3 ? "stable" : change > 0 ? "improving" : "declining")
      : (plant.current_trend ?? "stable");
    const followUpDays = Math.min(Math.max(body.followUpDays ?? (appliesToPlant ? 14 : 3), 1), 30);
    const nextCheckIn = new Date(Date.now() + followUpDays * 86_400_000);
    const healthIndicatorReadings = indicatorReadings(body.indicatorReadings);
    const presentation = {
      ...jsonObject(plant.presentation),
      healthIndicatorReadings
    };
    if (appliesToPlant) {
      presentation.summary = body.note ?? "";
      presentation.assessmentConfidence = Math.min(Math.max(body.confidence ?? 0, 0), 100);
      presentation.assessmentDate = new Date().toISOString();
      presentation.assessmentSource = "checkInPhoto";
    }

    return sql.begin(async (tx) => {
      const [updated] = await tx`
        update app.plants
           set current_health_score = ${score},
               current_health_band = ${band},
               current_trend = ${trend},
               state = ${appliesToPlant ? plantState(band) : plant.state},
               summary = ${appliesToPlant ? (body.note ?? plant.summary) : plant.summary},
               presentation = ${tx.json(presentation)},
               next_check_in_at = ${nextCheckIn},
               updated_at = now()
         where id = ${plantID}
        returning *
      `;

      const [observation] = await tx`
        insert into app.observations (plant_id, performed_by_account_id, source, answers, note, observed_at)
        values (
          ${plantID}, ${accountID}, 'scheduled_check_in',
          ${tx.json({
            previousScore,
            appearance: body.appearance ?? "same",
            soilMoisture: body.soilMoisture ?? "comfortable",
            hasNewGrowth: body.hasNewGrowth === true,
            actorName: actor.name,
            score,
            band,
            isEstimated,
            appliesToPlant,
            confidence: body.confidence ?? 0,
            actionability,
            assessmentAvailable,
            analysisVersion: body.analysisVersion ?? null,
            providerName: body.providerName ?? null,
            limitations: body.limitations ?? [],
            followUpDays,
            referenceObservationID: body.referenceObservationID ?? null,
            indicatorReadings: healthIndicatorReadings
          })},
          ${body.note ?? null}, now()
        )
        returning id
      `;

      await tx`
        insert into app.health_assessments (observation_id, provider_name, provider_version, health_score, health_band, trend, confidence, findings, limitations)
        values (
          ${observation.id}, ${body.providerName ?? (isEstimated ? "Grove owner observation" : "Grove check-in")},
          ${body.analysisVersion ?? null},
          ${appliesToPlant ? Math.min(Math.max(score, 0), 100) : null}, ${band}, ${trend},
          ${Math.min(Math.max(body.confidence ?? 0, 0), 100)},
          ${tx.json({
            indicatorReadings: healthIndicatorReadings,
            actionability,
            assessmentAvailable,
            isEstimated,
            appliesToPlant,
            referenceObservationID: body.referenceObservationID ?? null
          })}, ${tx.json(body.limitations ?? [])}
        )
      `;

      // Close the outstanding check-in and schedule the next, mirroring the
      // client so a bootstrap does not resurrect a task the user just did.
      await tx`
        update app.care_actions set status = 'completed', performed_at = now(), performed_by_account_id = ${accountID}
         where plant_id = ${plantID} and kind = 'checkIn' and status <> 'completed'
      `;
      await tx`
        insert into app.care_actions (plant_id, kind, instructions, status, due_from)
        values (${plantID}, 'checkIn', 'Take a new photo and compare it with the last check-in.', 'due', ${nextCheckIn})
      `;
      // Written against the plant's own grove, so a sitter's check-in lands in
      // the owner's feed as well as their own — and as `sitterCare`, because
      // "somebody looked after your plant" is a different piece of news from
      // "your plant is doing better". The id is the client's own where it sent
      // one, so its local entry and this row are one entry, not two.
      await tx`
        insert into app.activity_events (
          id, actor_account_id, grove_id, plant_id, observation_id,
          kind, message, audience, actor_name, actor_initials
        )
        values (
          coalesce(${body.activityEventID ?? null}::uuid, gen_random_uuid()),
          ${accountID}, ${plant.grove_id}, ${plantID}, ${observation.id},
          ${access.isOwner ? "improvement" : "sitterCare"},
          ${appliesToPlant
            ? `checked in, now ${bandTitle(band)} at ${score}%`
            : "checked in; observations saved and health score unchanged"},
          '{}'::jsonb, ${actor.name}, ${actor.initials}
        )
        on conflict (id) do nothing
      `;

      return plantWire(updated);
    });
  }

  async function updateCareAction(accountID, taskID, body) {
    const [row] = await sql`
      select c.*, owner.display_name as owner_name,
             g.owner_account_id = ${accountID} as is_owner,
             sitting.id as sitting_assignment_id
        from app.care_actions c
        join app.plants p on p.id = c.plant_id
        join app.groves g on g.id = p.grove_id
        join app.accounts owner on owner.id = g.owner_account_id
        left join lateral (
          select assignment.id
            from app.sitting_assignment_plants scope
            join app.sitting_assignments assignment on assignment.id = scope.assignment_id
           where scope.plant_id = p.id
             and assignment.sitter_account_id = ${accountID}
             and assignment.status in ('upcoming', 'active')
             and assignment.can_log_care = true
             and assignment.revoked_at is null
             and assignment.starts_at <= now() and assignment.ends_at > now()
             and c.status in ('proposed', 'due')
             and coalesce(c.due_from, now()) <= assignment.ends_at
             and (c.kind not in ('checkIn', 'check_in') or assignment.can_check_in = true)
           limit 1
        ) sitting on true
       where c.id = ${taskID}
         and (g.owner_account_id = ${accountID} or sitting.id is not null)
    `;
    if (!row) return undefined;
    if (body.outcome !== "completed" && row.is_owner !== true) return { forbidden: true };

    const completed = body.outcome === "completed";
    const [updated] = await sql`
      update app.care_actions
         set status = ${completed ? "completed" : "due"},
             performed_at = ${completed ? new Date(body.occurredAt ?? Date.now()) : null},
             performed_by_account_id = ${completed ? accountID : null},
             skip_reason = ${body.reason ?? null},
             due_from = ${body.rescheduledFor ? new Date(body.rescheduledFor) : row.due_from}
       where id = ${taskID}
      returning *
    `;
    return taskWire({
      ...updated,
      is_sitting_task: row.is_owner !== true,
      owner_name: row.owner_name
    });
  }

  async function createCareEvent(accountID, body) {
    const task = body.task ?? {};
    const taskID = String(task.id ?? "").toLowerCase();
    const plantID = String(task.plantID ?? "").toLowerCase();
    if (!UUID_PATTERN.test(taskID) || !UUID_PATTERN.test(plantID) || task.kind === "checkIn") {
      return { invalid: true };
    }
    const plant = await findPlant(accountID, plantID);
    if (!plant) return undefined;
    const occurredAt = task.completedAt ? new Date(task.completedAt) : new Date();
    if (Number.isNaN(occurredAt.getTime())) return { invalid: true };

    const [existing] = await sql`select * from app.care_actions where id = ${taskID}`;
    if (existing) return existing.plant_id === plantID ? taskWire(existing) : { conflict: true };
    const moisture = ["dry", "comfortable", "wet"].includes(task.soilMoisture)
      ? task.soilMoisture
      : null;
    const [created] = await sql`
      insert into app.care_actions (
        id, plant_id, kind, instructions, status, due_from,
        performed_by_account_id, performed_at, client_request_id, soil_moisture
      ) values (
        ${taskID}, ${plantID}, ${task.kind}, ${String(task.detail ?? "Care logged directly in Grove.").slice(0, 2000)},
        'completed', ${occurredAt}, ${accountID}, ${occurredAt}, ${body.clientRequestID}, ${moisture}
      ) returning *`;
    await sql`
      insert into app.activity_events (
        id, actor_account_id, grove_id, plant_id, kind, message
      ) values (
        ${taskID}, ${accountID}, ${plant.grove_id}, ${plantID}, 'milestone', ${`logged ${task.kind}`}
      ) on conflict (id) do nothing`;
    return taskWire(created);
  }

  async function deleteCareEvent(accountID, taskID) {
    const [event] = await sql`
      select action.id from app.care_actions action
        join app.plants plant on plant.id = action.plant_id
        join app.groves grove on grove.id = plant.grove_id
       where action.id = ${taskID} and grove.owner_account_id = ${accountID}
         and action.status = 'completed' and action.care_plan_id is null
         and action.client_request_id is not null`;
    if (!event) return false;
    await sql.begin(async (tx) => {
      await tx`delete from app.activity_events where id = ${taskID}`;
      await tx`delete from app.care_actions where id = ${taskID}`;
    });
    return true;
  }

  // Mirrors the production `createFriendInvitation`: an invitation names an
  // account, never a string someone typed. Inviting a username nobody has
  // claimed used to succeed here and leave the app showing a Pending row for a
  // gardener who did not exist.
  async function createFriendInvitation(accountID, body) {
    await requireAccount(accountID);
    const username = String(body.username ?? "").toLowerCase();
    if (!/^[a-z0-9_]{3,24}$/.test(username)) return { invalid: true };
    const suppliedRequestID = String(body.clientRequestID ?? "").toLowerCase();
    const invitationID = UUID_PATTERN.test(suppliedRequestID) ? suppliedRequestID : randomUUID();
    const suppliedActivityID = String(body.activityEventID ?? body.clientRequestID ?? "").toLowerCase();
    const activityEventID = UUID_PATTERN.test(suppliedActivityID) ? suppliedActivityID : randomUUID();

    return sql.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${`friend-invite-rate:${accountID}`}, 0))`;
      const [priorAttempt] = await tx`
        select attempted_username from app.friend_invitation_attempts
         where requested_by_account_id = ${accountID} and request_id = ${invitationID}`;
      if (priorAttempt && priorAttempt.attempted_username !== username) {
        return { idempotencyConflict: true };
      }
      if (!priorAttempt) {
        await tx`
          delete from app.friend_invitation_attempts
           where requested_by_account_id = ${accountID}
             and attempted_at < now() - interval '7 days'`;
        const [{ recent_count: recentCount }] = await tx`
          select count(*)::int as recent_count
            from app.friend_invitation_attempts
           where requested_by_account_id = ${accountID}
             and attempted_at >= now() - interval '24 hours'`;
        if (Number(recentCount) >= 30) return { rateLimited: true };
        await tx`
          insert into app.friend_invitation_attempts (
            requested_by_account_id, request_id, attempted_username
          ) values (${accountID}, ${invitationID}, ${username})`;
      }

      const [target] = await tx`
        select id, display_name, username from app.accounts
         where username = ${username}
         for key share`;
      if (!target) return { unknownUser: true };
      if (target.id === accountID) return { self: true };

      const pairKey = `friendship:${[accountID, target.id].sort().join(":")}`;
      await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;
      const createdResult = async (relationship) => {
        await recordFriendActivity(
          tx,
          activityEventID,
          accountID,
          target.id,
          "sent a trusted-person invitation"
        );
        return relationship;
      };
      const [existing] = await tx`
        select * from app.friendships
         where (requested_by_account_id = ${accountID} and requested_to_account_id = ${target.id})
            or (requested_by_account_id = ${target.id} and requested_to_account_id = ${accountID})
      `;

      let row;
      if (existing) {
        const iAmRequester = existing.requested_by_account_id === accountID;
        if (existing.status === "accepted") return { alreadyFriends: true };
        if (existing.status === "blocked") return { blocked: true };
        if (existing.status === "pending") {
          if (!iAmRequester) return { reversePending: true };
          row = existing;
        } else if (iAmRequester) {
          if (existing.status !== "withdrawn") return { alreadyAnswered: true };
          if (Date.now() - new Date(existing.updated_at).getTime() < 60 * 60 * 1000) {
            return { rateLimited: true };
          }
          [row] = await tx`
            update app.friendships
               set status = 'pending', created_at = now(), updated_at = now()
             where id = ${existing.id}
            returning *`;
          row = await createdResult(row);
        } else {
          [row] = await tx`
            update app.friendships
               set requested_by_account_id = ${accountID},
                   requested_to_account_id = ${target.id},
                   requested_to_username = ${username},
                   display_name = ${target.display_name},
                   initials = ${initialsFor(target.display_name)},
                   status = 'pending', created_at = now(), updated_at = now()
             where id = ${existing.id}
            returning *`;
          row = await createdResult(row);
        }
      } else {
        [row] = await tx`
          insert into app.friendships (
            id, requested_by_account_id, requested_to_account_id, requested_to_username,
            status, display_name, initials
          )
          values (
            ${invitationID}, ${accountID}, ${target.id}, ${username}, 'pending',
            ${target.display_name ?? `@${username}`}, ${initialsFor(target.display_name)}
          )
          returning *`;
        row = await createdResult(row);
      }

      return {
        invitation: {
          id: row.id,
          accountID: target.id,
          name: target.display_name,
          username: target.username,
          initials: initialsFor(target.display_name),
          direction: "outgoing",
          createdAt: iso(row.created_at)
        }
      };
    });
  }

  // Taking back an invitation this account sent. Sender-only, and a row already
  // withdrawn answers success so a replayed mutation cannot wedge the queue.
  async function withdrawFriendInvitation(accountID, invitationID) {
    await requireAccount(accountID);
    const [row] = await sql`select * from app.friendships where id = ${invitationID}`;
    if (!row) return { missing: true };
    if (row.requested_by_account_id !== accountID) return { notSender: true };
    if (row.status === "withdrawn") return { ok: true };
    if (row.status !== "pending") return { conflict: true };
    const [updated] = await sql`
      update app.friendships
         set status = 'withdrawn', updated_at = now()
       where id = ${invitationID} and status = 'pending'
      returning id
    `;
    if (!updated) {
      const [settled] = await sql`select status from app.friendships where id = ${invitationID}`;
      return settled?.status === "withdrawn" ? { ok: true } : { conflict: true };
    }
    return { ok: true };
  }

  // Answering an invitation someone sent to this account. Mirrors the
  // production `respondToFriendInvitation`: recipient-only, and a row already
  // in the requested state answers success so a replayed mutation cannot wedge
  // the client's queue.
  async function respondToFriendInvitation(accountID, invitationID, body) {
    await requireAccount(accountID);
    const status = body.accept === true ? "accepted" : "declined";
    const suppliedActivityID = String(body.activityEventID ?? body.clientRequestID ?? "").toLowerCase();
    const activityEventID = UUID_PATTERN.test(suppliedActivityID) ? suppliedActivityID : randomUUID();
    return sql.begin(async (tx) => {
      const [row] = await tx`select * from app.friendships where id = ${invitationID}`;
      if (!row) return { missing: true };
      if (row.requested_to_account_id !== accountID) return { notRecipient: true };
      if (row.status === status) return { ok: true };
      if (row.status !== "pending") return { conflict: true };
      const [updated] = await tx`
        update app.friendships
           set status = ${status}, updated_at = now()
         where id = ${invitationID} and status = 'pending'
        returning *
      `;
      if (!updated) {
        const [settled] = await tx`select status from app.friendships where id = ${invitationID}`;
        return settled?.status === status ? { ok: true } : { conflict: true };
      }
      if (body.accept === true) {
        await recordFriendActivity(
          tx,
          activityEventID,
          accountID,
          updated.requested_by_account_id,
          "accepted a trusted-person invitation"
        );
      }
      return { ok: true };
    });
  }

  async function removeFriend(accountID, friendID) {
    await requireAccount(accountID);
    const normalizedFriendID = String(friendID ?? "").toLowerCase();
    if (!UUID_PATTERN.test(normalizedFriendID) || normalizedFriendID === accountID) return { ok: true };
    return sql.begin(async (tx) => {
      const pairKey = `friendship:${[accountID, normalizedFriendID].sort().join(":")}`;
      await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;
      await tx`
        update app.friendships
           set requested_by_account_id = ${normalizedFriendID},
               requested_to_account_id = ${accountID},
               status = 'declined',
               updated_at = now()
         where status in ('accepted', 'pending')
           and ((requested_by_account_id = ${accountID} and requested_to_account_id = ${normalizedFriendID})
             or (requested_by_account_id = ${normalizedFriendID} and requested_to_account_id = ${accountID}))`;
      await tx`
        update app.sitting_assignments
           set status = 'revoked', revoked_at = coalesce(revoked_at, now())
         where status in ('invited', 'upcoming', 'active')
           and ((owner_account_id = ${accountID} and sitter_account_id = ${normalizedFriendID})
             or (owner_account_id = ${normalizedFriendID} and sitter_account_id = ${accountID}))`;
      return { ok: true };
    });
  }

  async function blockPair(tx, accountID, friendID) {
    const normalizedFriendID = String(friendID ?? "").toLowerCase();
    if (!UUID_PATTERN.test(normalizedFriendID) || normalizedFriendID === accountID) return undefined;
    const pairKey = `friendship:${[accountID, normalizedFriendID].sort().join(":")}`;
    await tx`select pg_advisory_xact_lock(hashtextextended(${pairKey}, 0))`;
    const [friend] = await tx`select id from app.accounts where id = ${normalizedFriendID}`;
    if (!friend) return undefined;
    const [existing] = await tx`
      select * from app.friendships
       where (requested_by_account_id = ${accountID} and requested_to_account_id = ${normalizedFriendID})
          or (requested_by_account_id = ${normalizedFriendID} and requested_to_account_id = ${accountID})
    `;
    if (existing) {
      const [blocked] = await tx`
        update app.friendships
           set requested_by_account_id = ${normalizedFriendID},
               requested_to_account_id = ${accountID},
               status = 'blocked', updated_at = now()
         where id = ${existing.id}
        returning *
      `;
      return blocked;
    }
    const [blocked] = await tx`
      insert into app.friendships (
        id, requested_by_account_id, requested_to_account_id, status
      ) values (${randomUUID()}, ${normalizedFriendID}, ${accountID}, 'blocked')
      returning *
    `;
    return blocked;
  }

  async function revokeLegacyFriendAccess(tx, accountID, friendID) {
    await tx`
      update app.sitting_assignments
         set status = 'revoked', revoked_at = coalesce(revoked_at, now())
       where status in ('invited', 'upcoming', 'active')
         and ((owner_account_id = ${accountID} and sitter_account_id = ${friendID})
           or (owner_account_id = ${friendID} and sitter_account_id = ${accountID}))
    `;
    await tx`
      update app.sitting_invites
         set revoked_at = coalesce(revoked_at, now())
       where owner_account_id = ${accountID}
         and recipient_account_id = ${friendID}
         and revoked_at is null
    `;
  }

  async function blockFriend(accountID, friendID) {
    await requireAccount(accountID);
    const normalizedFriendID = String(friendID ?? "").toLowerCase();
    return sql.begin(async (tx) => {
      const relationship = await blockPair(tx, accountID, normalizedFriendID);
      if (!relationship) return { missing: true };
      await revokeLegacyFriendAccess(tx, accountID, normalizedFriendID);
      return { ok: true };
    });
  }

  async function reportFriend(accountID, friendID, body) {
    await requireAccount(accountID);
    const normalizedFriendID = String(friendID ?? "").toLowerCase();
    const requestID = String(body.clientRequestID ?? "").toLowerCase();
    const reasons = new Set(["harassment", "impersonation", "spam", "inappropriateProfile", "other"]);
    const details = String(body.details ?? "").trim();
    if (!reasons.has(body.reason) || !UUID_PATTERN.test(requestID) || [...details].length > 1000) {
      return { invalid: true };
    }
    return sql.begin(async (tx) => {
      const relationship = await blockPair(tx, accountID, normalizedFriendID);
      if (!relationship) return { missing: true };
      await tx`
        insert into app.friend_reports (
          id, reporter_account_id, reported_account_id, friendship_id,
          reason, details, client_request_id
        ) values (
          ${requestID}, ${accountID}, ${normalizedFriendID}, ${relationship.id},
          ${body.reason}, ${details || null}, ${requestID}
        ) on conflict (reporter_account_id, client_request_id) do nothing
      `;
      await revokeLegacyFriendAccess(tx, accountID, normalizedFriendID);
      return { ok: true };
    });
  }

  async function createSittingAssignment(accountID, body) {
    const { groveID } = await requireAccount(accountID);
    const rawPlantIDs = Array.isArray(body.plantIDs) ? body.plantIDs.map(String) : [];
    if (rawPlantIDs.length > 100 || rawPlantIDs.some((id) => !UUID_PATTERN.test(id))) {
      return { invalidPlants: true };
    }
    const plantIDs = [...new Set(rawPlantIDs)];
    if (!plantIDs.length) return { invalidPlants: true };
    const startsAt = new Date(body.startDate);
    const endsAt = new Date(body.endDate);
    if (!Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) || startsAt >= endsAt) {
      return { invalidDates: true };
    }
    if (endsAt <= new Date() || endsAt.getTime() - startsAt.getTime() > 180 * 86_400_000) {
      return { invalidDates: true };
    }
    const assignmentID = UUID_PATTERN.test(String(body.clientRequestID ?? ""))
      ? String(body.clientRequestID).toLowerCase()
      : randomUUID();
    const activityEventID = UUID_PATTERN.test(String(body.activityEventID ?? ""))
      ? String(body.activityEventID).toLowerCase()
      : assignmentID;
    const totalTasks = Math.max(1, plantIDs.length * 2);

    // Delegated care is a real grant of access to real plants, so the sitter has
    // to be a real account. Creating one on demand would let any string become a
    // carer; failing the foreign key would surface as a 500.
    if (!UUID_PATTERN.test(String(body.sitterAccountID ?? ""))) return { unknownSitter: true };
    const [sitter] = await sql`select id from app.accounts where id = ${body.sitterAccountID}`;
    if (!sitter) return { unknownSitter: true };
    const [friendship] = await sql`
      select id from app.friendships
       where status = 'accepted'
         and ((requested_by_account_id = ${accountID} and requested_to_account_id = ${body.sitterAccountID})
           or (requested_by_account_id = ${body.sitterAccountID} and requested_to_account_id = ${accountID}))`;
    if (!friendship) return { notFriends: true };
    const owned = await sql`
      select id from app.plants
       where grove_id = ${groveID} and id = any(${plantIDs}::uuid[])`;
    if (owned.length !== plantIDs.length) return { invalidPlants: true };

    // Both ends of this row were stored as the sitter's raw account id, so the
    // owner's own list of assignments named their friend with a uuid.
    const sitterIdentity = await actorIdentity(body.sitterAccountID);
    const actor = await actorIdentity(accountID);
    const plantCount = `${plantIDs.length} ${plantIDs.length === 1 ? "plant" : "plants"}`;

    return sql.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${`sitting-assignment:${assignmentID}`}, 0))`;
      const [existing] = await tx`select * from app.sitting_assignments where id = ${assignmentID}`;
      if (existing) {
        if (existing.owner_account_id !== accountID) return { conflict: true };
        const scoped = await tx`
          select plant_id from app.sitting_assignment_plants
           where assignment_id = ${assignmentID}
           order by plant_id`;
        const existingPlantIDs = scoped.map((row) => row.plant_id).sort();
        const sameRequest = existing.sitter_account_id === body.sitterAccountID
          && existing.grove_id === groveID
          && new Date(existing.starts_at).getTime() === startsAt.getTime()
          && new Date(existing.ends_at).getTime() === endsAt.getTime()
          && (existing.can_check_in !== false) === (body.canCheckIn !== false)
          && (existing.can_log_care !== false) === (body.canLogCare !== false)
          && String(existing.owner_notes ?? "") === String(body.ownerNotes ?? "").trim()
          && (existing.time_zone_identifier ?? "UTC") === (body.timeZoneIdentifier ?? "UTC")
          && JSON.stringify(existingPlantIDs) === JSON.stringify([...plantIDs].sort());
        return sameRequest
          ? assignmentWire({ ...existing, plant_ids: existingPlantIDs }, accountID)
          : { conflict: true };
      }
      const [row] = await tx`
        insert into app.sitting_assignments (
          id, owner_account_id, sitter_account_id, grove_id, status, starts_at, ends_at,
          can_check_in, can_log_care, owner_notes,
          sitter_name, sitter_initials, completed_tasks, total_tasks,
          time_zone_identifier
        ) values (
          ${assignmentID}, ${accountID}, ${body.sitterAccountID}, ${groveID}, 'invited',
          ${startsAt}, ${endsAt},
          ${body.canCheckIn !== false}, ${body.canLogCare !== false},
          ${String(body.ownerNotes ?? "").trim() || null}, ${sitterIdentity.name},
          ${sitterIdentity.initials}, 0, ${totalTasks}, ${body.timeZoneIdentifier ?? "UTC"}
        )
        returning *
      `;
      for (const plantID of plantIDs) {
        await tx`
          insert into app.sitting_assignment_plants (assignment_id, plant_id)
          values (${row.id}, ${plantID})
          on conflict do nothing
        `;
      }
      await tx`
        insert into app.activity_events (
          id, actor_account_id, grove_id, assignment_id,
          kind, message, audience, actor_name, actor_initials
        )
        values (
          ${activityEventID},
          ${accountID}, ${groveID}, ${row.id}, 'assignment',
          ${`invited ${sitterIdentity.name} to care for ${plantCount}`},
          '{}'::jsonb, ${actor.name}, ${actor.initials}
        )
        on conflict (id) do nothing
      `;
      return assignmentWire({ ...row, plant_ids: plantIDs }, accountID);
    });
  }

  async function respondToSittingAssignment(accountID, assignmentID, accept) {
    await requireAccount(accountID);
    if (!UUID_PATTERN.test(String(assignmentID ?? "")) || typeof accept !== "boolean") {
      return { invalid: true };
    }
    return sql.begin(async (tx) => {
      const [current] = await tx`
        select * from app.sitting_assignments
         where id = ${assignmentID} and sitter_account_id = ${accountID}
         for update`;
      if (!current) return { missing: true };
      if (current.revoked_at != null || current.status === "revoked" || new Date(current.ends_at) <= new Date()) {
        return { conflict: true };
      }
      if (current.status !== "invited") {
        const alreadyAccepted = ["upcoming", "active"].includes(current.status);
        if (alreadyAccepted !== accept) return { conflict: true };
      }
      const nextStatus = accept
        ? (new Date(current.starts_at) <= new Date() ? "active" : "upcoming")
        : "declined";
      const [row] = current.status === "invited"
        ? await tx`
            update app.sitting_assignments
               set status = ${nextStatus}, accepted_at = ${accept ? new Date() : null}
             where id = ${assignmentID}
             returning *`
        : [current];
      const plants = await tx`select plant_id from app.sitting_assignment_plants where assignment_id = ${assignmentID}`;
      const [owner] = await tx`select display_name from app.accounts where id = ${row.owner_account_id}`;
      const [sitter] = await tx`select display_name from app.accounts where id = ${row.sitter_account_id}`;
      return assignmentWire({
        ...row,
        owner_name: owner?.display_name,
        sitter_name: sitter?.display_name,
        plant_ids: plants.map((plant) => plant.plant_id)
      }, accountID);
    });
  }

  async function revokeSittingAssignment(accountID, assignmentID) {
    await requireAccount(accountID);
    if (!UUID_PATTERN.test(String(assignmentID ?? ""))) return { invalid: true };
    return sql.begin(async (tx) => {
      const [row] = await tx`
        update app.sitting_assignments
           set status = 'revoked', revoked_at = coalesce(revoked_at, now())
         where id = ${assignmentID} and owner_account_id = ${accountID}
         returning *`;
      if (!row) return { missing: true };
      const plants = await tx`select plant_id from app.sitting_assignment_plants where assignment_id = ${assignmentID}`;
      const [owner] = await tx`select display_name from app.accounts where id = ${row.owner_account_id}`;
      const [sitter] = await tx`select display_name from app.accounts where id = ${row.sitter_account_id}`;
      return assignmentWire({
        ...row,
        owner_name: owner?.display_name,
        sitter_name: sitter?.display_name,
        plant_ids: plants.map((plant) => plant.plant_id)
      }, accountID);
    });
  }

  // MARK: - Idempotency

  async function readIdempotentResponse(accountID, method, path, key) {
    const [row] = await sql`
      select status, body from app.idempotency_keys
       where account_id = ${accountID} and idempotency_key = ${key}
         and method = ${method} and path = ${path}
    `;
    return row ? { status: row.status, body: row.body } : undefined;
  }

  async function claimIdempotentResponse(accountID, method, path, key, requestHash, claimID) {
    return sql.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${`api-idempotency:${accountID}`}, 0))`;
      const [row] = await tx`
        select status, body, request_hash,
               stored_at < now() - interval '15 minutes' as stale
          from app.idempotency_keys
         where account_id = ${accountID} and idempotency_key = ${key}
           and method = ${method} and path = ${path}
         for update
      `;
      if (!row) {
        await tx`
          insert into app.idempotency_keys
              (account_id, idempotency_key, method, path, request_hash, claim_id, status, body)
          values (${accountID}, ${key}, ${method}, ${path}, ${requestHash}, ${claimID}, 102, '{}'::jsonb)
        `;
        return { claimed: true };
      }
      if (Number(row.status) === 102 && row.stale === true) {
        await tx`
          update app.idempotency_keys
             set request_hash = ${requestHash}, claim_id = ${claimID},
                 status = 102, body = '{}'::jsonb, stored_at = now()
           where account_id = ${accountID} and idempotency_key = ${key}
             and method = ${method} and path = ${path}
        `;
        return { claimed: true };
      }
      if (!row.request_hash || row.request_hash !== requestHash) return { conflict: true };
      if (Number(row.status) === 102) return { wait: true };
      return { status: Number(row.status), body: row.body };
    });
  }

  async function completeIdempotentResponse(
    accountID,
    method,
    path,
    key,
    requestHash,
    claimID,
    status,
    body
  ) {
    await sql.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${`api-idempotency:${accountID}`}, 0))`;
      if (status >= 200 && status < 300) {
        await tx`
          update app.idempotency_keys
             set status = ${status}, body = ${sql.json(body ?? {})}, stored_at = now()
           where account_id = ${accountID} and idempotency_key = ${key}
             and method = ${method} and path = ${path}
             and request_hash = ${requestHash} and claim_id = ${claimID}
        `;
      } else {
        await tx`
          delete from app.idempotency_keys
           where account_id = ${accountID} and idempotency_key = ${key}
             and method = ${method} and path = ${path} and status = 102
             and request_hash = ${requestHash} and claim_id = ${claimID}
        `;
      }
      await tx`
        delete from app.idempotency_keys stored
         where stored.account_id = ${accountID}
           and (stored.idempotency_key, stored.method, stored.path) in (
             select idempotency_key, method, path from app.idempotency_keys
              where account_id = ${accountID}
              order by stored_at desc, idempotency_key, method, path
              offset 1000
           )
      `;
    });
  }

  async function abandonIdempotentResponse(accountID, method, path, key, requestHash, claimID) {
    await sql`
      delete from app.idempotency_keys
       where account_id = ${accountID} and idempotency_key = ${key}
         and method = ${method} and path = ${path} and status = 102
         and request_hash = ${requestHash} and claim_id = ${claimID}
    `;
  }

  async function writeIdempotentResponse(accountID, method, path, key, status, body) {
    await sql.begin(async (tx) => {
      await tx`select pg_advisory_xact_lock(hashtextextended(${`api-idempotency:${accountID}`}, 0))`;
      await tx`
        insert into app.idempotency_keys (account_id, idempotency_key, method, path, status, body)
        values (${accountID}, ${key}, ${method}, ${path}, ${status}, ${sql.json(body ?? {})})
        on conflict (account_id, idempotency_key, method, path) do nothing
      `;
      await tx`
        delete from app.idempotency_keys stored
         where stored.account_id = ${accountID}
           and (stored.idempotency_key, stored.method, stored.path) in (
             select idempotency_key, method, path from app.idempotency_keys
              where account_id = ${accountID}
              order by stored_at desc, idempotency_key, method, path
              offset 1000
           )
      `;
    });
  }

  // MARK: - Media uploads

  async function negotiateUpload(accountID, body) {
    await requireAccount(accountID);
    const [existing] = await sql`
      select * from app.media_uploads
       where owner_account_id = ${accountID} and local_media_id = ${body.localMediaID}
    `;
    if (existing) {
      if (
        existing.sha256 !== body.sha256 ||
        Number(existing.byte_count) !== body.byteCount ||
        existing.mime_type !== body.mimeType
      ) {
        return { conflict: true };
      }
      const token = randomUUID();
      const [refreshed] = await sql`
        update app.media_uploads
           set token = ${token}, expires_at = ${new Date(Date.now() + UPLOAD_TTL_MILLISECONDS)}
         where media_asset_id = ${existing.media_asset_id}
        returning *
      `;
      return { upload: refreshed, created: false };
    }

    const [created] = await sql`
      insert into app.media_uploads (
        media_asset_id, owner_account_id, local_media_id, token, mime_type,
        byte_count, sha256, pixel_width, pixel_height, purpose, expires_at
      ) values (
        ${randomUUID()}, ${accountID}, ${body.localMediaID}, ${randomUUID()}, ${body.mimeType},
        ${body.byteCount}, ${body.sha256}, ${body.pixelWidth ?? null}, ${body.pixelHeight ?? null},
        ${body.purpose ?? "scan"}, ${new Date(Date.now() + UPLOAD_TTL_MILLISECONDS)}
      )
      returning *
    `;
    return { upload: created, created: true };
  }

  async function findUpload(mediaAssetID) {
    const [row] = await sql`select * from app.media_uploads where media_asset_id = ${mediaAssetID}`;
    return row;
  }

  async function markUploadReady(accountID, mediaAssetID, plantID) {
    const upload = await findUpload(mediaAssetID);
    if (!upload || upload.owner_account_id !== accountID) return undefined;
    await sql.begin(async (tx) => {
      await tx`update app.media_uploads set status = 'ready' where media_asset_id = ${mediaAssetID}`;
      await tx`
        insert into app.media_assets (
          id, owner_account_id, plant_id, storage_key, purpose, mime_type,
          pixel_width, pixel_height, byte_count
        ) values (
          ${mediaAssetID}, ${accountID}, ${plantID ?? null}, ${`uploads/${mediaAssetID}`},
          ${upload.purpose}, ${upload.mime_type}, ${upload.pixel_width}, ${upload.pixel_height},
          ${upload.byte_count}
        )
        on conflict (id) do nothing
      `;
    });
    return { ...upload, status: "ready" };
  }

  /// Drops replay records and expired upload permissions. The in-memory Maps
  /// these replace grew without bound.
  async function sweep({ retentionMilliseconds = 60 * 60_000 } = {}) {
    const cutoff = new Date(Date.now() - retentionMilliseconds);
    await sql`delete from app.idempotency_keys where stored_at < ${cutoff}`;
    await sql`delete from app.media_uploads where expires_at < ${cutoff} and status <> 'ready'`;
  }

  return {
    resolveAccount,
    requireAccount,
    snapshot,
    profileFor,
    updateProfile,
    updateGardenerProgress,
    findPlant,
    createPlant,
    updatePlant,
    deletePlant,
    recordCheckIn,
    updateCareAction,
    createCareEvent,
    deleteCareEvent,
    createFriendInvitation,
    respondToFriendInvitation,
    withdrawFriendInvitation,
    removeFriend,
    blockFriend,
    reportFriend,
    createSittingAssignment,
    respondToSittingAssignment,
    revokeSittingAssignment,
    readIdempotentResponse,
    writeIdempotentResponse,
    claimIdempotentResponse,
    completeIdempotentResponse,
    abandonIdempotentResponse,
    negotiateUpload,
    findUpload,
    markUploadReady,
    sweep
  };
}
