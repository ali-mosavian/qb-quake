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

def load_palette(path):
    p = open(path, 'rb').read()
    if len(p) < 768:
        raise SystemExit(f"palette {path} is {len(p)} bytes, expected >= 768")
    return [tuple(p[i*3:i*3+3]) for i in range(256)]

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

def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: mkassets.py <map.bsp> <palette.lmp> <outdir>")
    bsp, palpath, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    d   = open(bsp, 'rb').read()
    pal = load_palette(palpath)
    print("building inverse palette cube ...", flush=True)
    cube, bits = inverse_palette(pal)

    toff, _ = read_lumps(d)[2]
    ntex    = struct.unpack_from('<i', d, toff)[0]
    offs    = [struct.unpack_from('<i', d, toff + 4 + 4*k)[0] for k in range(ntex)]

    cols = 8                                     # atlas grid width, in textures
    rows = (ntex + cols - 1) // cols
    for lvl in range(MIPS):
        cell = SIZES[lvl]
        aw, ah = cols*cell, rows*cell
        atlas  = bytearray(aw*ah)
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
            tile = resample(src, mw, mh, cell, cell, pal, cube, bits)
            cx, cy = (k % cols)*cell, (k // cols)*cell
            for y in range(cell):
                atlas[(cy+y)*aw + cx : (cy+y)*aw + cx + cell] = tile[y*cell:(y+1)*cell]
        out = os.path.join(outdir, f"mip{lvl}.bmp")
        write_bmp8(out, aw, ah, atlas, pal)
        print(f"  {out}  {aw}x{ah}  {ntex} textures @ {cell}x{cell}")
    print(f"done: {ntex} textures, {MIPS} atlases, grid {cols}x{rows}")

main()
