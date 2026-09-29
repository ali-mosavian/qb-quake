#!/bin/bash
# Regression test: the player's light glows where the player is.
#
# A lit face was keyed -1 whenever the light reached it, so the second
# frame was a cache hit and the glow stayed where it was first built.
# Falling to the dm3ish floor from the spawn left 3,247 pixels unlike a
# run started on that floor.
#
#   tools/test-dlight.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-dlight.sh <build-dir>}" && pwd)"

frame() {
    rm -f "$OUT/BENCH.BMP"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-240}" \
        QFLAGS="-lm -nosound -nostats -noai -bench 999 -ticks 120 $1" \
        "$ROOT/tools/dosbox.sh" run >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }
    md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1
}

fell=$(frame "")
landed=$(frame "-at 232 -16 184.0313")
if [[ "$fell" != "$landed" ]]; then
    echo "FAIL: after the fall $fell, started landed $landed -- the glow did not follow the light" >&2
    exit 1
fi
echo "ok: the glow follows the light"
