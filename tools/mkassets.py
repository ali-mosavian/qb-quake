#!/usr/bin/env python3
"""
mkassets.py -- turn a Quake .bsp's texture lump into ready-to-blit 8-bit BMPs.

texLoadAll does this work at every launch, in BASIC: it reads the miptex data
a byte at a time, expands palette indices to RGB, bilinearly resamples each
mip to a fixed size, and then searches all 256 palette entries per output texel
to get back to an index. For dm3ish that is 150,960 single-byte file reads,
108,800 output texels and 27,852,800 palette-search iterations.

All of it is a pure function of the .bsp and the palette, so none of it needs
to happen on the target. This emits one atlas BMP per mip level, already in the
game palette, which uGL's own assembly BMP loader can pull in directly.
"""
import struct, sys, os

MIPS   = 4
SIZES  = [64, 32, 16, 8]        # what the renderer wants, per mip level

def read_lumps(d):
    return [struct.unpack_from('<ii', d, 4 + 8*i) for i in range(15)]

def pack_read(path, want):
    """Pull one file out of a Quake PACK archive (base.dat is one)."""
    d = open(path, 'rb').read()
    magic, dirofs, dirlen = struct.unpack_from('<4sii', d, 0)
    if magic != b'PACK':
        raise SystemExit(f"{path} is not a PACK archive")
    for i in range(dirlen // 64):
        e    = dirofs + 64*i
        name = d[e:e+56].split(b'\0')[0].decode('latin-1')
        off, ln = struct.unpack_from('<ii', d, e+56)
        if name == want:
            return d[off:off+ln]
    raise SystemExit(f"{want} not found in {path}")

def load_palette(raw):
    if len(raw) < 768:
        raise SystemExit(f"palette is {len(raw)} bytes, expected >= 768")
    return [tuple(raw[i*3:i*3+3]) for i in range(256)]

def inverse_palette(pal, bits=5):
    """RGB -> nearest index, as a (2^bits)^3 cube.

    This is the lookup texLoadAll does by linear scan per texel. Built once
    here, it costs 32768*256 distance tests total instead of 256 per texel."""
    n    = 1 << bits
    step = 256 >> bits
    cube = bytearray(n*n*n)
    for r in range(n):
        for g in range(n):
            for b in range(n):
                rr, gg, bb = r*step + step//2, g*step + step//2, b*step + step//2
                best, bd = 0, 1 << 30
                for i, (pr, pg, pb) in enumerate(pal):
                    dr, dg, db = rr-pr, gg-pg, bb-pb
                    dist = dr*dr + dg*dg + db*db
                    if dist < bd:
                        best, bd = i, dist
                        if dist == 0:
                            break
                cube[(r << (2*bits)) | (g << bits) | b] = best
    return cube, bits

def resample(src, sw, sh, dw, dh, pal, cube, bits):
    """Bilinear in RGB, then back to an index through the cube.

    Matches texLoadAll's filter: sample at (x*sw/dw, y*sh/dh), blend the four
    neighbours with wrap, which is what the `mod` in the original does."""
    out   = bytearray(dw*dh)
    shift = 8 - bits
    dx, dy = sw/dw, sh/dh
    for y in range(dh):
        cy = y*dy
        iy = int(cy); t = cy - iy
        for x in range(dw):
            cx = x*dx
            ix = int(cx); s = cx - ix
            c1 = pal[src[(iy      % sh)*sw + (ix      % sw)]]
            c2 = pal[src[((iy+1)  % sh)*sw + (ix      % sw)]]
            c3 = pal[src[(iy      % sh)*sw + ((ix+1)  % sw)]]
            c4 = pal[src[((iy+1)  % sh)*sw + ((ix+1)  % sw)]]
            r = c1[0]*(1-s)*(1-t) + c2[0]*(1-s)*t + c3[0]*(1-t)*s + c4[0]*s*t
            g = c1[1]*(1-s)*(1-t) + c2[1]*(1-s)*t + c3[1]*(1-t)*s + c4[1]*s*t
            b = c1[2]*(1-s)*(1-t) + c2[2]*(1-s)*t + c3[2]*(1-t)*s + c4[2]*s*t
            r = 255 if r > 255 else int(r)
            g = 255 if g > 255 else int(g)
            b = 255 if b > 255 else int(b)
            out[y*dw + x] = cube[((r >> shift) << (2*bits)) |
                                 ((g >> shift) <<    bits ) |
                                  (b >> shift)]
    return out

def write_bmp8(path, w, h, pixels, pal):
    """8-bit uncompressed BMP, bottom-up, rows padded to 4 bytes."""
    stride = (w + 3) & ~3
    pad    = stride - w
    px     = bytearray()
    for y in range(h-1, -1, -1):                 # BMP rows run bottom to top
        px += pixels[y*w:(y+1)*w] + bytes(pad)
    palb = bytearray()
    for (r, g, b) in pal:
        palb += bytes((b, g, r, 0))              # BMP palette is BGRA
    off  = 14 + 40 + 1024
    hdr  = b'BM' + struct.pack('<IHHI', off + len(px), 0, 0, off)
    info = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 8, 0, len(px), 2835, 2835, 256, 256)
    open(path, 'wb').write(hdr + info + palb + px)

def write_bload(path, payload):
    """BSAVE-format file: 0xFD, segment, offset, length, then the bytes.

    BLOAD ignores the stored segment and offset when the caller supplies one,
    so those are zero here; only the length matters. The format caps at 65535
    bytes, which every converted lump in this map is comfortably under."""
    if len(payload) > 65535:
        raise SystemExit(f"{path}: {len(payload)} bytes, over BLOAD's 64K limit")
    hdr = struct.pack('<BHHH', 0xFD, 0, 0, len(payload))
    open(path, 'wb').write(hdr + payload)
    return len(payload)


def convert_lumps(d, lumps, outdir):
    """Convert each lump from its on-disk layout to the renderer's own.

    model.bas did this per element, in BASIC, copying field by field -- and
    for three lumps the two layouts genuinely differ, which is why the loop
    existed rather than a bulk read. Doing it here means the target can BLOAD
    each array in one go."""
    out = {}

    def lump(i):
        o, n = lumps[i]
        return d[o:o+n]

    # vertices, edges, marksurfaces, texinfo, models: identical either side
    out['verts.bld'] = lump(3)
    out['edges.bld'] = lump(12)
    out['lface.bld'] = lump(11)
    out['texinf.bld'] = lump(6)
    out['models.bld'] = lump(14)
    out['pvs.bld'] = lump(4)
    # clipnodes: the collision hulls. planenum/front/back is 8 bytes on disk
    # and 8 in memory, so this one needs no conversion either.
    out['clip.bld'] = lump(9)

    # ledges: long on disk, integer in memory. bspLoadEdgeIndex read a long
    # into a temporary and assigned it down, so the truncation is deliberate.
    raw = lump(13)
    out['ledges.bld'] = b''.join(
        struct.pack('<h', struct.unpack_from('<i', raw, k)[0])
        for k in range(0, len(raw), 4))

    # faces: face(20) -> face2(16), dropping the two flag words
    raw = lump(7)
    buf = bytearray()
    for k in range(0, len(raw), 20):
        planeid, side, ledgeid, ledgenum, texinfoid, _f1, _f2, lightmap = \
            struct.unpack_from('<hhihhhhi', raw, k)
        buf += struct.pack('<hhihhi', planeid, side, ledgeid,
                           ledgenum, texinfoid, lightmap)
    out['faces.bld'] = bytes(buf)

    # leaves: leaf(28) -> leaf2(20), dropping cont and the trailing 4 bytes
    raw = lump(10)
    buf = bytearray()
    for k in range(0, len(raw), 28):
        cont, vislist = struct.unpack_from('<ii', raw, k)
        bound = raw[k+8:k+20]                       # 6 int16, copied whole
        lfaceid, lfacenum = struct.unpack_from('<hh', raw, k+20)
        # contents is kept: the collision hulls hold only EMPTY and SOLID, so
        # hull 0's leaves are the only place water and lava are recorded.
        buf += struct.pack('<ii', cont, vislist) + bound + struct.pack('<hh', lfaceid, lfacenum)
    out['leaves.bld'] = bytes(buf)

    # planes: plane(20) -> plane2(18), ptype narrows to an integer
    raw = lump(1)
    buf = bytearray()
    for k in range(0, len(raw), 20):
        nx, ny, nz, dist, ptype = struct.unpack_from('<ffffi', raw, k)
        buf += struct.pack('<ffffh', nx, ny, nz, dist, ptype)
    out['planes.bld'] = bytes(buf)

    # nodes: node(24) -> nodeb(22). planeid narrows, and the bounding box
    # moves to the end -- the two structures are not in the same order.
    raw = lump(5)
    buf = bytearray()
    for k in range(0, len(raw), 24):
        planeid, child0, child1 = struct.unpack_from('<ihh', raw, k)
        bound = raw[k+8:k+20]
        lfaceid, lfacenum = struct.unpack_from('<hh', raw, k+20)
        buf += struct.pack('<hhhhh', planeid, child0, child1, lfaceid, lfacenum) + bound
    out['nodes.bld'] = bytes(buf)

    total = 0
    for name, payload in out.items():
        total += write_bload(os.path.join(outdir, name), payload)
        print(f"  {name:12} {len(payload):7,} bytes")
    print(f"  lumps total  {total:7,} bytes")


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: mkassets.py <map.bsp> <base.dat> <outdir>")
    bsp, packpath, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    d   = open(bsp, 'rb').read()
    pal = load_palette(pack_read(packpath, 'color/palette.lmp'))

    # texLoadAll read every miptex byte as colmap[byte], not as a palette index
    # directly -- row 0 of the colormap, its brightest level. In this data set
    # that row is nowhere near the identity (221 of 256 entries differ), so
    # skipping it shifts almost every texel to the wrong colour. Apply it here
    # exactly where the original applied it: on the way in.
    cmap = pack_read(packpath, 'color/colormap.lmp')
    if len(cmap) < 256:
        raise SystemExit(f"colormap is {len(cmap)} bytes, expected >= 256")
    shade0 = cmap[:256]
    print("building inverse palette cube ...", flush=True)
    cube, bits = inverse_palette(pal)

    lumps   = read_lumps(d)
    print("converting lumps ...", flush=True)
    convert_lumps(d, lumps, outdir)

    toff, _ = lumps[2]
    ntex    = struct.unpack_from('<i', d, toff)[0]
    offs    = [struct.unpack_from('<i', d, toff + 4 + 4*k)[0] for k in range(ntex)]

    # One BMP per texture per mip level, DOS 8.3: t<idx>m<level>.bmp.
    #
    # An atlas per mip level would mean fewer files, but pulling a cell out of
    # one needs uglBlit, and uglBlit is declared in ugl.bi without being
    # implemented in the VBD library -- LINK resolves the call to an int 3.
    # uglNewBMPEx is present, and it builds a DC straight from a file, so a
    # file per texture is both simpler and one call per texture on the target.
    written = 0
    for lvl in range(MIPS):
        cell = SIZES[lvl]
        for k, o in enumerate(offs):
            if o < 0:
                continue
            base = toff + o
            w, h = struct.unpack_from('<ii', d, base + 16)
            mo   = struct.unpack_from('<i',  d, base + 24 + 4*lvl)[0]
            mw, mh = w >> lvl, h >> lvl
            src  = d[base+mo : base+mo + mw*mh]
            if len(src) < mw*mh:
                print(f"  ! texture {k} mip {lvl} truncated, skipped")
                continue
            src  = bytes(shade0[b] for b in src)        # as texLoadAll did
            tile = resample(src, mw, mh, cell, cell, pal, cube, bits)
            out  = os.path.join(outdir, f"t{k:03d}m{lvl}.bmp")
            write_bmp8(out, cell, cell, tile, pal)
            written += 1
        print(f"  mip {lvl}: {ntex} textures @ {cell}x{cell}")
    print(f"done: {written} bmps for {ntex} textures across {MIPS} mip levels")

main()
