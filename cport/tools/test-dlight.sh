#!/bin/bash
# Regression test: the dynamic lights draw, animate, and wash out.
#
# A lit face used to cache under a constant stag of -1, so its second
# lit frame was a hit: the glow froze at its first build. So the frame
# at the quad, whose EF_DIMLIGHT flickers every tick, must move between
# ticks 32 and 33 -- and must not without the lights, or the
# difference is something else animating. And a light that has died
# must leave the frame -nodlight draws: the shotgun's first muzzle
# flash lives 0.1 s, the next shot is at 0.5 s.
#
#   cport/tools/test-dlight.sh build/cport-dl
#
# SKIPs when e1m1.qmp is not staged.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-dlight.sh <build-dir>}"
MIN="${MIN:-100}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() {  # <name> <args>: the frame to $OUT/dl-<name>.bmp
    rm -f "$OUT/dl-$1.bmp"
    TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "e1m1.qmp -lm -nostats -noai -nosound $2" >/dev/null 2>&1
    cp "$OUT/BENCH.BMP" "$OUT/dl-$1.bmp" 2>/dev/null || { echo "FAIL: $1 wrote no frame" >&2; exit 1; }
}

diff_px() {
    python3 - "$OUT/dl-$1.bmp" "$OUT/dl-$2.bmp" <<'PY'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
print(sum(1 for x, y in zip(px(sys.argv[1]), px(sys.argv[2])) if x != y))
PY
}

QUAD="-at 544 2480 -88 -yaw 90"
MEGA="-at 944 900 -240 -yaw 270 -fire"
run q32  "$QUAD -ticks 32"
run q33  "$QUAD -ticks 33"
run q32n "$QUAD -ticks 32 -nodlight"
run q33n "$QUAD -ticks 33 -nodlight"
run f3   "$MEGA -ticks 3"
run f3n  "$MEGA -ticks 3 -nodlight"
run f20  "$MEGA -ticks 20"
run f20n "$MEGA -ticks 20 -nodlight"

fail=0
check() {  # <what> <pixels> <op> <bound>
    if [ "$2" "$3" "$4" ]; then echo "ok: $1 -- $2 pixels"; else echo "FAIL: $1 -- $2 pixels" >&2; fail=1; fi
}
check "the quad's light draws"             "$(diff_px q32 q32n)"   -ge "$MIN"
check "nothing else moves over the tick"   "$(diff_px q32n q33n)"  -eq 0
check "the quad's light flickers"          "$(diff_px q32 q33)"    -ge "$MIN"
check "the muzzle flash draws"             "$(diff_px f3 f3n)"     -ge "$MIN"
check "the flash's glow is gone once dead" "$(diff_px f20 f20n)"   -eq 0
exit $fail
