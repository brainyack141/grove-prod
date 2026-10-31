#!/usr/bin/env bash
#
# Build Grove pointing at the local analysis backend and deploy it to your iPhone.
#
# Why a script: the app has to know a URL that the *phone* can reach, and that URL
# is baked in at build time. We use the Mac's Bonjour hostname (e.g. Foo.local)
# instead of a raw IP so it keeps working when the Mac's DHCP address changes.
#
# Requirements to test on the phone:
#   • iPhone and Mac on the SAME Wi-Fi network.
#   • Backend running (this script starts it if it isn't).
#   • First launch: tap "Allow" on the iOS "find devices on your local network" prompt.
#
# Usage:  ./scripts/dev-phone.sh
#
# To deliberately exercise account sign-in from a Debug phone build, opt in to
# an auth environment explicitly:
#   GROVE_AUTH_ENV_FILE=.env.production ./scripts/dev-phone.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Debug builds do not silently inherit production auth credentials. That keeps a
# local-backend build from signing real accounts into the wrong environment.
# When account sign-in is intentionally being tested, the caller can opt in to
# a specific env file and the status is reported below instead of failing later
# as an apparently broken set of missing buttons.
AUTH_ENV_FILE="${GROVE_AUTH_ENV_FILE:-}"
if [ -n "$AUTH_ENV_FILE" ]; then
  [ -f "$AUTH_ENV_FILE" ] || { echo "✗ Auth environment file not found: $AUTH_ENV_FILE"; exit 1; }
  echo "▸ Loading account-auth configuration from $AUTH_ENV_FILE (explicit Debug opt-in)."
  set -a
  source "$AUTH_ENV_FILE"
  set +a
fi

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "▸ Account sign-in is disabled in this Debug build (SUPABASE_URL/SUPABASE_ANON_KEY are not set)."
  echo "  Provider buttons are intentionally omitted; use scripts/prod-phone.sh or set GROVE_AUTH_ENV_FILE to test them."
else
  echo "▸ Account sign-in configuration is present for this Debug build."
fi

if [ -n "${GOOGLE_IOS_CLIENT_ID:-}" ] || [ -n "${GOOGLE_REVERSED_CLIENT_ID:-}" ]; then
  [ -n "${GOOGLE_IOS_CLIENT_ID:-}" ] && [ -n "${GOOGLE_REVERSED_CLIENT_ID:-}" ] || {
    echo "✗ GOOGLE_IOS_CLIENT_ID and GOOGLE_REVERSED_CLIENT_ID must be supplied together."; exit 1;
  }
fi

HOST_LOCAL="$(scutil --get LocalHostName).local"
PORT=8080
BASE_URL="http://${HOST_LOCAL}:${PORT}/v1/"
# The target iPhone. Not committed: set GROVE_DEVICE_ID (the device UDID that
# `xcodebuild -destination id=…` takes; `xcrun xctrace list devices` shows it)
# in your shell or in the env file. GROVE_DEVICECTL_ID optionally overrides the
# id handed to devicectl (`xcrun devicectl list devices`); it defaults to
# GROVE_DEVICE_ID, which devicectl also accepts.
[ -n "${GROVE_DEVICE_ID:-}" ] || { echo "✗ GROVE_DEVICE_ID is not set. Export your iPhone's UDID (xcrun xctrace list devices), e.g. GROVE_DEVICE_ID=00008xxx-… $0"; exit 1; }
DEVICE_BUILD_ID="$GROVE_DEVICE_ID"
DEVICECTL_ID="${GROVE_DEVICECTL_ID:-$GROVE_DEVICE_ID}"
BUNDLE_ID="nz.co.thinkingai.Grove"
DERIVED="/tmp/GroveDerivedData"                 # outside iCloud so codesign works
APP="$DERIVED/Build/Products/Debug-iphoneos/Grove.app"

echo "▸ Backend URL baked into the app: $BASE_URL"

# 1. Make sure the backend is up and reachable via the Bonjour hostname.
if ! curl -sf -m 4 "http://${HOST_LOCAL}:${PORT}/health" >/dev/null 2>&1; then
  echo "▸ Backend not reachable — starting it (HOST=$HOST_LOCAL)…"
  ( cd Backend && HOST="$HOST_LOCAL" PORT="$PORT" nohup node server.mjs \
      >/tmp/grove-backend.log 2>&1 & )
  for _ in $(seq 1 15); do
    sleep 1
    curl -sf -m 4 "http://${HOST_LOCAL}:${PORT}/health" >/dev/null 2>&1 && break
  done
fi
if curl -sf -m 4 "http://${HOST_LOCAL}:${PORT}/health" >/dev/null 2>&1; then
  echo "▸ Backend healthy at http://${HOST_LOCAL}:${PORT}"
else
  echo "✗ Backend still not healthy. Check /tmp/grove-backend.log"
  echo "  (Gemini key comes from the macOS Keychain in dev; approve the prompt if it appears.)"
  exit 1
fi

# 2. Regenerate the Xcode project (picks up any added/removed source files).
if command -v xcodegen >/dev/null 2>&1; then
  echo "▸ Regenerating Xcode project…"
  rm -rf Grove.xcodeproj && xcodegen generate >/dev/null
fi

# 3. Build with the reachable backend URL baked in.
echo "▸ Building…"
BUILD_LOG="$(mktemp -t grove-build)"
if ! xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Debug \
  -destination "id=${DEVICE_BUILD_ID}" -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" \
  GROVE_SYNC_URL="$BASE_URL" GROVE_ANALYSIS_URL="$BASE_URL" \
  SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}" GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}" \
  REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20
  echo "✗ BUILD FAILED (full log: $BUILD_LOG) — not installing."
  exit 1
fi
echo "▸ Build succeeded."

[ -d "$APP" ] || { echo "✗ Build did not produce $APP"; exit 1; }

# 4. Install + launch on the device.
echo "▸ Installing on iPhone…"
xcrun devicectl device install app --device "$DEVICECTL_ID" "$APP" >/dev/null
echo "▸ Launching…"
# Hot reload: the injection runtime watches this directory for saved sources.
# The scheme sets INJECTION_PROJECT_ROOT too, but a scheme only applies when
# Xcode does the launching, and nothing here goes through Xcode — devicectl
# passes an environment through by prefixing DEVICECTL_CHILD_.
DEVICECTL_CHILD_INJECTION_PROJECT_ROOT="$PWD" \
xcrun devicectl device process launch --device "$DEVICECTL_ID" "$BUNDLE_ID" >/dev/null \
  || echo "  (Launch failed — iPhone may be locked. The app is installed; tap its icon.)"

echo "✓ Done. Grove is pointed at $BASE_URL"
echo "  If plant analysis says 'unavailable', confirm the phone is on the same Wi-Fi"
echo "  and that you allowed local-network access on first launch."
