#!/bin/bash
# Regression test: -DQR_PROF=0 / -DQR_LOG=0 must remove instrumentation
# and NOTHING else.
#
# The defect this exists for is one wrong #if: a line that also did real
# work swept into a gate. It costs nothing at the build -- both arms
# compile, link and run -- and the only witness is the frame, so that is
# what this compares. It also asserts the gates actually fired, or an
# arm built without the defines would pass by drawing the same picture
# for the wrong reason.
#
#   cport/tools/test-cdefs.sh <build-with> <build-without>
#
# Both dirs must already hold a QCPORT.EXE and the map, built with their
# own CDEFS -- see cport/src/qrcfg.h on why each arm needs its own
# directory.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ON="${1:?usage: test-cdefs.sh <build-with> <build-without>}"
OFF="${2:?usage: test-cdefs.sh <build-with> <build-without>}"
MAP="${MAP:-dm3ish.qmp}"
ARGS="$MAP -lm -nostats -noai -ticks 200"

run() {
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$1" "$ARGS" >/dev/null 2>&1
    [[ -s "$1/BENCH.BMP" ]] || { echo MISSING; return; }
    md5 -q "$1/BENCH.BMP" 2>/dev/null || md5sum "$1/BENCH.BMP" | cut -d' ' -f1
}
field() { tr -d '\r' < "$1/BENCH.TXT" 2>/dev/null | awk -v k="$2" '$1==k{print $2}'; }

# frames and polys are NOT compared, deliberately. -ticks bounds the
# simulation, not the frame count, so the faster arm renders one or two
# more frames over the same 200 ticks and its poly TOTAL is larger --
# 128 frames against 127 here, which is the whole point of the change
# and not a fault in it. The camera ends in the same place either way,
# so the picture is the assertion.
a=$(run "$ON");  fa=$(field "$ON" frames);  pa=$(field "$ON" polys)
b=$(run "$OFF"); fb=$(field "$OFF" frames); pb=$(field "$OFF" polys)

bad=0
say() { echo "$1"; bad=1; }

[[ "$a" == MISSING || "$b" == MISSING ]] && say "FAIL: an arm rendered nothing ($a / $b)"
[[ "$a" == "$b" ]] || say "FAIL: the picture moved -- $a with the instrumentation, $b without"

# The gates fired. Without this the whole test passes on two arms built
# identically, which is the one way it could quietly stop testing.
[[ -n "$(field "$ON" pt_frame_mean)" ]] || say "FAIL: the QR_PROF arm wrote no pt_ profile"
[[ -z "$(field "$OFF" pt_frame_mean)" ]] || say "FAIL: the QR_PROF=0 arm still wrote pt_frame_mean"
[[ -s "$ON/cstep.txt" ]]  || say "FAIL: the QR_LOG arm wrote no cstep.txt"
[[ -f "$OFF/cstep.txt" ]] && say "FAIL: the QR_LOG=0 arm still wrote cstep.txt"

if [[ $bad == 0 ]]; then
    echo "ok: $MAP renders $a either way -- $fa/$fb frames, $pa/$pb polys, gates fired"
    exit 0
fi
exit 1
