#!/bin/bash
# Regression test: the map container holds the same bytes the five
# staged files did, and a container that is not one is refused by name.
#
# What went wrong, before there was a container: a map was the .bsp,
# assets.zip and three loose atlases, and nothing tied them to each
# other. e1m1's zip staged over dm3ish's atlases drew every texture as
# some other one and ran perfectly happily -- the offset table indexes
# whatever atlas is there, so there was no short read to notice. That
# cannot happen to one file, but only if the file is CHECKED: a reader
# that skips the magic reads a directory out of whatever it opened and
# fails somewhere else entirely.
#
#   cport/tools/test-qmap.sh build/cport-qgl [dm3ish]
#
# The first arm needs data/assets (mkassets' own output dir, where the
# zip and the loose atlases still land for the BASIC build).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:?usage: test-qmap.sh <build-dir> [map]}"
MAP="${2:-dm3ish}"
SRC="${SRC:-$ROOT/data/assets}"

fail=0

# 1. the same bytes, member for member, as the format it replaced
if [[ -f "$SRC/assets.zip" ]]; then
    python3 - "$OUT/$MAP.qmp" "$SRC" "$ROOT" <<'PY'
import sys, zipfile
qmp, src, root = sys.argv[1:4]
sys.path.insert(0, f'{root}/tools')
import qmapread

have = qmapread.members(qmp)
bad = []
with zipfile.ZipFile(f'{src}/assets.zip') as z:
    for name in z.namelist():
        if name not in have:
            bad.append(f'{name}: in the zip, not in the container')
        elif qmapread.read(qmp, name) != z.read(name):
            bad.append(f'{name}: differs from the zip')
for name in ('texr.raw', 'texs.raw', 'pal.raw'):
    if qmapread.read(qmp, name) != open(f'{src}/{name}', 'rb').read():
        bad.append(f'{name}: differs from the loose file')
for b in bad:
    print('FAIL:', b, file=sys.stderr)
print(f'  {len(have)} members checked')
sys.exit(1 if bad else 0)
PY
    [[ $? -eq 0 ]] || fail=1
else
    echo "SKIP: no $SRC/assets.zip to compare against"
fi

# 2. a file that is not a container is refused by name, not read anyway
tmp="$OUT/notamap.qmp"
python3 - "$OUT/$MAP.qmp" "$tmp" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[0:4] = b'QMAQ'          # one byte of the magic
open(sys.argv[2], 'wb').write(bytes(d))
PY
rm -f "$OUT/error.log"
TIMEOUT="${TIMEOUT:-120}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "notamap.qmp -nostats -ticks 2" >/dev/null 2>&1
said=""
[[ -f "$OUT/error.log" ]] && said=$(tr -d '\r' < "$OUT/error.log" | head -1)
rm -f "$tmp"
if [[ "$said" != *"not a map container"* ]]; then
    echo "FAIL: a corrupted container said [$said], wanted 'not a map container'" >&2
    fail=1
else
    echo "ok: a file that is not a container is refused -- $said"
fi

exit $fail
