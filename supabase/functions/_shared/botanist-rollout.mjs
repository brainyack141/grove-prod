// Pure rollout helpers shared by the Edge gateway and Node contract tests.
//
// Environment parsing stays in the gateway; account assignment lives here so
// release behaviour can be tested without starting Deno or touching Supabase.

/** @param {string} value */
export function stableBotanistCohort(value) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % 100;
}

/**
 * @param {{
 *   owner: string,
 *   forced?: boolean | null,
 *   rolloutPercent?: number | string
 * }} options
 */
export function botanistV2Enabled({
  owner,
  forced = null,
  rolloutPercent = 0
}) {
  if (forced != null) return forced;
  const boundedPercent = Math.max(0, Math.min(100, Number(rolloutPercent) || 0));
  return stableBotanistCohort(owner) < boundedPercent;
}
