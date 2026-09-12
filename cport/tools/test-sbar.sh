#!/bin/bash
# Regression test: the status bar covers the bottom of the view and
# shows the player's own numbers, and death brings them back.
#
# The bar is 24 rows of 320 scaled to the render target's width, so on
# a 160x100 frame it is the bottom 12 rows and nothing of the world
# shows through them. That gives two assertions that fail for different
# reasons:
#   covered -- those rows are identical with the monsters drawn and with
#              -nomdl, though the dog stands right there in the view.
#              Without the bar the band IS the view and they differ.
#   painted -- they differ between a run at 100 health and one that shot
#              the barrel and took the blast. A bar that loads and blits
#              but never repaints passes the first and fails this.
# Then the death arm: dying must respawn, not leave the player at zero.
#
#   cport/tools/test-sbar.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-sbar.sh <build-dir>}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() { TIMEOUT="${TIMEOUT:-400}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$@" >/dev/null 2>&1; }

# differing pixels in the bottom BAND rows of two 160x100 frames
band() {
python3 - "$1" "$2" <<'PYEOF'
import sys
W, H, BAND = 160, 100, 12
def rows(p):
    d = open(p, "rb").read()
    px = d[int.from_bytes(d[10:14], "little"):]
    # BMP rows are bottom-up, so the bar is the FIRST BAND rows stored
    return px[:W * BAND]
a, b = rows(sys.argv[1]), rows(sys.argv[2])
print(sum(1 for x, y in zip(a, b) if x != y))
PYEOF
}

fail=0
# 50 units from the dog, not 100: at 100 it draws nowhere near the
# bottom twelve rows and the covered assertion has nothing to catch --
# measured, the no-bar mutant moved 0 pixels there. At 50 it moves 310.
AT="-noai -at 88 1470 -190 -yaw 270 -ticks 20"

run "e1m1.qmp -nostats $AT"
cp "$OUT/BENCH.BMP" "$OUT/sbar-a.bmp" 2>/dev/null || { echo "FAIL: no frame written" >&2; exit 1; }
run "e1m1.qmp -nostats $AT -nomdl"
n=$(band "$OUT/sbar-a.bmp" "$OUT/BENCH.BMP")
if [[ ${n:-1} -ne 0 ]]; then
    echo "FAIL: $n pixels of the bar band changed when the monsters did -- the view is showing through" >&2
    fail=1
fi

# The barrel at (72,2056,-208), shot from 200 units: 160 less half the
# distance is 60, so the player lives at 40 and the digits change.
BAT="-noai -at 72 1856 -208 -yaw 270 -ticks 120"
run "e1m1.qmp -nostats $BAT -fire"
cp "$OUT/BENCH.BMP" "$OUT/sbar-b.bmp" 2>/dev/null || true
run "e1m1.qmp -nostats $BAT"
n=$(band "$OUT/sbar-b.bmp" "$OUT/BENCH.BMP")
if [[ ${n:-0} -lt 20 ]]; then
    echo "FAIL: the bar band moved $n pixels between full health and hurt; it is not repainting" >&2
    fail=1
fi

# Thirty seconds in the open on e1m1 kills the player, and the respawn
# has to put them back on their feet rather than leave them at zero.
run "e1m1.qmp -nostats -at 88 1420 -190 -yaw 270 -ticks 600"
k=$(tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | grep -m1 '^fight=')
d=$(sed -n 's/.* deaths \([0-9-]*\).*/\1/p' <<< "$k")
hp=$(sed -n 's/^fight=health \([0-9-]*\).*/\1/p' <<< "$k")
if [[ "${d:-0}" -lt 1 || "${hp:-0}" -le 0 ]]; then
    echo "FAIL: [$k] -- wanted at least one death and a live player after it" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: the bar covers and repaints, and death respawns ($d deaths, health $hp)"
exit $fail
