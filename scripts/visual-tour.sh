#!/usr/bin/env bash
#
# Run the read-only visual tour (GroveUITests/GroveVisualTourTests) on your
# iPhone against a Release build pointed at production, then export every
# screenshot it took into output/visual-tour/<timestamp>/.
#
# The phone must be unlocked and left alone while it runs. Afterwards, run
# ./scripts/prod-phone.sh to put the exact App Store-equivalent build back.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".env.production"
[ -f "$ENV_FILE" ] || { echo "✗ Missing $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# The target iPhone. Not committed: set GROVE_DEVICE_ID (the device UDID that
# `xcodebuild -destination id=…` takes; `xcrun xctrace list devices` shows it)
# in your shell or in the env file. GROVE_DEVICECTL_ID optionally overrides the
# id handed to devicectl (`xcrun devicectl list devices`); it defaults to
# GROVE_DEVICE_ID, which devicectl also accepts.
[ -n "${GROVE_DEVICE_ID:-}" ] || { echo "✗ GROVE_DEVICE_ID is not set. Export your iPhone's UDID (xcrun xctrace list devices), e.g. GROVE_DEVICE_ID=00008xxx-… $0"; exit 1; }
DEVICE_BUILD_ID="$GROVE_DEVICE_ID"
DERIVED="${GROVE_DERIVED:-/tmp/GroveDerivedDataTour}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="/tmp/grove-visual-tour-$STAMP.xcresult"
OUT="output/visual-tour/$STAMP"

if [ -z "${GROVE_SKIP_XCODEGEN:-}" ] && command -v xcodegen >/dev/null 2>&1; then
  echo "▸ Regenerating Xcode project…"
  rm -rf Grove.xcodeproj && xcodegen generate >/dev/null
fi

echo "▸ Running the visual tour on the iPhone (Release)…"
set +e
xcodebuild test -project Grove.xcodeproj -scheme GroveVisualTour -configuration Release \
  -destination "id=${DEVICE_BUILD_ID}" -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
  -only-testing:GroveUITests/GroveVisualTourTests \
  GROVE_ANALYSIS_URL="$GROVE_ANALYSIS_BASE_URL" GROVE_SYNC_URL="${GROVE_API_BASE_URL:-}" GROVE_APP_KEY="$GROVE_APP_KEY" \
  SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}" GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}" \
  REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}" > "/tmp/grove-visual-tour-$STAMP.log" 2>&1
STATUS=$?
set -e
grep -E "error:|Test Case|Executed|TEST (SUCCEEDED|FAILED)" "/tmp/grove-visual-tour-$STAMP.log" | tail -15

mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null 2>&1 || true
echo "▸ Screenshots: $OUT ($(ls "$OUT" | grep -c -i png || true) images)"
exit $STATUS
