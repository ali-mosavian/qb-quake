#!/usr/bin/env python3
"""
sbref.py -- reference implementation of sb_build, in Python.

The surface builder is moving to assembly (uglBuildSurf). Assembly that is
"probably right" is worthless here: a one-texel addressing slip looks like
plausible lighting, which is exactly the class of bug that cost this project
a session already. So the maths gets written down once, in a language where
it can be read, and the assembly is required to reproduce it byte for byte.

This mirrors d_surf.bas's sb_build statement for statement -- deliberately
not idiomatic Python. Where it looks clumsy it is because BASIC does it that
way and the point is to match, not to be elegant.

  ./tools/sbref.py <face> <mip> [out.bmp]

Prints the surface's bytes and optionally writes it as an 8-bit BMP that can
be diffed against a dump from the target.
"""
import struct, sys, os

ASSETS = os.path.join(os.path.dirname(__file__), '..', 'data', 'assets')
BSP    = os.path.join(os.path.dirname(__file__), '..', 'data', 'dm3ish.bsp')


def asset_bytes(path):
    """A member out of assets.zip, or the loose file if one still exists."""
    name = os.path.basename(path)
    zp = os.path.join(os.path.dirname(path), 'assets.zip')
    if os.path.exists(zp):
        import zipfile
        with zipfile.ZipFile(zp) as z:
            return z.read(name)
    return open(path, 'rb').read()


def read_bmp8(path):
    d = asset_bytes(path)
    off = struct.unpack_from('<I', d, 10)[0]
    w, h = struct.unpack_from('<ii', d, 18)
    stride = (w + 3) & ~3
    px = bytearray(w * h)
    for y in range(h):                      # BMP rows are bottom-up
        s = off + (h - 1 - y) * stride
        px[y*w:(y+1)*w] = d[s:s+w]
    pal = [struct.unpack_from('<BBBB', d, 14+40+4*i)[:3] for i in range(256)]
    return w, h, bytes(px), [(r, g, b) for (b, g, r) in pal]


def bload(path):
    """Headerless since assets went into the zip."""
    return asset_bytes(path)


def atlas_cell(mi, mip, cell):
    """One texture cell out of the raw atlas.

    The cells are packed as flat cell*cell runs, not as windows on the
    8192-wide image: uglBuildSurf maps one page and then walks the cell
    with the VIEW's bps, which is the cell width. texofs.bld gives the
    byte offset of each (texture, mip)."""
    w, h, px, _ = read_bmp8(os.path.join(ASSETS, 'texr.bmp'))
    tbl = bload(os.path.join(ASSETS, 'texofs.bld'))
    ofs = struct.unpack_from('<i', tbl, (mi*4 + mip) * 4)[0]
    return px[ofs:ofs + cell*cell]


def face_record(face):
    """One lmface.bin record: 8 signed 16-bit fields.

    The first two are the face's place in the luxel atlas -- scanline, then
    byte offset within it. The scanline is signed so -1 can still mean the
    face is unlit."""
    d = open(os.path.join(ASSETS, 'lmface.bin'), 'rb').read()
    o = face * 16
    lm_y, lm_x, tmin_s, tmin_t, lm_w, lm_h, st01, st23 = \
        struct.unpack_from('<hHhhhhHH', d, o)
    return lm_y, lm_x, tmin_s, tmin_t, lm_w, lm_h


def miptex_of_face(face):
    """face -> texinfo -> miptex index, and that miptex's original size."""
    d = open(BSP, 'rb').read()
    # lump 7 is FACES and lump 6 is TEXINFO -- not the other way round
    fo, _ = struct.unpack_from('<ii', d, 4 + 8*7)
    texinfoid = struct.unpack_from('<h', d, fo + face*20 + 10)[0]
    to, _ = struct.unpack_from('<ii', d, 4 + 8*6)
    miptex = struct.unpack_from('<i', d, to + texinfoid*40 + 32)[0]
    mo, _ = struct.unpack_from('<ii', d, 4 + 8*2)
    off = struct.unpack_from('<i', d, mo + 4 + 4*miptex)[0]
    w, h = struct.unpack_from('<ii', d, mo + off + 16)
    return miptex, w, h


def pot2(v):
    p = 1
    while p < v:
        p <<= 1
    return p


def build(face, mip):
    lm_y, lm_x, tms, tmt, lmw, lmh = face_record(face)
    if lm_y < 0:
        raise SystemExit(f"face {face} has no lightmap")

    mi, origw, origh = miptex_of_face(face)
    cell = 64 >> mip
    aw, msk = cell, cell - 1

    tex = atlas_cell(mi, mip, cell)
    tw, th = cell, cell

    aw_, ah_, lm, _ = read_bmp8(os.path.join(ASSETS, 'lm.bmp'))
    cmap = bload(os.path.join(ASSETS, 'colmap.bld'))

    # The face's rect inside the atlas: raw luxel bytes, rows pot(lmw)
    # apart because the slot is padded to a power of two in each dimension
    # for alignment. No quantization, so no per-face ramp to rebuild.
    lofs = lm_y * aw_ + lm_x
    lstride = pot2(lmw)

    # surface dims: extents >> mip, padded to the size class
    def shift(v):
        s, p = 4, 16
        while p < v and s < 8:
            p *= 2; s += 1
        return s
    sw = max(1, ((lmw-1) * 16) >> mip)
    sh = max(1, ((lmh-1) * 16) >> mip)
    W, H = 1 << shift(sw), 1 << shift(sh)

    # atlas texels per surface texel, 16.16 -- wdth is 1/origW already
    du = int(aw * 65536.0 * (1.0/origw)) * (1 << mip)
    dv = int(aw * 65536.0 * (1.0/origh)) * (1 << mip)
    stp = 16 >> mip

    out = bytearray(W * H)
    av = tmt * (dv >> mip)
    for y in range(H):
        ay = (av >> 16) & msk
        ly = min(max(y // stp, 0), lmh-2)
        ty = min(((y - ly*stp) << 16) // stp, 65536)

        au = tms * (du >> mip)
        for x in range(W):
            ax = (au >> 16) & msk
            texel = tex[ay*cell + ax]

            lx = min(max(x // stp, 0), lmw-2)
            tx = min(((x - lx*stp) << 16) // stp, 65536)

            def luxel(gx, gy):
                return lm[lofs + gy*lstride + gx]

            l00, l10 = luxel(lx, ly),   luxel(lx+1, ly)
            l01, l11 = luxel(lx, ly+1), luxel(lx+1, ly+1)

            # Quake's shape, and the builder's: light -> t is affine, so
            # convert at the four CORNERS and interpolate t, NOT the light
            # level. The two are equal in exact arithmetic but not in these
            # integers -- the intermediate truncations fall differently, and
            # the floor at 64 applies per corner rather than once at the end.
            # Interpolating light here disagreed with the target by one
            # colormap row on ~3% of texels.
            #
            # Down the row first, then across the span: the builder's order,
            # and uglsurf.asm's sf$tacc/sf$tstep accumulate exactly this way.
            t00 = max(16320 - l00*66, 64)
            t10 = max(16320 - l10*66, 64)
            t01 = max(16320 - l01*66, 64)
            t11 = max(16320 - l11*66, 64)

            # >> on a negative int floors in Python, which is exactly what
            # the builder's Flr& does and what the asm's arithmetic shift
            # does. A truncating divide here would round the wrong way.
            tleft  = t00 + (((t01 - t00) * ty) >> 16)
            tright = t10 + (((t11 - t10) * ty) >> 16)

            kk = x - lx*stp
            if kk >= stp:
                # the tail: tx caps at 65536, landing exactly on tright
                t = tright
            else:
                tstep = (tright - tleft) * (65536 // stp)
                t = (tleft*65536 + kk*tstep) >> 16
            if t < 64: t = 64
            row = min(t // 256, 63)

            out[y*W + x] = cmap[row*256 + texel]
            au += du
        av += dv
    return W, H, bytes(out)


def write_bmp8(path, w, h, px):
    stride = (w + 3) & ~3
    body = bytearray()
    for y in range(h-1, -1, -1):
        body += px[y*w:(y+1)*w] + bytes(stride - w)
    pal = bytearray()
    for i in range(256):
        pal += bytes((i, i, i, 0))
    off = 14 + 40 + 1024
    open(path, 'wb').write(
        b'BM' + struct.pack('<IHHI', off+len(body), 0, 0, off) +
        struct.pack('<IiiHHIIiiII', 40, w, h, 1, 8, 0, len(body),
                    2835, 2835, 256, 256) + pal + body)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    face, mip = int(sys.argv[1]), int(sys.argv[2])
    W, H, px = build(face, mip)
    print(f"face {face} mip {mip}: surface {W}x{H}")
    print("first row:", ' '.join(f'{b:3d}' for b in px[:min(W, 24)]))
    if len(sys.argv) > 3:
        write_bmp8(sys.argv[3], W, H, px)
        print("wrote", sys.argv[3])
