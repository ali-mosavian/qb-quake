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
#   tools/check.sh --hud        the overlay, stats on, against tools/ref/hud.bmp
#   tools/check.sh --portal     the bench with and without the portal flood:
#                               the flood must cut leaves and change nothing
#   tools/check.sh --model      the alias model against -nomdl at two campath
#                               ticks: one where it must draw nothing, one
#                               where it must draw something.
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
# -ticks pins anim_time, and without it the liquids leave the last frame
# wherever the host's speed put them -- three runs of one binary gave three
# md5s. With it, two runs are byte-identical, which is what lets the image
# comparison below be a gate rather than a report.
# -yaw 183 turns the spawn to face the pool room: 285 polygons against
# the 153 the default look draws, with liquid, lightmaps and mips all
# in frame. A reference wants the busiest view, not the nearest wall.
BENCH="${BENCH:--lm -nostats -yaw 183 -bench 40 -ticks 60}"

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

# --model is the streak test. mdl_draw projected every vertex and then
# handed the triangle to qgl, which clips to the view rectangle AFTER the
# divide -- so a corner whose w sat a hair above z_near projected to tens
# of thousands of pixels and the rect clip did not discard that triangle,
# it stretched the surviving sliver across the frame. On dm3ish's campath
# that is a black wedge over the wall, wandering as the camera walks.
#
# The other half of those streaks -- the clipper's ring walk stepping
# below offset 0 of a BASIC array -- is t09rs case 13, native.
#
# Two viewpoints, because one assertion cannot fail both ways:
#
#   away  campath tick 360, where no entity is in frame, so the model must
#         add NOTHING. Before the fix it added 138 index-0 pixels of
#         streak; 947 with lightmaps on.
#   near  a fixed camera 200 units in front of spawned entity 1, so the
#         model must add SOMETHING -- otherwise "draws no streaks" also
#         passes for "draws nothing at all". The spawns are seeded
#         `randomize 1` under -bench and do not move with -at, so this
#         viewpoint is stable.
#
# UNLIT, and that is not a shortcut. With `-lm` the two arms render a
# different NUMBER of frames over the same ticks -- drawing the model
# costs time -- and a different frame count evicts the surface cache
# differently (sc_evict 10 against 2). The frames then differ for reasons
# that have nothing to do with the model's geometry, which is the open
# "reuse after eviction is untested" note in AGENTS.md and not this
# test's business. Unlit there is no cache at all and the comparison is
# exact.
# --hud draws the overlay. Its panels, bevels, bars and graphs went through
# mgl's 2D calls onto what is now a qgl Surface -- SF_addrTB at 38 where
# mgl reads DC_addrTB at 32 -- and a -stats run never returned at all: no
# frame, no error.log, killed at 150s and at 600s under both cores. Two
# ticks, unlit, so the fps still reads 0 and every counter is fixed;
# measured byte-identical run to run.
if [[ "${1:-}" == "--hud" ]]; then
    build_exe
    run_frame "-stats -yaw 183 -bench 2 -ticks 2" "$VBD_OUT/hud.bmp"
    out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/hud.bmp" "$VBD_OUT/hud.bmp" | tail -1)
    [[ "$out" == IDENTICAL* ]] && { echo "PASS  hud: $out"; exit 0; }
    echo "FAIL  hud: $out"; exit 1
fi

# The portal flood refines the PVS, so it may only remove leaves the frame
# could not see: on and off must be pixel-identical. That is vacuous when
# the flood removes nothing, so the on run must also report a cut.
if [[ "${1:-}" == "--portal" ]]; then
    build_exe
    run_frame "$BENCH"           "$VBD_OUT/portal-on.bmp"
    cut=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="portal_culled"{print $2}')
    run_frame "$BENCH -noportal" "$VBD_OUT/portal-off.bmp"
    out=$(python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/portal-off.bmp" "$VBD_OUT/portal-on.bmp" | tail -1)
    [[ "$out" == IDENTICAL* ]] || { echo "FAIL  portal: $out -- the flood culled something visible"; exit 1; }
    [[ "${cut:-0}" -gt 0 ]] || { echo "FAIL  portal: portal_culled=${cut:-none}, the flood cut nothing"; exit 1; }
    echo "PASS  portal: $out, $cut leaves cut"; exit 0
fi

if [[ "${1:-}" == "--model" ]]; then
    build_exe
    rc=0
    for arm in "away:-campath -bench 4000 -ticks 360" \
               "near:-at 264 -40 40 -yaw 0 -bench 8 -ticks 2"; do
        tag="${arm%%:*}"; flags="${arm#*:}"
        run_frame "-nostats $flags"         "$VBD_OUT/mdl-$tag-on.bmp"
        run_frame "-nostats $flags -nomdl"  "$VBD_OUT/mdl-$tag-off.bmp"
        out=$(python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/mdl-$tag-off.bmp" "$VBD_OUT/mdl-$tag-on.bmp" | tail -1)
        if [[ "$tag" == away ]]; then
            if [[ "$out" == IDENTICAL* ]]; then
                echo "PASS  away: the model adds nothing where it is not"
            else
                echo "FAIL  away: $out -- the model painted outside itself"
                rc=1
            fi
        else
            if [[ "$out" == IDENTICAL* ]]; then
                echo "FAIL  near: the model drew nothing at all"
                rc=1
            else
                echo "PASS  near: $out -- the model still renders"
            fi
        fi
    done
    exit $rc
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

build_exe
grep -qiE "^ *[1-9][0-9]* Severe" /tmp/check-build.log && {
    echo "COMPILE ERRORS"; grep -iB4 -E "^ *[1-9][0-9]* Severe" /tmp/check-build.log | grep -E "\^|Severe"; exit 1; }

# The three BASIC-side qgl gates, before any timing. They run in the
# built EXE, which is the only place any of them can say anything: the
# ABI is BASIC's to get wrong, and the store test wants the EMS state
# the renderer starts with.
#
# -qglarr was written as a gate and then never run by one, which is how
# it kept a 25-second hold on the end for a human to look at.
#
# The map argument comes FIRST. sys_parse_args takes argv(0) as the map
# name and scans options from index 1, so `qrender.exe -qgldiff` makes
# the flag the map name and the check silently never runs.
for pair in "qglcheck:QGLCHK.LOG" "qgldiff:QGLDIFF.LOG" "qglarr:QGLARR.LOG"; do
    f="${pair%%:*}"
    log="$VBD_OUT/${pair##*:}"
    rm -f "$log"
    QFLAGS="-$f" TIMEOUT=300 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    if [[ "$(tr -d '\r' < "$log" 2>/dev/null | tail -1)" != "RESULT PASS" ]]; then
        echo "-$f FAILED"; tr -d '\r' < "$log" 2>/dev/null | grep -v '^ ' | head -10
        exit 1
    fi
done
echo "== qgl: -qglcheck, -qgldiff and -qglarr all PASS"

ticks=()
for ((i=0; i<PASSES; i++)); do
    QFLAGS="$BENCH" TIMEOUT=600 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
    t=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="ticks"{print $2}')
    ticks+=("$t")
done

echo "== image"
# A gate, not a report. It was a report, against a 320x200 reference this
# build could never produce, while the screenshot itself read the qgl
# backbuffer through mgl's uglPGet and came back as full-frame noise for
# every commit since the depth buffer moved onto the Surface. Nothing
# said so, because nothing was comparing.
if [[ -f "$REF" ]]; then
    python3 "$ROOT/tools/imgdiff.py" "$REF" "$VBD_OUT/BENCH.BMP" || {
        echo "IMAGE DIFFERS from $REF"; exit 1; }
else
    echo "  (no reference at $REF -- run tools/check.sh --save)"
fi

echo "== ticks (${PASSES} passes): ${ticks[*]}"

# The surface cache's own selftest, which every bench runs and nothing
# read. 1 is a pass; a negative number names the assertion. It read 1
# while its row write went through mgl's uglRowWriteBuff on a qgl
# Surface, because the read went through the same wrong address --
# the readback is through the surface's own pixels now.
sct=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="sc_test"{print $2}')
[[ "$sct" == "1" ]] || { echo "sc_test $sct, want 1"; exit 1; }

echo "== memory"
tr -d '\r' < "$VBD_OUT/bench.txt" | awk '
    $1=="mem"  {printf "  %-11s heapfree %8d  cost %8d\n", $2, $5, $6}
    $1=="free" {print}'
