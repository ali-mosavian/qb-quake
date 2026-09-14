#!/bin/bash
# Regression test: a world face drawn after a brush entity must not paint
# over it.
#
# Brush entities were inserted into the world's back-to-front walk, and
# world faces draw QGL_Z_SET -- write, no test. Across e1m1's plunger pit
# the button column's faces below the platform's top came later in the
# walk than the platform (*3) and covered it: the column's lower centre
# matched the -noents frame on every pixel, where the platform belongs.
#
#   cport/tools/test-brushdepth.sh build/cport-ls
#
# Needs e1m1.qmp staged; SKIPs without one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-brushdepth.sh <build-dir>}"
MIN="${MIN:-300}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

shot() {  # <name> <args>
    rm -f "$OUT/BENCH.BMP"
    TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "e1m1.qmp -lm -nostats -noai -nosound -bench 4000 -ticks 30 -at 96 569 24 -yaw 177 $2" >/dev/null 2>&1
    cp "$OUT/BENCH.BMP" "$OUT/bd-$1.bmp" 2>/dev/null || { echo "FAIL: $1 wrote no frame" >&2; exit 1; }
}

shot ents   ""
shot noents "-noents"

python3 - "$OUT/bd-ents.bmp" "$OUT/bd-noents.bmp" "$MIN" <<'PY'
import struct, sys

def rows(path):
    d = open(path, "rb").read()
    off, = struct.unpack_from("<I", d, 10)
    w, h = struct.unpack_from("<ii", d, 18)
    stride = (w + 3) & ~3
    r = [d[off + y * stride : off + y * stride + w] for y in range(abs(h))]
    return r[::-1] if h > 0 else r

a, b = rows(sys.argv[1]), rows(sys.argv[2])
want = int(sys.argv[3])
# the column's lower centre, where the platform's top covers it
diff = sum(1 for y in range(60, 88) for x in range(72, 100) if a[y][x] != b[y][x])
print("%d of 784 pixels of the column's foot are the platform's" % diff)
if diff < want:
    print("FAIL: wanted at least %d -- the column drawn over the platform gave 0" % want, file=sys.stderr)
    sys.exit(1)
PY
rc=$?
[[ $rc -eq 0 ]] && echo "ok: the platform covers the column's foot"
exit $rc
