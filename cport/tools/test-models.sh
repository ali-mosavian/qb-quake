#!/bin/bash
# Regression test: the map's monsters draw.
#
# Two things went wrong here and the first hid the second. d_draw_models
# passed `(BspVec3 *) &e->pos` -- world->mon is FAR, and a far-to-near
# cast drops the segment silently, so the frustum test read the box out
# of DS and rejected all ten monsters: 0 of 10 past the frustum with the
# soldier 100 units in front of the camera. And rdr.no_mdl was never
# assigned from args.no_mdl, so -nomdl drew the monsters too and the A/B
# that should have caught it reported IDENTICAL either way.
#
# Hence both assertions: mdl= says triangles were submitted, the frame
# against -nomdl says they reached the screen, and the -nomdl arm's
# mdl=0 is what keeps the second from being vacuous.
#
#   cport/tools/test-models.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-models.sh <build-dir>}"
MIN="${MIN:-100}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

run() { TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$@" >/dev/null 2>&1; }
mdl() { tr -d '\r' < "$OUT/cstep.txt" 2>/dev/null | sed -n 's/^frames=.* mdl=\([0-9]*\).*/\1/p' | head -1; }

# The soldier at (8,1520,-200) and the dog at (88,1520,-200), 100 units
# ahead of the camera: -yaw is the map's angle mirrored, so +y is 270.
AT="-at 88 1420 -190 -yaw 270 -ticks 4"
run "e1m1.qmp -nostats $AT"        || true
cp "$OUT/BENCH.BMP" "$OUT/mdl-on.bmp" 2>/dev/null || { echo "FAIL: no frame written" >&2; exit 1; }
on=$(mdl)
run "e1m1.qmp -nostats -nomdl $AT" || true
off=$(mdl)

diff_px=$(python3 - "$OUT/mdl-on.bmp" "$OUT/BENCH.BMP" <<'PY'
import sys
def px(p):
    d = open(p, "rb").read()
    return d[int.from_bytes(d[10:14], "little"):]
a, b = px(sys.argv[1]), px(sys.argv[2])
print(sum(1 for x, y in zip(a, b) if x != y))
PY
)

fail=0
if [[ "${on:-0}" -lt 1 ]]; then
    echo "FAIL: mdl=$on triangles submitted with two monsters in front of the camera" >&2
    fail=1
fi
if [[ "${off:-1}" -ne 0 ]]; then
    echo "FAIL: -nomdl still submitted mdl=$off triangles, so the frame A/B proves nothing" >&2
    fail=1
fi
if [[ ${diff_px:-0} -lt $MIN ]]; then
    echo "FAIL: the monsters put $diff_px pixels on screen, wanted at least $MIN" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: monsters draw -- mdl=$on tris, $diff_px pixels against -nomdl (mdl=$off)"
exit $fail
