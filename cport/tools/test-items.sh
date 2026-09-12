#!/bin/bash
# Regression test: the pickups draw, and standing on one takes it.
#
# Two arms, because one assertion cannot fail both ways. The frame
# against -noitems says a box reached the screen at all -- an item
# loaded and never drawn, or drawn behind the world by a depth test
# that rejects everything, both read 0 here. The kit line says the
# touch happened: 26 items load on e1m1 and the one at (672,-40) is
# 20 shells, so the player starts with 25 and must end with 45.
#
#   cport/tools/test-items.sh build/cport-e1m1
#
# The map must be staged (e1m1.qmp, which is all of it); the test
# SKIPs rather than fails when it is not.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-items.sh <build-dir>}"
MIN="${MIN:-100}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() { TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$@" >/dev/null 2>&1; }

# The megahealth at (944,1008,-272), seen from 108 units short of it.
AT="-at 944 900 -240 -yaw 270 -ticks 4"
run "e1m1.qmp -nostats $AT"          || true
cp "$OUT/BENCH.BMP" "$OUT/items-on.bmp" 2>/dev/null || { echo "FAIL: no frame written" >&2; exit 1; }
run "e1m1.qmp -nostats -noitems $AT" || true

diff_px=$(python3 - "$OUT/items-on.bmp" "$OUT/BENCH.BMP" <<'PY'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
a, b = px(sys.argv[1]), px(sys.argv[2])
print(sum(1 for x, y in zip(a, b) if x != y))
PY
)

fail=0
if [[ ${diff_px:-0} -lt $MIN ]]; then
    echo "FAIL: the pickups put $diff_px pixels on screen, wanted at least $MIN" >&2
    fail=1
else
    echo "ok: the pickups draw -- $diff_px pixels against -noitems"
fi

# Standing on item 21, 20 shells at (672,-40): 25 + 20, and one gone.
run "e1m1.qmp -nostats -at 672 -40 80 -ticks 30" || true
kit=$(tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | grep -m1 '^fight=')
shells=$(sed -n 's/.*shells \([0-9]*\).*/\1/p' <<< "$kit")
took=$(sed -n 's/.*took \([0-9]*\).*/\1/p' <<< "$kit")

if [[ "${shells:-0}" -ne 45 || "${took:-0}" -lt 1 ]]; then
    echo "FAIL: standing on the 20-shell box gave [$kit], wanted shells 45 and took 1" >&2
    fail=1
else
    echo "ok: the shells were taken -- $kit"
fi

exit $fail
