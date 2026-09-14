#!/bin/bash
# Regression test: a flickering light style keeps a surface per value.
#
# The surface cache keyed a face on the sum of its styles' epochs and
# held one surface a face, so every change of style 10's m/a flicker
# rebuilt all 39 (0, 10) faces in view at the e1m1 spawn: 1,184 builds
# between tick 303 and 603 of a still camera, 8.4 ms a frame.
#
# Keyed on the values, both surfaces stay and the flicker hits: the
# builds between the two ticks must stay under MAX, nothing may be
# evicted, and at both ticks -- style 10 is 'm' there -- the frame must
# match -nostyles, so a hit on the wrong value's surface shows.
#
#   cport/tools/test-scvariants.sh build/cport
#
# Needs an e1m1.qmp; SKIPs without one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-scvariants.sh <build-dir>}"
MAX="${MAX:-20}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() {  # <name> <args>: the frame to $OUT/scv-<name>.bmp, bench.txt beside it
    rm -f "$OUT/scv-$1.bmp" "$OUT/scv-$1.txt"
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "e1m1.qmp -lm -nostats -noai -nosound -nodlight -bench 4000 $2" >/dev/null 2>&1
    cp "$OUT/BENCH.BMP" "$OUT/scv-$1.bmp" 2>/dev/null &&
    cp "$OUT/BENCH.TXT" "$OUT/scv-$1.txt" 2>/dev/null || { echo "FAIL: $1 wrote no frame" >&2; exit 1; }
}

val() { tr -d '\r' < "$OUT/scv-$1.txt" | grep "^$2 " | cut -d' ' -f2; }

run t303  "-ticks 303"
run t603  "-ticks 603"
run t303n "-ticks 303 -nostyles"
run t603n "-ticks 603 -nostyles"

fail=0
b0="$(val t303 sc_builds)"; b1="$(val t603 sc_builds)"; ev="$(val t603 sc_evict)"
if [[ -z "$b0" || -z "$b1" || -z "$ev" ]]; then echo "FAIL: no sc_builds/sc_evict in bench.txt" >&2; exit 1; fi
d=$(( b1 - b0 ))
if (( d <= MAX )); then echo "ok: $d builds from tick 303 to 603"; else echo "FAIL: $d builds from tick 303 to 603" >&2; fail=1; fi
if (( ev == 0 )); then echo "ok: nothing evicted"; else echo "FAIL: $ev evicted" >&2; fail=1; fi
# sc_selftest checks the chain itself; it read -12 for as long as its
# page-edge row went to segment 0, and nothing after that check ran
for t in sc_selftest ls_selftest; do
    if grep -q "^$t 1" "$OUT/CSTEP.TXT" 2>/dev/null; then echo "ok: $t 1"
    else echo "FAIL: $(grep -h "^$t" "$OUT/CSTEP.TXT" 2>/dev/null || echo "no $t")" >&2; fail=1; fi
done
for t in 303 603; do
    if cmp -s "$OUT/scv-t$t.bmp" "$OUT/scv-t${t}n.bmp"; then echo "ok: tick $t matches -nostyles"
    else echo "FAIL: tick $t differs from -nostyles" >&2; fail=1; fi
done

# (480,-19,29) yaw 295 wants 409 blocks. At SC_NBLK 384 the records ran
# out, a new value got no block of its own and took the face's other
# one: 800 builds between the ticks, 41.3 ms a frame against 37.4.
SPOT="-at 480 -19 29 -yaw 295"
run s303 "$SPOT -ticks 303"
run s603 "$SPOT -ticks 603"
b0="$(val s303 sc_builds)"; b1="$(val s603 sc_builds)"; nf="$(val s603 sc_nofresh)"
if [[ -z "$b0" || -z "$b1" || -z "$nf" ]]; then echo "FAIL: no sc_builds/sc_nofresh at the spot" >&2; exit 1; fi
d=$(( b1 - b0 ))
if (( d <= MAX )); then echo "ok: spot, $d builds from tick 303 to 603"; else echo "FAIL: spot, $d builds from tick 303 to 603" >&2; fail=1; fi
if (( nf == 0 )); then echo "ok: spot, no key refused a block"; else echo "FAIL: spot, $nf keys refused a block" >&2; fail=1; fi
exit $fail
