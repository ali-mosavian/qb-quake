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
#   tools/check.sh --depth      the spawn fall with and without the depth
#                               buffer. The two frames may differ only where
#                               depth legitimately changes the picture.
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

# The native gates go first, and go before --churn as well: they take
# fifteen seconds against the DOS build's minutes, and a qgl fault caught
# here is a failing assertion by name rather than a picture that came out
# wrong for reasons unknown.
make -C "$ROOT" test || { echo "NATIVE GATES FAILED"; exit 1; }

# tools/dosbox.sh build predates the src/<subsystem>/ layout and cannot
# build this tree; make can, into VBD_OUT so two sessions never share one.
build_exe() {
    make -C "$ROOT" build BUILD="$VBD_OUT" > /tmp/check-build.log 2>&1 || {
        echo "BUILD FAILED"; tail -20 /tmp/check-build.log; exit 1; }
    [[ "$(grep -c L2029 "$VBD_OUT/LINK.OUT" 2>/dev/null)" == 0 ]] || {
        echo "LINK FAILED"; grep L2029 "$VBD_OUT/LINK.OUT" | head -5; exit 1; }
}

# One headless run into VBD_OUT, retried: a run in four dies before
# writing anything -- empty run.out, no error.log -- and that is its own
# open bug, not a verdict on the picture.
run_frame() {   # $1 = flags, $2 = where to keep BENCH.BMP
    local try
    for try in 1 2 3; do
        rm -f "$VBD_OUT/BENCH.BMP" "$VBD_OUT/bench.txt"
        QFLAGS="$1" TIMEOUT=900 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
        [[ -f "$VBD_OUT/BENCH.BMP" ]] && break
        echo "  attempt $try produced nothing; retrying"
    done
    [[ -f "$VBD_OUT/BENCH.BMP" ]] || { echo "RUN PRODUCED NOTHING"; exit 1; }
    cp "$VBD_OUT/BENCH.BMP" "$2"
    echo "  $(tr -d '\r' < "$VBD_OUT/bench.txt" |
        awk '/^(frames|ticks|polys|sc_evict) /{printf "%s=%s ",$1,$2}')"
}

# --depth is a symptom test for stale far-heap pointers in d_faces.c: the
# BASIC arrays it walks compact under the calls it makes, and a pointer
# taken at entry then names freed memory. Any change to what those calls
# allocate -- the depth buffer was one -- moves where the compaction
# lands, and the frame comes out as slanted stripes of texture from
# faces that were never in view. 87% of pixels differed before the fix,
# ~2.5% after; the 5% allows the edges a working depth test really moves.
if [[ "${1:-}" == "--depth" ]]; then
    build_exe
    BENCH="-lm -nostats -yaw 182 -bench 40 -ticks 60"
    run_frame "$BENCH"      "$VBD_OUT/depth-z.bmp"
    run_frame "$BENCH -noz" "$VBD_OUT/depth-noz.bmp"
    out=$(python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/depth-z.bmp" "$VBD_OUT/depth-noz.bmp" | tail -1)
    pct=$(sed -n 's/.*(\([0-9.]*\)%).*/\1/p' <<< "$out")
    echo "  $out"
    if [[ "$out" == IDENTICAL* ]] || awk -v p="$pct" 'BEGIN{exit !(p+0 <= 5.0)}'; then
        echo "PASS  depth changes only what depth may change"
        exit 0
    fi
    echo "FAIL  the depth buffer changed the picture, not the ordering"
    exit 1
fi

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
# Passes since 8e57e79 (d_faces.c re-taking its array pointers): two runs,
# 266 frames, byte-identical. With sc_evict 0, though -- the campath no
# longer evicts on qgl's 4MB store, so reuse after eviction is not what
# this exercises any more. See AGENTS.md.
if [[ "${1:-}" == "--churn" ]]; then
    BENCH="-lm -nostats -campath -ticks 900"
    build_exe
    for i in 1 2; do
        run_frame "$BENCH" "$VBD_OUT/churn$i.bmp"
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

# The two BASIC-side qgl gates, before any timing. They run in the built
# EXE against the same UGLV.LIB the renderer links, which is the only
# place either can say anything: the ABI is BASIC's to get wrong, and the
# differential needs an mgl that is initialised the way the renderer
# initialises it.
#
# The map argument comes FIRST. sys_parse_args takes argv(0) as the map
# name and scans options from index 1, so `qrender.exe -qgldiff` makes
# the flag the map name and the check silently never runs.
for pair in "qglcheck:QGLCHK.LOG" "qgldiff:QGLDIFF.LOG"; do
    f="${pair%%:*}"
    log="$VBD_OUT/${pair##*:}"
    rm -f "$log"
    QFLAGS="-$f" TIMEOUT=300 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    if [[ "$(tr -d '\r' < "$log" 2>/dev/null | tail -1)" != "RESULT PASS" ]]; then
        echo "-$f FAILED"; tr -d '\r' < "$log" 2>/dev/null | grep -v '^ ' | head -10
        exit 1
    fi
done
echo "== qgl: -qglcheck and -qgldiff both PASS"

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
