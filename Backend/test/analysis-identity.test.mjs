import assert from "node:assert/strict";
import test from "node:test";
import {
  analysisIdentityForUser,
  canUseBotanist,
  isOnboardingGuest,
  usesGuestAnalysisQuota
} from "../analysis-identity.mjs";

const userID = "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6";

test("a server-provisioned provider user keeps the account analysis class", () => {
  const identity = analysisIdentityForUser({
    id: userID,
    is_anonymous: false
  }, null, "account");
  assert.deepEqual(identity, {
    accountID: userID.toLowerCase(),
    kind: "account",
    anonymousPurpose: null
  });
  assert.equal(isOnboardingGuest(identity), false);
  assert.equal(usesGuestAnalysisQuota(identity), false);
  assert.equal(canUseBotanist(identity), true);
});

test("every anonymous purpose remains a strict guest without Botanist access", () => {
  for (const purpose of ["onboarding_scan", "botanist", "unexpected", null]) {
    const identity = analysisIdentityForUser({
      id: userID,
      is_anonymous: true,
      // Public Auth signup controls this object; it must never affect access.
      user_metadata: { purpose: "botanist" }
    }, purpose, "anonymous");
    assert.equal(identity.kind, "onboarding_guest");
    assert.equal(isOnboardingGuest(identity), true);
    assert.equal(usesGuestAnalysisQuota(identity), true);
    assert.equal(canUseBotanist(identity), false);
  }
});

test("the database-owned class, not an optional Auth JSON flag, is authoritative", () => {
  const ambiguousAnonymous = analysisIdentityForUser({ id: userID }, "botanist", "anonymous");
  assert.equal(ambiguousAnonymous.kind, "onboarding_guest");
  assert.equal(canUseBotanist(ambiguousAnonymous), false);

  const ambiguousAccount = analysisIdentityForUser({ id: userID }, null, "account");
  assert.equal(ambiguousAccount.kind, "account");
  assert.equal(canUseBotanist(ambiguousAccount), true);

  // A disagreement can only narrow access. It never promotes the caller.
  assert.equal(analysisIdentityForUser({ id: userID, is_anonymous: true }, null, "account"), null);
  assert.equal(analysisIdentityForUser({ id: userID, is_anonymous: false }, null, "anonymous"), null);
  assert.equal(analysisIdentityForUser({ id: userID, is_anonymous: false }, null, "unclassified"), null);
  assert.equal(analysisIdentityForUser({ id: userID, is_anonymous: false }), null);
});

test("a missing or malformed Auth user is never accepted", () => {
  assert.equal(analysisIdentityForUser(null, null, "account"), null);
  assert.equal(analysisIdentityForUser({ id: "", is_anonymous: true }, null, "anonymous"), null);
});
