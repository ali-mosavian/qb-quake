#!/usr/bin/env python3
"""mkfont.py -- convert a packed 1bpp .fnt out of a PACK archive to qgl's own.

    tools/mkfont.py data/base.dat font/4x6.fnt out/font.fnt

The source is already 1bpp and already the right size -- 4 bytes of id then
8 bytes a glyph, 256 glyphs, 2,052 bytes. What it is NOT is usable: the
renderer expands it at load into 256 separate 8x8 DCs (screen.bas's
uglNewMult), which a live MCB walk measured at 16,400 bytes of conventional
memory for 2,048 bytes of pixels.

So this changes the container, not the pixels. What it adds is a header, so
the target does not have to know the cell size by convention, and room for a
per-glyph advance table so text can be proportional later without another
format.

The source's bit order is the awkward part and it is not this format's:
four 16-bit words a glyph, bit index y*8+x, word = bit//16, and the mask is
1 << (15 - (bit and 15)) -- MSB-first inside each little-endian word. Here a
row is one byte per 8 pixels, MSB leftmost, which is what a shift-and-test
inner loop wants.
"""

from __future__ import annotations

import os
import struct
import sys

MAGIC = b"FNT1"
HDR = 20


def pack_read(path: str, want: str) -> bytes:
    d = open(path, "rb").read()
    magic, dirofs, dirlen = struct.unpack_from("<4sii", d, 0)
    if magic != b"PACK":
        raise SystemExit(f"{path} is not a PACK archive")
    for i in range(dirlen // 64):
        e = dirofs + 64 * i
        name = d[e : e + 56].split(b"\0")[0].decode("latin-1")
        off, ln = struct.unpack_from("<ii", d, e + 56)
        if name == want:
            return d[off : off + ln]
    raise SystemExit(f"{want} not found in {path}")


def decode_glyph(raw: bytes) -> list[list[int]]:
    """One 8x8 glyph, source bit order, as rows of 0/1."""
    words = struct.unpack("<4H", raw)
    rows = []
    for y in range(8):
        row = []
        for x in range(8):
            bit = y * 8 + x
            row.append(1 if words[bit // 16] & (1 << (15 - (bit & 15))) else 0)
        rows.append(row)
    return rows


def ink_width(rows: list[list[int]]) -> int:
    """Rightmost lit column, +1. Zero for a blank glyph."""
    return max((x + 1 for row in rows for x, b in enumerate(row) if b), default=0)


def convert(src: bytes, adv: int, proportional: bool) -> bytes:
    if src[:4] != b"font":
        raise SystemExit(f"expected a 'font' id, got {src[:4]!r}")
    body = src[4:]
    count = len(body) // 8
    if count * 8 != len(body):
        raise SystemExit(f"{len(body)} bytes is not a whole number of 8-byte glyphs")

    glyphs = [decode_glyph(body[i * 8 : i * 8 + 8]) for i in range(count)]

    bits = bytearray()
    for rows in glyphs:
        for row in rows:
            b = 0
            for x, on in enumerate(row):
                if on:
                    b |= 0x80 >> x
            bits.append(b)

    advs = b""
    flags = 0
    if proportional:
        flags |= 1
        # one blank column after the ink; a space still has to advance
        advs = bytes(min(255, ink_width(r) + 1) or adv for r in glyphs)

    # Laid out so the file IS the target's struct, magic included -- the
    # loader validates and uses it in place, with no fixup pass. That is
    # also why the two offsets are written here: this end knows them.
    adv_ofs = HDR if proportional else 0
    bits_ofs = HDR + len(advs)
    hdr = struct.pack(
        "<4sBBBBBBHHHHH",
        MAGIC,
        8,              # cell width
        8,              # cell height
        1,              # rowbytes = (w+7)>>3
        flags,
        adv,            # default advance, used when there is no table
        0,              # pad
        0,              # first codepoint
        count,
        bits_ofs,
        adv_ofs,
        0,              # pad
    )
    assert len(hdr) == HDR, len(hdr)
    return hdr + advs + bytes(bits)


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        sys.exit(__doc__)
    pack, member, out = argv[1], argv[2], argv[3]
    adv = int(argv[4]) if len(argv) > 4 else 4
    proportional = "--proportional" in argv

    src = pack_read(pack, member)
    blob = convert(src, adv, proportional)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "wb").write(blob)

    kind = "proportional" if proportional else f"fixed advance {adv}"
    print(f"{out}: {len(blob)} bytes, {kind}")
    print(f"  was {len(src)} on disk and 16,400 in conventional memory as DCs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
