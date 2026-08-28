#!/usr/bin/env bash
# check.sh -- build, bench, and compare against the stored reference.
#
# One command per change, so a phase is not "done" until the picture is
# identical, the frame time has not moved and the tracer agrees the bytes
# actually left. Run tools/check.sh --save once on a known-good build to
# lay down the reference.
#
# Two cases, and the second is not optional after a cache change:
#
#   tools/check.sh              a fixed camera -- builds every surface
#                               once, evicts nothing
#   tools/check.sh --churn      walks the campath -- ~180 evictions, so
#                               blocks are reused and re-read. Compares two
#                               runs of one binary, not a stored picture.
#
# -nostats is not optional. The overlay prints live fps and frame time, so
# two runs of the SAME build differ by ~28 pixels in the digits, and a
# harness that reports a difference every time reports nothing at all.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# VBD_OUT keeps concurrent runs out of one another's output tree. Two
# sessions sharing $ROOT/build/vbd overwrite each other's BENCH.BMP and
# bench.txt, so the picture and the ticks can come from DIFFERENT runs.
VBD_OUT="${VBD_OUT:-$ROOT/build/vbd}"
export VBD_OUT
REF="${REF:-$ROOT/tools/ref/bench.bmp}"
PASSES="${PASSES:-2}"
BENCH="${BENCH:--lm -nostats -bench 30}"

# --churn is a DETERMINISM check, not a reference-image one: it runs the
# same binary twice and compares the two frames to each other.
#
# That is the right shape for the surface cache. Standing still builds every
# surface once and evicts nothing, so the default case above cannot see the
# cache at all -- it reports sc_evict 0. Walking the campath evicts ~180
# times, and a correct cache must then draw the same picture however many
# frames happened to fit in those ticks.
#
# -ticks pins the simulation, so the camera stops in the same place whatever
# speed the host ran at and the two runs are comparing one viewpoint.
#
# THIS CURRENTLY FAILS. See AGENTS.md: a cached surface's bytes are
# overwritten between the build and the reuse, and the picture varies run to
# run. Forcing every face to rebuild makes it byte-identical, which is what
# says the fault is in reuse and not in the builder.
if [[ "${1:-}" == "--churn" ]]; then
    BENCH="-lm -nostats -campath -ticks 900"
    "$ROOT/tools/dosbox.sh" build > /tmp/check-build.log 2>&1 || {
        echo "BUILD FAILED"; tail -20 /tmp/check-build.log; exit 1; }
    for i in 1 2; do
        # A run in four here dies before writing anything -- empty run.out,
        # no error.log. That is its own open bug; retry rather than let it
        # masquerade as a determinism failure.
        for try in 1 2 3; do
            rm -f "$VBD_OUT/BENCH.BMP" "$VBD_OUT/bench.txt"
            QFLAGS="$BENCH" TIMEOUT=900 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
            [[ -f "$VBD_OUT/BENCH.BMP" ]] && break
            echo "  run $i attempt $try produced nothing; retrying"
        done
        [[ -f "$VBD_OUT/BENCH.BMP" ]] || { echo "RUN $i PRODUCED NOTHING"; exit 1; }
        cp "$VBD_OUT/BENCH.BMP" "$VBD_OUT/churn$i.bmp"
        echo "  run $i: $(tr -d '\r' < "$VBD_OUT/bench.txt" |
            awk '/^(frames|ticks|sc_evict) /{printf "%s=%s ",$1,$2}')"
    done
    if cmp -s "$VBD_OUT/churn1.bmp" "$VBD_OUT/churn2.bmp"; then
        echo "PASS  two runs identical under eviction"
        exit 0
    fi
    echo "FAIL  same binary, same tick, two different frames"
    python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/churn1.bmp" "$VBD_OUT/churn2.bmp"
    exit 1
fi

if [[ "${1:-}" == "--save" ]]; then
    mkdir -p "$(dirname "$REF")"
    python3 "$ROOT/tools/imgdiff.py" --save "$REF" "$VBD_OUT/BENCH.BMP"
    exit $?
fi

"$ROOT/tools/dosbox.sh" build > /tmp/check-build.log 2>&1 || {
    echo "BUILD FAILED"; tail -20 /tmp/check-build.log; exit 1; }
grep -qiE "^ *[1-9][0-9]* Severe" /tmp/check-build.log && {
    echo "COMPILE ERRORS"; grep -iB4 -E "^ *[1-9][0-9]* Severe" /tmp/check-build.log | grep -E "\^|Severe"; exit 1; }

# LINK emits an EXE even with an unresolved external, patching the call to
# int 3 -- and a failed link leaves the PREVIOUS exe in place, which runs
# fine and reports numbers for code that is not in it. dosbox.sh records
# the verdict; without this the harness cheerfully measures a stale build.
res=$(tr -d '\r' < "$VBD_OUT/RESULT.TXT" 2>/dev/null)
[[ "$res" == "PASS" ]] || {
    echo "LINK FAILED ($res)"; grep -i error "$VBD_OUT/LINK.OUT" | head -5; exit 1; }

ticks=()
for ((i=0; i<PASSES; i++)); do
    QFLAGS="$BENCH" TIMEOUT=600 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    t=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="ticks"{print $2}')
    ticks+=("$t")
done

echo "== image"
if [[ -f "$REF" ]]; then
    python3 "$ROOT/tools/imgdiff.py" "$REF" "$VBD_OUT/BENCH.BMP"
else
    echo "  (no reference at $REF -- run tools/check.sh --save)"
fi

echo "== ticks (${PASSES} passes): ${ticks[*]}"

echo "== memory"
tr -d '\r' < "$VBD_OUT/bench.txt" | awk '
    $1=="mem"  {printf "  %-11s heapfree %8d  cost %8d\n", $2, $5, $6}
    $1=="free" {print}'
