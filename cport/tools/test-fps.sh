#!/bin/bash
# Regression test: nothing in a captured frame may depend on how fast
# the build is.
#
# scr_draw_hud drew "fps: [N]" right-aligned in the top bar whatever
# the flags said, so BENCH.BMP carried the frame rate and no two arms
# of an A/B could come out identical -- 19 pixels at x 145..151 moving
# between palette 15 and 16, four digits of a 4x5 font, which reads
# exactly like a rasteriser difference and was chased as one for a
# session. The fps draws again now, because a person watching wants
# it; it is gated on the run being tick-bounded, which every A/B
# recipe is and no interactive run is.
#
# Two arms of ONE binary that differ only in speed: the leaf cache is
# worth about 8 ms a frame on e1m1, so the fps digits differ. The
# frames must not.
#
#   cport/tools/test-fps.sh build/cport-e1m1 [map]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-fps.sh <build-dir> [map]}"
MAP="${2:-e1m1.qmp}"

field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }

arm() {   # arm <flags> -> "<md5> <fps_mean>"
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "$MAP -noai -ticks 120 $1" >/dev/null 2>&1
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "MISSING 0"; return; }
    echo "$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1)" \
         "$(field fps_mean)"
}

read -r slow_md5 slow_fps <<< "$(arm '-nolcache')"
read -r fast_md5 fast_fps <<< "$(arm '')"

fail=0
if [[ "$slow_md5" == MISSING || "$fast_md5" == MISSING ]]; then
    echo "FAIL: no frame written -- the run did not render" >&2
    fail=1
elif [[ "$slow_md5" != "$fast_md5" ]]; then
    echo "FAIL: the frame depends on the frame rate ($slow_fps fps and $fast_fps drew different pictures)" >&2
    fail=1
else
    echo "ok: one picture at $slow_fps fps and at $fast_fps"
fi

# Or it is vacuous: two arms of equal speed prove nothing about a
# readout of the speed. Note this runs WITHOUT -nostats, so the arms
# also have to agree with the overlay at its default.
if [[ -z "$slow_fps" || -z "$fast_fps" ]]; then
    echo "FAIL: no fps_mean in BENCH.TXT -- the instrument is gone" >&2
    fail=1
elif [[ "$slow_fps" == "$fast_fps" ]]; then
    echo "FAIL: both arms ran at $slow_fps fps -- the test cannot see an fps in the frame" >&2
    fail=1
fi

exit $fail
