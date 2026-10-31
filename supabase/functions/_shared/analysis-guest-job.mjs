const allowedDecisions = new Set([
  "created",
  "existing",
  "daily_limited",
  "attempts_limited",
  "global_limited"
]);

const liveStatuses = new Set(["queued", "analysing", "completed"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/// Validates the security-sensitive result of `analysis_create_guest_job`.
/// PostgREST may return `null` without an error for a mismatched/void function;
/// callers must treat every unknown shape as unavailable rather than letting a
/// guest scan fall through to an unmetered insert.
export function parseGuestJobDecision(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { decision: "unavailable" };
  }
  const decision = value.decision;
  if (!allowedDecisions.has(decision)) return { decision: "unavailable" };
  if (decision !== "created" && decision !== "existing") return { decision };

  const job = value.job;
  if (!job || typeof job !== "object" || Array.isArray(job)) {
    return { decision: "unavailable" };
  }
  if (
    typeof job.id !== "string"
    || !uuidPattern.test(job.id)
    || !liveStatuses.has(job.status)
    || typeof job.created_at !== "string"
    || typeof job.updated_at !== "string"
    || (job.message !== null && job.message !== undefined && typeof job.message !== "string")
  ) {
    return { decision: "unavailable" };
  }
  return { decision, job };
}

export function guestJobDecisionIsLimited(decision) {
  return decision === "daily_limited"
    || decision === "attempts_limited"
    || decision === "global_limited";
}
