#!/usr/bin/env bash
#
# Archive Grove for App Store submission and export a signed .ipa.
#
# Reads GROVE_ANALYSIS_BASE_URL, GROVE_API_BASE_URL and GROVE_APP_KEY
# from .env.production (see .env.example).
# Output: build/Grove.xcarchive and build/export/Grove.ipa
#
# Upload afterwards with EITHER:
#   • Xcode → Window → Organizer → select the archive → Distribute App, OR
#   • xcrun altool --upload-app -f build/export/Grove.ipa -t ios \
#       --apiKey <key-id> --apiIssuer <issuer-id>   (App Store Connect API key)
#
# Usage:  ./scripts/archive-appstore.sh
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

bash scripts/check-production-gateway.sh
python3 scripts/apply-auth-email.py --check

OUT="/tmp/GroveArchive"                          # outside iCloud so codesign works
ARCHIVE="$OUT/Grove.xcarchive"
EXPORT="$OUT/export"

if command -v xcodegen >/dev/null 2>&1; then
  echo "▸ Regenerating Xcode project…"
  rm -rf Grove.xcodeproj && xcodegen generate >/dev/null
fi

echo "▸ Archiving Release against analysis gateway $GROVE_ANALYSIS_BASE_URL …"
rm -rf "$ARCHIVE" "$EXPORT"
BUILD_LOG="$(mktemp -t grove-archive)"
if ! xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Release \
  -destination "generic/platform=iOS" -allowProvisioningUpdates \
  -archivePath "$ARCHIVE" \
  GROVE_ANALYSIS_URL="$GROVE_ANALYSIS_BASE_URL" GROVE_SYNC_URL="${GROVE_API_BASE_URL:-}" GROVE_APP_KEY="$GROVE_APP_KEY" \
  SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
  GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-}" GOOGLE_REVERSED_CLIENT_ID="${GOOGLE_REVERSED_CLIENT_ID:-}" \
  REVENUECAT_API_KEY="${REVENUECAT_API_KEY:-}" archive >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20
  echo "✗ ARCHIVE FAILED (full log: $BUILD_LOG)."
  exit 1
fi
echo "▸ Archive succeeded."

[ -d "$ARCHIVE" ] || { echo "✗ Archive was not produced at $ARCHIVE"; exit 1; }

APP_PLIST="$ARCHIVE/Products/Applications/Grove.app/Info.plist"
for KEY in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$KEY" "$APP_PLIST" >/dev/null 2>&1; then
    echo "✗ $KEY is still present in the archived Info.plist"; exit 1
  fi
done
echo "▸ Dev-only Info.plist keys confirmed stripped."

echo "▸ Exporting signed .ipa…"
EXPORT_LOG="$(mktemp -t grove-export)"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT" -allowProvisioningUpdates >"$EXPORT_LOG" 2>&1; then
  grep -E "error:" "$EXPORT_LOG" | head -20
  echo "✗ EXPORT FAILED (full log: $EXPORT_LOG)."
  exit 1
fi

[ -f "$EXPORT/Grove.ipa" ] || { echo "✗ Export did not produce $EXPORT/Grove.ipa"; exit 1; }
echo "✓ Done: $EXPORT/Grove.ipa (archive: $ARCHIVE)"
echo "  Upload via Xcode Organizer or altool (see header of this script)."
