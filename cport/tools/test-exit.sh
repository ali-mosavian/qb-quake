#!/bin/bash
# Regression test: the slipgate, the intermission, and the next map.
#
# What it is written against, each arm mutation-checked:
#
#   0. Nothing restored INT 8 or INT 9 on the way out. DOS does not do
#      it for a program that ends, so the SECOND run in a session
#      installed its timer over the first run's dead handler and
#      chained to it: the BIOS tick stopped advancing and
#      sys_time_init spun in its tick-edge wait for ever, two marks
#      into the load. Invisible while one run was the whole session,
#      and a changelevel is exactly a second run.
#   1. ENT_TRIG_EXIT had no case in ent_move_trigs at all -- a touch on
#      e1m1's changelevel volume did nothing, so the level never ended.
#      Without the case the run reads gs_state 1 and the camera stays
#      where it walked; with it, gs_state 4 at the map's own
#      info_intermission, (-112,704).
#   2. host_next_level writes NEXT.BAT, which run.sh calls: without it
#      the run ends at e1m1 and the second "start" never appears.
#   3. pl_carry_save/pl_carry_load carry the kit. The first leg runs
#      WITH the AI, so e1m1's soldiers take health off before the exit
#      -- a fresh kit is exactly 100, so a carry that does nothing is
#      visible. That is the whole reason this arm does not use -noai.
#
#   cport/tools/test-exit.sh build/cport-e1m1
#
# Needs e1m1.qmp AND e1m2.qmp staged; skips without either.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-exit.sh <build-dir>}"
RUN="${RUN_SH:-$HERE/run.sh}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }
[[ -f "$OUT/e1m2.qmp" ]] || { echo "SKIP: no e1m2.qmp in $OUT"; exit 0; }

log="$OUT/cstep.txt"
fail=0

# 0: a run after a run. dm3ish because it loads in seconds and this
# arm is about the machine the first run left behind, not the map.
QARGS2="dm3ish.qmp -nostats -noai -ticks 5" \
TIMEOUT="${TIMEOUT:-300}" "$RUN" "$OUT" "dm3ish.qmp -nostats -noai -ticks 5" >/dev/null 2>&1
runs=$(tr -d '\r' < "$log" 2>/dev/null | grep -c '^frames=')
if [[ "$runs" -lt 2 ]]; then
    echo "FAIL: $runs of 2 runs in one session reached a frame -- the ISRs were left installed" >&2
    fail=1
fi

# The slipgate is 32 units up, past the 18 a step climbs, so the walk
# jumps into it -- check.sh's own e1m1 arm, same viewpoint.
WALK="-at 1312 660 -200 -yaw 90 -walk -jump"

# 1: the intermission. No -fire, so nothing goes on from it.
TIMEOUT="${TIMEOUT:-600}" "$RUN" "$OUT" "e1m1.qmp -nostats -noai $WALK -ticks 240" >/dev/null 2>&1
gs=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^gs_state ' | awk '{print $2}')
pos=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^frames=' | sed 's/.*pos=//')
IFS=, read px py pz <<< "${pos:-0,0,0}"
if [[ "$gs" != "4" ]]; then
    echo "FAIL: walked into the slipgate and gs_state is ${gs:-none}, not 4 (GS_EXIT)" >&2
    fail=1
elif [[ $(( (px+112)*(px+112) + (pz-704)*(pz-704) )) -gt 400 ]]; then
    echo "FAIL: GS_EXIT but the camera is at $pos, not e1m1's intermission (-112,*,704)" >&2
    fail=1
fi

# 2 and 3: the changelevel, with the AI on so the carry has something
# to say. run.sh calls NEXT.BAT, so cstep.txt holds both legs.
TIMEOUT="${TIMEOUT:-1200}" "$RUN" "$OUT" "e1m1.qmp -nostats $WALK -fire -ticks 300" >/dev/null 2>&1
legs=$(tr -d '\r' < "$log" 2>/dev/null | grep -c '^start$')
if [[ "$legs" -lt 2 ]]; then
    echo "FAIL: the changelevel ran $legs map(s); NEXT.BAT should have started e1m2" >&2
    fail=1
else
    map2=$(tr -d '\r' < "$log" | grep '^gs_state ' | tail -1 | awk '{print $4}')
    [[ "$map2" == "e1m2.qmp" ]] || { echo "FAIL: the second leg ran ${map2:-nothing}, not e1m2.qmp" >&2; fail=1; }

    carry=$(tr -d '\r' < "$log" | grep -m1 '^carry ')
    [[ -n "$carry" ]] || { echo "FAIL: e1m2 was started without -carry" >&2; fail=1; }
    ch=$(echo "$carry" | awk '{print $3}')
    left=$(tr -d '\r' < "$log" | grep -m1 '^fight=' | sed 's/.*health \([0-9-]*\).*/\1/')
    if [[ -n "$ch" && "$ch" -ge 100 ]]; then
        echo "FAIL: e1m1 ended on $left health and e1m2 carried $ch -- a fresh kit, not the carry" >&2
        fail=1
    fi
    if [[ -n "$ch" && "$ch" -lt 50 ]]; then
        echo "FAIL: carried $ch health; SetChangeParms floors it at 50" >&2
        fail=1
    fi
fi

[[ $fail -eq 0 ]] && echo "ok: the slipgate ends the level, e1m2 follows, and $ch health went with it"
exit $fail
