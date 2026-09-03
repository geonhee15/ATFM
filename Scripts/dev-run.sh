#!/bin/zsh
# Dev helper: relaunch the built app with the bubble auto-shown and save a PNG of it.
#   Scripts/dev-run.sh [snapshot.png]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/build/snapshot.png}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
pkill -x ATFM 2>/dev/null || true
sleep 0.5
rm -f "$OUT"
ATFM_AUTO_SHOW=1 ATFM_SNAPSHOT="$OUT" open -n build/ATFM.app
sleep 3.5
[[ -f "$OUT" ]] && echo "snapshot: $OUT" || echo "snapshot not written (is the app running?)"
