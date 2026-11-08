#!/bin/sh
# Usage: scripts/make-app-icon.sh path/to/icon-1024.png
# Resizes one 1024x1024 PNG into every size the macOS AppIcon set needs and points the set at them.
set -eu
src="$1"
dest="$(cd "$(dirname "$0")/.." && pwd)/Apps/Deepwell/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  sips -s format png -z "$size" "$size" "$src" --out "$dest/icon_$size.png" >/dev/null
done
entry() { printf '    { "idiom" : "mac", "scale" : "%s", "size" : "%sx%s", "filename" : "icon_%s.png" }' "$1" "$2" "$2" "$3"; }
{
  echo '{'
  echo '  "images" : ['
  entry 1x 16 16;   echo ','
  entry 2x 16 32;   echo ','
  entry 1x 32 32;   echo ','
  entry 2x 32 64;   echo ','
  entry 1x 128 128; echo ','
  entry 2x 128 256; echo ','
  entry 1x 256 256; echo ','
  entry 2x 256 512; echo ','
  entry 1x 512 512; echo ','
  entry 2x 512 1024; echo
  echo '  ],'
  echo '  "info" : { "author" : "xcode", "version" : 1 }'
  echo '}'
} > "$dest/Contents.json"
echo "Wrote icons to $dest. Rebuild the app to see the new icon."
