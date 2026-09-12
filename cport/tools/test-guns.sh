#!/bin/bash
# Regression test: the guns fire, what they hit takes it, and what is in
# flight keeps flying.
#
# Three arms, one per path through the fight:
#   shotgun -- hitscan pellets against a monster's box, the damage
#              landing per monster once all six are in.
#   nailgun -- the pickup puts it in hand, and the whole magazine
#              leaves. That last part is the projectile loop: only 24
#              spikes exist, so if nothing ever ended one, firing would
#              stop at 24 nails with 6 still in the belt.
#   barrel  -- a pellet against an exploding box, and its blast back on
#              the player: 160 less half of the 100 units is 110, which
#              kills outright.
#
# -noai throughout: a monster that walks turns every number here into a
# coin flip, and the point of each arm is the weapon, not the AI.
#
#   cport/tools/test-guns.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-guns.sh <build-dir>}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() { TIMEOUT="${TIMEOUT:-400}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$@" >/dev/null 2>&1; }
kit() { tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | grep -m1 '^fight='; }
fld() { sed -n "s/.* $1 \([0-9-]*\).*/\1/p" <<< "$2"; }

fail=0

# The dog at (88,1520,-200), 100 units ahead: 25 health against six
# pellets of four, and four shots of the 25 shells in 2 seconds.
run "e1m1.qmp -nostats -noai -at 88 1420 -190 -yaw 270 -fire -ticks 120"
k=$(kit)
if [[ "$(fld kills "$k")" -lt 1 || "$(fld shells "$k")" -ne 21 ]]; then
    echo "FAIL: two seconds of buckshot at a dog gave [$k], wanted a kill and 21 shells" >&2
    fail=1
fi

# Standing on the nailgun at (112,2352,16): weapon_touch puts it in hand
# with 30 nails, and 6.6 seconds at 0.2 s a nail empties it.
run "e1m1.qmp -nostats -noai -at 112 2352 16 -yaw 270 -fire -ticks 400"
k=$(kit)
items=$(fld items "$k")
if [[ $(( items & 4 )) -ne 4 || "$(fld nails "$k")" -ne 0 ]]; then
    echo "FAIL: the nailgun run gave [$k], wanted the nailgun in hand and 0 nails left" >&2
    fail=1
fi

# The exploding box at (72,2056,-208), shot from 100 units short of it.
run "e1m1.qmp -nostats -noai -at 72 1956 -208 -yaw 270 -fire -ticks 120"
k=$(kit)
if [[ "$(fld booms "$k")" -lt 1 || "$(fld health "$k")" -ge 100 ]]; then
    echo "FAIL: shooting the barrel gave [$k], wanted a boom and the blast felt" >&2
    fail=1
fi

# And a nail in the air is drawn. -nomdl and -noai leave the world the
# only other thing on screen, and it is identical in both arms, so every
# differing pixel is the nail. 14 ticks, because a nail at 1000 u/s is
# out of the room in a fraction of a second: by 20 it has hit the wall
# and there is nothing left to see.
NB="-noai -nomdl -at 112 2352 16 -yaw 270 -ticks 14"
run "e1m1.qmp -nostats $NB -fire"
cp "$OUT/BENCH.BMP" "$OUT/nail-on.bmp" 2>/dev/null || { echo "FAIL: no frame written" >&2; exit 1; }
run "e1m1.qmp -nostats $NB"
px=$(python3 - "$OUT/nail-on.bmp" "$OUT/BENCH.BMP" <<'PYEOF'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
a, b = px(sys.argv[1]), px(sys.argv[2])
print(sum(1 for x, y in zip(a, b) if x != y))
PYEOF
)
if [[ ${px:-0} -lt 20 ]]; then
    echo "FAIL: a nail in flight put $px pixels on screen, wanted at least 20" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: shotgun kills, the nailgun empties, the barrel goes off, the nail draws ($px px)"
exit $fail
