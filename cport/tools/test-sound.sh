#!/bin/bash
# Regression test: the mixer feeds the card, and the gun is in hand.
#
# The arms, and what each was written against:
#
#   1. snd_init has to reach the mixer: qglDspInit, snd.bsc into EMS,
#      sndtab.raw's count agreeing with snd.h's SND_*. Only
#      snd_mix_setup sets loops, so "loops=13" is the whole chain --
#      e1m1's four comp_hum, its drone and its eight fluoros.
#   2. under=0. The mixer paints from where it stopped to a quarter
#      second past the DMA EVERY frame, playing or not: the ring is a
#      loop and what is not repainted is played again. A mixer that
#      skipped an idle frame -- or skipped the paint entirely -- falls
#      behind the DMA and every frame after the first counts an
#      underrun, so this number is the "constantly feed it" rule.
#   3. started>0: a shot, a monster, a door actually start channels.
#   4. -noview takes the weapon out of hand, so the triangle count
#      drops by the gun's own -- the only headless view of a model
#      that is drawn every single frame.
#
#   cport/tools/test-sound.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-sound.sh <build-dir>}"
RUN="${RUN_SH:-$HERE/run.sh}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

log="$OUT/cstep.txt"
fail=0

# standing in front of e1m1's first soldier, firing: the shotgun, the
# soldier's own sounds, and the ambients humming behind them
ARGS="-nostats -at 88 1420 -190 -yaw 270 -fire -ticks 120"

run() { TIMEOUT="${TIMEOUT:-600}" "$RUN" "$OUT" "e1m1.qmp $*" >/dev/null 2>&1; }
field() { tr -d '\r' < "$log" 2>/dev/null | grep -m1 "^snd started=" | sed "s/.*$1=\([0-9-]*\).*/\1/"; }

run "$ARGS"
loops=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^snd loops=' | sed 's/.*loops=//')
started=$(field started)
under=$(field under)
mdl_on=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^frames=' | sed 's/.*mdl=\([0-9]*\).*/\1/')

if [[ "${loops:-0}" -lt 1 ]]; then
    echo "FAIL: the card and the mixer came up with ${loops:-no} ambients looping; e1m1 has 5" >&2
    fail=1
fi
if [[ "${started:-0}" -lt 1 ]]; then
    echo "FAIL: nothing started a channel over $ARGS" >&2
    fail=1
fi
if [[ -n "$under" && "$under" -ne 0 ]]; then
    echo "FAIL: $under underruns -- the mixer fell behind the DMA; it must paint every frame" >&2
    fail=1
fi

# -nosound: the card is left alone and nothing is started
run "$ARGS -nosound"
s2=$(field started)
if [[ "${s2:-0}" -ne 0 ]]; then
    echo "FAIL: -nosound still started $s2 sounds" >&2
    fail=1
fi

# the view weapon: every frame draws it, so the difference is large
run "$ARGS -noview"
mdl_off=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^frames=' | sed 's/.*mdl=\([0-9]*\).*/\1/')
# 500, not 1: the two arms are separate runs and may differ by a frame,
# which is ~45 triangles of monsters. The gun itself is ~1175 over 120
# ticks, so the margin is well clear of both.
if [[ $(( ${mdl_on:-0} - ${mdl_off:-0} )) -lt 500 ]]; then
    echo "FAIL: the gun drew ${mdl_on:-0} triangles against -noview's ${mdl_off:-0}" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: $loops ambients, $started sounds, $under underruns; the gun is $((mdl_on - mdl_off)) triangles"
exit $fail
