#!/bin/bash
# Regression test: switchable lights start as the map says, and their
# trigger toggles them.
#
# No light entity reached cport, so every style of 32 and up drew "m":
# e1m1's START_OFF lights (styles 33..36) were lit from the start, and
# no trigger changed any of them. Each arm is against -nostyles, which
# holds every style at "m", at the same tick (48 keeps style 10's
# flicker at "m" too):
#
#   - outside t11's trigger, style 33's faces draw darker: off at start
#   - in the room style 32 lights, clear of t3's trigger, the same: on
#   - in t3's trigger there, darker: turned off
#
# The room sits behind a secret door t3 also opens, so it holds no face
# of styles 33..36 -- and a view from outside it sees none of style 32.
#
#   cport/tools/test-lightsw.sh build/cport-ls
#
# Needs an e1m1.qmp built by the current mkassets; SKIPs without one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-lightsw.sh <build-dir>}"
MIN="${MIN:-100}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() {  # <name> <args>: the frame to $OUT/sw-<name>.bmp
    rm -f "$OUT/sw-$1.bmp"
    TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "e1m1.qmp -lm -nostats -noai -nosound -ticks 48 $2" >/dev/null 2>&1
    cp "$OUT/BENCH.BMP" "$OUT/sw-$1.bmp" 2>/dev/null || { echo "FAIL: $1 wrote no frame" >&2; exit 1; }
}

diff_px() {
    python3 - "$OUT/sw-$1.bmp" "$OUT/sw-$2.bmp" <<'PY'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
print(sum(1 for x, y in zip(px(sys.argv[1]), px(sys.argv[2])) if x != y))
PY
}

T11OUT="-at 840 2420 -80 -yaw 90"
T3OUT="-at -60 2352 40 -yaw 0"
T3IN="-at 112 2352 40 -yaw 0"
run off   "$T11OUT"
run offn  "$T11OUT -nostyles"
run on    "$T3OUT"
run onn   "$T3OUT -nostyles"
run used  "$T3IN"
run usedn "$T3IN -nostyles"

fail=0
check() {  # <what> <pixels> <op> <bound>
    if [ "$2" "$3" "$4" ]; then echo "ok: $1 -- $2 pixels"; else echo "FAIL: $1 -- $2 pixels" >&2; fail=1; fi
}
check "a START_OFF light starts off"   "$(diff_px off offn)"   -ge "$MIN"
check "an unflagged light starts on"   "$(diff_px on onn)"     -eq 0
check "its trigger turns it off"       "$(diff_px used usedn)" -ge "$MIN"

# No e1m1 view shows these: two lights sharing a style, where the one used
# last must win, and a style nothing sets, at id's 256 rather than 'm'.
for t in ent_lights_selftest ls_selftest; do
    if grep -q "^$t 1" "$OUT/CSTEP.TXT" 2>/dev/null; then echo "ok: $t"
    else echo "FAIL: $(grep "^$t" "$OUT/CSTEP.TXT" 2>/dev/null || echo "$t missing")" >&2; fail=1; fi
done
exit $fail
