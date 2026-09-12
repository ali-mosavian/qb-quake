#!/bin/bash
# Regression test: every record in assets.zip is a whole number of the
# records cport declares, and the count matches the map's own lumps.
#
# What went wrong: mkassets.py narrowed Leaf and Node from 22 bytes to
# 16 (PackedBounds), Plane from 18 to 16 and Submodel from 64 to 32,
# while cport/src/bsptypes.h still declared the wide ones. asset_load
# asked for 336 * 22 bytes of a 336 * 16 member and the run died in
# r_load_leaves with "assets.zip::leaves.pag: short read" -- several
# load marks after anything said which structure had drifted.
#
#   cport/tools/test-records.sh build/cport-qgl
#
# The sizes come from cport/src/bsptypes.h's own REC_* guards, which
# the compiler checks against sizeof in the same commit, so this side
# and the target side cannot disagree about what cport believes.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-records.sh <build-dir>}"
HDR="${HDR:-$HERE/../src/bsptypes.h}"

python3 - "$OUT" "$HDR" <<'PY'
import re, struct, sys, zipfile

out, hdr = sys.argv[1], sys.argv[2]
rec = {m.group(1): int(m.group(2))
       for m in re.finditer(r'#define\s+REC_(\w+)\s+(\d+)', open(hdr).read())}

# lump -> (its on-disk record size, the zip member, cport's own record)
LUMPS = {
    'planes.bld':  (1,  20, 'PLANE'),
    'nodes.pag':   (5,  24, 'NODE'),
    'faces.pag':   (7,  20, 'FACE'),
    'clip.pag':    (9,   8, 'CLIPNODE'),
    'leaves.pag':  (10, 28, 'LEAF'),
    'models.bld':  (14, 64, 'SUBMODEL'),
}

with open(f'{out}/dm3ish.bsp', 'rb') as f:
    head = f.read(4 + 15 * 8)
lump = lambda i: struct.unpack_from('<ii', head, 4 + i * 8)

fail = []
with zipfile.ZipFile(f'{out}/assets.zip') as z:
    for name, (idx, disk, key) in LUMPS.items():
        want = lump(idx)[1] // disk * rec[key]
        got = z.getinfo(name).file_size
        if got != want:
            fail.append(f'{name}: {got} bytes, cport asks for {want} '
                        f'({lump(idx)[1] // disk} x {rec[key]})')

for line in fail:
    print('FAIL:', line, file=sys.stderr)
sys.exit(1 if fail else 0)
PY
rc=$?
[[ $rc -eq 0 ]] && echo "ok: every assets.zip record matches cport's own"
exit $rc
