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
import re

# The geometry store's row width, and the corner count d_poly.bas's
# polyb()/uvbuffb() can hold. GEOM_W must match GEOM_W in q_map.bi: it is
# the unit uglMapEx maps, and a record that straddled it would be read
# half from the wrong EMS page.
GEOM_W = 8192
GEOM_MAXVTX = 33

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
    open(path, 'wb').write(bmp8_bytes(w, h, pixels, pal))

def bmp8_bytes(w, h, pixels, pal):
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
    return hdr + info + palb + px

UA_WIN = 16384          # uglArr's page size (UA_WIN in src/ugl/uglarr.asm)

# Element sizes for the paged lumps, so the padding lands where uGL puts it.
PAGED_ELEM = {
    'nodes.pag': 22,    # nodeb: planeid child0 child1 lfaceid lfacenum + 12
    'clip.pag':   6,    # ClipNode: planenum front back
    'leaves.pag':22,    # leaf2: cont vislist bound[12] lfaceid lfacenum
    'faces.pag': 10,    # Face: planeid side geom_row geom_ofs texinfoid
}


# Arrays the renderer backs with CONVENTIONAL memory are laid out FLAT --
# no page padding. uglArr maps such a store once, whole, and the renderer
# then indexes arr(i) natively, so element i must be at exactly i*elem.
# Page padding would break that at every page boundary.
#
# EMS-backed arrays still need padding: a 16k frame really is a window.
FLAT = {'nodes.pag', 'clip.pag', 'leaves.pag', 'faces.pag'}


def write_flat(path, payload):
    open(path, 'wb').write(payload)
    return len(payload)


def write_paged(path, payload, elem, win=UA_WIN):
    """Lay a lump out the way uglArr's store is laid out.

    Page p starts at byte p*win and holds (win // elem) elements, with the
    page's tail padded -- INCLUDING the last page. uglArrLoad can then read
    whole pages straight into the mapped EMS window, with no partial page to
    special-case and no element arithmetic: the two layouts are identical by
    construction.

    Page padding, not element padding, is deliberate. At 22 bytes it wastes
    16 bytes per page rather than 10 bytes per element -- 64 bytes against
    27,500 on e1m1's node tree.

    Unlike BLOAD there is no 64K cap here, which is the other reason the
    paged lumps are not .bld: e1m1's node tree does not fit in one.
    """
    perpg = win // elem
    if perpg < 1:
        raise SystemExit(f"{path}: element {elem} is larger than a {win}-byte page")
    n = len(payload) // elem
    out = bytearray()
    for start in range(0, n, perpg):
        chunk = payload[start * elem:min(start + perpg, n) * elem]
        out += chunk + b'\x00' * (win - len(chunk))
    open(path, 'wb').write(out)
    return len(out)


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
# The luxel atlas. 8192 divides an EMS page exactly -- two scanlines per
# page, neither straddling one -- which mgl's EMS dcs do NOT guarantee for
# an arbitrary width. It is also uglbmp.asm's BMP_MAX_BPS, the widest
# scanline that loader will take.
EMS_PGSIZE  = 16384
LM_ATLAS_W  = 8192
LM_BMP_MAXBPS = 8192        # uglbmp.asm's BMP_MAX_BPS
assert LM_ATLAS_W <= LM_BMP_MAXBPS, "atlas scanline wider than uGL will load"

def pot2(v):
    """v rounded up to a power of two."""
    p = 1
    while p < v:
        p <<= 1
    return p

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

    # Every lit face's style-0 plane, in face order. Only style 0 is kept:
    # the builder has never read the others, and they were pure weight.
    runs = []
    for k in range(0, len(faces), 20):
        styles = faces[k+12:k+16]
        lightofs = struct.unpack_from('<i', faces, k+16)[0]
        (tmin, ext) = geo[k // 20]
        lm_w = (ext[0] >> 4) + 1
        lm_h = (ext[1] >> 4) + 1
        nstyles = sum(1 for b in styles if b != 255)
        if lightofs < 0 or nstyles == 0:
            continue
        size = lm_w * lm_h
        if lightofs + size > len(lighting):
            raise SystemExit(f"face {k//20}: lightofs {lightofs}+{size} "
                             f"runs past the {len(lighting)}-byte LIGHTING lump")
        if pot2(lm_w) * pot2(lm_h) > LM_ATLAS_W:
            raise SystemExit(f"face {k//20}: {lm_w}x{lm_h} luxels round up to "
                             f"a slot past one {LM_ATLAS_W}-byte scanline")
        runs.append((k // 20, size, lightofs, lm_w, lm_h))

    # Each face gets a slot of pot(lm_w) x pot(lm_h) bytes. Two reasons.
    #
    # Alignment: a run whose size is 2^k, placed at an offset that is a
    # multiple of 2^k, cannot cross an 8192-byte scanline -- 8192 being a
    # power of two itself. Allocating slots in DESCENDING size order from
    # offset 0 keeps every one of them naturally aligned, so the invariant
    # costs no padding at all beyond the power-of-two rounding.
    #
    # And the rows stay addressable with a single stride, so the builder
    # walks the rect with an add rather than a multiply per row.
    #
    # Only the slot is padded, not the grid: the builder is still told the
    # face's REAL lm_w/lm_h and reads lm_w bytes from each of lm_h rows, so
    # the pad bytes are never read and sf$lgrid stays its old size. Padding
    # the grid itself would have grown that DGROUP buffer four-fold.
    slots = sorted(runs, key=lambda r: -(pot2(r[3]) * pot2(r[4])))
    atlas = bytearray()
    placed = {}
    for (fid, size, lightofs, lm_w, lm_h) in slots:
        pw, ph = pot2(lm_w), pot2(lm_h)
        base = len(atlas)
        assert base % (pw * ph) == 0, "slot allocation lost its alignment"
        atlas += bytes(pw * ph)
        for row in range(lm_h):
            src = lightofs + row * lm_w
            atlas[base + row*pw : base + row*pw + lm_w] = \
                lighting[src:src+lm_w]
        placed[fid] = (base % LM_ATLAS_W, base // LM_ATLAS_W, pw)

    if len(atlas) % LM_ATLAS_W:
        atlas += bytes(LM_ATLAS_W - (len(atlas) % LM_ATLAS_W))
    atlas_h = max(1, len(atlas) // LM_ATLAS_W)

    table = bytearray()
    lit = unlit = 0
    for k in range(0, len(faces), 20):
        styles = faces[k+12:k+16]
        (tmin, ext) = geo[k // 20]
        lm_w = (ext[0] >> 4) + 1
        lm_h = (ext[1] >> 4) + 1
        fid = k // 20
        if fid not in placed:
            unlit += 1
            ax, ay = 0, -1
        else:
            lit += 1
            ax, ay, _pw = placed[fid]
        # Same 16-byte record as before, but the two offset fields now carry
        # the face's place in the atlas: the scanline, then x within it. The
        # scanline takes the signed field so -1 still means "unlit", which is
        # the sign test sb_build already makes.
        table += struct.pack('<hH4h2H', ay, ax, tmin[0], tmin[1], lm_w, lm_h,
                             styles[0] | (styles[1] << 8),
                             styles[2] | (styles[3] << 8))

    # An 8-bit BMP, loaded by uglNewBMPEx straight into one EMS dc -- the
    # same path the textures take. BMPOPT.NO332 keeps the bytes verbatim, so
    # the palette below is never consulted; it is an identity ramp purely so
    # the file is a valid BMP.
    out['lm.bmp'] = bmp8_bytes(LM_ATLAS_W, atlas_h, bytes(atlas),
                               [(i, i, i) for i in range(256)])
    blob = atlas

    # The table is not written out on its own any more: convert_lumps folds
    # it into each face's geometry record, so one mapping and one copy per
    # drawn face fetch the corners and the lightmap placement together.
    return lit, unlit, 1, len(blob), 1, bytes(table)


ENT_PAIR = re.compile(r'"([^"]*)"\s*"([^"]*)"')


def parse_entities(text: str, nmodels: int) -> bytes:
    # Resolved here, not on the target: BASIC strings cap at 32,767 bytes
    # and e1m3's entities lump is 45,762 -- mod_find_spawn died at error 5
    # before anything else could. The renderer wants four facts out of the
    # text, so those are what ships: spawn, matched teleporter pairs,
    # func_plats, and which submodels a trigger hides. Layout must match
    # EntsHead/EntsTele/EntsPlat in q_ent.bi.
    spawn: tuple[float, float, float] = (0.0, 0.0, 0.0)
    angle = 0.0
    dests: dict[str, tuple[tuple[float, float, float], float]] = {}
    trigs: list[tuple[str, int]] = []
    plats: list[tuple[int, float, float]] = []

    def vec(v: str) -> tuple[float, float, float]:
        x, y, z = (float(t) for t in v.split())
        return (x, y, z)

    def model(v: str) -> int:
        m = int(v[1:]) if v.startswith('*') and v[1:].isdigit() else 0
        return m if 0 < m < nmodels else 0

    for block in text.split('{')[1:]:
        kv = dict(ENT_PAIR.findall(block.split('}')[0]))
        match kv.get('classname'):
            case 'info_player_start':
                spawn = vec(kv.get('origin', '0 0 0'))
                angle = float(kv.get('angle', '0'))
            case 'info_teleport_destination':
                dests[kv.get('targetname', '')] = (
                    vec(kv.get('origin', '0 0 0')), float(kv.get('angle', '0')))
            case 'trigger_teleport' if model(kv.get('model', '')):
                trigs.append((kv.get('target', ''), model(kv['model'])))
            case 'func_plat' if model(kv.get('model', '')):
                plats.append((model(kv['model']),
                              float(kv.get('speed', '0')),
                              float(kv.get('height', '0'))))

    # a trigger with no destination still hides its brush, exactly as the
    # BASIC pass 1 did before pass 2 paired them
    teles = [(m, *dests[t]) for t, m in trigs if t in dests]
    hides = [m for _, m in trigs]

    buf = bytearray(struct.pack('<4f4h', *spawn, angle, nmodels,
                                len(teles), len(plats), len(hides)))
    for m, org, yaw in teles:
        buf += struct.pack('<h3ff', m, *org, yaw)
    for m, speed, height in plats:
        buf += struct.pack('<hff', m, speed, height)
    for m in hides:
        buf += struct.pack('<h', m)
    return bytes(buf)


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

    # Lightmaps first: their per-face table goes into the geometry records
    # below, so it has to exist before they are built.
    lit, unlit, nchunks, lmbytes, ntab, lmtab = convert_lightmaps(d, lumps, out)
    print(f"  lightmaps    {lit:,} lit faces, {unlit:,} unlit, "
          f"{lmbytes:,} bytes in {nchunks} chunk(s), table in {ntab}")

    # The per-face geometry store, fgeom.bin -- which replaces BOTH the
    # vertex array and the surfedge list.
    #
    # The renderer's inner loop wants one thing from the mesh: this face's
    # corner positions, in order. An indexed mesh cannot answer that
    # without both tables resident, which is why they cost 43K of
    # conventional memory on dm3ish and 151K on e1m1. Written out flat,
    # per face, the answer streams from EMS with a working set of ONE
    # face -- so the arrays leave low memory entirely and nothing has to
    # be cached, evicted or prefetched.
    #
    # The price is duplication: a vertex shared by four faces is stored
    # four times, 3.6x overall on e1m1. In EMS, against 4MB, that is not
    # a price.
    #
    # Layout. Rows of GEOM_W bytes, because a row is what uglMapEx maps
    # and a record must not straddle one -- the same constraint, and the
    # same solution, as the luxel atlas. A record is
    #
    #     word nvtx
    #     16 bytes of lightmap placement, as convert_lightmaps built it
    #     nvtx * { int16 x, y, z }                        Q13.3 as before
    #
    # and a face carries (row, offset) instead of (ledgeid, ledgenum). The
    # lightmap header rides along because both are wanted at the same
    # moment, by the same face, and shipping them apart cost a second
    # 36K-to-88K block that had to be resident all frame.
    raw = lump(3)
    verts = []
    for k in range(0, len(raw), 12):
        vidx = k // 12
        xyz = []
        for axis, coord in zip('xyz', struct.unpack_from('<fff', raw, k)):
            scaled = round(coord * 8)
            # BASIC's build is overflow-unchecked, so a coordinate that
            # did not fit would silently wrap and corrupt geometry with
            # no error. Fail here instead.
            if not (-32768 <= scaled <= 32767):
                raise SystemExit(
                    f"fgeom.bin: vertex {vidx} {axis}={coord} scales to "
                    f"{scaled}, outside signed 16-bit Q13.3 range")
            xyz.append(scaled)
        verts.append(xyz)

    raw = lump(12)
    edges = [struct.unpack_from('<2H', raw, k) for k in range(0, len(raw), 4)]
    raw = lump(13)
    surfedges = [struct.unpack_from('<i', raw, k)[0]
                 for k in range(0, len(raw), 4)]

    rows = [bytearray()]
    fgeom = []                                  # (row, offset) per face
    raw = lump(7)
    for k in range(0, len(raw), 20):
        firstedge, = struct.unpack_from('<i', raw, k + 4)
        nvtx, = struct.unpack_from('<h', raw, k + 8)
        # d_poly.bas indexes polyb(32)/uvbuffb(32), so 33 corners is the
        # standing contract; a face past it would run off the end of both.
        if not (0 < nvtx <= GEOM_MAXVTX):
            raise SystemExit(
                f"fgeom.bin: face {k // 20} has {nvtx} corners, and "
                f"d_poly.bas's polyb() holds {GEOM_MAXVTX}")
        fi = k // 20
        rec = bytearray(struct.pack('<h', nvtx))
        rec += lmtab[fi * 16:(fi + 1) * 16]
        for e in range(nvtx):
            se = surfedges[firstedge + e]
            rec += struct.pack('<3h', *verts[edges[abs(se)][0 if se >= 0 else 1]])
        if len(rows[-1]) + len(rec) > GEOM_W:
            rows[-1].extend(b'\0' * (GEOM_W - len(rows[-1])))
            rows.append(bytearray())
        fgeom.append((len(rows) - 1, len(rows[-1])))
        rows[-1] += rec
    rows[-1].extend(b'\0' * (GEOM_W - len(rows[-1])))
    out['fgeom.bin'] = b''.join(bytes(r) for r in rows)

    ent_text = lump(0).split(b'\0')[0].decode('latin-1')
    nmodels = lumps[14][1] // 64
    out['ents.bin'] = parse_entities(ent_text, nmodels)

    # marksurfaces, models: identical either side
    out['lface.bld'] = lump(11)
    out['models.bld'] = lump(14)
    # raw, not BLOAD: read by fileReadH into a memAlloc block, which puts
    # it in upper memory rather than the far heap. It is walked by a PEEK
    # loop over a byte offset and nothing indexes it as an array.
    out['pvs.bin'] = lump(4)

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
    out['clip.pag'] = b''.join(
        struct.pack('<hhh', struct.unpack_from('<i', raw, k)[0], *struct.unpack_from('<hh', raw, k+4))
        for k in range(0, len(raw), 8))

    # faces: face(20) -> face2(10), dropping the two flag words and the
    # LIGHTING-lump offset (unused: d_surf.bas's lm_info replaced it).
    #
    # firstedge/numedges are replaced by the face's address in fgeom.bin:
    # the row uglMapEx maps, and the byte offset of its record inside it.
    # Same ten bytes, and no ledges.bld index to unwrap on read.
    raw = lump(7)
    buf = bytearray()
    for k in range(0, len(raw), 20):
        planeid, side, _le, _ln, texinfoid, _f1, _f2, _lightmap = \
            struct.unpack_from('<hhihhhhi', raw, k)
        grow, gofs = fgeom[k // 20]
        # gofs is 0..GEOM_W-1 so it always fits; grow is a row count and a
        # map big enough to pass 32,767 rows would be 256MB of geometry
        buf += struct.pack('<hhhhh', planeid, side, grow, gofs, texinfoid)
    out['faces.pag'] = bytes(buf)

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
    out['leaves.pag'] = bytes(buf)

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
    out['nodes.pag'] = bytes(buf)
    out['nodes.bld'] = bytes(buf)   # kept so the pre-paging path still runs

    total = 0
    for name, payload in out.items():
        path = os.path.join(outdir, name)
        if name.endswith('.pag'):
            if name in FLAT:
                total += write_flat(path, payload)
            else:
                # page-padded: read a page at a time into an EMS window
                total += write_paged(path, payload, PAGED_ELEM[name])
        elif name.endswith('.bin') or name.endswith('.bmp'):
            # raw: .bin is read by mgl's fileRead -- into a memAlloc'd
            # block for lmface, straight into a mapped EMS window for
            # fgeom -- and .bmp by uglNewBMPEx, so none of them is bound
            # by BLOAD's 64K cap or by BASIC's far heap
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
    # colormap.lmp already is. Raw rather than BLOAD: it is read by
    # fileReadH into a paragraph-aligned memAlloc block, both because
    # uglSetLUT requires an offset of zero and because that block lands in
    # upper memory rather than in the far heap.
    if len(cmap) < 64*256:
        raise SystemExit(f"colormap is {len(cmap)} bytes, need >= {64*256}")
    open(os.path.join(outdir, 'colmap.bin'), 'wb').write(cmap[:64*256])
    print(f"  colmap.bin    {64*256:7,} bytes  (64 shades x 256)")
    print("building inverse palette cube ...", flush=True)
    cube, bits = inverse_palette(pal)

    lumps   = read_lumps(d)
    print("converting lumps ...", flush=True)
    convert_lumps(d, lumps, outdir)

    toff, _ = lumps[2]
    ntex    = struct.unpack_from('<i', d, toff)[0]
    offs    = [struct.unpack_from('<i', d, toff + 4 + 4*k)[0] for k in range(ntex)]

    # ------------------------------------------------------------------
    # Two atlases, not 648 DCs.
    #
    # Each texture used to become its own EMS dc, four mips times two
    # variants: 648 dcs on dm3ish, and a dc costs conventional memory for
    # its struct and scanline table whatever its pixels cost. Measured at
    # 42,176 bytes, the largest item after the back buffer, and it scales
    # with texture count -- which is what stops e1m1 loading.
    #
    # One store per variant instead, with the renderer making FOUR view
    # dcs -- one per mip size -- and re-aiming them per face with
    # uglSetView. That is the same trick the surface cache uses.
    #
    # CELL-MAJOR, and no cell may straddle a scanline. A view reads its
    # rows through the parent's scanline table, so a cell that crossed a
    # row boundary would not be contiguous. Cells are 4096/1024/256/64
    # bytes and the scanline is 8192, so each divides it exactly; each mip
    # block is padded up to a scanline so the next one starts clean.
    #
    # The offset of any cell is then arithmetic, not a table:
    #     ofs(k, lvl) = mip_base(lvl) + k * cell(lvl)^2
    # ------------------------------------------------------------------
    # Two atlases and a lookup table, not 648 dcs.
    #
    # Each texture used to become its own EMS dc, four mips times two
    # variants: 160 dcs on dm3ish at 264 bytes of CONVENTIONAL memory each
    # for the struct and scanline table, measured at 42,176. e1m1 would
    # make 648 -- the ~171K that stops it loading.
    #
    # One store per variant instead. The renderer makes four VIEWS per
    # store, one per mip size, and re-aims them per face with uglSetView --
    # no allocation, no copy. The same trick the surface cache uses.
    #
    # Scanlines are 8192 and cells are crammed in, largest mip first. A
    # cell must never cross a scanline: a view reads its rows through the
    # parent's table, so a split cell would not be contiguous. Going
    # largest-first every cell starts at a multiple of its own size
    # (4096/1024/256/64), and each divides 8192, so none ever does.
    #
    # The placement is EMITTED, not re-derived. Two independent
    # derivations of the same layout is exactly the bug the luxel atlas
    # avoids by shipping its own table.
    place = [[0] * MIPS for _ in range(ntex)]
    raw_at, shd_at = bytearray(), bytearray()

    for lvl in range(MIPS):
        cell = SIZES[lvl]
        for k, o in enumerate(offs):
            # A view must not straddle a 16K page (uglview.asm). Cells are
            # powers of two and packed largest-first, so every offset is a
            # multiple of its own size and none ever does.
            assert len(raw_at) % (cell * cell) == 0, "cell not self-aligned"
            place[k][lvl] = len(raw_at)
            if o < 0:
                raw_at += bytes(cell * cell); shd_at += bytes(cell * cell)
                continue
            base = toff + o
            w, h = struct.unpack_from('<ii', d, base + 16)
            mo   = struct.unpack_from('<i',  d, base + 24 + 4*lvl)[0]
            mw, mh = w >> lvl, h >> lvl
            src  = d[base+mo : base+mo + mw*mh]
            if len(src) < mw*mh:
                print(f"  ! texture {k} mip {lvl} truncated, left blank")
                raw_at += bytes(cell * cell); shd_at += bytes(cell * cell)
                continue
            # raw: indices, for the surface builder, which shades through the
            # full colormap itself. shaded: row 0 applied, for the unlit path.
            raw_at += resample(src, mw, mh, cell, cell, pal, cube, bits)
            lit     = bytes(shade0[b] for b in src)
            shd_at += resample(lit, mw, mh, cell, cell, pal, cube, bits)
        print(f"  mip {lvl}: {ntex} cells @ {cell}x{cell}")

    for at in (raw_at, shd_at):
        if len(at) % LM_ATLAS_W:
            at += bytes(LM_ATLAS_W - (len(at) % LM_ATLAS_W))
    rows = len(raw_at) // LM_ATLAS_W
    for name, at in (("texr.bmp", raw_at), ("texs.bmp", shd_at)):
        write_bmp8(os.path.join(outdir, name), LM_ATLAS_W, rows, bytes(at), pal)
        print(f"  {name}: {LM_ATLAS_W}x{rows} = {len(at):,} bytes")

    tbl = bytearray()
    for k in range(ntex):
        for lvl in range(MIPS):
            tbl += struct.pack('<l', place[k][lvl])
    write_bload(os.path.join(outdir, "texofs.bld"), bytes(tbl))
    print(f"  texofs.bld: {ntex} x {MIPS} offsets")
    written = 2

    written = MIPS * 2

    print(f"done: {written} atlases for {ntex} textures across {MIPS} mip levels")

main()
