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
#   tools/check.sh --drown      fifteen seconds under dm3ish's pool: the breath
#                               out at twelve, three bites, health 82
#   tools/check.sh --fight      ten seconds next to a knight: it must reach
#                               the player and strike, and nothing may crash
#   tools/check.sh --e1m1       id's e1m1, from the shareware PAK: it must
#                               load and draw polygons at the spawn
#   tools/check.sh --e1m2       e1m2's own entities, from the build's MAPS\
#   tools/check.sh --e1m3       e1m3, the first map with no soldier: its spawn frame
#   tools/check.sh --e1m4       e1m4's spawn frame, the super nailgun
#   tools/check.sh --e1m5       e1m5's spawn frame, the shambler, the rocket launcher
#   tools/check.sh --e1m6       e1m6's spawn frame; --e1m7, --e1m8 and --start likewise,
#                               and e1m8's jump under its sv_gravity of 100, its pentagram
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
        # a run that dies writing the frame leaves a 54-byte header: not a run
        [[ -f "$VBD_OUT/BENCH.BMP" && $(stat -f%z "$VBD_OUT/BENCH.BMP") -gt 1000 ]] && break
        [[ -f "$VBD_OUT/ERROR.LOG" ]] && { echo "RUN FAILED: $(cat "$VBD_OUT/ERROR.LOG")"; exit 1; }
        echo "  attempt $try produced nothing; retrying"
    done
    [[ -f "$VBD_OUT/BENCH.BMP" ]] || { echo "RUN PRODUCED NOTHING"; exit 1; }
    cp "$VBD_OUT/BENCH.BMP" "$2"
    # A timer whose mean falls outside its own min and max divides by the
    # wrong count: pt_present read min 0.982 mean 0.975, one frame short.
    local bad
    bad=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^pt_/ && ($3 < $2 - 0.001 || $3 > $4 + 0.001) {print $1, $2, $3, $4}')
    [[ -z "$bad" ]] || { echo "FAIL  timer mean outside min..max: $bad"; exit 1; }
    # fp87.asm rewrites each emulator interrupt into the 8087 instruction
    # it stands for. Zero sites means every float in the run went back to
    # costing an interrupt -- silently, and for 13ms of an e1m6 frame.
    local fp
    fp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 == "fp_sites" {print $2}')
    [[ -n "$fp" && "$fp" -gt 0 ]] || { echo "FAIL  fp_sites ${fp:-absent}: emulator interrupts unpatched"; exit 1; }
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
# randomize 1, so the knight at (464,-48) is always there. The player
# stands 100 units from it, inside RANGE_MELEE, where FindTarget needs
# no infront: at 150 the knight has to happen to face them while it
# wanders, and once it did not -- it walked to x 620 and health stayed
# 100 for the whole 600 ticks.
# --drown is WaterMove's air. Dropped into dm3ish's pool at (500,0,-60) the
# player sinks to -104 with the eyes under; the breath runs out at 12 s
# and the bites are 4, 6 and 8 by 15 s: health 82. Without the port it
# reads 100.
if [[ "${1:-}" == "--drown" ]]; then
    build_exe
    run_frame "-lm -nostats -noai -at 500 0 -60 -bench 2000 -ticks 900" "$VBD_OUT/drown.bmp"
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    if [[ -f "$VBD_OUT/ERROR.LOG" ]]; then echo "FAIL  drown: $(cat "$VBD_OUT/ERROR.LOG")"; exit 1; fi
    if [[ "${hp:-100}" -ge 80 && "${hp:-100}" -le 90 ]]; then
        echo "PASS  drown: health $hp after fifteen seconds under"; exit 0
    fi
    echo "FAIL  drown: health ${hp:-none}, want 80..90 (three bites from 100)"; exit 1
fi

if [[ "${1:-}" == "--fight" ]]; then
    build_exe
    run_frame "-lm -nostats -at 364 -48 48 -yaw 0 -bench 400 -ticks 600" "$VBD_OUT/fight.bmp"
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
        "$VBD_OUT/e1m1-assets" 0 "$PAK" > /dev/null || { echo "FAIL  e1m1: mkassets"; exit 1; }
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
    # Placement is cached per brush model and redone only for one a mover
    # marked. A mover that forgets to mark leaves its model drawn at the
    # node it left: with the doors' mark removed this scene read 1.
    ps=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="place_stale"{print $2}')
    if [[ "$ps" == 0 ]]; then
        echo "PASS  e1m1 placement: place_stale 0 after the lift moved"
    else
        echo "FAIL  e1m1 placement: place_stale ${ps:-none}, a moved model kept a stale node"; rc=1
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
    ix=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="px"{print $2}')
    iy=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="py"{print $2}')
    if [[ "$gs" == 4 && "$ix" == -112 && "$iy" == 704 ]]; then
        echo "PASS  e1m1 slipgate: gs_state 4 at ($ix,$iy), the level ends on the intermission camera"
    else
        echo "FAIL  e1m1 slipgate: gs_state ${gs:-none} at (${ix:-none},${iy:-none}); want 4 at the info_intermission (-112,704)"; rc=1
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
    # and the box is solid: two seconds' walk at it from 100 units stops
    # at its face plus the player's half width, x 103.03; with no hull the
    # walk went through it to the wall past -60. Placed 28 up: at the
    # floor's own z the world hull holds the player's feet solid and
    # nothing moves, box or no box
    run_frame "-lm -nostats -noai -at 172 2056 -180 -yaw 180 -walk -bench 400 -ticks 120" "$VBD_OUT/e1m1-boxwall.bmp" e1m1.bsp
    bx=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="px"{print $2}')
    if awk -v x="${bx:-0}" 'BEGIN{exit !(x > 100)}'; then
        echo "PASS  e1m1 boxwall: px $bx, the box stopped the walk"
    else
        echo "FAIL  e1m1 boxwall: px ${bx:-none}, the walk went through the box"; rc=1
    fi
    # the patrols, AI on from the spawn: the soldier at (1232,2088) walks
    # its corners (1232,2048) then (880,2048) at ai_walk's pace, and ten
    # seconds in some ent line stands on y 2048 between x 950 and 1200
    run_frame "-lm -nostats -yaw 270 -bench 400 -ticks 600" "$VBD_OUT/e1m1-patrol.bmp" e1m1.bsp
    np=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^ent[0-9]/ && $7 > 2040 && $7 < 2056 && $6 > 950 && $6 < 1200' | wc -l | tr -d ' ')
    if [[ "${np:-0}" -ge 1 ]]; then
        echo "PASS  e1m1 patrol: a soldier on its way along y 2048"
    else
        echo "FAIL  e1m1 patrol: no soldier between (950,2048) and (1200,2048) after 600 ticks"; rc=1
        tr -d '\r' < "$VBD_OUT/bench.txt" | grep '^ent[0-9]'
    fi
    # and the level after it. LAST: it leaves e1m2's assets staged. The
    # slipgate walk with fire held and the soldier behind the exit awake:
    # two seconds into the intermission the run writes NEXT.BAT, run.bat
    # chains, and the bench is e1m2's with the soldier's damage carried
    run_frame "-lm -nostats -at 1312 660 -200 -yaw 90 -walk -jump -fire -bench 400 -ticks 420" "$VBD_OUT/e1m1-chain.bmp" e1m1.bsp
    cm=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="map"{print $2}')
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    if [[ "$cm" == e1m2.bsp && "${hp:-100}" -lt 100 && "${hp:-0}" -gt 0 ]]; then
        echo "PASS  e1m1 chain: the bench is $cm's, health $hp carried over"
    else
        echo "FAIL  e1m1 chain: map ${cm:-none}, health ${hp:-none}; want e1m2.bsp under 100"; rc=1
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
    exit $rc
fi

# e1m2, from the build's own MAPS\e1m2 staging (make maps): the things
# e1m1 has none of. The two func_trains *17 and *18 start by the floor
# button *16 (t71 -> t65) and run their path_corners: six seconds after
# the player lands on the button both must stand at their last corner,
# t64 and t68, which is (corner - mins): *17 (-10,263,-82), *18 (-26,263,-82).
if [[ "${1:-}" == "--e1m2" ]]; then
    build_exe
    [[ -f "$VBD_OUT/MAPS/e1m2/assets.zip" ]] || { echo "SKIP  e1m2: no MAPS/e1m2 in the build (needs the PAK)"; exit 0; }
    for f in assets.zip texr.raw texs.raw pal.raw e1m2.bsp; do cp "$VBD_OUT/MAPS/e1m2/$f" "$VBD_OUT/$f"; done
    rc=0
    run_frame "-lm -nostats -noai -at -96 288 327 -yaw 0 -bench 400 -ticks 360" "$VBD_OUT/e1m2-train.bmp" e1m2.bsp
    t17=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="plat_1"{print $2,$5,$6,$7}')
    t18=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="plat_2"{print $2,$5,$6,$7}')
    if [[ "$t17" == "17 -10 263 -82" && "$t18" == "18 -26 263 -82" ]]; then
        echo "PASS  e1m2 train: *17 and *18 at their last corners"
    else
        echo "FAIL  e1m2 train: *17 at (${t17:-none}), *18 at (${t18:-none}); want 17 -10 263 -82 and 18 -26 263 -82"; rc=1
    fi
    # the silver key at (880,-300) on its floor at 424: taken, it is
    # PL_IT_KEY1 in pl_items and its target t122, door *49, opens
    run_frame "-lm -nostats -noai -at 880 -300 452 -yaw 0 -bench 400 -ticks 120" "$VBD_OUT/e1m2-key.bmp" e1m2.bsp
    it=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_items"{print $2}')
    d49=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$2==49 && $1 ~ /^door_/ {print $3}')
    if [[ $(( ${it:-0} & 8 )) == 8 && "${d49:-0}" != 0 ]]; then
        echo "PASS  e1m2 key: pl_items $it, door *49 state $d49"
    else
        echo "FAIL  e1m2 key: pl_items ${it:-none}, door *49 state ${d49:-none}; want the key bit and the door open"; rc=1
    fi
    # and the key doors *39/*40 without it: three seconds' walk at them
    # from (240,-140) stops at their face, py -215.97, both shut
    run_frame "-lm -nostats -noai -at 240 -140 333 -yaw 90 -walk -bench 400 -ticks 180" "$VBD_OUT/e1m2-keydoor.bmp" e1m2.bsp
    d39=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$2==39 && $1 ~ /^door_/ {print $3}')
    ky=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="py"{print $2}')
    if [[ "${d39:-1}" == 0 ]] && awk -v y="${ky:-0}" 'BEGIN{exit !(y < -210 && y > -220)}'; then
        echo "PASS  e1m2 keydoor: *39 shut, the walk stopped at py $ky"
    else
        echo "FAIL  e1m2 keydoor: *39 state ${d39:-none}, py ${ky:-none}; want shut and py near -216"; rc=1
    fi
    # the spike trap: standing in trigger_multiple *41 at (2000,-256) has
    # the shooter at (2120,-256) fire down the line every 0.8 s, 9 a hit
    run_frame "-lm -nostats -noai -at 2000 -256 355 -yaw 0 -bench 400 -ticks 150" "$VBD_OUT/e1m2-trap.bmp" e1m2.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    if [[ "${hp:-100}" -lt 100 ]]; then
        echo "PASS  e1m2 trap: health $hp, the spikes bit"
    else
        echo "FAIL  e1m2 trap: health ${hp:-none}; want under 100"; rc=1
    fi
    # the ogre at (1790,-146) facing +y: 146 units before it for six
    # seconds, the chainsaw or a grenade must have bitten -- it kills in
    # that time and the respawn reads 100, so a death counts too -- and
    # the kind-3 entity must be hunting (ent line: kind state hunting ...)
    run_frame "-lm -nostats -at 1790 0 340 -yaw 90 -bench 400 -ticks 360" "$VBD_OUT/e1m2-ogre.bmp" e1m2.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    og=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^ent[0-9]/ && $2 == 3 && $4 == -1' | wc -l | tr -d ' ')
    if [[ ( "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ) && "${og:-0}" -ge 1 ]]; then
        echo "PASS  e1m2 ogre: health $hp, deaths $deaths, $og ogre hunting"
    else
        echo "FAIL  e1m2 ogre: health ${hp:-none}, deaths ${deaths:-none}, ${og:-0} ogres hunting; want a bite and one"; rc=1
        tr -d '\r' < "$VBD_OUT/bench.txt" | grep '^ent[0-9]'
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
    exit $rc
fi

# e1m3: no soldier among its monsters (ogres, a demon, and kinds not yet
# ported), so the map is the one where a load gated on the soldier's
# model skips something -- mdl_ent() and nail() were sized inside that
# gate, and the first frame died in ubound( nail ), error 9 at line 0.
# The spawn frame against tools/ref/e1m3-spawn.bmp is the test.
if [[ "${1:-}" == "--e1m3" ]]; then
    build_exe
    [[ -f "$VBD_OUT/MAPS/e1m3/assets.zip" ]] || { echo "SKIP  e1m3: no MAPS/e1m3 in the build (needs the PAK)"; exit 0; }
    for f in assets.zip texr.raw texs.raw pal.raw e1m3.bsp; do cp "$VBD_OUT/MAPS/e1m3/$f" "$VBD_OUT/$f"; done
    rc=0
    run_frame "-lm -nostats -noai -bench 40 -ticks 60" "$VBD_OUT/e1m3-spawn.bmp" e1m3.bsp
    out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/e1m3-spawn.bmp" "$VBD_OUT/e1m3-spawn.bmp" | tail -1)
    if [[ "$out" == IDENTICAL* ]]; then echo "PASS  e1m3 spawn: $out"; else echo "FAIL  e1m3 spawn: $out"; rc=1; fi
    # the grenade launcher at (-408,-1800,88), fired at the ceiling (-pitch
    # 89 looks up) for four seconds: the five rockets it came with go, and
    # the grenades fall back and their blasts hurt
    run_frame "-lm -nostats -noai -at -408 -1800 88 -pitch 89 -fire -bench 400 -ticks 240" "$VBD_OUT/e1m3-gl.bmp" e1m3.bsp
    rk=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_rockets"{print $2}')
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    if [[ "${rk:-5}" -lt 5 && ( "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ) ]]; then
        echo "PASS  e1m3 gl: rockets $rk, health $hp, deaths $deaths"
    else
        echo "FAIL  e1m3 gl: rockets ${rk:-none}, health ${hp:-none}, deaths ${deaths:-none}; want under 5 and a blast felt"; rc=1
    fi
    # zombie: 92 units from the zombie at (800,-216), inside RANGE_MELEE so it looks
    # round; six seconds of its gibs
    run_frame "-lm -nostats -at 755 -296 -288 -yaw 299 -bench 400 -ticks 360" "$VBD_OUT/e1m3-zombie.bmp" e1m3.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    hunt=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^ent[0-9]/ && $2 == 5 && $4 == -1' | wc -l | tr -d ' ')
    if [[ ( "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ) && "${hunt:-0}" -ge 1 ]]; then
        echo "PASS  e1m3 zombie: health $hp, deaths $deaths, $hunt hunting"
    else
        echo "FAIL  e1m3 zombie: health ${hp:-none}, deaths ${deaths:-none}, ${hunt:-0} hunting; want a hit and one"; rc=1
    fi
    # wizard: 88 from the wizard at (8,-472), which flies over and fires its spikes
    run_frame "-lm -nostats -at 56 -400 -32 -yaw 124 -bench 400 -ticks 360" "$VBD_OUT/e1m3-wizard.bmp" e1m3.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    hunt=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^ent[0-9]/ && $2 == 6 && $4 == -1' | wc -l | tr -d ' ')
    if [[ ( "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ) && "${hunt:-0}" -ge 1 ]]; then
        echo "PASS  e1m3 wizard: health $hp, deaths $deaths, $hunt hunting"
    else
        echo "FAIL  e1m3 wizard: health ${hp:-none}, deaths ${deaths:-none}, ${hunt:-0} hunting; want a hit and one"; rc=1
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
    exit $rc
fi

# e1m4: knights, ogres and wizards, a train, 29 drips; the map that needed
# the leaf-face list out of the far heap. The spawn frame against
# tools/ref/e1m4-spawn.bmp.
if [[ "${1:-}" == "--e1m4" ]]; then
    build_exe
    [[ -f "$VBD_OUT/MAPS/e1m4/assets.zip" ]] || { echo "SKIP  e1m4: no MAPS/e1m4 in the build (needs the PAK)"; exit 0; }
    for f in assets.zip texr.raw texs.raw pal.raw e1m4.bsp; do cp "$VBD_OUT/MAPS/e1m4/$f" "$VBD_OUT/$f"; done
    rc=0
    run_frame "-lm -nostats -noai -bench 40 -ticks 60" "$VBD_OUT/e1m4-spawn.bmp" e1m4.bsp
    out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/e1m4-spawn.bmp" "$VBD_OUT/e1m4-spawn.bmp" | tail -1)
    if [[ "$out" == IDENTICAL* ]]; then echo "PASS  e1m4 spawn: $out"; else echo "FAIL  e1m4 spawn: $out"; rc=1; fi
    # the super nailgun at (704,1368,516), 4 above its floor, with fire held
    # a second from 540 (516 is inside hull 1): the first tick's shotgun,
    # its 30 nails and the spikes beside it, then two nails a shot at 0.2
    # from 0.5 -- 55 less three shots by tick 60. It fell to the room 192
    # below before pl_items_drop traced from the box point
    run_frame "-lm -nostats -noai -at 704 1368 540 -fire -bench 400 -ticks 60" "$VBD_OUT/e1m4-sng.bmp" e1m4.bsp
    wp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_weapon"{print $2}')
    nl=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_nails"{print $2}')
    if [[ "${wp:-0}" -eq 64 && "${nl:-0}" -eq 49 ]]; then
        echo "PASS  e1m4 sng: weapon $wp, nails $nl"
    else
        echo "FAIL  e1m4 sng: weapon ${wp:-none}, nails ${nl:-none}; want 64 and 49"; rc=1
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
    exit $rc
fi

# e1m5: knights, ogres, demons, a wizard and the shambler; the rocket
# launcher's first single-player map. The spawn frame against
# tools/ref/e1m5-spawn.bmp.
if [[ "${1:-}" == "--e1m5" ]]; then
    build_exe
    [[ -f "$VBD_OUT/MAPS/e1m5/assets.zip" ]] || { echo "SKIP  e1m5: no MAPS/e1m5 in the build (needs the PAK)"; exit 0; }
    for f in assets.zip texr.raw texs.raw pal.raw e1m5.bsp; do cp "$VBD_OUT/MAPS/e1m5/$f" "$VBD_OUT/$f"; done
    rc=0
    run_frame "-lm -nostats -noai -bench 40 -ticks 60" "$VBD_OUT/e1m5-spawn.bmp" e1m5.bsp
    out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/e1m5-spawn.bmp" "$VBD_OUT/e1m5-spawn.bmp" | tail -1)
    if [[ "$out" == IDENTICAL* ]]; then echo "PASS  e1m5 spawn: $out"; else echo "FAIL  e1m5 spawn: $out"; rc=1; fi
    # the shambler at (712,1908): 128 units before it, past the shut door *22
    # that hides it from farther off, facing it for six seconds: outside
    # RANGE_MELEE its lightning comes first, then it closes and smashes; a
    # hit must land and it must be hunting
    run_frame "-lm -nostats -at 712 1780 48 -yaw 270 -bench 400 -ticks 360" "$VBD_OUT/e1m5-sham.bmp" e1m5.bsp
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    hunt=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^ent[0-9]/ && $2 == 7 && $4 == -1' | wc -l | tr -d ' ')
    if [[ ( "${hp:-100}" -lt 100 || "${deaths:-0}" -gt 0 ) && "${hunt:-0}" -ge 1 ]]; then
        echo "PASS  e1m5 shambler: health $hp, deaths $deaths, $hunt hunting"
    else
        echo "FAIL  e1m5 shambler: health ${hp:-none}, deaths ${deaths:-none}, ${hunt:-0} hunting; want a hit and one"; rc=1
        tr -d '\r' < "$VBD_OUT/bench.txt" | grep '^ent[0-9]'
    fi
    # the rocket launcher at (-544,1368,128), on its floor, fired straight
    # down (-pitch -89) from 160 for a second: the first tick's shotgun,
    # the pickup, one rocket at 0.5 that stops on hull 1's floor at the
    # origin -- 118 halved for its owner, 59
    run_frame "-lm -nostats -noai -at -544 1368 160 -pitch -89 -fire -bench 400 -ticks 60" "$VBD_OUT/e1m5-rl.bmp" e1m5.bsp
    wp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_weapon"{print $2}')
    rk=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_rockets"{print $2}')
    hp=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_health"{print $2}')
    deaths=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_deaths"{print $2}')
    if [[ "${wp:-0}" -eq 128 && "${rk:-5}" -eq 4 && "${hp:-100}" -lt 100 && "${deaths:-0}" -eq 0 ]]; then
        echo "PASS  e1m5 rl: weapon $wp, rockets $rk, health $hp"
    else
        echo "FAIL  e1m5 rl: weapon ${wp:-none}, rockets ${rk:-none}, health ${hp:-none}, deaths ${deaths:-none}; want 128, 4, a blast felt and no death"; rc=1
    fi
    for f in assets.zip texr.raw texs.raw pal.raw; do cp "$ROOT/data/assets/$f" "$VBD_OUT/$f"; done   # the other gates' map back
    exit $rc
fi

# e1m6, e1m7 and e1m8: the shareware's last three, spawn frames against
# tools/ref/<map>-spawn.bmp. e1m7's Chthon is a trigger, unseen: the rune
# wakes him and the bolt kills him, see AGENTS. e1m8 is world.qc's sv_gravity
# 100: the spawn hangs 630 over its floor, -jump lands at -736 and goes
# 364 up by v^2/2g against 48 under 800, so at tick 400 the body is still
# 300 up. peak_z is the spawn, -104: it read 0 on any map under z 0
# before pl_init set it, and a jump there was unmeasurable.
# start is the hub: its episode gates ship hidden, as a runeless
# Quake never spawns them; the boss gate stays, gone only with all four
if [[ "${1:-}" == "--e1m6" || "${1:-}" == "--e1m7" || "${1:-}" == "--e1m8" || "${1:-}" == "--start" ]]; then
    m="${1#--}"
    build_exe
    [[ -f "$VBD_OUT/MAPS/$m/assets.zip" ]] || { echo "SKIP  $m: no MAPS/$m in the build (needs the PAK)"; exit 0; }
    for f in assets.zip texr.raw texs.raw pal.raw $m.bsp; do cp "$VBD_OUT/MAPS/$m/$f" "$VBD_OUT/$f"; done
    rc=0
    run_frame "-lm -nostats -noai -bench 40 -ticks 60" "$VBD_OUT/$m-spawn.bmp" $m.bsp
    out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/$m-spawn.bmp" "$VBD_OUT/$m-spawn.bmp" | tail -1)
    if [[ "$out" == IDENTICAL* ]]; then echo "PASS  $m spawn: $out"; else echo "FAIL  $m spawn: $out"; rc=1; fi
    if [[ "$m" == e1m8 ]]; then
        run_frame "-lm -nostats -noai -jump -bench 400 -ticks 400" "$VBD_OUT/e1m8-jump.bmp" e1m8.bsp
        pk=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="peak_z"{print int($2)}')
        pz=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pz"{print int($2)}')
        if [[ "${pz:-0}" -gt -600 && "${pk:-0}" -eq -104 ]]; then
            echo "PASS  e1m8 jump: pz $pz over the -736 floor, peak_z $pk the spawn"
        else
            echo "FAIL  e1m8 jump: pz ${pz:-none} peak_z ${pk:-none}; want pz over -600 (a jump under sv_gravity 100) and peak_z -104"; rc=1
        fi
        # the pentagram at (672,536,-712): standing on it starts its thirty seconds
        run_frame "-lm -nostats -noai -at 672 536 -712 -bench 400 -ticks 30" "$VBD_OUT/e1m8-pent.bmp" e1m8.bsp
        np=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1=="pl_pent_left"{print int($2)}')
        if [[ "${np:-0}" -ge 28 ]]; then
            echo "PASS  e1m8 pent: pl_pent_left $np, the pentagram was taken"
        else
            echo "FAIL  e1m8 pent: pl_pent_left ${np:-none}, the pentagram was not taken"; rc=1
        fi
    fi
    if [[ "$m" == start ]]; then
        # in *8, the episode 2 hall's trigger_onlyregistered: the shareware's
        # "For registered users only!" is in the frame, its door t2 shut
        run_frame "-lm -nostats -noai -at -160 2368 128 -yaw 270 -bench 40 -ticks 60" "$VBD_OUT/start-reg.bmp" start.bsp
        out=$(python3 "$ROOT/tools/imgdiff.py" "$ROOT/tools/ref/start-reg.bmp" "$VBD_OUT/start-reg.bmp" | tail -1)
        if [[ "$out" == IDENTICAL* ]]; then echo "PASS  start registered: $out"; else echo "FAIL  start registered: $out"; rc=1; fi
    fi
    if [[ "$m" == e1m6 ]]; then
        # misc_fireball: fifteen emitters, a ball each in 0..5 s and every 3..8
        # after, counted in the emitter's left: ten seconds must send some
        run_frame "-lm -nostats -noai -bench 2000 -ticks 600" "$VBD_OUT/e1m6-fire.bmp" e1m6.bsp
        nf=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^trig_[0-9]+$/ && $3==11 {s += $5} END {print s+0}')
        if [[ "${nf:-0}" -ge 15 ]]; then
            echo "PASS  e1m6 fireballs: $nf sent in ten seconds"
        else
            echo "FAIL  e1m6 fireballs: ${nf:-none} sent in ten seconds, want 15 or more"; rc=1
        fi
        # in *10, a once with delay 3 for the nine t5 stair doors: at a second
        # the trigger is spent and door *8 still shut; fired at once it would be opening
        run_frame "-lm -nostats -noai -at -256 1280 -100 -bench 40 -ticks 60" "$VBD_OUT/e1m6-delay.bmp" e1m6.bsp
        ts=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^trig_[0-9]+$/ && $2==10 {print $4}')
        ds=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^door_[0-9]+$/ && $2==8 {print $3}')
        if [[ "${ts:-0}" -eq 4 && "${ds:-1}" -eq 0 ]]; then
            echo "PASS  e1m6 delay: trigger *10 spent, door *8 still shut a second on"
        else
            echo "FAIL  e1m6 delay: trigger *10 state ${ts:-none} (want 4 DONE), door *8 state ${ds:-none} (want 0 SHUT)"; rc=1
        fi
    fi
    if [[ "$m" == e1m7 ]]; then
        # on the rune at (8,64,24): sigil_touch fires t4 and Chthon (kind 9) wakes to ARMED, 5
        run_frame "-lm -nostats -noai -at 8 64 24 -bench 40 -ticks 30" "$VBD_OUT/e1m7-rune.bmp" e1m7.bsp
        st=$(tr -d '\r' < "$VBD_OUT/bench.txt" | awk '$1 ~ /^trig_[0-9]+$/ && $3==9 {print $4}')
        if [[ "${st:-0}" -eq 5 ]]; then
            echo "PASS  e1m7 rune: Chthon woken, state $st"
        else
            echo "FAIL  e1m7 rune: Chthon's state ${st:-none}, want 5 (ARMED)"; rc=1
        fi
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
#
# They run from the oracle build, ORACLES=1 in its own directory: the
# production EXE links qglstub in their place and refuses the flags.
ORACLE_OUT="$VBD_OUT-oracle"
make -C "$ROOT" build BUILD="$ORACLE_OUT" ORACLES=1 > /tmp/check-oracle.log 2>&1 || {
    echo "ORACLE BUILD FAILED"; tail -20 /tmp/check-oracle.log; exit 1; }
for pair in "qglcheck:QGLCHK.LOG" "qgldiff:QGLDIFF.LOG" "qglarr:QGLARR.LOG"; do
    f="${pair%%:*}"
    log="$ORACLE_OUT/${pair##*:}"
    rm -f "$log"
    VBD_OUT="$ORACLE_OUT" QFLAGS="-$f" TIMEOUT=300 "$ROOT/tools/dosbox.sh" run > /dev/null 2>&1
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
