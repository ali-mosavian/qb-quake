#!/bin/bash
# Regression test: the monsters think, walk and fight.
#
# Three assertions, because each fails on its own: `hunting` says
# FindTarget saw the player through hull 1, `moved` says the compass
# search and SV_movestep actually carried them off their spawn, and the
# health says an attack landed. A monster that hunts but cannot step,
# or steps but never notices anyone, passes two of the three.
#
# The -noai arm is not decoration: it is what says the first arm's
# numbers came from the AI and not from the map loader dropping
# monsters to the floor, and it keeps the image gates that pass -noai
# honest.
#
#   cport/tools/test-ai.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-ai.sh <build-dir>}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

# 100 units in front of the dog at (88,1520,-200) and the soldier beside
# it: 30 seconds of think at 10 Hz.
AT="-at 88 1420 -190 -yaw 270 -ticks 300"
run() { TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$@" >/dev/null 2>&1; }
val() { tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | sed -n "s/.*$1=\([0-9-]*\).*/\1/p" | head -1; }
# the kit line spells its fields "health 23", not "health=23"
hp()  { tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | sed -n 's/^fight=health \([0-9-]*\).*/\1/p' | head -1; }

run "e1m1.qmp -nostats $AT"
on_hunt=$(val hunting); on_moved=$(val moved); on_hp=$(hp)
run "e1m1.qmp -nostats -noai $AT"
off_hunt=$(val hunting); off_moved=$(val moved); off_hp=$(hp)

fail=0
if [[ "${on_hunt:-0}" -lt 1 ]]; then
    echo "FAIL: nothing hunted the player standing 100 units away (hunting=$on_hunt)" >&2
    fail=1
fi
# 4, not 1: a dog that leaps moves without stepping at all, so a
# threshold of one passes with every SV_movestep refused (measured --
# that mutant read moved=1). A working walk reads 9 of 10 here.
if [[ "${on_moved:-0}" -lt 4 ]]; then
    echo "FAIL: only $on_moved monsters left their spawn in 30 s; the walk is refused" >&2
    fail=1
fi
if [[ "${on_hp:-100}" -ge 100 ]]; then
    echo "FAIL: 30 s beside a dog and a soldier cost no health (health=$on_hp)" >&2
    fail=1
fi
if [[ "${off_hunt:-1}" -ne 0 || "${off_moved:-1}" -ne 0 || "${off_hp:-0}" -ne 100 ]]; then
    echo "FAIL: -noai still thought -- hunting=$off_hunt moved=$off_moved health=$off_hp" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: AI on hunting=$on_hunt moved=$on_moved health=$on_hp; -noai still 100"
exit $fail
