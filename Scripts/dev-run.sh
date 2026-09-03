#!/bin/zsh
# Dev helper: relaunch the built app on a given tab with the bubble auto-shown and save a PNG of it.
#   Scripts/dev-run.sh [clipboard|system|network|settings] [snapshot.png] [delay-seconds] [panel-height]
set -euo pipefail
cd "$(dirname "$0")/.."
TAB="${1:-clipboard}"
OUT="${2:-$PWD/build/snap-$TAB.png}"
DELAY="${3:-4}"
HEIGHT="${4:-640}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
pkill -x ATFM 2>/dev/null || true
sleep 0.5
rm -f "$OUT"
(ATFM_TAB="$TAB" ATFM_AUTO_SHOW=1 ATFM_SNAPSHOT="$OUT" ATFM_SNAPSHOT_DELAY="$DELAY" ATFM_PANEL_HEIGHT="$HEIGHT" \
  ./build/ATFM.app/Contents/MacOS/ATFM > build/app.log 2>&1 &)
sleep $((DELAY + 2))
[[ -f "$OUT" ]] && echo "snapshot: $OUT" || { echo "snapshot not written"; tail -5 build/app.log; }
