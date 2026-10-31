import assert from "node:assert/strict";
import test from "node:test";
import {
  botanistV2Enabled,
  stableBotanistCohort
} from "../botanist-rollout.mjs";

test("Botanist v2 assigns the same account to the same stable cohort", () => {
  const first = stableBotanistCohort("account-123");
  assert.equal(stableBotanistCohort("account-123"), first);
  assert.ok(first >= 0 && first <= 99);
});

test("Botanist v2 rollout handles off, full, bounds, and forced overrides", () => {
  for (const owner of ["a", "guest:123", "demo-account", "long-lived-user"]) {
    assert.equal(botanistV2Enabled({ owner, rolloutPercent: 0 }), false);
    assert.equal(botanistV2Enabled({ owner, rolloutPercent: -20 }), false);
    assert.equal(botanistV2Enabled({ owner, rolloutPercent: 100 }), true);
    assert.equal(botanistV2Enabled({ owner, rolloutPercent: 120 }), true);
    assert.equal(botanistV2Enabled({ owner, forced: false, rolloutPercent: 100 }), false);
    assert.equal(botanistV2Enabled({ owner, forced: true, rolloutPercent: 0 }), true);
  }
});
