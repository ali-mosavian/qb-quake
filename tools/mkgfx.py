#!/usr/bin/env python3
"""mkgfx.py -- the status bar's pictures out of gfx.wad, as raw indices.

    tools/mkgfx.py PAK0.PAK out/

Emits, for screen.bas's scr_sbar_load:

    sbar.raw    SBAR, 320x24, top-down palette indices
    sbnum.raw   SB_CELLS cells of 24x24, each a flat run of 576 bytes, in
                the order below: the digits, the minus, the shells icon,
                the five faces from healthy to nearly dead

A qpic's 255 is transparent and is kept: the bar under the number slots
is textured and differs slot to slot, so screen.bas composes the cells'
opaque spans over a copy of the bar itself when a number changes.
"""

from __future__ import annotations

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdlview as mdl  # noqa: E402

CELLS = [*(f"NUM_{d}" for d in range(10)), "NUM_MINUS", "SB_SHELLS", "FACE1", "FACE2", "FACE3", "FACE4", "FACE5",
         "SB_ARMOR1", "SB_ARMOR2"]
CELL = 24


def wad_pics(wad: bytes) -> dict[str, tuple[int, int, bytes]]:
    n, diroff = struct.unpack_from("<ii", wad, 4)
    pics = {}
    for i in range(n):
        ent = wad[diroff + i * 32:diroff + i * 32 + 32]
        off, _, size, typ = struct.unpack_from("<iiiB", ent, 0)
        name = ent[16:32].split(b"\0", 1)[0].decode("latin-1").upper()
        if typ == 0x42:
            w, h = struct.unpack_from("<ii", wad, off)
            pics[name] = (w, h, wad[off + 8:off + 8 + w * h])
    return pics


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    pak, outdir = sys.argv[1:3]
    blob, entries = mdl.read_pak(pak)
    pics = wad_pics(mdl.pak_read(blob, entries, "gfx.wad"))
    w, h, bar = pics["SBAR"]
    assert (w, h) == (320, CELL), (w, h)
    cells = bytearray()
    for name in CELLS:
        cw, ch, px = pics[name]
        assert (cw, ch) == (CELL, CELL), (name, cw, ch)
        cells += px

    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "sbar.raw"), "wb").write(bar)
    open(os.path.join(outdir, "sbnum.raw"), "wb").write(bytes(cells))
    print(f"  sbar.raw       {len(bar):,} B   sbnum.raw  {len(CELLS)} cells, {len(cells):,} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
