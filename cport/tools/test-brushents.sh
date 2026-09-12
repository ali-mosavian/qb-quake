#!/bin/bash
# Regression test: a brush entity must reach the screen with the depth
# buffer ON.
#
# What went wrong: qglSfZClear takes the DESTINATION surface and follows
# its zsf to find the buffer. cport passed the depth surface itself,
# whose own zsf is null, so the routine returned at its guard and the
# depth buffer was never cleared for the life of the run. It held
# whatever its allocation left, every QGL_Z_TEST face failed against
# that, and the world still looked right because QGL_Z_SET writes
# without testing -- so the ONLY casualty was the one thing that tests:
# brush entities. Doors, lifts and trigger brushes drew nothing, on
# every map, and the frame was otherwise correct.
#
#   cport/tools/test-brushents.sh build/cport-e1m1 e1m1.qmp
#
# The viewpoint looks down e1m1's entry corridor at the first double
# door (submodels *1 and *2, 220 units ahead). Drawn, the two leaves
# cover about 2,100 of the 16,000 pixels; the bug drew 0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-brushents.sh <build-dir> [map]}"
MAP="${2:-e1m1.qmp}"
AT="${AT:--at 452 576 40 -yaw 180}"
MIN="${MIN:-500}"

# e1m1's double door is the one brush entity in this project that is
# unambiguously in shot: dm3ish's only drawable submodel is a func_plat
# that rests a full travel down its own shaft, where no viewpoint sees
# it at load.
[[ -f "$OUT/$MAP" ]] || { echo "SKIP: $OUT/$MAP not staged"; exit 0; }

shot() {
    TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "$MAP -lm -nostats $AT -bench 40 -ticks 30 $1" >/dev/null 2>&1
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame with '$1'" >&2; exit 1; }
    cp "$OUT/BENCH.BMP" "$OUT/be-$2.bmp"
}

shot ""         ents
shot "-noents"  noents

python3 - "$OUT/be-ents.bmp" "$OUT/be-noents.bmp" "$MIN" <<'PY'
import struct, sys

def pixels(path):
    d = open(path, 'rb').read()
    off, = struct.unpack_from('<I', d, 10)
    w, h = struct.unpack_from('<ii', d, 18)
    row = (w + 3) & ~3
    return [d[off + y*row : off + y*row + w] for y in range(abs(h))], w * abs(h)

a, n = pixels(sys.argv[1])
b, _ = pixels(sys.argv[2])
diff = sum(1 for ra, rb in zip(a, b) for x, y in zip(ra, rb) if x != y)
want = int(sys.argv[3])
print('%d of %d pixels come from brush entities' % (diff, n))
if diff < want:
    print('FAIL: brush entities put %d pixels on screen, wanted at least %d '
          '-- with the depth buffer unclearable they drew 0' % (diff, want),
          file=sys.stderr)
    sys.exit(1)
PY
rc=$?
[[ $rc -eq 0 ]] && echo "ok: brush entities draw with the depth buffer on"
exit $rc
