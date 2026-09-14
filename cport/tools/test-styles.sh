#!/bin/bash
# Regression test: a light style on a face's second lightmap animates.
#
# mkassets shipped only each face's style-0 plane, so the 137 e1m1 faces
# lit (0, 10) -- style 10 being world.qc's fluorescent flicker -- drew
# steady. The camera faces face 949, lit (0, 10) with the most light in
# its style-10 plane. Style 10 is 'm' at step 7 (tick 48), as it starts,
# and 'a' at step 9 (tick 57). So against -nostyles at the same tick the
# frame must match at 48 and differ at 57; the same tick on both arms
# keeps the textures' own 10 Hz animation out of it.
#
#   cport/tools/test-styles.sh build/cport-ls
#
# Needs an e1m1.qmp built by the current mkassets; SKIPs without one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-styles.sh <build-dir>}"
MIN="${MIN:-100}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() {  # <name> <args>: the frame to $OUT/ls-<name>.bmp
    rm -f "$OUT/ls-$1.bmp"
    TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "e1m1.qmp -lm -nostats -noai -nosound -at 398 2130 -93 -yaw 180 $2" >/dev/null 2>&1
    cp "$OUT/BENCH.BMP" "$OUT/ls-$1.bmp" 2>/dev/null || { echo "FAIL: $1 wrote no frame" >&2; exit 1; }
}

diff_px() {
    python3 - "$OUT/ls-$1.bmp" "$OUT/ls-$2.bmp" <<'PY'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
print(sum(1 for x, y in zip(px(sys.argv[1]), px(sys.argv[2])) if x != y))
PY
}

run t48  "-ticks 48"
run t48n "-ticks 48 -nostyles"
run t57  "-ticks 57"
run t57n "-ticks 57 -nostyles"
run t63  "-ticks 63"
run t63n "-ticks 63 -nostyles"

fail=0
check() {  # <what> <pixels> <op> <bound>
    if [ "$2" "$3" "$4" ]; then echo "ok: $1 -- $2 pixels"; else echo "FAIL: $1 -- $2 pixels" >&2; fail=1; fi
}
check "style 10 at its start value draws as held" "$(diff_px t48 t48n)" -eq 0
check "style 10 dark draws dark"                  "$(diff_px t57 t57n)" -ge "$MIN"
check "style 10 back at 'm' draws as held"        "$(diff_px t63 t63n)" -eq 0
exit $fail
