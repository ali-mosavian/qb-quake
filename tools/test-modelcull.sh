#!/bin/bash
# Regression test: alias models cull their BACK faces.
#
# d_alias.c kept triangles whose screen area was negative, which is id's
# d_xdenom sign inverted: every model drew its far side, hollow, and the
# knight 116 units away differed from an uncull build by 319 pixels
# where the right winding differs by 68 (silhouette ties). The frame
# below was checked against that uncull build before it was pinned.
#
#   tools/test-modelcull.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-modelcull.sh <build-dir>}" && pwd)"
WANT=15910d4ec5eb0236a1fd64a1f97c74f1

rm -f "$OUT/BENCH.BMP"
VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-180}" \
    QFLAGS="-nosound -noai -nostats -at 364 -48 48 -yaw 0 -bench 8 -ticks 2" \
    "$ROOT/tools/dosbox.sh" run >/dev/null 2>&1 || true
[[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }

got=$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1)
if [[ "$got" != "$WANT" ]]; then
    echo "FAIL: knight frame is $got, want $WANT -- model winding or projection changed" >&2
    exit 1
fi
echo "ok: the knight draws its front faces"
