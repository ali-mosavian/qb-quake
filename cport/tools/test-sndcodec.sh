#!/bin/bash
# Regression test: the mixer decodes bsc4/32n to the samples mksnd.py
# coded, and the container's stream is laid out the way the decoder
# reaches it.
#
# Why a checksum and not a counter: a decode that reads the high nibble
# for the low one, or divides by the wrong blocks-per-page, still fills
# the DMA ring on time with plausible-looking numbers. started, loops
# and under all stay right and the card plays noise. The only headless
# view of what it is actually handed is the samples themselves, so
# -sndsum walks every sound in the table through snd_fetch -- the paint's
# own decoder, not a copy of it -- and sums what comes out; this then
# asks mksnd.py what that sum should have been.
#
# The second arm is the layout the fetch depends on: 963 blocks to a 16K
# EMS page and a sound starting on a block, so no block straddles a page
# and one window reaches any of them. A sound may span as many pages as
# it likes -- snd_fetch returns short at a page's end and the caller
# comes back -- but a block may not.
#
#   cport/tools/test-sndcodec.sh build/cport-e1m1 [dm3ish]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:?usage: test-sndcodec.sh <build-dir> [map]}"
MAP="${2:-dm3ish}"
RUN="${RUN_SH:-$HERE/run.sh}"

[[ -f "$OUT/$MAP.qmp" ]] || { echo "SKIP: no $MAP.qmp in $OUT"; exit 0; }

log="$OUT/cstep.txt"
TIMEOUT="${TIMEOUT:-600}" "$RUN" "$OUT" "$MAP.qmp -nostats -sndsum -ticks 1" >/dev/null 2>&1
got=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^snd_sum=' | sed 's/.*=//')

python3 - "$ROOT" "$OUT/$MAP.qmp" "${got:-}" <<'PY'
import struct, sys
root, qmp, got = sys.argv[1:4]
sys.path.insert(0, f'{root}/tools')
import numpy as np
import qmapread
import mksnd

stream = qmapread.read(qmp, 'snd.bsc')
tab = np.frombuffer(qmapread.read(qmp, 'snddec.raw'), np.int8).reshape(mksnd.NSCALE, 1 << mksnd.BITS)
raw = qmapread.read(qmp, 'sndtab.raw')
count = struct.unpack_from('<h', raw, 0)[0]
rec = [struct.unpack_from('<ll', raw, 2 + 10 * i) for i in range(count)]   # (offset, length), then the loop's short

bad = []
# the blocks, read back the way snd_fetch reaches them: page b/963,
# offset (b%963)*17, and nothing of a block in the next page
npage = (len(stream) + mksnd.EMS_PAGE - 1) // mksnd.EMS_PAGE
blocks = []
for b in range(npage * mksnd.BLK_PER_PAGE):
    at = (b // mksnd.BLK_PER_PAGE) * mksnd.EMS_PAGE + (b % mksnd.BLK_PER_PAGE) * mksnd.BLK_BYTES
    if at + mksnd.BLK_BYTES > len(stream):
        break
    blocks.append(stream[at : at + mksnd.BLK_BYTES])
rec_arr = np.frombuffer(b''.join(blocks), np.uint8).reshape(-1, mksnd.BLK_BYTES)
# a code byte read as a scale is what a stream laid out any other way
# looks like from here, and it is worth saying so rather than raising
if int(rec_arr[:, 0].max()) >= mksnd.NSCALE:
    print(f'FAIL: a block reached at the page stride has scale {int(rec_arr[:, 0].max())} '
          f'-- the stream is not {mksnd.BLK_PER_PAGE} blocks to a page', file=sys.stderr)
    sys.exit(1)
samples = mksnd.bsc_decode(rec_arr[:, 0], rec_arr[:, 1:], tab).reshape(-1)

for i, (ofs, n) in enumerate(rec):
    if ofs % mksnd.BLK:
        bad.append(f'sound {i} starts at sample {ofs}, which is not a block')
    if ofs + n > len(samples):
        bad.append(f'sound {i} runs to {ofs + n} of {len(samples)} samples')

want = 0
for ofs, n in rec:
    for v in samples[ofs : ofs + n]:
        want = (want * 31 + (int(v) + 128)) & 0xFFFFFFFF
if not got:
    bad.append('the run printed no snd_sum -- did it reach snd_init?')
elif int(got, 16) != want:
    bad.append(f'the mixer decoded to {got}, mksnd.py to {want:08X}')

for b in bad:
    print('FAIL:', b, file=sys.stderr)
if not bad:
    print(f'ok: {count} sounds decode to mksnd.py\'s own samples ({got}), '
          f'{len(blocks):,} blocks, none across a page')
sys.exit(1 if bad else 0)
PY
