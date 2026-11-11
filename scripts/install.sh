#!/usr/bin/env bash
# FALLBACK ONLY. Deepwell normally installs from TestFlight (scripts/release.sh, docs/install.md). Use this to try a
# local change on this Mac without uploading: it builds Release, signed for development with the paid team, and
# replaces /Applications/Deepwell.app, including a TestFlight install. Same bundle id, team and app group, so the
# capture inbox is shared; whether settings and the library bookmark survive the switch between TestFlight and local
# signing is not verified (worst case: pick the library folder again). Reinstall from TestFlight to go back.
#   scripts/install.sh          build, quit the running Deepwell, replace /Applications/Deepwell.app, launch it
#   scripts/install.sh --zip    also write build/local/Deepwell-<version>.zip (runs only on Macs registered to the team)
# Needs: xcodegen, Xcode signed in to the team, DEVELOPMENT_TEAM in Config/Local.xcconfig, this Mac registered
# (see "One-time setup" in docs/install.md).
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED=build/local
APP="$DERIVED/Build/Products/Release/Deepwell.app"
DEST=/Applications/Deepwell.app

echo "==> Generating project"
xcodegen generate --quiet

echo "==> Building Release"
xcodebuild -project Deepwell.xcodeproj -scheme Deepwell -configuration Release \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build -quiet

codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="$DERIVED/Deepwell-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Wrote $ZIP"
fi

if pgrep -xq Deepwell; then
  echo "==> Quitting the running Deepwell"
  osascript -e 'tell application id "com.tejaskale.deepwell" to quit' || true
  for _ in {1..20}; do pgrep -xq Deepwell || break; sleep 0.5; done
fi

echo "==> Installing $VERSION to $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
# Make the installed copy the only one that handles deepwell:// and provides the Safari/Share extensions.
scripts/unregister-stale-builds.sh "$DEST"

open "$DEST"
echo "==> Done. Enable the extension in Safari > Settings > Extensions if it is not already on."
