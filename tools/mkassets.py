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
import struct, sys, os, math

MIPS   = 4
SIZES  = [64, 32, 16, 8]        # what the renderer wants, per mip level

# The texture store. Every texture and mip lands in ONE image, at the exact
# byte offset the renderer will aim a uGL view at, so the target loads the
# whole set with a single uglPutBMPEx instead of one call per texture.
#
# It used to be a BMP per texture per mip (t<k>m<l>.bmp, 160 files). That
# meant 160 uglNewBMPEx calls, each building a DC that costs conventional
# memory for its scanline table and each allocating and freeing uGL's 10K BMP
# scratch buffer -- the churn fragmented the heap even though every DC was
# freed again.
#
# STORE_W is 2048 because a store row must divide the 16K EMS page evenly (8
# rows to a page) and because uGL's BMP loader caps a scanline at 8192 bytes.
STORE_W   = 2048
EMS_PAGE  = 16384
STORE_RPP = EMS_PAGE // STORE_W         # store rows per EMS page

def pack_offsets(ntex):
    """Byte offset of every (texture, mip), and the page count that implies.

    Packed end to end, skipping to the next EMS page whenever a texture would
    straddle one: the uGL texture fillers map a single page and then address
    the texture flat, so crossing a page boundary is what breaks -- being
    unaligned within one does not. Four mips are 5,440 bytes, so three whole
    textures fit a page and the fourth starts the next.
    """
    offs, nxt = [], 0
    for _ in range(ntex):
        for lvl in range(MIPS):
            sz = SIZES[lvl] * SIZES[lvl]
            if (nxt % EMS_PAGE) + sz > EMS_PAGE:
                nxt = ((nxt // EMS_PAGE) + 1) * EMS_PAGE
            offs.append(nxt)
            nxt += sz
    pages = (nxt + EMS_PAGE - 1) // EMS_PAGE
    return offs, pages

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


LM_CHUNK = 32000        # keep a chunk's byte offsets inside a signed 16-bit
                        # BASIC integer, and every chunk under BLOAD's 64K cap
LM_FACES_PER_CHUNK = 4000   # 16 bytes a record, so 64,000 -- also under the cap.
                            # e3m6 has 6,985 faces and would otherwise need a
                            # 111K table, which BLOAD cannot take.


def face_lightmap_geometry(d, lumps):
    """Per-face texturemins/extents, exactly as Quake's CalcSurfaceExtents.

    The lightmap grid is one luxel per 16 texels, anchored at the face's
    texture-space minimum rounded down to a multiple of 16. Both numbers are
    needed at runtime -- extents sizes the cached surface, texturemins is what
    turns an interpolated texture coordinate back into a lightmap coordinate --
    and both are a pure function of the .bsp, so they are computed here rather
    than at every launch.
    """
    def lump(i):
        o, n = lumps[i]
        return d[o:o+n]

    raw = lump(3)
    verts = [struct.unpack_from('<3f', raw, k) for k in range(0, len(raw), 12)]
    raw = lump(12)
    edges = [struct.unpack_from('<2H', raw, k) for k in range(0, len(raw), 4)]
    raw = lump(13)
    surfedges = [struct.unpack_from('<i', raw, k)[0] for k in range(0, len(raw), 4)]
    raw = lump(6)
    texinfo = [struct.unpack_from('<8f2i', raw, k) for k in range(0, len(raw), 40)]

    faces = lump(7)
    geo = []
    for k in range(0, len(faces), 20):
        _pl, _sd, firstedge, numedges, ti = struct.unpack_from('<hhihh', faces, k)
        tv = texinfo[ti]
        mins = [1e30, 1e30]
        maxs = [-1e30, -1e30]
        for e in range(numedges):
            se = surfedges[firstedge + e]
            v = verts[edges[abs(se)][0 if se >= 0 else 1]]
            for j in range(2):
                val = (v[0]*tv[j*4+0] + v[1]*tv[j*4+1] +
                       v[2]*tv[j*4+2] + tv[j*4+3])
                mins[j] = min(mins[j], val)
                maxs[j] = max(maxs[j], val)
        tmin, ext = [], []
        for j in range(2):
            bmin = math.floor(mins[j] / 16)
            bmax = math.ceil(maxs[j] / 16)
            tmin.append(int(bmin * 16))
            ext.append(int((bmax - bmin) * 16))
        geo.append((tmin, ext))
    return geo


'''Lightmap 4-bit encoding, per style plane: 16 LINEAR levels between the
plane's own min and max, DXT-style. A global 16-level palette banded --
adjacent levels sat ~15 apart, and the renderer's bilinear reconstruction
turned every smooth gradient into visible plateaus (and dithering traded
the plateaus for luxel-scale ripple, since alternating levels 15 apart
rides a +-7 wave that a 16-texel-per-luxel bilerp cannot hide). Per-plane
ranges are narrow -- dm3ish median max-min is 34, so the median step is
~2.3 and the reconstruction is visually exact. Encoder and decoder must
agree on the level formula: level(j) = base + (j*rng + 7) \\ 15.'''

PLANE_FIT_THRESHOLD = 120   # rng up to this, nearest-level rounding errs by
                            # at most rng/30 = 4 light values -- one row of
                            # the 64-row colormap, invisible by construction.
                            # Above it, plateaus can straddle 2+ rows, so
                            # switch to the reconstruction-fit assignment,
                            # whose alternation noise is the lesser artifact


def plane_levels(base, rng):
    return [base + (j * rng + 7) // 15 for j in range(16)]


def fit_plane(plane, w, h, levels, sweeps=6):
    """Choose nibble indices minimizing the BILERP-RECONSTRUCTED error, not
    the per-luxel error. The renderer reconstructs by bilinearly blending
    the four surrounding luxels, so the reconstruction error is a quadratic
    form in the per-luxel errors with positive cross-couplings (the bilinear
    element mass matrix: within a cell, self 4, edge-adjacent 2, diagonal 1,
    /36) -- meaning neighbours that err in OPPOSITE signs cancel through the
    interpolation, PWM-style. Iterated conditional modes: sweep the plane,
    each luxel picking the level that minimizes its quadratic contribution
    given its neighbours' current errors, until no luxel changes."""
    v = [float(b) for b in plane]
    n = w * h
    Mii = [0.0] * n
    nbr = [dict() for _ in range(n)]
    W = [[4, 2, 2, 1], [2, 4, 1, 2], [2, 1, 4, 2], [1, 2, 2, 4]]
    for cy in range(h - 1):
        for cx in range(w - 1):
            c = [cy*w + cx, cy*w + cx + 1, (cy+1)*w + cx, (cy+1)*w + cx + 1]
            for a in range(4):
                Mii[c[a]] += W[a][a]
                for b in range(4):
                    if a != b:
                        nbr[c[a]][c[b]] = nbr[c[a]].get(c[b], 0.0) + W[a][b]
    q = [min(range(16), key=lambda j: abs(levels[j] - x)) for x in v]
    e = [levels[qi] - vi for qi, vi in zip(q, v)]
    for s in range(sweeps):
        changed = 0
        order = range(n) if (s & 1) == 0 else range(n - 1, -1, -1)
        for i in order:
            S = sum(wgt * e[j] for j, wgt in nbr[i].items())
            best_j, best_c = q[i], None
            for j in range(16):
                ei = levels[j] - v[i]
                cost = Mii[i] * ei * ei + 2.0 * ei * S
                if best_c is None or cost < best_c:
                    best_c, best_j = cost, j
            if best_j != q[i]:
                q[i] = best_j
                e[i] = levels[best_j] - v[i]
                changed += 1
        if changed == 0:
            break
    return q


def encode_plane(plane, w, h):
    """One style plane -> (base, rng, nibble indices)."""
    base, mx = min(plane), max(plane)
    rng = mx - base
    levels = plane_levels(base, rng)
    if rng > PLANE_FIT_THRESHOLD:
        q = fit_plane(plane, w, h, levels)
    else:
        q = [min(range(16), key=lambda j: abs(levels[j] - b)) for b in plane]
    return base, rng, q


def convert_lightmaps(d, lumps, out):
    """Repack the LIGHTING lump face-by-face, plus a per-face index.

    Two reasons not to ship the lump verbatim. It is 73.5K on dm3ish and
    BLOAD stops at 64K, so it has to be split regardless; and splitting on
    face boundaries means a face's luxels never straddle two arrays, which
    would otherwise have to be special-cased in the builder. Faces come out
    in face order, so the table is indexed by face id with no indirection.

    Record is 8 integers, because QuickBASIC has no byte type and a uniform
    TYPE is what the loader can BLOAD straight into an array:
        ofs_hi, ofs_lo, tmin_s, tmin_t, lm_w, lm_h, styles01, styles23
    ofs_hi = -1 marks a face with no lightmap. The two styles words pack four
    bytes each and are written unsigned -- an unlit face is styles 255,255,
    i.e. 0xFFFF, which BASIC reads back as -1; only the bytes matter.
    """
    lo, ln = lumps[8]
    lighting = d[lo:lo+ln]
    faces = d[lumps[7][0]:lumps[7][0]+lumps[7][1]]
    geo = face_lightmap_geometry(d, lumps)

    blob = bytearray()
    table = bytearray()
    lit = unlit = 0
    for k in range(0, len(faces), 20):
        styles = faces[k+12:k+16]
        lightofs = struct.unpack_from('<i', faces, k+16)[0]
        (tmin, ext) = geo[k // 20]
        lm_w = (ext[0] >> 4) + 1
        lm_h = (ext[1] >> 4) + 1
        nstyles = sum(1 for b in styles if b != 255)

        if lightofs < 0 or nstyles == 0:
            unlit += 1
            table += struct.pack('<hH4h2H', -1, 0, tmin[0], tmin[1], lm_w, lm_h,
                                 styles[0] | (styles[1] << 8),
                                 styles[2] | (styles[3] << 8))
            continue

        plane_sz = lm_w * lm_h
        size = plane_sz * nstyles
        blk = lighting[lightofs:lightofs+size]
        if len(blk) != size:
            raise SystemExit(f"face {k//20}: lightofs {lightofs}+{size} "
                             f"runs past the {len(lighting)}-byte LIGHTING lump")

        ofs = len(blob)
        # each style plane: [base][rng] then its nibbles packed two per byte,
        # low nibble first, padded to a whole byte -- so every plane starts
        # byte-aligned and sb_build reaches plane s at a computable offset.
        # Planes are quantized independently: each gets its own base/rng.
        for s in range(nstyles):
            base, rng, q = encode_plane(blk[s*plane_sz:(s+1)*plane_sz], lm_w, lm_h)
            if len(q) % 2:
                q.append(0)            # pad nibble; unused, never read
            packed = bytearray(len(q) // 2)
            for i in range(0, len(q), 2):
                packed[i // 2] = q[i] | (q[i+1] << 4)
            blob += bytes([base, rng]) + packed
        lit += 1
        # flat 32-bit byte offset, split low/high across the first two fields;
        # mod_load_lightmaps turns it into a far pointer once the blob has an
        # address. 0..65535 low, 0..n high -- 4 GB of headroom we will not use.
        table += struct.pack('<hH4h2H', ofs >> 16, ofs & 0xFFFF, tmin[0], tmin[1],
                             lm_w, lm_h,
                             styles[0] | (styles[1] << 8),
                             styles[2] | (styles[3] << 8))

    # raw, not BLOAD: it goes into a memAlloc'd block via mgl's fileRead, so
    # neither BLOAD's 64K cap nor BASIC's far heap is involved.
    out['lmdat.bin'] = bytes(blob)
    # face id -> (i \\ LM_FACES_PER_CHUNK, i MOD LM_FACES_PER_CHUNK), so the
    # loader needs no side table to find a record.
    step = LM_FACES_PER_CHUNK * 16
    tparts = [table[k:k+step] for k in range(0, max(len(table), 1), step)]
    # Split by who reads it, not by what it describes. BASIC needs only
    # texturemins, to shift a face's texture coordinates into its surface's
    # own space before drawing -- 4 bytes a face, and that is all that goes
    # in the far heap BLOAD allocates from. The rest (where the luxels are,
    # how big, which styles) is read once per cache miss by the builder, in
    # assembly, so it lives in the same memAlloc'd memory as the luxels.
    tmin = bytearray()
    for k in range(0, len(table), 16):
        tmin += table[k+4:k+8]
    out['lmtmin.bld'] = bytes(tmin)
    out['lmface.bin'] = bytes(table)
    return lit, unlit, 1, len(blob), 1


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

    # vertices: vertex(12, 3 floats) -> vertex2(6, Q13.3 fixed point).
    # scale by 8 and round to the nearest 1/8 unit; bspfile.bi's vertex2
    # comment has the range/precision reasoning. A coordinate whose scaled
    # value doesn't fit a signed 16-bit integer would silently wrap in
    # BASIC's overflow-unchecked build, corrupting geometry with no error --
    # so this fails loudly at asset-build time instead.
    raw = lump(3)
    buf = bytearray()
    for k in range(0, len(raw), 12):
        vidx = k // 12
        x, y, z = struct.unpack_from('<fff', raw, k)
        for axis, coord in (('x', x), ('y', y), ('z', z)):
            scaled = round(coord * 8)
            if not (-32768 <= scaled <= 32767):
                raise SystemExit(
                    f"verts.bld: vertex {vidx} {axis}={coord} scales to "
                    f"{scaled}, outside signed 16-bit Q13.3 range")
            buf += struct.pack('<h', scaled)
    out['verts.bld'] = bytes(buf)

    # edges, marksurfaces, models: identical either side
    out['edges.bld'] = lump(12)
    out['lface.bld'] = lump(11)
    out['models.bld'] = lump(14)
    out['pvs.bld'] = lump(4)

    # texinfo: texinfo(40) -> texinfo2(34). flags is dropped (nothing reads
    # it -- see bspfile.bi's texinfo2 comment) and miptex narrows to an
    # integer (it indexes this map's own texture list, max seen is 72).
    raw = lump(6)
    buf = bytearray()
    for k in range(0, len(raw), 40):
        tidx = k // 40
        vals = struct.unpack_from('<8fii', raw, k)
        miptex = vals[8]
        if not (-32768 <= miptex <= 32767):
            raise SystemExit(
                f"texinf.bld: texinfo {tidx} miptex={miptex}, outside "
                f"signed 16-bit range")
        buf += struct.pack('<8fh', *vals[:8], miptex)
    out['texinf.bld'] = bytes(buf)
    # clipnodes: the collision hulls. planenum narrowed long->integer (see
    # bspfile.bi's clipnode/cliptmp comment): 8 bytes on disk, 6 in memory.
    raw = lump(9)
    out['clip.bld'] = b''.join(
        struct.pack('<hhh', struct.unpack_from('<i', raw, k)[0], *struct.unpack_from('<hh', raw, k+4))
        for k in range(0, len(raw), 8))

    # ledges: long on disk, integer in memory. bspLoadEdgeIndex read a long
    # into a temporary and assigned it down, so the truncation is deliberate.
    raw = lump(13)
    out['ledges.bld'] = b''.join(
        struct.pack('<h', struct.unpack_from('<i', raw, k)[0])
        for k in range(0, len(raw), 4))

    # faces: face(20) -> face2(10), dropping the two flag words and the
    # LIGHTING-lump offset (unused: d_surf.bas's lmtmin/lm_info replaced it),
    # and narrowing ledgeid to an integer -- it is an unsigned ledges.bld
    # index (max 32,880 on e3m6), so values over 32,767 are packed as their
    # two's-complement bit pattern; the BASIC side undoes the wrap on read.
    raw = lump(7)
    buf = bytearray()
    for k in range(0, len(raw), 20):
        planeid, side, ledgeid, ledgenum, texinfoid, _f1, _f2, _lightmap = \
            struct.unpack_from('<hhihhhhi', raw, k)
        if ledgeid >= 32768:
            ledgeid -= 65536
        buf += struct.pack('<hhhhh', planeid, side, ledgeid,
                           ledgenum, texinfoid)
    out['faces.bld'] = bytes(buf)

    # leaves: leaf(28) -> leaf2(22), dropping the trailing 4 bytes and
    # narrowing cont to an integer (always one of six small CONTENTS_*
    # negatives -- see bspfile.bi's leaf2 comment)
    raw = lump(10)
    buf = bytearray()
    for k in range(0, len(raw), 28):
        cont, vislist = struct.unpack_from('<ii', raw, k)
        bound = raw[k+8:k+20]                       # 6 int16, copied whole
        lfaceid, lfacenum = struct.unpack_from('<hh', raw, k+20)
        buf += struct.pack('<h', cont) + struct.pack('<i', vislist) + bound + struct.pack('<hh', lfaceid, lfacenum)
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

    lit, unlit, nchunks, lmbytes, ntab = convert_lightmaps(d, lumps, out)
    print(f"  lightmaps    {lit:,} lit faces, {unlit:,} unlit, "
          f"{lmbytes:,} bytes in {nchunks} chunk(s), table in {ntab}")

    total = 0
    for name, payload in out.items():
        path = os.path.join(outdir, name)
        if name.endswith('.bin'):
            # raw: read by mgl's fileRead into a memAlloc'd block, so it is
            # bound by neither BLOAD's 64K cap nor BASIC's far heap
            open(path, 'wb').write(payload)
            total += len(payload)
        else:
            total += write_bload(path, payload)
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
    # The whole table, not just its first row, for the surface builder:
    # uglSetLUT wants [shade][index] with 64 shades, which is exactly what
    # colormap.lmp already is. Raw, and read into paragraph-aligned memAlloc
    # storage -- uglSetLUT requires an offset of zero.
    if len(cmap) < 64*256:
        raise SystemExit(f"colormap is {len(cmap)} bytes, need >= {64*256}")
    write_bload(os.path.join(outdir, 'colmap.bld'), cmap[:64*256])
    print(f"  colmap.bld    {64*256:7,} bytes  (64 shades x 256)")
    print("building inverse palette cube ...", flush=True)
    cube, bits = inverse_palette(pal)

    lumps   = read_lumps(d)
    print("converting lumps ...", flush=True)
    convert_lumps(d, lumps, outdir)

    toff, _ = lumps[2]
    ntex    = struct.unpack_from('<i', d, toff)[0]
    offs    = [struct.unpack_from('<i', d, toff + 4 + 4*k)[0] for k in range(ntex)]

    # Two stores: one image each for the shaded and the raw texel sets, with
    # every texture and mip already at the offset the renderer aims a view at.
    # See STORE_W / pack_offsets above for why this replaced 160 files.
    #
    # texofs.bld is emitted rather than recomputed on the target so the packer
    # and the loader cannot drift apart -- an offset table and the code that
    # reads it have to move together, the lesson clip.bld already taught once.
    offsets, pages = pack_offsets(ntex)
    store_h = pages * STORE_RPP
    shaded  = bytearray(STORE_W * store_h)
    rawbuf  = bytearray(STORE_W * store_h)

    def place(buf, ofs, tile, cell):
        """Drop a cell x cell tile into a store at byte offset ofs.

        The tile occupies cell*cell CONTIGUOUS bytes there, which is exactly
        what a view of width cell reads back as cell rows -- checked on the
        target with a standalone test before any of this was written."""
        for r in range(cell):
            at = ofs + r * cell
            buf[at:at + cell] = tile[r*cell:(r+1)*cell]

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
            # Two sets, because they feed two different things.
            #
            # shaded: shade0 applied, as texLoadAll did -- what the unlit path
            # draws directly.
            #
            # raw: raw indices, for the surface builder. It shades through the
            # full colormap itself, and colormap row 0 is not the identity --
            # it BRIGHTENS (index 40, luminance 83, becomes 47, luminance
            # 146). Shading a texel that already went through row 0 treats a
            # brightened index as a raw one, and the lighting range collapses
            # to almost nothing.
            at = offsets[k*MIPS + lvl]
            place(rawbuf, at, resample(src, mw, mh, cell, cell, pal, cube, bits), cell)
            shd = bytes(shade0[b] for b in src)         # as texLoadAll did
            place(shaded, at, resample(shd, mw, mh, cell, cell, pal, cube, bits), cell)
        print(f"  mip {lvl}: {ntex} textures @ {cell}x{cell}")

    write_bmp8(os.path.join(outdir, 'tex.bmp'),  STORE_W, store_h, shaded, pal)
    write_bmp8(os.path.join(outdir, 'texr.bmp'), STORE_W, store_h, rawbuf, pal)
    write_bload(os.path.join(outdir, 'texofs.bld'),
                b''.join(struct.pack('<i', v) for v in offsets))
    print(f"  tex.bmp/texr.bmp  {STORE_W}x{store_h}  "
          f"({pages} EMS pages, {ntex} textures x {MIPS} mips)")
    print(f"  texofs.bld    {len(offsets)*4:7,} bytes  ({len(offsets)} offsets)")

main()
