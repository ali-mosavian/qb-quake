#!/bin/bash
# Regression test: a light style on a face's second lightmap animates.
#
# sb_build read each face's style-0 plane only and the cache keyed on
# style 0 alone, so e1m1's faces lit (0, 10) -- world.qc's fluorescent
# flicker -- drew steady; and the player's light, reaching face 949 here,
# replaced the style key instead of adding to it. Style 10 is 'm' at
# tick 48 and 'a' at 57, so against -nostyles the frame must match at 48
# and differ at 57. ls_test is the selftest: 1, or the failing case.
#
#   tools/test-styles.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-styles.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

frame() {
    rm -f "$OUT/BENCH.BMP"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-240}" \
        QFLAGS="-lm -nostats -noai -nosound -bench 999 -ticks $1 -at 398 2130 -93 -yaw 180 ${2:-}" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }
    md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1
}

fail=0
[[ "$(frame 48)" == "$(frame 48 -nostyles)" ]] || { echo "FAIL: style 10 at 'm' draws unlike held" >&2; fail=1; }
t=$(tr -d '\r' < "$OUT/BENCH.TXT" | awk '$1 == "ls_test" {print $2}')
[[ "$t" == "1" ]] || { echo "FAIL: ls_test $t" >&2; fail=1; }
[[ "$(frame 57)" != "$(frame 57 -nostyles)" ]] || { echo "FAIL: style 10 at 'a' draws as held" >&2; fail=1; }
[[ $fail == 0 ]] && echo "ok: style 10 flickers"
exit $fail
