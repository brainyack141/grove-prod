#!/usr/bin/env bash
#
# Archive Grove (Release) on this Mac and upload it to TestFlight — the same
# job .github/workflows/testflight.yml does, minus GitHub Actions minutes.
#
# Usage:  ./scripts/testflight-local.sh <build-number>
#
#   e.g.  ./scripts/testflight-local.sh 22
#
# The build number must be higher than every build already uploaded for the
# current MARKETING_VERSION. Check the current highest at
# App Store Connect → Grove → TestFlight → iOS Builds, and pass the next one.
#
# ── Configuration ─────────────────────────────────────────────────────────
# Read from .env.production (gitignored, see .env.example):
#
#   GROVE_ANALYSIS_BASE_URL, GROVE_API_BASE_URL, GROVE_APP_KEY,
#   SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_IOS_CLIENT_ID,
#   GOOGLE_REVERSED_CLIENT_ID   — baked into the build, as in archive-appstore.sh
#
#   ASC_KEY_ID     — App Store Connect API key id (Users and Access →
#                    Integrations → App Store Connect API)
#   ASC_ISSUER_ID  — the Issuer ID shown above that key table
#   ASC_KEY_PATH   — path to the matching AuthKey_<ASC_KEY_ID>.p8
#
# ── Signing ───────────────────────────────────────────────────────────────
# Cloud signing (-allowProvisioningUpdates + the API key). CI avoids this
# because a fresh runner asks Apple for a *new* certificate every run and
# eventually hits the account's certificate cap. This Mac keeps what it
# creates in the login keychain, so the first run mints an Apple Distribution
# certificate and an App Store profile and every run after reuses them —
# the cap is not a concern here. The API key needs the Admin role for that
# first run; App Manager is enough once the assets exist.
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${1:-}"
[ -n "$BUILD_NUMBER" ] || { echo "✗ Usage: $0 <build-number>  (next unused build for this version)"; exit 1; }

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

for VAR in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  [ -n "${!VAR:-}" ] || { echo "✗ $VAR is not set in $ENV_FILE — see the header of this script."; exit 1; }
done
[ -f "$ASC_KEY_PATH" ] || { echo "✗ ASC_KEY_PATH does not exist: $ASC_KEY_PATH"; exit 1; }

bash scripts/check-production-gateway.sh
python3 scripts/apply-auth-email.py --check

# Everything happens outside iCloud. The repo lives in ~/Documents, which is
# iCloud-synced, and that breaks the build in two separate ways:
#
#   1. xcodebuild opens the .xcodeproj through NSFileCoordinator. When the
#      iCloud claim on that directory wedges, the coordinated read never
#      returns — the process sits at 0% CPU forever, having logged nothing
#      past its build settings. It looks like a slow build, not a hang.
#   2. codesign fails on iCloud-backed paths, and iCloud rewrites files
#      under the working tree mid-build.
#
# So stage a plain copy in /tmp and build that.
OUT="/tmp/GroveTestFlight"
STAGE="/tmp/GroveBuild"
ARCHIVE="$OUT/Grove.xcarchive"
EXPORT="$OUT/export"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"

echo "▸ Staging a build copy in $STAGE (outside iCloud)…"
rm -rf "$STAGE"
rsync -a --exclude '.git' --exclude 'build' --exclude 'node_modules' ./ "$STAGE/"
cd "$STAGE"

AUTH=(
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "▸ Archiving Release as build $BUILD_NUMBER (gateway $GROVE_ANALYSIS_BASE_URL)…"
BUILD_LOG="$OUT/archive.log"
if ! xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GROVE_ANALYSIS_URL="$GROVE_ANALYSIS_BASE_URL" GROVE_SYNC_URL="${GROVE_API_BASE_URL:-}" GROVE_APP_KEY="$GROVE_APP_KEY" \
  SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}" GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}" \
  REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}" \
  archive >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20
  echo "✗ ARCHIVE FAILED (full log: $BUILD_LOG)."
  exit 1
fi
echo "▸ Archive succeeded."

# The in-build strip phase races ProcessInfoPlistFile nondeterministically,
# so delete here too; the export re-signs afterwards either way.
APP_PLIST="$ARCHIVE/Products/Applications/Grove.app/Info.plist"
for KEY in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Delete :$KEY" "$APP_PLIST" 2>/dev/null; then
    echo "▸ Stripped $KEY (in-build phase lost the race)."
  fi
done

echo "▸ Exporting and uploading to TestFlight…"
EXPORT_LOG="$OUT/export.log"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptionsTestFlight.plist \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates "${AUTH[@]}" >"$EXPORT_LOG" 2>&1; then
  grep -E "error:" "$EXPORT_LOG" | head -20
  echo "✗ UPLOAD FAILED (full log: $EXPORT_LOG)."
  exit 1
fi

echo "✓ Uploaded build $BUILD_NUMBER to TestFlight."
echo "  Processing takes ~5–15 min; testers get it once it finishes."
echo "  Logs: $BUILD_LOG, $EXPORT_LOG"
