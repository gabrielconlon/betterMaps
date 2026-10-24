#!/usr/bin/env bash
# Archive BetterMaps for iOS, export a signed .ipa, and upload it to TestFlight.
#
# Usage:
#   scripts/release.sh              # archive, export, upload
#   scripts/release.sh --no-upload  # archive and export only (a dry run before paying the
#                                   # 10-minute upload+processing tax to find a signing bug)
#
# The build number is the git commit count, so it climbs on its own and never collides with
# a build App Store Connect has already seen. The marketing version lives in project.yml.
#
# Credentials: the App Store Connect API key is read from
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, which is the path Apple's tools search
# by default. The key ID and issuer ID are not secrets; the .p8 is, and it stays out of git.
set -euo pipefail
cd "$(dirname "$0")/.."

API_KEY_ID="${ASC_KEY_ID:-FMX4FN3K62}"
API_ISSUER_ID="${ASC_ISSUER_ID:-69a6de80-535b-47e3-e053-5b8c7c11a4d1}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"

UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

ARCHIVE="build/BetterMaps.xcarchive"
EXPORT_DIR="build/export"
IPA="$EXPORT_DIR/CustomMapApp.ipa"

BUILD_NUMBER="$(git rev-list --count HEAD)"
MARKETING_VERSION="$(awk '/MARKETING_VERSION/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "error: API key not found at $KEY_PATH" >&2
  echo "       Download it from App Store Connect > Users and Access > Integrations." >&2
  exit 1
fi

# A dirty tree means the build number (a commit count) does not describe what is in the
# binary. Warn rather than block — a quick tester build off uncommitted work is legitimate.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: working tree is dirty; build $BUILD_NUMBER will not match any commit"
fi

echo "==> BetterMaps $MARKETING_VERSION ($BUILD_NUMBER)"

echo "==> Regenerating project"
xcodegen generate --quiet

echo "==> Archiving (Release, generic iOS device)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
  -project CustomMapApp.xcodeproj \
  -scheme CustomMapApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "==> Exporting signed .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID"

if [[ "$UPLOAD" -eq 0 ]]; then
  echo "==> Done (no upload). Artifact: $IPA"
  exit 0
fi

echo "==> Uploading to TestFlight"
xcrun altool --upload-app \
  --file "$IPA" \
  --type ios \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID"

echo "==> Uploaded build $BUILD_NUMBER."
echo "    Processing takes 5-15 minutes; internal testers get it with no review."
