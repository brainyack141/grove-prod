import assert from "node:assert/strict";
import test from "node:test";
import {
  guestJobDecisionIsLimited,
  parseGuestJobDecision
} from "../analysis-guest-job.mjs";

const job = {
  id: "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6",
  status: "queued",
  created_at: "2026-08-02T00:00:00.000Z",
  updated_at: "2026-08-02T00:00:00.000Z",
  result: null,
  message: null
};

test("guest job RPC accepts only complete created/existing job contracts", () => {
  assert.deepEqual(parseGuestJobDecision({ decision: "created", job }), {
    decision: "created",
    job
  });
  assert.deepEqual(parseGuestJobDecision({ decision: "existing", job }), {
    decision: "existing",
    job
  });
});

test("null and malformed guest job RPC results fail closed", () => {
  for (const value of [
    null,
    undefined,
    {},
    { decision: "created" },
    { decision: "created", job: { ...job, id: "not-a-uuid" } },
    { decision: "allowed" },
    []
  ]) {
    assert.deepEqual(parseGuestJobDecision(value), { decision: "unavailable" });
  }
});

test("every quota decision is recognized as limited", () => {
  for (const decision of ["daily_limited", "attempts_limited", "global_limited"]) {
    assert.deepEqual(parseGuestJobDecision({ decision }), { decision });
    assert.equal(guestJobDecisionIsLimited(decision), true);
  }
  assert.equal(guestJobDecisionIsLimited("unavailable"), false);
});
