#!/bin/bash
# Regression test: a moved brush entity culls against where it IS.
#
# The face cull and the brush's node walk used the planes where the
# compiler put the brush. From inside e1m1's first doorway, with the door
# slid 94 units into its pocket, the culled frame drew the door's face
# over the recess: 1,113 pixels unlike the -nocull frame.
#
#   tools/test-brushcull.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-brushcull.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

frame() {
    rm -f "$OUT/BENCH.BMP"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-240}" \
        QFLAGS="-nosound -nostats -noai -bench 999 -ticks 120 -at 250 560 40 -yaw 90 $1" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }
    md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1
}

culled=$(frame "")
all=$(frame -nocull)
if [[ "$culled" != "$all" ]]; then
    echo "FAIL: culled frame $culled differs from -nocull $all -- a moved brush culls at its compiled place" >&2
    exit 1
fi
echo "ok: the open door culls where it stands"
