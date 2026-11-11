#!/usr/bin/env bash
# Archive Deepwell for the Mac (app + Safari and Share extensions) or for iPhone/iPad (DeepwellMobile), export it
# for App Store Connect, validate it and upload it to TestFlight. See docs/install.md and docs/ios.md.
#
#   scripts/release.sh                 bump CURRENT_PROJECT_VERSION, archive, export, validate, upload (Mac)
#   scripts/release.sh --platform ios  the same for the iOS app (one .ipa, iPhone and iPad)
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
# numbers are recorded in build/release/uploaded (Mac) and build/release/uploaded-ios, and --keep-build refuses
# to upload the same number twice for a platform. Both platforms share CURRENT_PROJECT_VERSION.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

OUT=build/release
EXPORT_ONLY=0
KEEP_BUILD=0
PLATFORM=mac
while (( $# )); do
  case "$1" in
    --export-only) EXPORT_ONLY=1 ;;
    --keep-build) KEEP_BUILD=1 ;;
    --platform) shift; PLATFORM="${1:-}" ;;
    --platform=*) PLATFORM="${1#--platform=}" ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
case "$PLATFORM" in
  mac) SCHEME=Deepwell; DEST='generic/platform=macOS'; ALTOOL_TYPE=macos
       ARCHIVE="$OUT/Deepwell.xcarchive"; EXPORT="$OUT/export"; UPLOADED="$OUT/uploaded" ;;
  ios) SCHEME=DeepwellMobile; DEST='generic/platform=iOS'; ALTOOL_TYPE=ios
       ARCHIVE="$OUT/ios/DeepwellMobile.xcarchive"; EXPORT="$OUT/ios/export"; UPLOADED="$OUT/uploaded-ios" ;;
  *) die "--platform must be mac or ios (got '$PLATFORM')" ;;
esac
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
  AUTH_ALTOOL=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
  export API_PRIVATE_KEYS_DIR="$KEYDIR"
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
echo "==> Deepwell $VERSION ($BUILD) for $PLATFORM, team $TEAM"

mkdir -p "$(dirname "$ARCHIVE")"
rm -rf "$ARCHIVE" "$EXPORT"

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Archiving (Release)"
# The archive is signed for development (export re-signs it for distribution), and development profiles need at
# least one registered Mac. `archive` does not register one, a Debug `build` does: see "One-time setup" in docs/install.md.
# The iOS development profile needs a registered iPhone or iPad (see docs/ios.md).
if ! xcodebuild -project Deepwell.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "$DEST" -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" archive -quiet; then
  [[ $PLATFORM == ios ]] && die "archive failed. If it says \"Your team has no devices\", connect your iPhone or iPad,
       open Deepwell.xcodeproj in Xcode, pick the device as the DeepwellMobile run destination and build once
       (Xcode registers it), then re-run with --keep-build."
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
# Signing goes through the Apple ID signed in to Xcode (Account Holder), which may use Apple's cloud-managed
# distribution certificates. The API key is deliberately not passed here: an App Manager key may not use cloud
# signing ("Cloud signing permission error"). The key is used only by altool below.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates -quiet \
  || die "export failed. Check Xcode > Settings > Accounts is signed in to the $TEAM Account Holder, then re-run with --keep-build."
if [[ $PLATFORM == ios ]]; then
  PKG=$(ls "$EXPORT"/*.ipa 2>/dev/null | head -1)
  [[ -n "$PKG" ]] || die "export produced no .ipa in $EXPORT"
  echo "==> Checking the .ipa locally"
  CHECK="$OUT/ios/ipa-check"
  rm -rf "$CHECK"
  ditto -x -k "$PKG" "$CHECK"
  APP=$(find "$CHECK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)
  [[ -n "$APP" ]] || die "no .app inside $PKG"
  codesign --verify --deep --strict "$APP"
  ents=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - )
  team=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  groups=$(printf '%s' "$ents" | plutil -extract com\\.apple\\.security\\.application-groups json -o - - 2>/dev/null)
  icloud=$(printf '%s' "$ents" | plutil -extract com\\.apple\\.developer\\.icloud-container-identifiers json -o - - 2>/dev/null)
  env=$(printf '%s' "$ents" | plutil -extract com\\.apple\\.developer\\.icloud-container-environment raw -o - - 2>/dev/null || true)
  printf '    %-32s team=%s groups=%s icloud=%s env=%s\n' "$(basename "$APP")" "$team" "$groups" "$icloud" "$env"
  [[ "$team" == "$TEAM" ]] || die "$(basename "$APP") is signed by team '$team', expected $TEAM"
  [[ "$groups" == *'group.com.tejaskale.deepwell'* ]] || die "$(basename "$APP") lacks the app group group.com.tejaskale.deepwell"
  [[ "$icloud" == *'iCloud.com.tejaskale.deepwell'* ]] || die "$(basename "$APP") lacks the iCloud container"
  [[ -f "$APP/embedded.mobileprovision" ]] || die "$(basename "$APP") has no embedded.mobileprovision"
  rm -rf "$CHECK"
else
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
fi

if [[ $EXPORT_ONLY == 1 ]]; then
  echo "==> Done (export only): $PKG"
  echo "    Not validated or uploaded to App Store Connect. Set the ASC_* variables and run again to do both."
  exit 0
fi

echo "==> Validating with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t "$ALTOOL_TYPE" "${AUTH_ALTOOL[@]}"

echo "==> Uploading build $BUILD to TestFlight"
xcrun altool --upload-app -f "$PKG" -t "$ALTOOL_TYPE" "${AUTH_ALTOOL[@]}"
echo "$BUILD" >> "$UPLOADED"
echo "==> Uploaded Deepwell $VERSION ($BUILD) for $PLATFORM. Processing takes a few minutes; it then appears in TestFlight."
echo "    Commit the bumped CURRENT_PROJECT_VERSION in project.yml."
