/// Turns a verified Supabase Auth user plus a database-owned identity class
/// into the identity used by the paid gateways.
///
/// Neither `user_metadata` nor a possibly omitted client-facing
/// `is_anonymous` field grants access. `registeredClass` comes from
/// `analysis_identity_class`, which checks the Auth row and a real app account
/// under a security-definer function. Every anonymous identity remains a guest;
/// no public signup metadata can mint Botanist access.
export function analysisIdentityForUser(
  user,
  registeredPurpose = null,
  registeredClass = null
) {
  if (!user || typeof user.id !== "string" || !user.id.trim()) return null;
  const accountID = user.id.toLowerCase();
  if (registeredClass === "account" && user.is_anonymous !== true) {
    return { accountID, kind: "account", anonymousPurpose: null };
  }
  if (registeredClass !== "anonymous" || user.is_anonymous === false) {
    return null;
  }
  // Purpose is descriptive only. Public anonymous signup metadata can never
  // elevate an identity into a paid surface or a larger budget.
  return {
    accountID,
    kind: "onboarding_guest",
    anonymousPurpose: typeof registeredPurpose === "string" ? registeredPurpose : null
  };
}

export function isOnboardingGuest(identity) {
  return identity?.kind === "onboarding_guest";
}

/// Every anonymous Auth identity gets the strict analysis budget. `purpose` is
/// retained only for cleanup/diagnostics; it is never an authorization input.
export function usesGuestAnalysisQuota(identity) {
  return identity?.kind === "onboarding_guest";
}

/// Only a provisioned account may use the Botanist. Anonymous signup is public,
/// so no value supplied during that signup can safely authorize Ari's paid
/// Gemini path without server-verified device attestation.
export function canUseBotanist(identity) {
  return identity?.kind === "account";
}
