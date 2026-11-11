#!/usr/bin/env bash
# Archive Deepwell for the Mac (app + Safari and Share extensions), export it for App Store Connect, validate it
# and upload it to TestFlight. See docs/install.md.
#
#   scripts/release.sh                 bump CURRENT_PROJECT_VERSION, archive, export, validate, upload
#   scripts/release.sh --export-only   bump, archive, export and check the package locally; no App Store Connect
#   scripts/release.sh --keep-build    reuse the current build number (e.g. re-run after a failed archive or upload)
#
# App Store Connect API key, never committed:
#   ASC_KEY_ID      key id (10 characters)
#   ASC_ISSUER_ID   issuer id (UUID)
#   ASC_KEY_PATH    path to AuthKey_<id>.p8, or leave unset and store the .p8 in the login Keychain:
#                   security add-generic-password -s deepwell.asc-api-key -a "$ASC_KEY_ID" -w "$(base64 -i AuthKey_XXXX.p8)"
#
# Safe to re-run: every run cleans its own outputs under build/release/. A run bumps the build number before
# archiving, so a failed run only skips a number. App Store Connect needs a new number for each upload. Uploaded
# numbers are recorded in build/release/uploaded, and --keep-build refuses to upload the same number twice.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

OUT=build/release
UPLOADED="$OUT/uploaded"
EXPORT_ONLY=0
KEEP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --export-only) EXPORT_ONLY=1 ;;
    --keep-build) KEEP_BUILD=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "error: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"

TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' Config/Local.xcconfig 2>/dev/null | tail -1)
[[ -n "$TEAM" ]] || die "set DEVELOPMENT_TEAM in Config/Local.xcconfig (copy Config/Local.xcconfig.example)"

# --- API key: check before touching anything, so a missing key fails before the build number changes. --------
KEYDIR=""
cleanup() { [[ -n "$KEYDIR" ]] && rm -rf "$KEYDIR"; return 0; }
trap cleanup EXIT
if [[ $EXPORT_ONLY == 0 ]]; then
  missing=()
  [[ -n "${ASC_KEY_ID:-}" ]] || missing+=(ASC_KEY_ID)
  [[ -n "${ASC_ISSUER_ID:-}" ]] || missing+=(ASC_ISSUER_ID)
  if (( ${#missing[@]} )); then
    die "App Store Connect API key not configured: ${missing[*]} unset.
       Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (or the Keychain item; see the header of $0),
       or run with --export-only to stop after a locally checked export."
  fi
  KEYDIR=$(mktemp -d)
  chmod 700 "$KEYDIR"
  KEYFILE="$KEYDIR/AuthKey_$ASC_KEY_ID.p8"
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    [[ -r "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH=$ASC_KEY_PATH is not a readable file"
    cp "$ASC_KEY_PATH" "$KEYFILE"
  elif b64=$(security find-generic-password -s deepwell.asc-api-key -a "$ASC_KEY_ID" -w 2>/dev/null); then
    printf '%s' "$b64" | base64 -D > "$KEYFILE"
  else
    die "no .p8 for key $ASC_KEY_ID: set ASC_KEY_PATH or add the Keychain item deepwell.asc-api-key (see header)"
  fi
  chmod 600 "$KEYFILE"
  grep -q 'BEGIN PRIVATE KEY' "$KEYFILE" || die "the API key for $ASC_KEY_ID does not look like a .p8 private key"
  AUTH_XCODEBUILD=(-authenticationKeyPath "$KEYFILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  AUTH_ALTOOL=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
  export API_PRIVATE_KEYS_DIR="$KEYDIR"
else
  AUTH_XCODEBUILD=()   # export-only: provisioning goes through the Apple ID signed in to Xcode
fi

# --- Build number -------------------------------------------------------------------------------------------
BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)
[[ -n "$BUILD" ]] || die "CURRENT_PROJECT_VERSION not found in project.yml"
if [[ $KEEP_BUILD == 0 ]]; then
  BUILD=$((BUILD + 1))
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*).*/\1\"$BUILD\"/" project.yml
elif [[ $EXPORT_ONLY == 0 ]] && grep -qx "$BUILD" "$UPLOADED" 2>/dev/null; then
  die "build $BUILD was already uploaded; run without --keep-build to bump it"
fi
VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)
echo "==> Deepwell $VERSION ($BUILD), team $TEAM"

ARCHIVE="$OUT/Deepwell.xcarchive"
EXPORT="$OUT/export"
mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT"

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Archiving (Release)"
# The archive is signed for development (export re-signs it for distribution), and development profiles need at
# least one registered Mac. `archive` does not register one, a Debug `build` does: see "One-time setup" in docs/install.md.
if ! xcodebuild -project Deepwell.xcodeproj -scheme Deepwell -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH_XCODEBUILD[@]+"${AUTH_XCODEBUILD[@]}"} \
  DEVELOPMENT_TEAM="$TEAM" archive -quiet; then
  die "archive failed. If it says \"Your team has no devices\", register this Mac once with:
       xcodebuild -project Deepwell.xcodeproj -scheme Deepwell -destination 'platform=macOS' \\
         -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
       then re-run with --keep-build."
fi

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> Exporting for App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates ${AUTH_XCODEBUILD[@]+"${AUTH_XCODEBUILD[@]}"} -quiet
PKG=$(ls "$EXPORT"/*.pkg 2>/dev/null | head -1)
[[ -n "$PKG" ]] || die "export produced no .pkg in $EXPORT"

echo "==> Checking the package locally"
pkgutil --check-signature "$PKG" | sed -n '1,4p'
CHECK="$OUT/pkg-check"
rm -rf "$CHECK"
pkgutil --expand-full "$PKG" "$CHECK" >/dev/null
APP=$(find "$CHECK" -maxdepth 3 -name Deepwell.app -type d | head -1)
[[ -n "$APP" ]] || die "no Deepwell.app inside $PKG"
codesign --verify --deep --strict "$APP"
for bundle in "$APP" "$APP"/Contents/PlugIns/*.appex; do
  ents=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null | plutil -convert json -o - - )
  team=$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  printf '    %-32s team=%s groups=%s sandbox=%s\n' "$(basename "$bundle")" "$team" \
    "$(printf '%s' "$ents" | plutil -extract com\\.apple\\.security\\.application-groups json -o - - 2>/dev/null)" \
    "$(printf '%s' "$ents" | plutil -extract com\\.apple\\.security\\.app-sandbox raw -o - - 2>/dev/null)"
  [[ "$team" == "$TEAM" ]] || die "$(basename "$bundle") is signed by team '$team', expected $TEAM"
  # TestFlight rejects any executable bundle without a profile (ITMS-90889); see PROVISIONING_PROFILE_REQUIRED.
  [[ -f "$bundle/Contents/embedded.provisionprofile" ]] || die "$(basename "$bundle") has no embedded.provisionprofile"
done
# The archive and the expanded package each contain a Deepwell.app that registers its Safari extension; drop them
# so Safari keeps listing only the installed copy.
rm -rf "$CHECK"
scripts/unregister-stale-builds.sh

if [[ $EXPORT_ONLY == 1 ]]; then
  echo "==> Done (export only): $PKG"
  echo "    Not validated or uploaded to App Store Connect. Set the ASC_* variables and run again to do both."
  exit 0
fi

echo "==> Validating with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos "${AUTH_ALTOOL[@]}"

echo "==> Uploading build $BUILD to TestFlight"
xcrun altool --upload-app -f "$PKG" -t macos "${AUTH_ALTOOL[@]}"
echo "$BUILD" >> "$UPLOADED"
echo "==> Uploaded Deepwell $VERSION ($BUILD). Processing takes a few minutes; it then appears in TestFlight."
echo "    Commit the bumped CURRENT_PROJECT_VERSION in project.yml."
