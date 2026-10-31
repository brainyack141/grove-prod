// Who is allowed how many Botanist questions today, decided on the server.
//
// The free meter used to live only in the app, so a modified or replayed client
// simply never reported that it was out and received the abuse ceiling's worth
// of paid answers. Everything a limit depends on is now resolved here:
//
//   * premium, from RevenueCat's own record of the entitlement rather than the
//     client's claim about it;
//   * early access, from a server switch rather than the client's inference
//     that an empty catalogue means "nothing is for sale yet";
//   * the day, from UTC rather than the device's clock and time zone.
//
// Pure functions only. The Edge gateway owns the network call and the cache
// table; keeping the policy here lets the Node contract tests run every
// combination without Deno, Supabase, or a RevenueCat account.

/** Free questions an unsubscribed account gets each UTC day. */
export const freeAsksPerDay = 3;

/**
 * The abuse ceiling. Far above anything a person does by hand, so it never
 * shapes the product; it exists because the app key ships inside every binary.
 */
export const dailyAskCeiling = 60;

/** The RevenueCat entitlement every paid plan grants. Matches the dashboard. */
export const premiumEntitlementID = "premium";

/**
 * How long a verified verdict is reused before RevenueCat is asked again.
 * Short, because a purchase must unlock the app in the same session it happens.
 */
export const entitlementFreshMilliseconds = 5 * 60_000;

/**
 * How long a *paying* verdict survives once RevenueCat stops answering.
 *
 * Verification fails closed — an account Grove cannot vouch for is metered —
 * but a subscriber who was verified twenty minutes ago has not stopped paying
 * because a third party had an outage, and locking them out of something they
 * bought is the worst possible way to spend that hour. Their answer is the one
 * thing that is safe to keep serving: the free tier keeps its three questions
 * either way, so an outage can never open the gate wider than a purchase does.
 */
export const entitlementGraceMilliseconds = 6 * 60 * 60_000;

/** RevenueCat's read-only subscriber endpoint for one app user id. */
export function revenueCatSubscriberURL(appUserID) {
  return `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(String(appUserID))}`;
}

function millisecondsFrom(value) {
  if (value == null) return null;
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * Reads one entitlement out of a RevenueCat subscriber body.
 *
 * A missing `expires_date` is RevenueCat's lifetime/non-expiring shape, not a
 * malformed row, so it must read as active rather than as "expired at zero".
 * An unparseable body returns null so the caller can tell "RevenueCat says this
 * account does not pay" apart from "RevenueCat did not answer" — the first is a
 * verdict, the second must fall back to the cache.
 *
 * @param {unknown} payload
 * @param {{ now?: number, entitlementID?: string }} [options]
 * @returns {{ premium: boolean, expiresAt: string | null } | null}
 */
export function revenueCatEntitlement(payload, options = {}) {
  const { now = Date.now(), entitlementID = premiumEntitlementID } = options;
  if (typeof payload !== "object" || payload === null) return null;
  const subscriber = payload.subscriber;
  if (typeof subscriber !== "object" || subscriber === null) return null;
  const entitlements = subscriber.entitlements;
  // A subscriber who has never bought anything has an empty (or absent)
  // entitlements object. That is a real "not premium" answer, not a bad body.
  if (entitlements != null && typeof entitlements !== "object") return null;
  const entitlement = entitlements?.[entitlementID];
  if (typeof entitlement !== "object" || entitlement === null) {
    return { premium: false, expiresAt: null };
  }
  const expiresAt = entitlement.expires_date ?? null;
  if (expiresAt == null) return { premium: true, expiresAt: null };
  const expiry = millisecondsFrom(expiresAt);
  if (expiry == null) return null;
  return { premium: expiry > now, expiresAt: new Date(expiry).toISOString() };
}

function cacheVerdict(cache, now) {
  if (typeof cache !== "object" || cache === null) return null;
  const checkedAt = millisecondsFrom(cache.checkedAt ?? cache.checked_at);
  if (checkedAt == null) return null;
  const expiry = millisecondsFrom(cache.expiresAt ?? cache.expires_at);
  const premium = cache.premium === true && (expiry == null || expiry > now);
  return { premium, checkedAt, expiresAt: expiry == null ? null : new Date(expiry).toISOString() };
}

/**
 * Decides today's ceiling for one account.
 *
 * `entitlement` is a verdict RevenueCat just gave (null when it could not be
 * reached), `cache` is the last verdict Grove stored.
 *
 * @param {{
 *   earlyAccess?: boolean,
 *   verificationConfigured?: boolean,
 *   entitlement?: { premium: boolean, expiresAt: string | null } | null,
 *   cache?: { premium?: boolean, expiresAt?: string | null, checkedAt?: string | number | null } | null,
 *   now?: number,
 *   freshMilliseconds?: number,
 *   graceMilliseconds?: number
 * }} options
 * @returns {{ premium: boolean, metered: boolean, limit: number, source: string, expiresAt: string | null }}
 */
export function resolveAskPlan(options = {}) {
  const {
    earlyAccess = false,
    verificationConfigured = true,
    entitlement = null,
    cache = null,
    now = Date.now(),
    freshMilliseconds = entitlementFreshMilliseconds,
    graceMilliseconds = entitlementGraceMilliseconds
  } = options;

  // Early access is the deliberate pre-launch state: nothing is for sale, so
  // metering a subscription nobody can buy would be a wall with no door. It is
  // a server switch precisely so it cannot be inferred, faked, or left on by an
  // old binary after the products go live.
  if (earlyAccess) {
    return {
      premium: false,
      metered: false,
      limit: dailyAskCeiling,
      source: "early_access",
      expiresAt: null
    };
  }

  // No secret key configured is the same pre-launch state seen from the other
  // side: there is no way to verify a purchase, so there is nothing to sell and
  // nothing to meter. Failing closed here would put the paywall in front of
  // every account at once the moment the key went missing.
  if (!verificationConfigured) {
    return {
      premium: false,
      metered: false,
      limit: dailyAskCeiling,
      source: "verification_unconfigured",
      expiresAt: null
    };
  }

  if (entitlement && typeof entitlement.premium === "boolean") {
    return {
      premium: entitlement.premium,
      metered: !entitlement.premium,
      limit: entitlement.premium ? dailyAskCeiling : freeAsksPerDay,
      source: "revenuecat",
      expiresAt: entitlement.expiresAt ?? null
    };
  }

  const cached = cacheVerdict(cache, now);
  const age = cached == null ? Infinity : now - cached.checkedAt;
  if (cached && age >= 0 && age <= freshMilliseconds) {
    return {
      premium: cached.premium,
      metered: !cached.premium,
      limit: cached.premium ? dailyAskCeiling : freeAsksPerDay,
      source: "cache",
      expiresAt: cached.expiresAt
    };
  }
  // Only a paying verdict is carried through an outage. A stale *free* verdict
  // is worth nothing — free is already where verification fails to.
  if (cached?.premium && age >= 0 && age <= graceMilliseconds) {
    return {
      premium: true,
      metered: false,
      limit: dailyAskCeiling,
      source: "cache_grace",
      expiresAt: cached.expiresAt
    };
  }

  return {
    premium: false,
    metered: true,
    limit: freeAsksPerDay,
    source: "unverified",
    expiresAt: null
  };
}

/** Start of the next UTC day: when `botanist_usage` rolls over. */
export function nextUTCDayISO(now = Date.now()) {
  const date = new Date(now);
  return new Date(Date.UTC(
    date.getUTCFullYear(),
    date.getUTCMonth(),
    date.getUTCDate() + 1
  )).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * The meter as the app should draw it.
 *
 * Unmetered accounts report null rather than a large number, so a premium or
 * early-access client has nothing to render a countdown from and cannot invent
 * one. `used` is clamped because the counter deliberately saturates one past
 * the limit to keep a script from driving it upward forever.
 *
 * @param {{ used?: number, plan: ReturnType<typeof resolveAskPlan>, now?: number }} options
 */
export function askQuotaSnapshot({ used = 0, plan, now = Date.now() }) {
  const metered = plan.metered === true;
  const limit = metered ? Math.max(0, Math.trunc(plan.limit ?? freeAsksPerDay)) : null;
  const spent = Number.isFinite(used) ? Math.max(0, Math.trunc(used)) : 0;
  return {
    metered,
    premium: plan.premium === true,
    limit,
    used: limit == null ? spent : Math.min(spent, limit),
    remaining: limit == null ? null : Math.max(0, limit - spent),
    resetsAt: nextUTCDayISO(now)
  };
}
