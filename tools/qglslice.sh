#!/usr/bin/env bash
# qglslice.sh -- the same frame through mgl and through qgl.
#
# One binary, two runs, the tick pinned so the camera stops in the same
# place and anim_time lands on the same value.
#
# THE FLAGS ARE NOT DECORATION and each one cost a wrong measurement:
#
#   -polytp  the qgl branch sits inside the one-call-per-polygon path.
#            Without it the fan path runs, the branch is never reached,
#            and the run reports qgl_faces 0.
#   -noz     the slice leaves depth to mgl, so it stands aside when a
#            depth buffer exists. Without this it stands aside always.
#   -nostats the overlay prints live fps and frame time, so two runs of
#            ONE build differ in the digits.
#   no -lm   the surface cache draws a different picture every run --
#            AGENTS.md's open bug, and its own bisection records "-lm
#            off: byte-identical x3". With lightmaps on, this harness
#            measures that and calls it a qgl difference. It did: 581
#            pixels, from a build where qgl drew nothing at all.
#
# So the first thing it does is run mgl TWICE and require the two to be
# identical. A comparison whose baseline is not repeatable cannot say
# anything about the arm under test, and that check is cheap next to
# believing a number that was noise.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VBD_OUT="${VBD_OUT:-$ROOT/build/vbd}"
export VBD_OUT
TICKS="${TICKS:-120}"
FRAMES="${FRAMES:-400}"
BASE="-nostats -polytp -noz -bench $FRAMES -ticks $TICKS"

run () {                        # run <tag> <extra flags>
    rm -f "$VBD_OUT/BENCH.BMP" "$VBD_OUT/bench.txt"
    QFLAGS="$BASE $2" TIMEOUT=600 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    [[ -f "$VBD_OUT/BENCH.BMP" ]] || { echo "$1: PRODUCED NOTHING"; return 1; }
    cp "$VBD_OUT/BENCH.BMP" "$VBD_OUT/slice-$1.bmp"
    cp "$VBD_OUT/bench.txt" "$VBD_OUT/slice-$1.txt"
    echo "  $1: $(tr -d '\r' < "$VBD_OUT/bench.txt" |
        awk '/^(frames|polys|tris|ticks|qgl_faces) /{printf "%s=%s ",$1,$2}')"
}

field () { tr -d '\r' < "$VBD_OUT/slice-$1.txt" | awk -v k="$2" '$1==k{print $2}'; }

echo "== baseline repeatability"
run mgl  "" || exit 1
run mgl2 "" || exit 1
floor=$(python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/slice-mgl.bmp" \
        "$VBD_OUT/slice-mgl2.bmp" | awk '/DIFFER/{print $2} /IDENTICAL/{print 0}')
echo "  noise floor: ${floor:-?} pixels"
# ZERO, and it has to be zero. An earlier version allowed 64 pixels,
# which was the wrong move twice over: it was a tolerance invented to
# get past a measurement problem rather than to describe one, and at
# that width it would hide a real slice error as readily as the noise
# it was aimed at.
#
# The noise it was aimed at was real -- 1 to 7 pixels, moving with host
# load, because the two runs render different FRAME counts to reach the
# same tick (48 and 52 observed) and the last frame lands on a different
# liquid phase. Tick-bound, not frame-bound. But with -lm off it has
# also been observed at exactly 0, so the frame CAN be pinned and the
# answer is to pin it, not to allow it.
if [[ "${floor:-9999}" -ne 0 ]]; then
    echo "FAIL  the mgl arm is not repeatable: $floor pixels"
    exit 1
fi

echo "== qgl"
run qgl "-qgl" || exit 1

echo "== picture"
python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/slice-mgl.bmp" "$VBD_OUT/slice-qgl.bmp"

echo "== memory"
for a in mgl qgl; do
    printf '  %-4s %s\n' "$a" "$(tr -d '\r' < "$VBD_OUT/slice-$a.txt" |
        awk '/^(free|mem) /{printf "%s ", $0}')"
done

mp=$(field mgl polys); qp=$(field qgl polys)
[[ "$mp" == "$qp" ]] || { echo "FAIL  polys differ: mgl $mp, qgl $qp"; exit 1; }

# THE ONE WAY THIS PASSES FOR THE WRONG REASON. A slice that adopted
# nothing and fell through to mgl for every face draws a perfect
# picture; only the counter tells that from a slice that worked.
mf=$(field mgl qgl_faces); qf=$(field qgl qgl_faces)
[[ "${mf:-0}" == "0" ]] || { echo "FAIL  the mgl arm drew $mf faces through qgl"; exit 1; }
[[ "${qf:-0}" -gt 0 ]] || { echo "FAIL  the qgl arm drew NO faces through qgl"; exit 1; }
echo "== polys agree: $mp; qgl drew $qf of them"
