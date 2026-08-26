#!/usr/bin/env bash
# check.sh -- build, bench, and compare against the stored reference.
#
# One command per change, so a phase is not "done" until the picture is
# identical, the frame time has not moved and the tracer agrees the bytes
# actually left. Run tools/check.sh --save once on a known-good build to
# lay down the reference.
#
# -nostats is not optional. The overlay prints live fps and frame time, so
# two runs of the SAME build differ by ~28 pixels in the digits, and a
# harness that reports a difference every time reports nothing at all.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF:-$ROOT/tools/ref/bench.bmp}"
PASSES="${PASSES:-2}"
BENCH="${BENCH:--lm -nostats -bench 30}"

if [[ "${1:-}" == "--save" ]]; then
    mkdir -p "$(dirname "$REF")"
    python3 "$ROOT/tools/imgdiff.py" --save "$REF" "$ROOT/build/vbd/BENCH.BMP"
    exit $?
fi

"$ROOT/tools/dosbox.sh" build > /tmp/check-build.log 2>&1 || {
    echo "BUILD FAILED"; tail -20 /tmp/check-build.log; exit 1; }
grep -qi "Severe.*[1-9]" /tmp/check-build.log && {
    echo "COMPILE ERRORS"; grep -i severe /tmp/check-build.log; exit 1; }

ticks=()
for ((i=0; i<PASSES; i++)); do
    QFLAGS="$BENCH" TIMEOUT=600 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    t=$(tr -d '\r' < "$ROOT/build/vbd/bench.txt" | awk '$1=="ticks"{print $2}')
    ticks+=("$t")
done

echo "== image"
if [[ -f "$REF" ]]; then
    python3 "$ROOT/tools/imgdiff.py" "$REF" "$ROOT/build/vbd/BENCH.BMP"
else
    echo "  (no reference at $REF -- run tools/check.sh --save)"
fi

echo "== ticks (${PASSES} passes): ${ticks[*]}"

echo "== memory"
tr -d '\r' < "$ROOT/build/vbd/bench.txt" | awk '
    $1=="mem"  {printf "  %-11s heapfree %8d  cost %8d\n", $2, $5, $6}
    $1=="free" {print}'
