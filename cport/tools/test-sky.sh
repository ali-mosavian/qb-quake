#!/usr/bin/env bash
# The sky moves. Before d_sky.c a sky face was a wall wearing both halves
# of its texture squeezed into one cell, and two ticks of a camera looking
# straight up at e1m1's largest sky face drew one picture.
#
#   cport/tools/test-sky.sh <builddir>
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD="${1:?builddir}"
MAP=data/maps/e1m1/e1m1.qmp
fail=0

python3 - <<'EOF' || fail=1
import sys, zipfile
z = zipfile.ZipFile('data/maps/e1m1/assets.zip')
sky = z.read('sky.raw')
if len(sky) != 128 * 256:
    sys.exit(f"FAIL: e1m1 sky.raw is {len(sky)} bytes, want 32768")
if sky[128 * 128:].count(0) == 0:
    sys.exit("FAIL: e1m1's front layer has no clear texel")
if 'sky.raw' in zipfile.ZipFile('data/maps/e1m8/assets.zip').namelist():
    sys.exit("FAIL: e1m8 has no sky texture but ships sky.raw")
print("ok: sky.raw is two 128x128 layers, front clear where it should be")
EOF

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sky.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
frame() {   # ticks -> md5 of the frame looking up at face 335
    local d="$TMP/t$1"
    mkdir -p "$d"
    cp "$BUILD/QCPORT.EXE" "$MAP" data/stuff.ini "$d/"
    cport/tools/run.sh "$d" "e1m1.qmp -at 160 2824 180 -pitch 89 -ticks $1 -nostats -noai -nosound -noview -bench 4000 -lm" >/dev/null 2>&1
    md5 -q "$d/BENCH.BMP"
}
a="$(frame 60)"; b="$(frame 180)"
if [[ "$a" == "$b" ]]; then
    echo "FAIL: the sky drew the same frame at tick 60 and 180 ($a)" >&2
    fail=1
else
    echo "ok: the sky moved between tick 60 and 180"
fi
exit $fail
