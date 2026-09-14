#!/bin/bash
# Regression test: a brush whose entity the skill removes is not there.
#
# What went wrong: mkassets skipped a NOT_EASY entity before reading its
# model, so nothing hid the brush. e1m3's trigger_once *67 (spawnflags
# 256) stood across the corridor at y -1575..-1569 as a solid wall of the
# "trigger" texture, and walking into it stopped the player.
#
#   cport/tools/test-skillhide.sh build/cport-e1m3 [e1m3.qmp]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-skillhide.sh <build-dir> [map]}"
MAP="${2:-e1m3.qmp}"
[[ -f "$OUT/$MAP" ]] || { echo "SKIP: $OUT/$MAP not staged"; exit 0; }

TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
    "$MAP -nostats -noai -nosound -at -194 -1724 112 -yaw 275 -walk -ticks 120" >/dev/null 2>&1

# pos is x, up, bsp y
final=$(tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | grep -m1 '^frames=' | sed 's/.*pos=//')
[[ -n "$final" ]] || { echo "FAIL: no pos in $OUT/cstep.txt" >&2; exit 1; }
IFS=, read fx fup fy <<< "$final"
if [[ ${fy%.*} -lt -1560 ]]; then
    echo "FAIL: stopped at bsp y $fy, short of the hidden trigger at -1575..-1569" >&2
    exit 1
fi
echo "ok: walked through the NOT_EASY trigger to bsp y $fy"
