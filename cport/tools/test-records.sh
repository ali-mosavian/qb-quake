#!/bin/bash
# Regression test: every record in the map container is a whole number
# of the records cport declares, the count matches the map's own lumps,
# and counts.bin says what the .bsp's header says.
#
# What went wrong first: mkassets.py narrowed Leaf and Node from 22
# bytes to 16 (PackedBounds), Plane from 18 to 16 and Submodel from 64
# to 32, while cport/src/bsptypes.h still declared the wide ones.
# asset_load asked for 336 * 22 bytes of a 336 * 16 member and the run
# died in r_load_leaves with "leaves.pag: short read" -- several load
# marks after anything said which structure had drifted.
#
# The counts half is newer and guards a different thing: cport does not
# open the .bsp any more, so counts.bin and miptex.bin are the only
# statement of what the map holds. This is the second side of that --
# the SOURCE .bsp, which mkassets read and the runtime no longer does.
#
#   cport/tools/test-records.sh build/cport-qgl [dm3ish]
#
# The record sizes come from cport/src/bsptypes.h's own REC_* guards,
# which the compiler checks against sizeof in the same commit, so this
# side and the target side cannot disagree about what cport believes.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-records.sh <build-dir> [map]}"
MAP="${2:-dm3ish}"
HDR="${HDR:-$HERE/../src/bsptypes.h}"
BSP="${BSP:-$HERE/../../data/$MAP.bsp}"

python3 - "$OUT/$MAP.qmp" "$HDR" "$BSP" "$HERE/../.." <<'PY'
import re, struct, sys

qmp, hdr, bsp, root = sys.argv[1:5]
sys.path.insert(0, f'{root}/tools')
import qmapread

rec = {m.group(1): int(m.group(2))
       for m in re.finditer(r'#define\s+REC_(\w+)\s+(\d+)', open(hdr).read())}

# member -> (its lump index, the on-disk record size, cport's own record)
LUMPS = {
    'planes.bld':  (1,  20, 'PLANE'),
    'nodes.pag':   (5,  24, 'NODE'),
    'faces.pag':   (7,  20, 'FACE'),
    'clip.pag':    (9,   8, 'CLIPNODE'),
    'leaves.pag':  (10, 28, 'LEAF'),
    'models.bld':  (14, 64, 'SUBMODEL'),
}

head = open(bsp, 'rb').read(4 + 15 * 8)
lump = lambda i: struct.unpack_from('<ii', head, 4 + i * 8)

fail = []
have = qmapread.members(qmp)
for name, (idx, disk, key) in LUMPS.items():
    want = lump(idx)[1] // disk * rec[key]
    got = have[name][1]
    if got != want:
        fail.append(f'{name}: {got} bytes, cport asks for {want} '
                    f'({lump(idx)[1] // disk} x {rec[key]})')

# counts.bin against the .bsp the runtime no longer opens
names = 'faces verts edges ledges leaves planes nodes tex_infos clips textures face_lump_bytes models'.split()
got = dict(zip(names, struct.unpack('<11lh', qmapread.read(qmp, 'counts.bin'))))
want = {
    'faces': lump(7)[1] // 20,   'verts': lump(3)[1] // 12,
    'edges': lump(12)[1] // 4,   'ledges': lump(13)[1] // 4,
    'leaves': lump(10)[1] // 28, 'planes': lump(1)[1] // 20,
    'nodes': lump(5)[1] // 24,   'tex_infos': lump(6)[1] // 40,
    'clips': lump(9)[1] // 8,    'face_lump_bytes': lump(11)[1],
    'models': lump(14)[1] // 64,
    'textures': struct.unpack_from('<i', open(bsp, 'rb').read(lump(2)[0] + 4), lump(2)[0])[0],
}
for k, v in want.items():
    if got[k] != v:
        fail.append(f'counts.bin {k}: {got[k]}, the bsp says {v}')

# and miptex.bin: one 40-byte header per texture the map owns
n = have['miptex.bin'][1]
if n != want['textures'] * 40:
    fail.append(f"miptex.bin: {n} bytes, {want['textures']} textures want {want['textures'] * 40}")

for line in fail:
    print('FAIL:', line, file=sys.stderr)
sys.exit(1 if fail else 0)
PY
rc=$?
[[ $rc -eq 0 ]] && echo "ok: every $MAP.qmp record matches cport's own, and counts.bin matches the bsp"
exit $rc
