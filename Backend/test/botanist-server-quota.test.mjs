// The free-question allowance is a server decision. These tests pin the policy
// itself, then pin that the gateway, migration, client and release gate all
// still agree with it — the loophole this closes was not a bug in any one of
// them, it was the allowance living in a place the server could not see.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  askQuotaSnapshot,
  dailyAskCeiling,
  entitlementFreshMilliseconds,
  entitlementGraceMilliseconds,
  freeAsksPerDay,
  nextUTCDayISO,
  resolveAskPlan,
  revenueCatEntitlement,
  revenueCatSubscriberURL
} from "../botanist-entitlement.mjs";

const migrationURL = new URL(
  "../../supabase/migrations/20260804000001_botanist_server_quota.sql",
  import.meta.url
);
const gatewayURL = new URL("../../supabase/functions/botanist/index.ts", import.meta.url);
const askSessionURL = new URL("../../Grove/AskSession.swift", import.meta.url);
const botanistServiceURL = new URL("../../Grove/BotanistService.swift", import.meta.url);
const releaseGateURL = new URL("../../scripts/check-production-gateway.sh", import.meta.url);

const now = Date.parse("2026-08-04T09:00:00Z");

test("an unverified account gets the free allowance, never the abuse ceiling", () => {
  const plan = resolveAskPlan({ now });
  assert.equal(plan.premium, false);
  assert.equal(plan.metered, true);
  assert.equal(plan.limit, freeAsksPerDay);
  assert.equal(plan.source, "unverified");
});

test("a verified subscriber is unmetered", () => {
  const plan = resolveAskPlan({
    now,
    entitlement: { premium: true, expiresAt: "2026-09-01T00:00:00Z" }
  });
  assert.equal(plan.premium, true);
  assert.equal(plan.metered, false);
  assert.equal(plan.limit, dailyAskCeiling);
  assert.equal(plan.source, "revenuecat");
});

test("a verified non-subscriber is metered even with a premium cache", () => {
  // A live "no" beats a stored "yes". Otherwise a cancelled subscription would
  // keep paying out for as long as the cache survived.
  const plan = resolveAskPlan({
    now,
    entitlement: { premium: false, expiresAt: null },
    cache: { premium: true, expiresAt: null, checkedAt: new Date(now - 1_000).toISOString() }
  });
  assert.equal(plan.premium, false);
  assert.equal(plan.limit, freeAsksPerDay);
  assert.equal(plan.source, "revenuecat");
});

test("early access is a server switch, and it unmeters without claiming premium", () => {
  const plan = resolveAskPlan({ now, earlyAccess: true });
  assert.equal(plan.metered, false);
  assert.equal(plan.limit, dailyAskCeiling);
  // Not premium: the app must not draw a subscriber badge for someone who has
  // bought nothing, and must not skip the paywall once products go on sale.
  assert.equal(plan.premium, false);
  assert.equal(plan.source, "early_access");
});

test("no secret key is the pre-launch state, not a reason to meter everyone", () => {
  const plan = resolveAskPlan({ now, verificationConfigured: false });
  assert.equal(plan.metered, false);
  assert.equal(plan.source, "verification_unconfigured");
});

test("a fresh cached verdict answers without troubling RevenueCat", () => {
  const plan = resolveAskPlan({
    now,
    cache: {
      premium: true,
      expiresAt: "2026-09-01T00:00:00Z",
      checkedAt: new Date(now - entitlementFreshMilliseconds + 1_000).toISOString()
    }
  });
  assert.equal(plan.premium, true);
  assert.equal(plan.source, "cache");
});

test("a subscriber keeps premium through a RevenueCat outage, inside the grace window", () => {
  const cache = {
    premium: true,
    expiresAt: "2026-09-01T00:00:00Z",
    checkedAt: new Date(now - entitlementGraceMilliseconds + 60_000).toISOString()
  };
  const plan = resolveAskPlan({ now, entitlement: null, cache });
  assert.equal(plan.premium, true);
  assert.equal(plan.source, "cache_grace");
});

test("a subscriber past the grace window falls back to the free tier, not to nothing", () => {
  const plan = resolveAskPlan({
    now,
    entitlement: null,
    cache: {
      premium: true,
      expiresAt: "2026-09-01T00:00:00Z",
      checkedAt: new Date(now - entitlementGraceMilliseconds - 1_000).toISOString()
    }
  });
  assert.equal(plan.premium, false);
  assert.equal(plan.metered, true);
  // Fail closed still means three questions. An outage must never take away the
  // allowance an account would have had with no subscription at all.
  assert.equal(plan.limit, freeAsksPerDay);
  assert.equal(plan.source, "unverified");
});

test("a stale free verdict is worth nothing and never opens the gate", () => {
  const plan = resolveAskPlan({
    now,
    entitlement: null,
    cache: {
      premium: false,
      expiresAt: null,
      checkedAt: new Date(now - entitlementGraceMilliseconds + 1_000).toISOString()
    }
  });
  assert.equal(plan.premium, false);
  assert.equal(plan.limit, freeAsksPerDay);
});

test("a cache stamped in the future is not treated as fresh", () => {
  const plan = resolveAskPlan({
    now,
    cache: { premium: true, expiresAt: null, checkedAt: new Date(now + 86_400_000).toISOString() }
  });
  assert.equal(plan.premium, false);
  assert.equal(plan.source, "unverified");
});

test("an expired cached entitlement is not premium even while it is fresh", () => {
  const plan = resolveAskPlan({
    now,
    cache: {
      premium: true,
      expiresAt: new Date(now - 1_000).toISOString(),
      checkedAt: new Date(now - 1_000).toISOString()
    }
  });
  assert.equal(plan.premium, false);
  assert.equal(plan.limit, freeAsksPerDay);
});

test("RevenueCat bodies are read the way RevenueCat writes them", () => {
  assert.deepEqual(
    revenueCatEntitlement(
      { subscriber: { entitlements: { premium: { expires_date: "2026-09-01T00:00:00Z" } } } },
      { now }
    ),
    { premium: true, expiresAt: "2026-09-01T00:00:00.000Z" }
  );
  // A null expiry is RevenueCat's non-expiring shape, not an expiry at zero.
  assert.deepEqual(
    revenueCatEntitlement({ subscriber: { entitlements: { premium: { expires_date: null } } } }, { now }),
    { premium: true, expiresAt: null }
  );
  assert.deepEqual(
    revenueCatEntitlement(
      { subscriber: { entitlements: { premium: { expires_date: "2026-08-01T00:00:00Z" } } } },
      { now }
    ),
    { premium: false, expiresAt: "2026-08-01T00:00:00.000Z" }
  );
  // A subscriber who never bought anything is a real answer.
  assert.deepEqual(
    revenueCatEntitlement({ subscriber: { entitlements: {} } }, { now }),
    { premium: false, expiresAt: null }
  );
  // An unusable body is not an answer, so the caller can reach for the cache.
  assert.equal(revenueCatEntitlement(null, { now }), null);
  assert.equal(revenueCatEntitlement({ subscriber: null }, { now }), null);
  assert.equal(
    revenueCatEntitlement({ subscriber: { entitlements: { premium: { expires_date: "soon" } } } }, { now }),
    null
  );
});

test("the account id is escaped into the RevenueCat path", () => {
  assert.equal(
    revenueCatSubscriberURL("a/../b?c"),
    "https://api.revenuecat.com/v1/subscribers/a%2F..%2Fb%3Fc"
  );
});

test("the quota the app draws is bounded and resets on the UTC day", () => {
  const metered = askQuotaSnapshot({ used: 2, plan: resolveAskPlan({ now }), now });
  assert.deepEqual(metered, {
    metered: true,
    premium: false,
    limit: 3,
    used: 2,
    remaining: 1,
    resetsAt: "2026-08-05T00:00:00Z"
  });
  // The counter saturates one past the limit; the meter must not show -1 left.
  const saturated = askQuotaSnapshot({ used: 4, plan: resolveAskPlan({ now }), now });
  assert.equal(saturated.used, 3);
  assert.equal(saturated.remaining, 0);
  // An unmetered account gets no countdown to render at all.
  const unmetered = askQuotaSnapshot({
    used: 12,
    plan: resolveAskPlan({ now, entitlement: { premium: true, expiresAt: null } }),
    now
  });
  assert.equal(unmetered.limit, null);
  assert.equal(unmetered.remaining, null);
  assert.equal(unmetered.metered, false);
  assert.equal(unmetered.premium, true);
});

test("the UTC day boundary is the reset, whatever the device thinks", () => {
  assert.equal(nextUTCDayISO(Date.parse("2026-08-04T00:00:01Z")), "2026-08-05T00:00:00Z");
  assert.equal(nextUTCDayISO(Date.parse("2026-08-04T23:59:59Z")), "2026-08-05T00:00:00Z");
  assert.equal(nextUTCDayISO(Date.parse("2026-12-31T18:00:00Z")), "2027-01-01T00:00:00Z");
});

test("the migration keeps the entitlement cache service-role only and purges it with the account", async () => {
  const sql = await readFile(migrationURL, "utf8");
  assert.match(sql, /create table if not exists public\.botanist_entitlements/i);
  assert.match(sql, /alter table public\.botanist_entitlements enable row level security/i);
  for (const role of ["public", "anon", "authenticated"]) {
    assert.match(sql, new RegExp(`revoke all on public\\.botanist_entitlements from ${role}`, "i"));
  }
  assert.match(
    sql,
    /grant select, insert, update, delete on public\.botanist_entitlements to service_role/i
  );
  assert.match(
    sql,
    /botanist_entitlements_live_account[\s\S]*botanist_require_live_account/i
  );
  assert.match(sql, /delete from public\.botanist_entitlements where account_id = old\.id::text/i);
  // The cache stores a verdict, never a receipt, price, or transaction.
  const columns = sql.slice(
    sql.indexOf("create table if not exists public.botanist_entitlements"),
    sql.indexOf("alter table public.botanist_entitlements")
  );
  assert.ok(columns.length > 0);
  assert.doesNotMatch(columns, /receipt|transaction|price|product|store|token/i);
  assert.match(sql, /botanist_asks_today[\s\S]*now\(\) at time zone 'utc'/i);
  assert.match(sql, /botanist_schema_contract_version[\s\S]*select 8/i);
  for (const routine of [
    "public.botanist_entitlement(text)",
    "public.botanist_asks_today(text)",
    "public.botanist_store_entitlement(text, boolean, timestamptz, text)"
  ]) {
    const escaped = routine.replace(/[.()]/g, (character) => `\\${character}`);
    assert.match(sql, new RegExp(`grant execute on function ${escaped} to service_role`, "i"));
    assert.match(sql, new RegExp(`revoke all on function ${escaped} from anon`, "i"));
  }
});

test("the gateway enforces the allowance itself and never trusts the request for it", async () => {
  const source = await readFile(gatewayURL, "utf8");
  assert.match(source, /const plan = await askPlan\(owner\)/);
  // The limit passed to the counter is the resolved plan's, not a constant and
  // not anything the client sent.
  assert.match(source, /claimRequest\(owner, payload\.requestID, plan\.limit\)/);
  assert.match(source, /recordAsk\(owner, plan\.limit\)/);
  assert.doesNotMatch(source, /p_daily_limit: dailyAskCeiling/);
  // A metered wall is a paywall the user can act on; the ceiling is not.
  assert.match(source, /if \(plan\.metered\) \{[\s\S]*json\(402/);
  assert.match(source, /json\(429, \{[\s\S]*That's a lot of questions for one day/);
  // Every charged answer reports the meter back, so the app never has to guess.
  assert.match(source, /quota: await quotaFor\(owner, plan\)/);
  assert.match(source, /serverQuota: true/);
  assert.match(source, /freeAsksPerDay,/);
  // Verification failing must not be storable as if RevenueCat had said it.
  assert.match(source, /if \(entitlement\) await storeEntitlement\(owner, entitlement\)/);
  assert.match(source, /p_source: "revenuecat"/);
  // An unreadable count is reported as absent, not as zero used, so a database
  // hiccup cannot refill the app's meter on the request that spent from it.
  assert.match(source, /return used == null \? null : askQuotaSnapshot/);
});

test("the app treats the gateway's count as the one that decides", async () => {
  const [session, service] = await Promise.all([
    readFile(askSessionURL, "utf8"),
    readFile(botanistServiceURL, "utf8")
  ]);
  assert.match(service, /struct BotanistAskQuota[\s\S]*let remaining: Int\?/);
  assert.match(service, /quota: response\.quota/);
  assert.match(session, /private func applyServerQuota\(_ quota: BotanistAskQuota\)/);
  assert.match(session, /if let quota = answer\.quota/);
  // A refusal corrects the local meter rather than leaving it showing questions
  // the gateway will not serve.
  assert.match(session, /markAllowanceSpent\(\)[\s\S]*BotanistClientPolicyError|premiumRequired[\s\S]*markAllowanceSpent\(\)/);
  // The app's day must be the gateway's day, or the meter reads full for hours
  // after the gateway starts refusing.
  assert.match(session, /isSameUTCDay/);
  assert.match(session, /TimeZone\(identifier: "UTC"\)/);
  assert.doesNotMatch(session, /Calendar\.current\.isDate\(meterDay!/);
});

test("the release gate refuses a metered client against an unmetered gateway", async () => {
  const gate = await readFile(releaseGateURL, "utf8");
  assert.match(gate, /"contractVersion"\[\[:space:\]\]\*:\[\[:space:\]\]\*8/);
  assert.match(gate, /"schemaContractVersion"\[\[:space:\]\]\*:\[\[:space:\]\]\*8/);
  assert.match(gate, /"serverQuota"/);
  assert.match(gate, /"freeAsksPerDay"\[\[:space:\]\]\*:\[\[:space:\]\]\*3/);
});

test("the client and the server agree on how many free questions there are", async () => {
  const session = await readFile(askSessionURL, "utf8");
  const declared = session.match(/static let freeAsksPerDay = (\d+)/);
  assert.ok(declared, "AskSession must declare the free allowance");
  assert.equal(Number(declared[1]), freeAsksPerDay);
});
