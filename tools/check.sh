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
#   tools/check.sh --fight      ten seconds next to a knight: it must reach
#                               the player and strike, and nothing may crash
#   tools/check.sh --e1m1       id's e1m1, from the shareware PAK: it must
#                               load and draw polygons at the spawn
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
run_frame() {   # $1 = flags, $2 = where to keep BENCH.BMP, $3 = map (default dm3ish)
    local try
    for try in 1 2 3; do
        rm -f "$VBD_OUT/BENCH.BMP" "$VBD_OUT/bench.txt" "$VBD_OUT/ERROR.LOG"
        QFLAGS="$1" TIMEOUT=900 "$ROOT/tools/dosbox.sh" run ${3:-} > /dev/null 2>&1
        [[ -f "$VBD_OUT/BENCH.BMP" ]] && break
        [[ -f "$VBD_OUT/ERROR.LOG" ]] && { echo "RUN FAILED: $(cat "$VBD_OUT/ERROR.LOG")"; exit 1; }
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
#         streak; 947 with lightmaps on. -noai, since the monsters
#         wander: by tick 360 a knight had walked into a visible leaf
#         and mdl_drawn read 1 with the picture still identical.
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
    for arm in "away:-noai -campath -bench 4000 -ticks 360" \
               "near:-at 264 -40 40 -yaw 0 -bench 8 -ticks 2"; do
        tag="${arm%%:*}"; flags="${arm#*:}"
        run_frame "-nostats -noview $flags"         "$VBD_OUT/mdl-$tag-on.bmp"
        drawn=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="mdl_drawn"{print $2}')
        run_frame "-nostats -noview $flags -nomdl"  "$VBD_OUT/mdl-$tag-off.bmp"
        out=$(python3 "$ROOT/tools/imgdiff.py" "$VBD_OUT/mdl-$tag-off.bmp" "$VBD_OUT/mdl-$tag-on.bmp" | tail -1)
        if [[ "$tag" == away ]]; then
            # And the cull must have rejected them, not the depth test: the
            # eight spawned models are all out of view here, and a model
            # drawn into nothing still cost its 170 vertices in BASIC.
            if [[ "$out" == IDENTICAL* && "${drawn:-8}" == 0 ]]; then
                echo "PASS  away: the model adds nothing where it is not, mdl_drawn 0"
            else
                echo "FAIL  away: $out -- the model painted outside itself"
                rc=1
            fi
        else
            if [[ "$out" == IDENTICAL* ]]; then
                echo "FAIL  near: the model drew nothing at all"
                rc=1
            else
                echo "PASS  near: $out -- the model still renders, mdl_drawn $drawn"
            fi
        fi
    done
    exit $rc
fi

# --fight is the first bench run in which the player is ever hurt. The
# damage flash's palette copy was a module-level dynamic array screen.bas
# never allocated -- the trap this repo already documents -- and every
# other gate stands where no monster ever lands a hit. Spawn is
# randomize 1, so the knight at (464,-40) is always there.
if [[ "${1:-}" == "--fight" ]]; then
    build_exe
    run_frame "-lm -nostats -at 314 -40 48 -yaw 0 -bench 400 -ticks 600" "$VBD_OUT/fight.bmp"
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    if [[ -f "$VBD_OUT/ERROR.LOG" ]]; then echo "FAIL  fight: $(cat "$VBD_OUT/ERROR.LOG")"; exit 1; fi
    if [[ "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ]]; then
        echo "PASS  fight: health $hp, deaths $deaths -- the knight struck"; exit 0
    fi
    echo "FAIL  fight: health ${hp:-none}, deaths ${deaths:-none} -- nothing hit the player"; exit 1
fi

# --e1m1 is the first id map through the loader: 5,516 faces, a tree 62
# deep, a portal table past 64K, a PVS that only fits in EMS. Two frames
# against references: the spawn hall (-yaw 270 is the map's angle 90,
# mirrored) and the exit slipgate, whose walls the old frame linking
# painted with the "trigger" texture -- it assumed a chain's frames sit
# side by side in the lump -- and whose changelevel volume drew as a
# column. Then the first double door: -walk from its approach side must
# carry the player through it, where a door that does not open stops
# them at x 271. Then the plunger floor at the first button: -walk into
# the button must press it and send the floor, a targeted door, down with
# the player on it, the slipgate must end the level (gs_state 4), a
# shot at the wall switch must lift the bridge it targets, and
# the bench's ent lines must count the nine
# soldiers and the dog the map places on easy. The exit reference carries the "Walk into the
# slipgate" centerprint, since its camera stands in that trigger. Needs
# the shareware PAK; skips without it.
if [[ "${1:-}" == "--e1m1" ]]; then
    PAK="${PAK:-$HOME/dos/QUAKE_SW/ID1/PAK0.PAK}"
    if [[ ! -f "$ROOT/data/e1m1.bsp" ]]; then
        [[ -f "$PAK" ]] || { echo "SKIP  e1m1: no $PAK"; exit 0; }
        python3 - "$PAK" "$ROOT/data/e1m1.bsp" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
off, n = struct.unpack_from("<ii", d, 4)
for i in range(n // 64):
    name, fo, fs = struct.unpack_from("<56sii", d, off + i * 64)
    if name.rstrip(b"\0") == b"maps/e1m1.bsp":
        open(sys.argv[2], "wb").write(d[fo:fo + fs])
        break
PY
    fi
    build_exe
    python3 "$ROOT/tools/mkassets.py" "$ROOT/data/e1m1.bsp" "$ROOT/data/base.dat" \
        "$VBD_OUT/e1m1-assets" > /dev/null || { echo "FAIL  e1m1: mkassets"; exit 1; }
    # the zip AND the flat atlases beside the exe: dm3ish's texr.raw under
    # e1m1's offset table drew every texture as some other one
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$VBD_OUT/e1m1-assets/$f" "$VBD_OUT/$f"; done
    rc=0
    for arm in "spawn:-yaw 270" "exit:-at 1312 660 -200 -yaw 90"; do
        tag="${arm%%:*}"; flags="${arm#*:}"
        # -noai: a soldier behind the exit camera shot the player within
        # the second, and the health digits moved the frame
        run_frame "-lm -nostats -noai $flags -bench 40 -ticks 60" "$VBD_OUT/e1m1-$tag.bmp" e1m1.bsp
        out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/e1m1-$tag.bmp" "$VBD_OUT/e1m1-$tag.bmp" | tail -1)
        if [[ "$out" == IDENTICAL* ]]; then echo "PASS  e1m1 $tag: $out"; else echo "FAIL  e1m1 $tag: $out"; rc=1; fi
    done
    run_frame "-lm -nostats -at 330 576 40 -yaw 180 -walk -bench 400 -ticks 240" "$VBD_OUT/e1m1-door.bmp" e1m1.bsp
    px=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="px"{print $2}')
    if awk -v x="${px:-999}" 'BEGIN{exit !(x < 190)}'; then
        echo "PASS  e1m1 door: px $px, through the door"
    else
        echo "FAIL  e1m1 door: px ${px:-none}, the door did not open"; rc=1
    fi
    run_frame "-lm -nostats -at 0 576 24 -yaw 180 -walk -bench 400 -ticks 240" "$VBD_OUT/e1m1-button.bmp" e1m1.bsp
    pz=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pz"{print $2}')
    if awk -v z="${pz:-999}" 'BEGIN{exit !(z < -100)}'; then
        echo "PASS  e1m1 button: pz $pz, the floor went down"
    else
        echo "FAIL  e1m1 button: pz ${pz:-none}, the button did nothing"; rc=1
    fi
    # and the map's own monsters: nine soldiers and a dog on easy, from ents.bin
    nent=$(tr -d '\r' < "$VBD_OUT/bench.txt" | grep -c '^ent[0-9]' || true)
    ndog=$(tr -d '\r' < "$VBD_OUT/bench.txt" | grep -c '^ent[0-9]* 2 ' || true)
    if [[ "$nent" == 10 && "$ndog" == 1 ]]; then
        echo "PASS  e1m1 monsters: $nent from the map, $ndog dog"
    else
        echo "FAIL  e1m1 monsters: $nent spawned, $ndog dogs; the map places 9 soldiers and a dog"; rc=1
    fi
    # and the exit: the slipgate's pad is 32 units up, so -jump too
    run_frame "-lm -nostats -noai -at 1312 660 -200 -yaw 90 -walk -jump -bench 400 -ticks 240" "$VBD_OUT/e1m1-slipgate.bmp" e1m1.bsp
    gs=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="gs_state"{print $2}')
    if [[ "$gs" == 4 ]]; then
        echo "PASS  e1m1 slipgate: gs_state 4, the level ends"
    else
        echo "FAIL  e1m1 slipgate: gs_state ${gs:-none}, the slipgate did nothing"; rc=1
    fi
    # and the shootable switch *16: -fire at it from the bridge it lifts,
    # 108 units off and 26 degrees up, must send door *15 -- lowered 64 at
    # load -- up: its brush leaves -64
    run_frame "-lm -nostats -noai -at 560 2016 -160 -yaw 180 -pitch 26 -fire -bench 400 -ticks 120" "$VBD_OUT/e1m1-shoot.bmp" e1m1.bsp
    dz=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^door_/ && $2==15 {print $6}')
    if awk -v z="${dz:--64}" 'BEGIN{exit !(z > -64)}'; then
        echo "PASS  e1m1 shoot: door 15 at z $dz, the switch was shot"
    else
        echo "FAIL  e1m1 shoot: door 15 at z ${dz:-none}, the switch took no shot"; rc=1
    fi
    # and the secret door *43, "Shoot this secret door...": shot level from
    # 60 units -- the default 11 degrees down puts the pellet on the hull's
    # floor first -- it slides 14 back in y, waits a second, then 62 aside
    # in x, and open_once keeps it there
    run_frame "-lm -nostats -noai -at 688 120 60 -yaw 90 -pitch 0 -fire -bench 400 -ticks 240" "$VBD_OUT/e1m1-secret.bmp" e1m1.bsp
    sx=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^door_/ && $2==43 {print $4}')
    if awk -v x="${sx:-0}" 'BEGIN{exit !(x > 60)}'; then
        echo "PASS  e1m1 secret: door 43 at x $sx, the secret door slid aside"
    else
        echo "FAIL  e1m1 secret: door 43 at x ${sx:-none}, the secret door stayed"; rc=1
    fi
    # and killtarget: standing in trigger_once *54 removes the hint *51,
    # "You can jump up here...", for good -- its state reads DONE, 4
    run_frame "-lm -nostats -noai -at 688 192 60 -yaw 90 -bench 400 -ticks 30" "$VBD_OUT/e1m1-kill.bmp" e1m1.bsp
    ks=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^trig_/ && $2==51 {print $4}')
    if [[ "$ks" == 4 ]]; then
        echo "PASS  e1m1 kill: trigger 51 state 4, the hint was removed"
    else
        echo "FAIL  e1m1 kill: trigger 51 state ${ks:-none}, the hint survived"; rc=1
    fi
    # the same run carries the map's five ambient_* points, looping on
    # the static channels from the moment the card came up
    na=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="snd_loops"{print $2}')
    if [[ "$na" == 5 ]]; then
        echo "PASS  e1m1 ambient: snd_loops 5, four hums and a drone"
    else
        echo "FAIL  e1m1 ambient: snd_loops ${na:-none}, want 5"; rc=1
    fi
    # and the dog's leap: 120 units from e1m1's dog at (88,1520,-200), in
    # its sight and on its level, it must leave the ground within 3 s
    run_frame "-lm -nostats -at 208 1520 -200 -yaw 180 -bench 400 -ticks 180" "$VBD_OUT/e1m1-leap.bmp" e1m1.bsp
    nl=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_leaps"{print $2}')
    if [[ "${nl:-0}" -ge 1 ]]; then
        echo "PASS  e1m1 leap: pl_leaps $nl, the dog leapt"
    else
        echo "FAIL  e1m1 leap: pl_leaps ${nl:-none}, the dog kept its feet"; rc=1
    fi
    # and trigger_secret *44, the area behind the shot door: standing in
    # it counts one secret
    run_frame "-lm -nostats -noai -at 688 40 60 -yaw 90 -bench 400 -ticks 30" "$VBD_OUT/e1m1-secret-area.bmp" e1m1.bsp
    ns=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_secrets"{print $2}')
    if [[ "$ns" == 1 ]]; then
        echo "PASS  e1m1 secrets: pl_secrets 1, the secret area counted"
    else
        echo "FAIL  e1m1 secrets: pl_secrets ${ns:-none}, the secret area did not count"; rc=1
    fi
    # and item_armor1 at (688,480,80): standing on it is 100 of green armor
    run_frame "-lm -nostats -noai -at 688 480 80 -yaw 90 -bench 400 -ticks 30" "$VBD_OUT/e1m1-armor.bmp" e1m1.bsp
    na=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_armor"{print $2}')
    if [[ "$na" == 100 ]]; then
        echo "PASS  e1m1 armor: pl_armor 100, the green armor was taken"
    else
        echo "FAIL  e1m1 armor: pl_armor ${na:-none}, the armor was not taken"; rc=1
    fi
    # and weapon_supershotgun at (-360,2912,-80): standing on it puts the
    # super shotgun in hand, with its five shells on the 25
    run_frame "-lm -nostats -noai -at -360 2912 -80 -yaw 90 -bench 400 -ticks 30" "$VBD_OUT/e1m1-ssg.bmp" e1m1.bsp
    nw=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_weapon"{print $2}')
    nsh=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_shells"{print $2}')
    if [[ "$nw" == 2 && "$nsh" == 30 ]]; then
        echo "PASS  e1m1 ssg: pl_weapon 2 pl_shells 30, the super shotgun was taken"
    else
        echo "FAIL  e1m1 ssg: pl_weapon ${nw:-none} pl_shells ${nsh:-none}, the super shotgun was not taken"; rc=1
    fi
    # and weapon_nailgun at (112,2352,16), fire held a second: the first
    # tick's shotgun, the pickup with its 30 nails, then a nail every 0.2
    # from 0.5 -- three by tick 60
    run_frame "-lm -nostats -noai -at 112 2352 16 -yaw 90 -fire -bench 400 -ticks 60" "$VBD_OUT/e1m1-nail.bmp" e1m1.bsp
    nw=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_weapon"{print $2}')
    nn=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_nails"{print $2}')
    if [[ "$nw" == 4 && "$nn" == 27 ]]; then
        echo "PASS  e1m1 nail: pl_weapon 4 pl_nails 27, the nailgun was taken and fired"
    else
        echo "FAIL  e1m1 nail: pl_weapon ${nw:-none} pl_nails ${nn:-none}, the nailgun was not taken or did not fire"; rc=1
    fi
    # the quad at (544,2480,-88): standing on it starts its thirty seconds
    run_frame "-lm -nostats -noai -at 544 2480 -88 -yaw 90 -bench 400 -ticks 30" "$VBD_OUT/e1m1-quad.bmp" e1m1.bsp
    nq=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_quad_left"{print int($2)}')
    if [[ "${nq:-0}" -ge 28 ]]; then
        echo "PASS  e1m1 quad: pl_quad_left $nq, the quad was taken"
    else
        echo "FAIL  e1m1 quad: pl_quad_left ${nq:-none}, the quad was not taken"; rc=1
    fi
    # the slime pool under the walkway at (1100,2280): two seconds in it,
    # no suit, costs 12 a second
    run_frame "-lm -nostats -noai -at 1100 2280 -500 -yaw 90 -bench 400 -ticks 120" "$VBD_OUT/e1m1-slime.bmp" e1m1.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    if [[ "${hp:-100}" -lt 100 ]]; then
        echo "PASS  e1m1 slime: health $hp, the slime bit"
    else
        echo "FAIL  e1m1 slime: health ${hp:-none}, the slime did nothing"; rc=1
    fi
    # misc_explobox at (72,2056,-208), shot from 100 units: one volley
    # takes its 20, and its 160 less half the distance reaches the shooter
    run_frame "-lm -nostats -noai -at 172 2056 -208 -yaw 180 -pitch 0 -fire -bench 400 -ticks 30" "$VBD_OUT/e1m1-boom.bmp" e1m1.bsp
    nb=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_booms"{print $2}')
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    if [[ "${nb:-0}" -ge 1 && "${hp:-100}" -lt 100 ]]; then
        echo "PASS  e1m1 boom: pl_booms $nb, health $hp -- the box went off"
    else
        echo "FAIL  e1m1 boom: pl_booms ${nb:-none}, health ${hp:-none} -- the box did not go off"; rc=1
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
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
