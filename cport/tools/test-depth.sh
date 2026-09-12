#!/bin/bash
# Regression test: a viewpoint that sees a brush entity must still draw
# the world with the depth buffer on.
#
# What went wrong: qglSfZMode returns the mode it REPLACED, and
# d_draw_faces assigned that return to its own z_have. So after an
# entity face switched the mode to Z_TEST, z_have still read 1 (Z_SET)
# and the next world face matched it, skipped the call, and was drawn
# test-only against a depth buffer nothing had written that frame.
# Everything after the first entity was rejected.
#
# It looked like an angle: turn until the func_plat comes into view and
# the whole screen goes black, turn back and it returns. 242 polygons
# and 41 leaves were being submitted the whole time, so nothing in the
# culling counters moved -- and -noz drew the frame perfectly, which is
# what named the depth path.
#
# 1,655 non-black pixels of 16,000 before (the HUD bar alone), 15,998
# after, same viewpoint.
#
#   cport/tools/test-depth.sh build/cport-qgl
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-depth.sh <build-dir>}"

# dm3ish's func_plat is in view from here; the spawn is not a test,
# because no entity is drawn there and the mode never switches.
TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
    "dm3ish.qmp -at 231 -37 184 -yaw 196 -ticks 4" >/dev/null 2>&1

read -r lit total <<< "$(python3 - "$OUT/BENCH.BMP" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
px = d[int.from_bytes(d[10:14], "little"):]
print(sum(1 for b in px if b), len(px))
PY
)"

if [[ -z "${total:-}" || $total -eq 0 ]]; then
    echo "FAIL: no frame written" >&2; exit 1
fi
if [[ $(( lit * 2 )) -lt $total ]]; then
    echo "FAIL: $lit of $total pixels drawn -- the world is missing behind the overlay" >&2
    exit 1
fi
echo "ok: $lit of $total pixels drawn with the depth buffer on"
