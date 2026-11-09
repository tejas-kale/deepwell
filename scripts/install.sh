#!/usr/bin/env bash
# Build a signed Release of Deepwell and install it to /Applications.
#   scripts/install.sh          build, quit the running Deepwell, replace /Applications/Deepwell.app, launch it
#   scripts/install.sh --zip    also write build/release/Deepwell-<version>.zip (to copy to another Mac you own)
# Needs: xcodegen, Xcode signed in to your Apple ID, DEVELOPMENT_TEAM in Config/Local.xcconfig.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Deepwell.app"
DEST=/Applications/Deepwell.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
# Make the installed copy the one that handles deepwell:// and provides the Safari/Share extensions.
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/DeepwellSafariExtension.appex" 2>/dev/null || true
pluginkit -a "$DEST/Contents/PlugIns/DeepwellShareExtension.appex" 2>/dev/null || true

open "$DEST"
echo "==> Done. Enable the extension in Safari > Settings > Extensions if it is not already on."
