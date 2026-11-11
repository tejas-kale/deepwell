#!/usr/bin/env bash
# Unregister every Deepwell.app that Launch Services knows about except the installed one, so Safari lists one
# Deepwell extension and /Applications/Deepwell.app handles deepwell://. Builds (DerivedData, build/, archives,
# expanded packages) register themselves as they are produced; release.sh and install.sh run this afterwards.
# Only touches Launch Services and pluginkit registrations; no files are deleted.
#   scripts/unregister-stale-builds.sh [installed app, default /Applications/Deepwell.app]
set -euo pipefail

KEEP="${1:-/Applications/Deepwell.app}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

shopt -s nullglob
"$LSREGISTER" -dump 2>/dev/null \
  | sed -nE 's/^path: +(.*\/Deepwell\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u \
  | { grep -vxF "$KEEP" || true; } \
  | while read -r stale; do
      for ext in "$stale"/Contents/PlugIns/*.appex; do pluginkit -r "$ext" 2>/dev/null || true; done
      "$LSREGISTER" -u "$stale" 2>/dev/null || true
    done
shopt -u nullglob

if [[ -d "$KEEP" ]]; then
  "$LSREGISTER" -f "$KEEP"
  for ext in "$KEEP"/Contents/PlugIns/*.appex; do pluginkit -a "$ext" 2>/dev/null || true; done
fi
