#!/usr/bin/env bash
#
# Fail a release before build/archive when its production intelligence services
# are missing, unconfigured, or older than the client contract.
#
# Expects GROVE_ANALYSIS_BASE_URL and GROVE_API_BASE_URL to be loaded by the
# caller (.env.production locally, repository secrets in CI). No endpoint is
# hard-coded here.
set -euo pipefail

BASE_URL="${GROVE_ANALYSIS_BASE_URL:-}"
case "$BASE_URL" in
  https://*/) : ;;
  https://*) BASE_URL="${BASE_URL}/" ;;
  *) echo "✗ GROVE_ANALYSIS_BASE_URL must be an https URL."; exit 1 ;;
esac

# A cold edge isolate or a stalled request can drop a single probe in under a
# second. That is a flaky network, not a broken release contract, so probe each
# gateway a few times before failing the release. A genuinely missing or stale
# deployment still fails every attempt and is reported just as loudly.
PROBE_ATTEMPTS="${PROBE_ATTEMPTS:-3}"
PROBE_DELAY="${PROBE_DELAY:-2}"

probe_health() {  # probe_health <url> <validator-fn> — 0 when the contract holds
  local url="$1" validate="$2" body="" attempt
  for attempt in $(seq 1 "$PROBE_ATTEMPTS"); do
    if body="$(curl --fail-with-body --silent --show-error --max-time 10 "$url" 2>/dev/null)" \
        && [ -n "$body" ] && "$validate" "$body"; then
      return 0
    fi
    if [ "$attempt" -lt "$PROBE_ATTEMPTS" ]; then sleep "$PROBE_DELAY"; fi
  done
  return 1
}

valid_analysis_contract() {
  local body="$1"
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"$body" \
    && grep -Eq '"geminiConfigured"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"model"[[:space:]]*:[[:space:]]*"gemini-3\.7-flash"' <<<"$body" \
    && grep -Eq '"thinkingLevel"[[:space:]]*:[[:space:]]*"low"' <<<"$body" \
    && grep -Eq '"legacyBearersAllowed"[[:space:]]*:[[:space:]]*false' <<<"$body"
}

# Contract 8 moves the free-question allowance onto the server, on top of
# contract 7's fail-closed app identification, persistent evidence-boundary
# answers, and bounded denied-request storage. A release must not expose this
# client against an older gateway or schema: shipping the metered client against
# a contract 7 gateway would leave the daily allowance enforced only in the app,
# which is the loophole this contract exists to close.
valid_botanist_contract() {
  local body="$1"
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"$body" \
    && grep -Eq '"appIdentificationConfigured"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"provider"[[:space:]]*:[[:space:]]*"configured"' <<<"$body" \
    && grep -Eq '"contractVersion"[[:space:]]*:[[:space:]]*8[[:space:]]*[,}]' <<<"$body" \
    && grep -Eq '"schemaContractVersion"[[:space:]]*:[[:space:]]*8[[:space:]]*[,}]' <<<"$body" \
    && grep -Eq '"serverQuota"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"freeAsksPerDay"[[:space:]]*:[[:space:]]*3[[:space:]]*[,}]' <<<"$body" \
    && grep -Eq '"model"[[:space:]]*:[[:space:]]*"gemini-3\.7-flash"' <<<"$body" \
    && grep -Eq '"verifierModel"[[:space:]]*:[[:space:]]*"gemini-3\.7-flash"' <<<"$body" \
    && grep -Eq '"visionModel"[[:space:]]*:[[:space:]]*"gemini-3\.7-flash"' <<<"$body" \
    && grep -Eq '"thinkingEnabled"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"photoAnalysisConfigured"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"visionThreads"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"requestIdempotency"[[:space:]]*:[[:space:]]*true' <<<"$body" \
    && grep -Eq '"maxPhotoAttachments"[[:space:]]*:[[:space:]]*2' <<<"$body" \
    && grep -Eq '"intelligenceVersion"[[:space:]]*:' <<<"$body" \
    && grep -Eq '"adviceStore"[[:space:]]*:[[:space:]]*"ready"' <<<"$body" \
    && grep -Eq '"rolloutPercent"[[:space:]]*:' <<<"$body" \
    && grep -Eq '"visionRolloutPercent"[[:space:]]*:' <<<"$body"
}

ANALYSIS_URL="${BASE_URL}analysis/health"
echo "▸ Checking analysis gateway contract: $ANALYSIS_URL"
if ! probe_health "$ANALYSIS_URL" valid_analysis_contract >/dev/null; then
  echo "✗ Production analysis is unavailable, unhealthy, on an invalid model/thinking contract, or still accepts legacy bearers."
  exit 1
fi

BOTANIST_URL="${BASE_URL}botanist/health"
echo "▸ Checking botanist gateway contract: $BOTANIST_URL"
if ! probe_health "$BOTANIST_URL" valid_botanist_contract >/dev/null; then
  echo "✗ Production botanist is stale and does not serve the current response contract."
  echo "  Apply pending Supabase migrations, deploy the botanist function, then retry."
  exit 1
fi

# Auth signup now depends on a server-owned completion marker. Refuse to ship a
# client that asks for the RPC before the production database and sync function
# expose that contract; otherwise every provider sign-in would fail after the
# App Store update until the backend caught up.
SYNC_V1_BASE="${GROVE_API_BASE_URL:-}"
case "$SYNC_V1_BASE" in
  https://*/v1/) : ;;
  https://*/v1) SYNC_V1_BASE="${SYNC_V1_BASE}/" ;;
  *) echo "✗ GROVE_API_BASE_URL must be set to an https URL ending in /v1/."; exit 1 ;;
esac
# App requests live below /v1/, while both supported gateways keep their open
# readiness probe beside it: /health for Node and /api/health for the Edge
# function. Appending `health` to the v1 base incorrectly asked for /v1/health.
SYNC_HEALTH="${SYNC_V1_BASE%v1/}health"
echo "▸ Checking account gateway contract: $SYNC_HEALTH"
valid_account_contract() {
  local body="$1"
  grep -Eq '"database"[[:space:]]*:[[:space:]]*"connected"' <<<"$body" \
    && grep -Eq '"signupCompletionReady"[[:space:]]*:[[:space:]]*true' <<<"$body"
}
if ! probe_health "$SYNC_HEALTH" valid_account_contract >/dev/null; then
  echo "✗ Production account gateway is missing the signup-completion contract."
  echo "  Apply pending Supabase migrations, deploy the api function, then retry."
  exit 1
fi

echo "✓ Production analysis, botanist, and account contracts are ready."
