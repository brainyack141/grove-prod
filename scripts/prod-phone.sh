#!/usr/bin/env bash
#
# Build Grove in Release configuration against the PRODUCTION backend and deploy
# it to your iPhone. This is the "exactly what the App Store build will do"
# smoke test: HTTPS only, app key enforced, local-network entitlements stripped.
#
# Reads GROVE_ANALYSIS_BASE_URL, GROVE_API_BASE_URL and GROVE_APP_KEY
# from .env.production (see .env.example).
#
# Usage:  ./scripts/prod-phone.sh
#         GROVE_DIALS=1 ./scripts/prod-phone.sh   # + live motion-tuning drawer (shake)
#
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".env.production"
[ -f "$ENV_FILE" ] || { echo "✗ Missing $ENV_FILE — copy .env.example and fill it in."; exit 1; }
set -a; source "$ENV_FILE"; set +a

case "${GROVE_ANALYSIS_BASE_URL:-}" in
  https://*) : ;;
  *) echo "✗ GROVE_ANALYSIS_BASE_URL must be an https URL (got '${GROVE_ANALYSIS_BASE_URL:-}')."; exit 1 ;;
esac
# The data-sync backend. Release builds require it (no endpoint is compiled in).
case "${GROVE_API_BASE_URL:-}" in
  https://*) : ;;
  *) echo "✗ GROVE_API_BASE_URL must be an https URL (got '${GROVE_API_BASE_URL:-}')."; exit 1 ;;
esac
[ -n "${GROVE_APP_KEY:-}" ] || { echo "✗ GROVE_APP_KEY is empty in $ENV_FILE."; exit 1; }

# The target iPhone. Not committed: set GROVE_DEVICE_ID (the device UDID that
# `xcodebuild -destination id=…` takes; `xcrun xctrace list devices` shows it)
# in your shell or in the env file. GROVE_DEVICECTL_ID optionally overrides the
# id handed to devicectl (`xcrun devicectl list devices`); it defaults to
# GROVE_DEVICE_ID, which devicectl also accepts.
[ -n "${GROVE_DEVICE_ID:-}" ] || { echo "✗ GROVE_DEVICE_ID is not set. Export your iPhone's UDID (xcrun xctrace list devices), e.g. GROVE_DEVICE_ID=00008xxx-… $0"; exit 1; }
DEVICE_BUILD_ID="$GROVE_DEVICE_ID"
DEVICECTL_ID="${GROVE_DEVICECTL_ID:-$GROVE_DEVICE_ID}"
BUNDLE_ID="nz.co.thinkingai.Grove"
# Outside iCloud so codesign works. Overridable because two agents building the
# same repo at once deadlock on the shared build.db ("database is locked"); the
# second one can point somewhere else instead of waiting out the first.
DERIVED="${GROVE_DERIVED:-/tmp/GroveDerivedDataRelease}"
APP="$DERIVED/Build/Products/Release-iphoneos/Grove.app"

bash scripts/check-production-gateway.sh
python3 scripts/apply-auth-email.py --check

# Skippable because the rm -rf deletes the project out from under any build
# already running in this tree — including another agent's. Set this when the
# change is source-only and project.yml has not moved.
if [ -z "${GROVE_SKIP_XCODEGEN:-}" ] && command -v xcodegen >/dev/null 2>&1; then
  echo "▸ Regenerating Xcode project…"
  rm -rf Grove.xcodeproj && xcodegen generate >/dev/null
fi

# Opt-in tuning build: compiles in the DialKit drawer for GroveMotion. Never
# set this for a build that is going to TestFlight or the App Store.
EXTRA_CONDITIONS=""
if [ -n "${GROVE_DIALS:-}" ]; then
  EXTRA_CONDITIONS="GROVE_DIALS"
  echo "▸ GROVE_DIALS on: shake the phone to open the motion dials."
fi

echo "▸ Building Release against analysis gateway $GROVE_ANALYSIS_BASE_URL …"
BUILD_LOG="$(mktemp -t grove-build)"
if ! xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Release \
  -destination "id=${DEVICE_BUILD_ID}" -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" \
  GROVE_ANALYSIS_URL="$GROVE_ANALYSIS_BASE_URL" GROVE_SYNC_URL="${GROVE_API_BASE_URL:-}" GROVE_APP_KEY="$GROVE_APP_KEY" \
  SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}" GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}" \
  REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}" GROVE_EXTRA_SWIFT_CONDITIONS="$EXTRA_CONDITIONS" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20
  echo "✗ BUILD FAILED (full log: $BUILD_LOG) — not installing."
  exit 1
fi
echo "▸ Build succeeded."

[ -d "$APP" ] || { echo "✗ Build did not produce $APP"; exit 1; }

# Strip the dev-only keys here rather than trusting the in-build phase: Xcode
# gives no deterministic ordering between that phase, ProcessInfoPlistFile and
# CodeSign, so the phase can lose the race in either direction. Deleting after
# the build always works — but it breaks the code seal, so re-sign afterwards
# with the same identity and entitlements.
STRIPPED=0
for KEY in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Delete :$KEY" "$APP/Info.plist" 2>/dev/null; then
    STRIPPED=1
  fi
done
if [ "$STRIPPED" = 1 ]; then
  echo "▸ Stripped dev-only Info.plist keys post-build."
fi
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "✗ No Apple Development signing identity found for re-signing."; exit 1; }
ENTS="$(mktemp -t grove-ents).plist"
codesign -d --entitlements - --xml "$APP" > "$ENTS" 2>/dev/null || true
if [ -s "$ENTS" ]; then
  codesign --force --sign "$IDENTITY" --entitlements "$ENTS" "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep "$APP" || { echo "✗ Re-signed bundle failed verification."; exit 1; }

# Sanity: the dev-only keys must be gone from a Release bundle.
for KEY in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$KEY" "$APP/Info.plist" >/dev/null 2>&1; then
    echo "✗ $KEY is still present in the Release Info.plist"; exit 1
  fi
done
echo "▸ Dev-only Info.plist keys confirmed stripped."

echo "▸ Installing on iPhone…"
xcrun devicectl device install app --device "$DEVICECTL_ID" "$APP" >/dev/null
echo "▸ Launching…"
xcrun devicectl device process launch --device "$DEVICECTL_ID" "$BUNDLE_ID" >/dev/null \
  || echo "  (Launch failed — iPhone may be locked. The app is installed; tap its icon.)"

echo "✓ Done. Release build on the phone is pointed at $GROVE_ANALYSIS_BASE_URL"
