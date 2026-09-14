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
import hashlib
import struct, sys, os, math
import re
import zlib
from dataclasses import dataclass
from dataclasses import field

import mksnd

# every output lands here and becomes one assets.zip member
OUT: dict[str, bytes] = {}


def write_zip(path: str) -> None:
    # STORED, every member. The reader is src/qgl/zip.asm, which walks
    # local headers and refuses any method but 0 -- there is no inflate in
    # the renderer any more, and a member it could not read would surface
    # as a missing file rather than as wrong bytes. Costs ~330K on disk;
    # nothing in the build or the run is measured in disk.
    locs, cens, pos = [], [], 0
    for name, data in OUT.items():
        payload, method, xtra = data, 0, b""
        crc = zlib.crc32(data)
        nm = name.encode()
        locs.append(struct.pack("<4sHHHHHLLLHH", b"PK\x03\x04", 20, 0, method,
                                0, 0x21, crc, len(payload), len(data), len(nm),
                                len(xtra)) + nm + xtra + payload)
        cens.append(struct.pack("<4sHHHHHHLLLHHHHHLL", b"PK\x01\x02", 20, 20, 0,
                                method, 0, 0x21, crc, len(payload), len(data),
                                len(nm), 0, 0, 0, 0, 0, pos) + nm)
        pos += len(locs[-1])
    cd = b"".join(cens)
    open(path, 'wb').write(b"".join(locs) + cd + struct.pack(
        "<4sHHHHLLH", b"PK\x05\x06", 0, 0, len(OUT), len(OUT), len(cd), pos, 0))
    # round trip before trusting the writer
    import zipfile
    with zipfile.ZipFile(path) as z:
        for name, data in OUT.items():
            assert z.read(name) == data, name
            assert z.getinfo(name).compress_type == zipfile.ZIP_STORED, \
                f"{name} is not stored; qgl cannot inflate it"
    raw = sum(len(v) for v in OUT.values())
    print(f"  assets.zip: {len(OUT)} members, {raw:,} -> {os.path.getsize(path):,} bytes")

# ---------------------------------------------------------------------
# The .qmp container: one file per converted map.
#
# A map used to be FIVE files staged together -- the .bsp itself (read
# for its lump counts and its miptex names), assets.zip, texr.raw,
# texs.raw and pal.raw -- and nothing tied them to each other. e1m1's
# zip over dm3ish's atlases drew every texture as some other one and
# ran perfectly happily; the offset table indexes whatever atlas is
# there. One file cannot be half of another map.
#
# It is a flat directory, not a zip: the members are the same STORED
# bytes, but the reader (src/qgl/qmap.asm) seeks once to a table
# instead of walking seventeen local headers, and there is no method
# field to get wrong. Everything is little-endian.
#
#     0   "QMAP"              magic
#     4   version    long     QMAP_VER
#     8   ndir       short    directory entries
#    10   dirofs     long     where the directory starts
#    14   bsp_sum    long     the source .bsp's checksum: identity only
#    18   name       16 bytes the map's own name, NUL padded
#    34   pad to QMAP_HEAD
#    64   directory: ndir x { char name[16]; long ofs; long size; }
#   ...   member data, each aligned to 16
# The monster models a map needs, by MDL_KIND_*: the .mdl to cut and
# the frame sets to keep, which IS the frame layout -- d_mdl.bas and
# cport's mdl.c index the sets by position, so the order here is the
# order they read. Vertex counts decide what fits one EMS page, which
# is why the dog keeps one stand frame and the zombie eight of its run.
# The Makefile has the same list as fourteen rules, for the BASIC build
# that still stages these loose; this is the one a container uses.
MDL_SETS = {
    0: ('soldier',  'stand,run,death,pain'),
    1: ('knight',   'stand,runb,death,pain,attackb'),
    2: ('dog',      'stand:1,run,death,pain:1'),
    3: ('ogre',     'stand:1,run,death,pain:3,shoot'),
    4: ('demon',    'stand:1,run,death,pain:3,attacka'),
    5: ('zombie',   'stand:1,run:8,death,paina:8,atta'),
    6: ('wizard',   'hover,fly,death,pain,magatt'),
    7: ('shambler', 'stand:1,run,death,pain,magic'),
}


# q_pl.bi's PL_IT_* order for the weapons that have one: shotgun,
# super shotgun, nailgun, grenade launcher, super nailgun, rocket
# launcher.
VIEW_MDLS = ('v_shot', 'v_shot2', 'v_nail', 'v_rock', 'v_nail2', 'v_rock2')


def build_sbar(pak: str, tmp: str) -> dict[str, bytes]:
    """sbar.raw and sbnum.raw out of gfx.wad, as container members."""
    import subprocess

    if not pak or not os.path.exists(pak):
        # The runtime is fatal on a missing sbar.raw, by name -- say so
        # here too, where the fix is.
        print("  sbar: no PAK, so no status bar in the container")
        return {}
    os.makedirs(tmp, exist_ok=True)
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "mkgfx.py"), pak, tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"mkgfx: {r.stderr.strip() or r.stdout.strip()}")
    return {n: open(os.path.join(tmp, n), "rb").read() for n in ("sbar.raw", "sbnum.raw")}


def build_sounds(pak: str, tmp: str) -> dict[str, bytes]:
    """The bsc4/32n stream, its decode table and the id table, as container members."""
    import subprocess

    if not pak or not os.path.exists(pak):
        print("  sound: no PAK, so no sounds in the container")
        return {}
    os.makedirs(tmp, exist_ok=True)
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "mksnd.py"), pak, tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"mksnd: {r.stderr.strip() or r.stdout.strip()}")
    print(r.stdout, end="")
    return {n: open(os.path.join(tmp, n), "rb").read() for n in ("snd.bsc", "snddec.raw", "sndtab.raw")}


def build_models(pak: str, kinds: set[int], tmp: str) -> dict[str, bytes]:
    """<name>.geo/.vtx/.skn for each kind, as container members."""
    import subprocess

    out: dict[str, bytes] = {}
    if not pak or not os.path.exists(pak):
        return out
    os.makedirs(tmp, exist_ok=True)
    for k in sorted(kinds):
        if k not in MDL_SETS:
            continue
        name, sets = MDL_SETS[k]
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'mkmdl.py'),
                            pak, name, tmp, sets], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"mkmdl {name}: {r.stderr.strip() or r.stdout.strip()}")
        # mkmdl truncates the .geo's name to 8 characters and not the
        # other two; the member keeps the model's own name either way.
        for ext, stem in (('geo', name[:8]), ('vtx', name), ('skn', name)):
            out[f'{name}.{ext}'] = open(os.path.join(tmp, f'{stem}.{ext}'), 'rb').read()
    print(f"  models: {len(out) // 3} of the map's own monster kinds")

    # The view weapons. Not the map's -- a weapon can be picked up on
    # any of them -- so all six ship and the runtime loads the one in
    # hand. mkmdl's 'shot' set is v_*.mdl's whole frame list.
    for name in VIEW_MDLS:
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'mkmdl.py'),
                            pak, name, tmp, 'shot'], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"mkmdl {name}: {r.stderr.strip() or r.stdout.strip()}")
        for ext, stem in (('geo', name[:8]), ('vtx', name), ('skn', name)):
            out[f'{name}.{ext}'] = open(os.path.join(tmp, f'{stem}.{ext}'), 'rb').read()
    print(f"  view models: {len(VIEW_MDLS)}")
    return out


ENTS_HEAD  = '<4f3fff13hf8shh'   # ent.h's EntsHead; the monsters follow it

QMAP_VER   = 1
QMAP_HEAD  = 64
QMAP_NAME  = 16
QMAP_ENT   = 24
QMAP_ALIGN = 16


def write_qmap(path: str, name: str, bsp: bytes, members: dict[str, bytes]) -> None:
    # cport/src/assets.h's QMAP_MAX: the runtime reads the directory into
    # a fixed array and is fatal past it, which is a dead run rather
    # than a bad build unless this says so here.
    if len(members) > 80:
        raise SystemExit(f"{len(members)} members: cport's QMAP_MAX is 80")
    for m in members:
        if len(m.encode()) >= QMAP_NAME:
            raise SystemExit(f"member name {m!r} does not fit {QMAP_NAME - 1} characters")

    dirofs = QMAP_HEAD
    ofs    = dirofs + QMAP_ENT * len(members)
    ofs   += -ofs % QMAP_ALIGN
    dirs, blob = bytearray(), bytearray()
    for mname, data in members.items():
        dirs += struct.pack(f"<{QMAP_NAME}sll", mname.encode(), ofs, len(data))
        pad   = -len(data) % QMAP_ALIGN
        blob += data + bytes(pad)
        ofs  += len(data) + pad

    head = struct.pack(f"<4slHlL{QMAP_NAME}s", b"QMAP", QMAP_VER, len(members),
                       dirofs, zlib.crc32(bsp) & 0xffffffff, name.encode())
    head += bytes(QMAP_HEAD - len(head))
    body  = head + bytes(dirs)
    body += bytes(-len(body) % QMAP_ALIGN)
    open(path, "wb").write(bytes(body) + bytes(blob))

    # Round trip before trusting the writer: read every member back the
    # way the driver will, by the directory alone.
    d = open(path, "rb").read()
    magic, ver, n, do, _, nm = struct.unpack_from(f"<4slHlL{QMAP_NAME}s", d, 0)
    assert magic == b"QMAP" and ver == QMAP_VER and n == len(members)
    assert nm.split(b"\0")[0].decode() == name
    for k in range(n):
        mn, mo, ms = struct.unpack_from(f"<{QMAP_NAME}sll", d, do + k * QMAP_ENT)
        mn = mn.split(b"\0")[0].decode()
        assert d[mo:mo + ms] == members[mn], mn
    print(f"  {os.path.basename(path)}: {len(members)} members, "
          f"{sum(len(v) for v in members.values()):,} -> {len(d):,} bytes")


# The geometry store's row width, and the corner count a face record may
# carry. GEOM_MAXVTX must match q_map.bi's, and d_faces.c sizes its own
# vertex arrays as GEOM_MAXVTX + 8 -- the clipper's headroom. GEOM_W must
# match GEOM_W in q_map.bi: it is
# the unit uglMapEx maps, and a record that straddled it would be read
# half from the wrong EMS page.
GEOM_W = 8192
GEOM_MAXVTX = 33

MIPS   = 4
EMS_PAGE = 16384                # one window: the most a cell may ever be
MIN_CELL = 64                   # texels; under this a level shares the one above
OFS_BITS = 23                   # of the table entry; the top nine carry the dims


def _p2_down(v):
    return v if v and (v & (v - 1)) == 0 else 1 << (v.bit_length() - 1)


def tex_cell_levels(w, h):
    """Atlas cell (width, height) per mip level, at the texture's own aspect.

    Quake sizes are multiples of 16, not powers of two, and the renderer
    addresses a cell by masking -- so each side is rounded DOWN to a power
    of two, and the pair down again until it fits one EMS window. 79 of
    e1m1's 81 textures come through untouched; 256x128 and 128x192 lose one
    halving each.

    A level whose cell would be under MIN_CELL texels repeats the one above
    instead: 2x2 is a scanline table for nothing, and the saving is 440
    bytes of e1m1's 508K, so this is about degenerate views and not memory.
    """
    W, H = _p2_down(w), _p2_down(h)
    while W * H > EMS_PAGE:
        if W >= H: W //= 2
        else:      H //= 2
    out = []
    for k in range(MIPS):
        cw, ch = max(W >> k, 1), max(H >> k, 1)
        out.append(out[-1] if out and cw * ch < MIN_CELL else (cw, ch))
    return out

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
    OUT[os.path.basename(path)] = bmp8_bytes(w, h, pixels, pal)

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
    'nodes.pag': 16,    # Node: planeid child0 child1 lfaceid lfacenum + bound[6]
    'clip.pag':   6,    # ClipNode: planenum front back
    'leaves.pag':16,    # Leaf: cont vislist bound[6] lfaceid lfacenum
    'faces.pag': 10,    # Face: planeid side geom_row geom_ofs texinfoid
}


# A node or leaf box in six bytes, (v + 4096) / 32 with the min rounded
# down and the max up, so a box only ever grows: r_cull_box_c culls less
# than it might, never more. bspfile.bi's PackedBounds, r_walk.c's unpack.
BOUND_Q = 32
BOUND_BASE = -4096


def bound_bytes(bound: bytes) -> bytes:
    mn = struct.unpack_from('<3h', bound, 0)
    mx = struct.unpack_from('<3h', bound, 6)
    lo = [(v - BOUND_BASE) // BOUND_Q for v in mn]
    hi = [-((BOUND_BASE - v) // BOUND_Q) for v in mx]
    if not all(0 <= q <= 255 for q in lo + hi):
        raise SystemExit(f'a box past the packed range: {mn} {mx}')
    return bytes(lo + hi)


# Arrays the renderer backs with CONVENTIONAL memory are laid out FLAT --
# no page padding. uglArr maps such a store once, whole, and the renderer
# then indexes arr(i) natively, so element i must be at exactly i*elem.
# Page padding would break that at every page boundary.
#
# EMS-backed arrays still need padding: a 16k frame really is a window.
FLAT = {'nodes.pag', 'clip.pag', 'leaves.pag', 'faces.pag'}


def write_flat(path, payload):
    OUT[os.path.basename(path)] = bytes(payload)
    return len(payload)
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
    OUT[os.path.basename(path)] = bytes(out)
    return len(out)
    return len(out)


def write_bload(path, payload):
    # headerless now: the loader takes the size from uarSize
    OUT[os.path.basename(path)] = bytes(payload)
    return len(payload)
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

    # Every lit face's planes, one a style, in face order and stacked lm_h
    # rows apart in its slot: R_BuildLightMap sums them, each scaled by its
    # style, and a flickering light lives only in a face's second plane.
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
        if lightofs + size * nstyles > len(lighting):
            raise SystemExit(f"face {k//20}: lightofs {lightofs}+{size}x{nstyles} "
                             f"runs past the {len(lighting)}-byte LIGHTING lump")
        if pot2(lm_w) * pot2(lm_h * nstyles) > LM_ATLAS_W:
            raise SystemExit(f"face {k//20}: {lm_w}x{lm_h}x{nstyles} luxels round up to "
                             f"a slot past one {LM_ATLAS_W}-byte scanline")
        runs.append((k // 20, size, lightofs, lm_w, lm_h * nstyles))

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

    # Raw rows of LM_ATLAS_W, top down, into a qgl EMS store of one row
    # per record -- the same shape fgeom.bin has. Padded above to a whole
    # row, which the loader demands.
    out['lm.bin'] = bytes(atlas)
    blob = atlas

    # The table is not written out on its own any more: convert_lumps folds
    # it into each face's geometry record, so one mapping and one copy per
    # drawn face fetch the corners and the lightmap placement together.
    return lit, unlit, 1, len(blob), 1, bytes(table)


ENT_PAIR = re.compile(r'"([^"]*)"\s*"([^"]*)"')
TRIG_ONCE, TRIG_MULTI, TRIG_COUNTER, TRIG_BUTTON, TRIG_EXIT, TRIG_SHOOT, TRIG_SECRET = 0, 1, 2, 3, 4, 5, 6   # ENT_TRIG_*
TRIG_SHOOTER = 7
TRIG_RELAY, TRIG_BOSS, TRIG_BOLT = 8, 9, 10   # a use passed on; Chthon, unseen; event_lightning
TRIG_FIREBALL = 11   # misc_fireball: a lava ball up from its origin every 3 to 8 seconds
KEY_NAMES = ('key', 'runekey', 'keycard')   # items.qc's netname by worldtype



@dataclass(slots=True, frozen=True)
class CrateSrc:
    size: tuple[float, float, float]
    faces: list[tuple[str, list[tuple[int, int, int]]]]   # texture, 4 x (corner bits, u*32, v*32)
    textures: dict[str, tuple[bytes, int]]                # name -> (buffer, miptex offset)


def pack_members(path: str, prefix: str) -> dict[str, bytes]:
    d = open(path, 'rb').read()
    magic, dirofs, dirlen = struct.unpack_from('<4sii', d, 0)
    if magic != b'PACK':
        raise SystemExit(f"{path} is not a PACK archive")
    out: dict[str, bytes] = {}
    for i in range(dirlen // 64):
        e = dirofs + 64 * i
        name = d[e:e + 56].split(b'\0')[0].decode('latin-1')
        off, ln = struct.unpack_from('<ii', d, e + 56)
        if name.startswith(prefix):
            out[name[len(prefix):]] = d[off:off + ln]
    return out


def crate_src(b: bytes) -> CrateSrc:
    # a b_*.bsp is one box from the origin: six faces, the bottom on the
    # floor and never shipped. u,v are the face's own, shifted up by whole
    # textures so the least is in [0,1) -- the filler wraps
    h = struct.unpack_from('<i30i', b, 0)
    lump = lambda k: (h[1 + 2 * k], h[2 + 2 * k])  # noqa: E731
    vo, vl = lump(3)
    verts = [struct.unpack_from('<3f', b, vo + j * 12) for j in range(vl // 12)]
    eo, el = lump(12)
    edges = [struct.unpack_from('<2H', b, eo + j * 4) for j in range(el // 4)]
    so, sl = lump(13)
    sedges = [struct.unpack_from('<i', b, so + j * 4)[0] for j in range(sl // 4)]
    to, tl = lump(6)
    tinf = [struct.unpack_from('<8fii', b, to + j * 40) for j in range(tl // 40)]
    xo, _ = lump(2)
    names: list[tuple[str, int, int]] = []
    textures: dict[str, tuple[bytes, int]] = {}
    for t in range(struct.unpack_from('<i', b, xo)[0]):
        o = struct.unpack_from('<i', b, xo + 4 + t * 4)[0]
        tn, w, hh = struct.unpack_from('<16sii', b, xo + o)
        name = tn.split(b'\0')[0].decode('latin-1')
        names.append((name, w, hh))
        textures[name] = (b, xo + o)
    size = tuple(max(v[i] for v in verts) for i in range(3))
    faces: list[tuple[str, list[tuple[int, int, int]]]] = []
    fo, fl = lump(7)
    for j in range(fl // 20):
        _, _, fe, ne, ti = struct.unpack_from('<hhihh', b, fo + j * 20)
        vs = []
        for k in range(ne):
            e = sedges[fe + k]
            vs.append(verts[edges[abs(e)][0 if e >= 0 else 1]])
        if all(v[2] == 0.0 for v in vs):
            continue
        t = tinf[ti]
        name, tw, th = names[t[8]]
        uv = [((t[0] * x + t[1] * y + t[2] * z + t[3]) / tw, (t[4] * x + t[5] * y + t[6] * z + t[7]) / th)
              for x, y, z in vs]
        du = -math.floor(min(u for u, _ in uv))
        dv = -math.floor(min(v for _, v in uv))
        faces.append((name, [((x > 0) | (y > 0) << 1 | (z > 0) << 2, round((u + du) * 32), round((v + dv) * 32))
                             for (x, y, z), (u, v) in zip(vs, uv)]))
        if len(vs) != 4:
            raise SystemExit(f"crate face {j} has {len(vs)} vertices")
    if len(faces) != 5:
        raise SystemExit(f"crate has {len(faces)} faces off the floor, not 5")
    return CrateSrc(size, faces, textures)


def load_crates(pak: str) -> dict[str, CrateSrc]:
    if not pak or not os.path.exists(pak):
        return {}
    return {n[:-4]: crate_src(b) for n, b in pack_members(pak, 'maps/').items() if n.startswith('b_')}


def crate_name(classname: str, amount: int) -> str | None:
    # items.qc's setmodel by spawnflags, which item_amount already read
    match classname, amount:
        case 'item_health', 15: return 'b_bh10'
        case 'item_health', 100: return 'b_bh100'
        case 'item_health', _: return 'b_bh25'
        case 'item_shells', 40: return 'b_shell1'
        case 'item_shells', _: return 'b_shell0'
        case 'item_spikes', 50: return 'b_nail1'
        case 'item_spikes', _: return 'b_nail0'
        case 'item_rockets', 10: return 'b_rock1'
        case 'item_rockets', _: return 'b_rock0'
        case 'misc_explobox', _: return 'b_explob'
        case _: return None


@dataclass(slots=True)
class CrateSet:
    src: dict[str, CrateSrc]
    tex_base: int                                            # the map's own texture count
    used: list[str] = field(default_factory=list)            # models in crate-index order
    tex: list[tuple[str, bytes, int]] = field(default_factory=list)   # atlas cells after the map's

    def crate(self, name: str | None) -> int:
        if name is None or name not in self.src:
            return -1
        if name not in self.used:
            self.used.append(name)
        return self.used.index(name)

    def tex_id(self, model: str, name: str) -> tuple[int, int]:
        # a +0name face brings every +Nname frame, consecutive: the
        # renderer steps them at 10 Hz as it does the world's chains
        textures = self.src[model].textures
        frames = sorted(n for n in textures if n[0] == '+' and n[2:] == name[2:]) if name[0] == '+' else [name]
        ids = []
        for n in frames:
            if n not in [t[0] for t in self.tex]:
                self.tex.append((n, *textures[n]))
            ids.append(self.tex_base + [t[0] for t in self.tex].index(n))
        if ids != list(range(ids[0], ids[0] + len(ids))):
            raise SystemExit(f"{name}'s frames are not consecutive in the atlas: {ids}")
        return ids[0], len(ids)

    def cells(self) -> list[tuple[bytes, int]]:
        return [(b, o) for _, b, o in self.tex]


def parse_entities(text: str, nmodels: int, boxes: list[tuple[float, ...]], skill: int, gravity: float,
                   crates: CrateSet) -> bytes:
    # Resolved here, not on the target: BASIC strings cap at 32,767 bytes
    # and e1m3's entities lump is 45,762 -- mod_find_spawn died at error 5
    # before anything else could. The renderer wants four facts out of the
    # text, so those are what ships: spawn, matched teleporter pairs,
    # func_plats, func_doors, what fires them, the monsters, and which
    # submodels a trigger hides. Layout must match the Ents* types in q_ent.bi.
    spawn: tuple[float, float, float] = (0.0, 0.0, 0.0)
    title = ''
    worldtype = 0
    angle = 0.0
    inter: tuple[tuple[float, float, float], float, float] | None = None   # origin, pitch, yaw
    next_map = ''
    dests: dict[str, tuple[tuple[float, float, float], float]] = {}
    trigs: list[tuple[str, int]] = []
    hides: list[int] = []
    bolt_doors: list[int] = []   # the electrode doors, target "lightning"
    plats: list[tuple[int, float, float]] = []
    doors: list[tuple[int, tuple[float, float, float], float, float, int, int, int]] = []
    items: list[tuple[int, int, tuple[float, float, float]]] = []
    uses: list[tuple] = []
    names: dict[str, int] = {}
    mons: list[tuple[int, tuple[float, float, float], float]] = []
    ambs: list[tuple[int, int, tuple[float, float, float]]] = []
    corners: list[tuple[str, tuple[float, float, float], float, str]] = []   # targetname, origin, wait, target
    trains: list[tuple[int, float, int, str]] = []                           # model, speed, targetname id, first corner
    # misc.qc's ambientsound calls: the wav and its volume, ATTN_STATIC
    amb_kind = {'ambient_comp_hum': ('ambience/comp1', 1.0), 'ambient_drone': ('ambience/drone6', 0.5),
                'ambient_drip': ('ambience/drip1', 0.5), 'ambient_swamp1': ('ambience/swamp1', 0.5),
                'ambient_swamp2': ('ambience/swamp2', 0.5)}
    mon_kind = {'monster_army': 0, 'monster_knight': 1, 'monster_dog': 2, 'monster_ogre': 3, 'monster_demon1': 4,
                'monster_zombie': 5, 'monster_wizard': 6, 'monster_shambler': 7}   # MDL_KIND_*; no model for the rest
    item_kind = {'item_health': 0, 'item_shells': 1, 'item_armor1': 2, 'item_armor2': 3,
                 'weapon_supershotgun': 4, 'item_spikes': 5, 'weapon_nailgun': 6,
                 'item_artifact_super_damage': 7, 'item_artifact_envirosuit': 8, 'misc_explobox': 9,
                 'item_key1': 10, 'item_key2': 11, 'weapon_grenadelauncher': 12, 'item_rockets': 13,
                 'weapon_supernailgun': 14, 'weapon_rocketlauncher': 15,
                 'item_artifact_invulnerability': 16, 'item_sigil': 17}

    def vec(v: str) -> tuple[float, float, float]:
        x, y, z = (float(t) for t in v.split())
        return (x, y, z)

    def item_amount(classname: str, flags: int) -> int:
        # items.qc: H_ROTTEN 15, H_MEGA 100, else 25; WEAPON_BIG2 40 shells,
        # else 20; armor_touch's 100 green, 150 yellow; weapon_touch's
        # 5 shells with the super shotgun, 30 nails with either nailgun and
        # 5 rockets with either launcher; item_rockets 5, WEAPON_BIG2 10;
        # item_spikes 25, WEAPON_BIG2 50; a powerup's 30 seconds; the
        # exploding box's 20 health
        match classname, flags & 1, flags & 2:
            case 'item_artifact_super_damage' | 'item_artifact_envirosuit' | 'item_artifact_invulnerability', _, _:
                return 30
            case 'misc_explobox', _, _: return 20
            case 'weapon_supershotgun', _, _: return 5
            case 'weapon_nailgun', _, _: return 30
            case 'weapon_grenadelauncher' | 'weapon_rocketlauncher', _, _: return 5
            case 'weapon_supernailgun', _, _: return 30
            case 'item_rockets', 1, _: return 10
            case 'item_rockets', _, _: return 5
            case 'item_spikes', 1, _: return 50
            case 'item_spikes', _, _: return 25
            case 'item_armor1', _, _: return 100
            case 'item_armor2', _, _: return 150
            case 'item_health', 1, _: return 15
            case 'item_health', _, 2: return 100
            case 'item_health', _, _: return 25
            case _, 1, _: return 40
            case _: return 20

    def name_id(s: str) -> int:
        # targetnames become ids; 0 is none
        return names.setdefault(s, len(names) + 1) if s else 0

    def msg_of(kv: dict[str, str]) -> bytes:
        # the first line: a map's newline is a literal backslash-n, and the
        # overlay draws one line of 40; only start's registered notice has more
        return kv.get('message', '').split('\\n')[0][:40].encode('latin1').ljust(40)

    def movedir(angle: float) -> tuple[float, float, float]:
        # SetMovedir: angle -1 up, -2 down, anything else a heading
        match angle:
            case -1.0: return (0.0, 0.0, 1.0)
            case -2.0: return (0.0, 0.0, -1.0)
            case _: return (math.cos(math.radians(angle)), math.sin(math.radians(angle)), 0.0)

    def travel_of(angle: float, box: tuple[float, ...], lip: float) -> tuple[float, float, float]:
        # the brush moves its size along its movedir, less the lip
        mdir = movedir(angle)
        size = [box[k + 3] - box[k] for k in range(3)]
        dist = max(sum(abs(mdir[k]) * size[k] for k in range(3)) - lip, 0.0)
        return (mdir[0] * dist, mdir[1] * dist, mdir[2] * dist)

    def door_record(m: int, kv: dict[str, str], box: tuple[float, ...]) -> tuple:
        # func_door: speed 100, wait 3, lip 8 unless the map says
        speed = float(kv.get('speed', '0')) or 100.0
        hold = float(kv.get('wait', '0')) or 3.0
        lip = float(kv.get('lip', '0')) or 8.0
        flags = int(kv.get('spawnflags', '0'))
        travel = travel_of(float(kv.get('angle', '0')), box, lip)
        # DOOR_SILVER_KEY 16, DOOR_GOLD_KEY 8: door_touch's "You need the
        # silver key" stands in for a message the map does not give
        key = 1 if flags & 16 else 2 if flags & 8 else 0
        msg = msg_of(kv)
        if key and not kv.get('message'):
            msg = f"You need the {'silver' if key == 1 else 'gold'} {KEY_NAMES[worldtype]}".encode('latin1').ljust(40)
        return (m, travel, (0.0, 0.0, 0.0), speed, hold, 1 if flags & 1 else 0, 1 if flags & 4 else 0,
                name_id(kv.get('targetname', '')), 0, 0, int(kv.get('sounds', '0')), key, msg)

    def secret_record(m: int, kv: dict[str, str], box: tuple[float, ...]) -> tuple:
        # func_door_secret, fd_secret_use: back t_width along v_right (or
        # down), then t_length along v_forward; speed 50, wait 5, open_once
        # stays; shot open unless named, or no_shoot, or always_shoot
        flags = int(kv.get('spawnflags', '0'))
        yaw = math.radians(float(kv.get('angle', '0')))
        fwd = (math.cos(yaw), math.sin(yaw), 0.0)
        right = (math.sin(yaw), -math.cos(yaw), 0.0)
        size = [box[k + 3] - box[k] for k in range(3)]
        width = float(kv.get('t_width', '0')) or (size[2] if flags & 4 else abs(sum(right[k] * size[k] for k in range(3))))
        length = float(kv.get('t_length', '0')) or abs(sum(fwd[k] * size[k] for k in range(3)))
        temp = 1.0 - (flags & 2)
        mid = (0.0, 0.0, -width) if flags & 4 else tuple(right[k] * width * temp for k in range(3))
        travel = tuple(mid[k] + fwd[k] * length for k in range(3))
        speed = float(kv.get('speed', '0')) or 50.0
        hold = -1.0 if flags & 1 else (float(kv.get('wait', '0')) or 5.0)
        name = name_id(kv.get('targetname', ''))
        shoot = 0 if flags & 8 else (1 if not name or flags & 16 else 0)
        return (m, travel, mid, speed, hold, 0, 1, name, 1, shoot, int(kv.get('sounds', '0')) or 3, 0, msg_of(kv))

    def trig_record(m: int, kv: dict[str, str]) -> tuple:
        # trigger_once is a multiple with wait -1; a multiple re-arms after
        # wait, 0.2 unless the map says; a counter fires at count, 2
        match kv['classname']:
            case 'trigger_secret': kind, wait, count = TRIG_SECRET, -1.0, 0
            case 'trigger_once': kind, wait, count = TRIG_ONCE, -1.0, 0
            case 'trigger_multiple': kind, wait, count = TRIG_MULTI, float(kv.get('wait', '0')) or 0.2, 0
            case _: kind, wait, count = TRIG_COUNTER, -1.0, int(kv.get('count', '0')) or 2
        if int(kv.get('health', '0')) > 0:
            kind = TRIG_SHOOT   # multi_killed: shot, not touched; wait as above
        msg = msg_of(kv)
        snd = int(kv.get('sounds', '0'))
        if kind == TRIG_SECRET:
            snd = snd or 1
            if not kv.get('message'):
                msg = b'You found a secret area!'.ljust(40)
        # delay: SUB_UseTargets' DelayThink, seconds before the target fires
        return (m, kind, name_id(kv.get('target', '')), name_id(kv.get('targetname', '')),
                name_id(kv.get('killtarget', '')), count, wait, 0.0, (0.0, 0.0, 0.0), snd, msg,
                (0.0, 0.0, 0.0), float(kv.get('delay', '0')))

    def button_record(m: int, kv: dict[str, str], box: tuple[float, ...]) -> tuple:
        # func_button: speed 40, wait 1, lip 4; wait -1 stays pressed
        speed = float(kv.get('speed', '0')) or 40.0
        wait = float(kv.get('wait', '0')) or 1.0
        lip = float(kv.get('lip', '0')) or 4.0
        travel = travel_of(float(kv.get('angle', '0')), box, lip)
        return (m, TRIG_BUTTON, name_id(kv.get('target', '')), name_id(kv.get('targetname', '')),
                name_id(kv.get('killtarget', '')), 0, wait, speed, travel, int(kv.get('sounds', '0')), msg_of(kv))

    def model(v: str) -> int:
        m = int(v[1:]) if v.startswith('*') and v[1:].isdigit() else 0
        return m if 0 < m < nmodels else 0

    # NOT_EASY 256, NOT_MEDIUM 512, NOT_HARD 1024, on any entity -- e1m1's
    # ambush hints exist only below hard; nightmare is hard's set
    skip = 256 << min(skill, 2)
    lights: list[tuple[int, int, int]] = []   # targetname id, style, starts on
    for block in text.split('{')[1:]:
        kv = dict(ENT_PAIR.findall(block.split('}')[0]))
        if int(kv.get('spawnflags', '0')) & skip:
            continue
        match kv.get('classname'):
            case 'worldspawn':
                title = kv.get('message', '')
                worldtype = int(kv.get('worldtype', '0') or 0)
            case 'info_player_start':
                spawn = vec(kv.get('origin', '0 0 0'))
                angle = float(kv.get('angle', '0'))
            case 'info_intermission' if inter is None:
                # FindIntermission picks one at random; the first is as good
                mangle = vec(kv.get('mangle', '0 0 0'))
                inter = (vec(kv.get('origin', '0 0 0')), mangle[0], mangle[1])
            case 'info_teleport_destination':
                dests[kv.get('targetname', '')] = (
                    vec(kv.get('origin', '0 0 0')), float(kv.get('angle', '0')))
            case 'trigger_teleport' if model(kv.get('model', '')):
                trigs.append((kv.get('target', ''), model(kv['model'])))
                hides.append(model(kv['model']))
            case 'trigger_once' | 'trigger_multiple' if model(kv.get('model', '')):
                hides.append(model(kv['model']))
                uses.append(trig_record(model(kv['model']), kv))
            case 'trigger_secret' if model(kv.get('model', '')):
                hides.append(model(kv['model']))
                uses.append(trig_record(model(kv['model']), kv))
            case 'trigger_counter':
                if model(kv.get('model', '')):
                    hides.append(model(kv['model']))
                uses.append(trig_record(model(kv.get('model', '')), kv))
            case 'trap_spikeshooter':
                # spikeshooter_use: a spike along movedir at 500 when used;
                # SUPERSPIKE (1) bites 18 for 9. wait carries the damage
                uses.append((0, TRIG_SHOOTER, 0, name_id(kv.get('targetname', '')), 0,
                             18 if int(kv.get('spawnflags', '0')) & 1 else 9, 0.0, 500.0,
                             movedir(float(kv.get('angle', '0'))), 0, b''.ljust(40), vec(kv.get('origin', '0 0 0'))))
            case 'trigger_changelevel' if model(kv.get('model', '')):
                # the level ends here; its message is the map's title
                hides.append(model(kv['model']))
                uses.append((model(kv['model']), TRIG_EXIT, 0, 0, 0, 0, -1.0, 0.0, (0.0, 0.0, 0.0), 0,
                             title[:40].encode('latin1').ljust(40)))
                next_map = kv.get('map', '')
            case 'func_button' if model(kv.get('model', '')):
                uses.append(button_record(model(kv['model']), kv, boxes[model(kv['model'])]))
            case 'misc_fireball':
                # speed as the map gives it: id's default is `self.speed == 1000`,
                # a compare, so an unset one leaves 0 and the ball rises 0..200
                uses.append((0, TRIG_FIREBALL, 0, 0, 0, 0, 0.0, float(kv.get('speed', '0')),
                             (0.0, 0.0, 0.0), 0, b''.ljust(40), vec(kv.get('origin', '0 0 0'))))
            case 'trigger_relay':
                # SUB_UseTargets passed on, at once: delay is not ported
                uses.append((0, TRIG_RELAY, name_id(kv.get('target', '')), name_id(kv.get('targetname', '')),
                             name_id(kv.get('killtarget', '')), 0, 0.0, 0.0, (0.0, 0.0, 0.0), 0, msg_of(kv)))
            case 'monster_boss':
                # Chthon, unseen (boss.mdl is past MDL_MAXV): the rune wakes him, his
                # health boss_awake's 1 on easy else 3, a bolt a point, dead his target fires
                uses.append((0, TRIG_BOSS, name_id(kv.get('target', '')), name_id(kv.get('targetname', '')),
                             0, 1 if skill == 0 else 3, 0.0, 0.0, (0.0, 0.0, 0.0), 0, b''.ljust(40)))
            case 'event_lightning':
                # lightning_use: a point off Chthon with both electrode doors up; travel
                # carries the doors' indices, patched below once every door is read
                uses.append((0, TRIG_BOLT, 0, name_id(kv.get('targetname', '')),
                             0, 0, 0.0, 0.0, (0.0, 0.0, 0.0), 0, b''.ljust(40)))
            case 'trigger_onlyregistered' if model(kv.get('model', '')) and kv.get('message'):
                # OnlyRegisteredTouch on the shareware: the message and misc/talk
                # every two seconds, its target never fired -- a multiple with no target
                hides.append(model(kv['model']))
                uses.append(trig_record(model(kv['model']), {
                    'classname': 'trigger_multiple', 'message': kv['message'], 'wait': '2'}))
            case str(c) if c.startswith('trigger_') and model(kv.get('model', '')):
                # any trigger's brush is a volume: e1m1 drew its changelevel
                # as a column of the "trigger" texture
                hides.append(model(kv['model']))
            case 'func_episodegate' if model(kv.get('model', '')):
                # misc.qc spawns it only for a rune held, and none ever is here;
                # func_bossgate is the reverse, gone with all four, so it stays
                hides.append(model(kv['model']))
            case 'func_door' if model(kv.get('model', '')):
                if kv.get('target') == 'lightning':
                    bolt_doors.append(len(doors))
                doors.append(door_record(model(kv['model']), kv, boxes[model(kv['model'])]))
            case 'func_door_secret' if model(kv.get('model', '')):
                doors.append(secret_record(model(kv['model']), kv, boxes[model(kv['model'])]))
            case 'light' | 'light_fluoro' if int(kv.get('style', '0') or 0) >= 32:
                # light_use toggles its style between "m" and "a", START_OFF (1)
                # starting it "a"; a plain light with no targetname is removed
                # before it sets anything
                if kv.get('targetname') or kv['classname'] == 'light_fluoro':
                    lights.append((name_id(kv.get('targetname', '')), int(kv['style']),
                                   0 if int(kv.get('spawnflags', '0')) & 1 else 1))
            case 'path_corner':
                corners.append((kv.get('targetname', ''), vec(kv.get('origin', '0 0 0')), float(kv.get('wait', '0')),
                                kv.get('target', '')))
            case 'func_train' if model(kv.get('model', '')):
                # func_train: speed 100; a targetname waits for its trigger
                trains.append((model(kv['model']), float(kv.get('speed', '0')) or 100.0,
                               name_id(kv.get('targetname', '')), kv.get('target', '')))
            case 'func_plat' if model(kv.get('model', '')):
                plats.append((model(kv['model']),
                              float(kv.get('speed', '0')),
                              float(kv.get('height', '0'))))
            case str(c) if c in mon_kind:
                mons.append((mon_kind[c], vec(kv.get('origin', '0 0 0')), float(kv.get('angle', '0')),
                             kv.get('target', '')))
            case str(c) if c in item_kind:
                amount = item_amount(c, int(kv.get('spawnflags', '0')))
                items.append((item_kind[c], amount, name_id(kv.get('target', '')),
                              crates.crate(crate_name(c, amount)), vec(kv.get('origin', '0 0 0'))))
            case str(c) if c in amb_kind:
                wav, fvol = amb_kind[c]
                ambs.append((mksnd.SOUNDS.index(wav), int(255 * fvol), vec(kv.get('origin', '0 0 0'))))

    # a teleporter with no destination still hides its brush
    teles = [(m, *dests[t]) for t, m in trigs if t in dests]

    if inter is None:
        inter = (spawn, 0.0, angle)   # no info_intermission: the start, as Quake does
    # corners by index, each pointing at the next; a train at one with no target stays
    corner_at = {name: i for i, (name, _, _, _) in reversed(list(enumerate(corners))) if name}
    trains = [(m, speed, targeted, corner_at[first]) for m, speed, targeted, first in trains if first in corner_at]
    if any(u[1] == TRIG_BOLT for u in uses):
        assert len(bolt_doors) == 2, bolt_doors
        uses = [(*u[:8], (float(bolt_doors[0]), float(bolt_doors[1]), 0.0), *u[9:]) if u[1] == TRIG_BOLT else u
                for u in uses]
    # messages are ids into one table after the crates, 0 none: 40 bytes a
    # record was 3K on e1m4, whose 78 doors and triggers say two things
    msgs: dict[bytes, int] = {}

    def msg_id(b: bytes) -> int:
        return msgs.setdefault(b, len(msgs) + 1) if b.strip() else 0

    for d in doors:
        msg_id(d[-1])
    for u in uses:
        msg_id(u[10])
    buf = bytearray(struct.pack(ENTS_HEAD, *spawn, angle, *inter[0], inter[1], inter[2], nmodels,
                                len(teles), len(plats), len(hides), len(items), len(doors), len(uses), len(mons),
                                len(ambs), len(trains), len(corners), worldtype, len(crates.used), gravity,
                                next_map[:8].encode('latin1').ljust(8), len(msgs), len(lights)))
    for kind, org, yaw, target in mons:
        buf += struct.pack('<h3ffh', kind, *org, yaw, corner_at.get(target, -1))   # its patrol's first corner
    for m, org, yaw in teles:
        buf += struct.pack('<h3ff', m, *org, yaw)
    for m, speed, height in plats:
        buf += struct.pack('<hff', m, speed, height)
    for m in hides:
        buf += struct.pack('<h', m)
    for kind, amount, target, crate, org in items:
        buf += struct.pack('<hhhh3f', kind, amount, target, crate, *org)
    for m, travel, mid, speed, hold, start_open, nolink, targeted, secret, shoot, snd, key, msg in doors:
        buf += struct.pack('<h3f3fffhhhhhhhh', m, *travel, *mid, speed, hold, start_open, nolink, targeted,
                           secret, shoot, snd, key, msg_id(msg))
    for m, kind, target, name, kill, count, wait, speed, travel, snd, msg, *rest in uses:
        org = rest[0] if rest else (0.0, 0.0, 0.0)   # a shooter's
        delay = rest[1] if len(rest) > 1 else 0.0
        buf += struct.pack('<6hff3f3fhhf', m, kind, target, name, kill, count, wait, speed, *travel, *org, snd,
                           msg_id(msg), delay)
    for snd, vol, org in ambs:
        buf += struct.pack('<hh3f', snd, vol, *org)
    for m, speed, targeted, first in trains:
        buf += struct.pack('<hfhh', m, speed, targeted, first)
    for _, org, wait, target in corners:
        buf += struct.pack('<3ffh', *org, wait, corner_at.get(target, -1))
    # q_ent.bi's CrateModel: the size, then five faces of atlas id,
    # frame count and four (corner bits, u*32, v*32)
    for name in crates.used:
        src = crates.src[name]
        buf += struct.pack('<3f', *src.size)
        for tn, corners4 in src.faces:
            tex, frames = crates.tex_id(name, tn)
            buf += struct.pack('<hh12b', tex, frames, *(v for corner in corners4 for v in corner))
    for name, style, on in lights:
        buf += struct.pack('<3h', name, style, on)
    for b in msgs:
        buf += b
    return bytes(buf)


def convert_lumps(d, lumps, outdir, skill, gravity, crates):
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
        # 33 corners is the standing contract, and d_faces.c's MAXV is
        # derived from it; a face past it runs off every per-face array.
        if not (0 < nvtx <= GEOM_MAXVTX):
            raise SystemExit(
                f"fgeom.bin: face {k // 20} has {nvtx} corners, and "
                f"GEOM_MAXVTX is {GEOM_MAXVTX}")
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
    boxes = [struct.unpack_from('<6f', lump(14), m * 64) for m in range(nmodels)]
    out['ents.bin'] = parse_entities(ent_text, nmodels, boxes, skill, gravity, crates)

    # marksurfaces: identical either side. models: 64 -> 32, bspfile.bi's
    # Submodel -- the box, hulls 0 and 1, the face run
    out['lface.bld'] = lump(11)
    out['models.bld'] = b''.join(struct.pack('<6f4h', *struct.unpack_from('<6f', lump(14), m * 64),
                                             *struct.unpack_from('<2i', lump(14), m * 64 + 36),
                                             *struct.unpack_from('<2i', lump(14), m * 64 + 56))
                                 for m in range(nmodels))
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

    # leaves: leaf(28) -> Leaf(16), dropping the trailing 4 bytes,
    # narrowing cont to an integer (always one of six small CONTENTS_*
    # negatives -- see bspfile.bi's Leaf comment) and the box to bytes
    raw = lump(10)
    buf = bytearray()
    for k in range(0, len(raw), 28):
        cont, vislist = struct.unpack_from('<ii', raw, k)
        bound = bound_bytes(raw[k+8:k+20])
        lfaceid, lfacenum = struct.unpack_from('<hh', raw, k+20)
        buf += struct.pack('<h', cont) + struct.pack('<i', vislist) + bound + struct.pack('<hh', lfaceid, lfacenum)
    out['leaves.pag'] = bytes(buf)

    # planes: plane(20) -> Plane(16), the type dropped -- nothing reads it
    raw = lump(1)
    buf = bytearray()
    for k in range(0, len(raw), 20):
        buf += raw[k:k + 16]
    out['planes.bld'] = bytes(buf)

    # nodes: node(24) -> Node(16). planeid narrows, the box packs, and it
    # moves to the end -- the two structures are not in the same order.
    raw = lump(5)
    buf = bytearray()
    for k in range(0, len(raw), 24):
        planeid, child0, child1 = struct.unpack_from('<ihh', raw, k)
        bound = bound_bytes(raw[k+8:k+20])
        lfaceid, lfacenum = struct.unpack_from('<hh', raw, k+20)
        buf += struct.pack('<hhhhh', planeid, child0, child1, lfaceid, lfacenum) + bound
    out['nodes.pag'] = bytes(buf)

    total = 0
    for name, payload in out.items():
        path = os.path.join(outdir, name)
        if name.endswith('.pag'):
            if name in FLAT:
                total += write_flat(path, payload)
            else:
                # page-padded: read a page at a time into an EMS window
                total += write_paged(path, payload, PAGED_ELEM[name])
        elif name.endswith('.bin'):
            # raw: read through qglFileRead into a block or straight into
            # a mapped EMS window, so none of them is bound by BLOAD's
            # 64K cap or by BASIC's far heap
            OUT[name] = bytes(payload)
            total += len(payload)
        else:
            total += write_bload(path, payload)
        print(f"  {name:12} {len(payload):7,} bytes")
    print(f"  lumps total  {total:7,} bytes")


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: mkassets.py <map.bsp> <base.dat> <outdir> [skill 0..3, 0] [pak0.pak: the pickups' b_*.bsp]")
    bsp, packpath, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    skill = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    pak = sys.argv[5] if len(sys.argv) > 5 else ''
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
    OUT['colmap.bin'] = bytes(cmap[:64*256])
    # qgl links a zip driver and no PACK driver, so the font travels in
    # assets.zip; the BASIC build reads it straight out of base.dat.
    OUT['font.fnt'] = pack_read(packpath, 'font/4x6.fnt')
    print(f"  colmap.bin    {64*256:7,} bytes  (64 shades x 256)")
    print("building inverse palette cube ...", flush=True)
    cube, bits = inverse_palette(pal)

    lumps   = read_lumps(d)
    toff, _ = lumps[2]
    ntex    = struct.unpack_from('<i', d, toff)[0]
    offs    = [struct.unpack_from('<i', d, toff + 4 + 4*k)[0] for k in range(ntex)]
    # the pickups' b_*.bsp boxes: their textures are cells after the map's
    crates  = CrateSet(load_crates(pak), ntex)
    print("converting lumps ...", flush=True)
    # world.qc: sv_gravity 100 on e1m8, 800 everywhere else
    gravity = 100.0 if os.path.basename(bsp).lower() == 'e1m8.bsp' else 800.0
    convert_lumps(d, lumps, outdir, skill, gravity, crates)
    cells = [(d, toff + o) if o >= 0 else None for o in offs] + crates.cells()
    ntex  = len(cells)
    if ntex * MIPS > 1024:
        raise SystemExit(f"{ntex} textures with the pickups': q_map.bi's ofs(1023) holds 256")
    print(f"  crates: {len(crates.used)} models, {len(crates.tex)} textures after the map's {len(offs)}")

    # What the runtime used to read out of the .bsp itself, so it no
    # longer has to open it: the lump COUNTS, and the miptex headers,
    # whose NAMES are what say which texture is a liquid and which is
    # one frame of an animation. bsphdr.h's DiskMipTex, 40 bytes, one
    # per texture the map owns -- the crates' cells come after those in
    # the atlas and have no header here. A texture the map lists with a
    # -1 offset has none on disk either; it ships as zeros, which is a
    # blank name, which is neither a liquid nor a chain.
    OUT['miptex.bin'] = b''.join(
        d[toff + o : toff + o + 40] if o >= 0 else bytes(40) for o in offs)
    # mod.h's QmapCounts, in its field order. The divisors are
    # bsphdr.h's DISK*_SIZE, and they are the same fact twice by
    # necessity -- one side writes the count, the other only reads it.
    OUT['counts.bin'] = struct.pack(
        '<11lh',
        lumps[7][1] // 20,      # faces      DISKFACE_SIZE
        lumps[3][1] // 12,      # verts      DISKVERTEX_SIZE
        lumps[12][1] // 4,      # edges      DISKEDGE_SIZE
        lumps[13][1] // 4,      # ledges     DISKLEDGE_SIZE
        lumps[10][1] // 28,     # leaves     DISKLEAF_SIZE
        lumps[1][1] // 20,      # planes     DISKPLANE_SIZE
        lumps[5][1] // 24,      # nodes      DISKNODE_SIZE
        lumps[6][1] // 40,      # tex_infos  DISKTEXINFO_SIZE
        lumps[9][1] // 8,       # clips      DISKCLIPNODE_SIZE
        len(offs),              # textures, the map's own
        lumps[11][1],           # face_lump_bytes
        lumps[14][1] // 64 )    # models     DISKSUBMODEL_SIZE

    # ------------------------------------------------------------------
    # Two atlases and a lookup table, not 648 dcs.
    #
    # Each texture used to become its own EMS dc, four mips times two
    # variants: 160 dcs on dm3ish at 264 bytes of CONVENTIONAL memory each
    # for the struct and scanline table, measured at 42,176. e1m1 would
    # make 648 -- the ~171K that stops it loading. One store per variant
    # instead, with the renderer making one VIEW per cell HEIGHT and
    # re-shaping it per face.
    #
    # Cell-major, every cell a self-aligned power-of-two run, packed
    # largest first -- so an offset is always a multiple of its own size
    # and no cell can straddle the 16K window a view maps (uglview.asm).
    # With the sizes descending that alignment is free: each area divides
    # the one before it.
    levels = []
    for cl in cells:
        if cl is None:
            levels.append([(8, 8)] * MIPS)
            continue
        buf, base = cl
        w, h = struct.unpack_from('<ii', buf, base + 16)
        levels.append(tex_cell_levels(w, h))

    def shared(k, lvl):
        return lvl > 0 and levels[k][lvl] == levels[k][lvl - 1]

    blocks = [(cw * ch, k, lvl)
              for k in range(ntex)
              for lvl, (cw, ch) in enumerate(levels[k]) if not shared(k, lvl)]
    blocks.sort(key=lambda b: -b[0])

    place, pos = [[0] * MIPS for _ in range(ntex)], 0
    for area, k, lvl in blocks:
        assert pos % area == 0, "cell not self-aligned"
        place[k][lvl] = pos
        pos += area
    for k in range(ntex):
        for lvl in range(1, MIPS):
            if shared(k, lvl):
                place[k][lvl] = place[k][lvl - 1]
    assert pos < (1 << OFS_BITS), f"atlas {pos} bytes, past what the table can say"

    raw_at, shd_at = bytearray(pos), bytearray(pos)
    for k, cl in enumerate(cells):
        for lvl in range(MIPS):
            if shared(k, lvl):
                continue
            cw, ch = levels[k][lvl]
            o = place[k][lvl]
            if cl is None:
                continue                       # already zeros
            buf, base = cl
            w, h = struct.unpack_from('<ii', buf, base + 16)
            mo   = struct.unpack_from('<i',  buf, base + 24 + 4*lvl)[0]
            mw, mh = w >> lvl, h >> lvl
            src  = buf[base+mo : base+mo + mw*mh]
            if len(src) < mw*mh:
                print(f"  ! texture {k} mip {lvl} truncated, left blank")
                continue
            # raw: indices, for the surface builder, which shades through the
            # full colormap itself. shaded: row 0 applied, for the unlit path.
            lit = bytes(shade0[b] for b in src)
            # A cell at the texture's own size is a COPY. resample would
            # sample every texel at its own centre and still round-trip it
            # RGB -> cube -> index, which moves indices the atlas is meant
            # to carry exactly.
            if (mw, mh) == (cw, ch):
                raw_at[o:o+cw*ch] = src
                shd_at[o:o+cw*ch] = lit
            else:
                raw_at[o:o+cw*ch] = resample(src, mw, mh, cw, ch, pal, cube, bits)
                shd_at[o:o+cw*ch] = resample(lit, mw, mh, cw, ch, pal, cube, bits)

    exact = sum(1 for k, cl in enumerate(cells)
                if cl is not None and
                levels[k][0] == tuple(struct.unpack_from('<ii', cl[0], cl[1] + 16)))
    print(f"  atlas: {pos:,} bytes a variant, {exact}/{ntex} textures at native size")

    for at in (raw_at, shd_at):
        if len(at) % LM_ATLAS_W:
            at += bytes(LM_ATLAS_W - (len(at) % LM_ATLAS_W))
    rows = len(raw_at) // LM_ATLAS_W
    # Loose and raw, beside the exe, for the same reason lm.bin is raw --
    # and loose rather than zipped because qgl maps them into EMS a page
    # at a time, which a deflated member cannot serve.
    for name, at in (("TEXR.RAW", raw_at), ("TEXS.RAW", shd_at)):
        with open(os.path.join(outdir, name), "wb") as fh:
            fh.write(bytes(at))
        print(f"  {name}: {LM_ATLAS_W}x{rows} = {len(at):,} bytes")

    # The same bytes again, flat and beside the exe rather than in the zip,
    # because qgl reads them: qglSfLoad is a raw blob straight into an EMS
    # surface's store and file.asm is plain INT 21h, which cannot see inside
    # assets.zip. Same delivery FONT.FNT and SOLDIER.GEO already use -- the
    # zip is for what mgl loads.
    #
    # Truncated to exactly rows*LM_ATLAS_W: qglSfLoad reads y_res rows of
    # x_res and fails the load if any row runs short, so the file has to be
    # the surface's own size and not a byte more.
    qmap_texr = qmap_texs = b""
    for name, at in (("texr.raw", raw_at), ("texs.raw", shd_at)):
        payload = bytes(at)[: rows * LM_ATLAS_W]
        open(os.path.join(outdir, name), "wb").write(payload)
        if name == "texr.raw": qmap_texr = payload
        else:                  qmap_texs = payload
        print(f"  {name}: {LM_ATLAS_W}x{rows} = {len(payload):,} bytes (flat, unzipped)")

    # The palette too, flat: screen.bas picks the HUD colours out of it and
    # writes it into screenshots, and reads it with a plain OPEN.
    pal_raw = pack_read(packpath, 'color/palette.lmp')[:768]
    open(os.path.join(outdir, "pal.raw"), "wb").write(pal_raw)
    qmap_pal = pal_raw
    print(f"  pal.raw: {len(pal_raw)} bytes (flat, unzipped)")

    # [id*4 + lvl] -> the cell's byte offset in bits 0..22, then log2 of
    # its width in 23..26 and of its height in 27..30. Bit 31 stays clear
    # so BASIC's signed long arithmetic reads it like any other positive
    # number -- `p \ 65536` truncating toward zero has cost this project a
    # day before now.
    #
    # In the entry rather than beside it because the dims are wanted at
    # exactly the sites that already read the offset, and a second table
    # is 1K of near data on the C side and 2K on BASIC's, which is the
    # memory neither has. The offset is still EMITTED, not re-derived.
    tbl = bytearray()
    for k in range(ntex):
        for lvl in range(MIPS):
            cw, ch = levels[k][lvl]
            tbl += struct.pack('<l', place[k][lvl]
                               | (cw.bit_length() - 1) << OFS_BITS
                               | (ch.bit_length() - 1) << (OFS_BITS + 4))
    write_bload(os.path.join(outdir, "texofs.bld"), bytes(tbl))
    print(f"  texofs.bld: {ntex} x {MIPS} cells, offset and dims")
    written = MIPS * 2

    print(f"done: {written} atlases for {ntex} textures across {MIPS} mip levels")

    # Portals, rebuilt from the tree -- tools/mkportals.py says why -- held to
    # its PVS-subset check here too, so a map whose portals do not cover the
    # PVS fails the build rather than culling what it should have drawn.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import mkportals
    pb = mkportals.read_bsp(bsp)
    portals = mkportals.build_portals(pb)
    checked, bad = mkportals.pvs_subset_check(pb, portals)
    if bad:
        # e1m4: 152 of 1230. Such a map ships an index of zeros -- a ref count
        # of 0 -- and r_load_portals leaves pt_ok 0, so the walk reads the PVS
        # alone. Its table would have passed the runtime's 4,681 anyway.
        print(f"  portals do not cover the PVS: {bad} of {checked} leaves; shipped without, the PVS alone draws")
        OUT['portalidx.bld'] = bytes(2 * (len(pb.leaves) + 1))
    else:
        OUT['portalidx.bld'], OUT['portalref.bld'] = mkportals.portal_lumps(pb, portals)
        print(f"  portals: {len(OUT['portalref.bld'])//14} refs over {len(pb.leaves)} leaves")

    write_zip(os.path.join(outdir, 'assets.zip'))

    # And the same bytes as ONE file. The zip and the three loose ones
    # stay for the BASIC build, which still stages five things; cport
    # reads this and nothing else.
    stem = os.path.splitext(os.path.basename(bsp))[0]
    # Only the kinds the map actually spawns, read back out of the
    # ents.bin just written rather than kept on the side: the file is
    # what the runtime loads, so it is what decides which models ship.
    head = struct.calcsize('<3ff3fff')
    nmon = struct.unpack_from('<13h', OUT['ents.bin'], head)[7]
    kinds = {struct.unpack_from('<h', OUT['ents.bin'], struct.calcsize(ENTS_HEAD) + i * 20)[0]
             for i in range(nmon)}
    models = build_models(pak, kinds, os.path.join(outdir, '.mdl'))
    sbar = build_sbar(pak, os.path.join(outdir, '.gfx'))
    sounds = build_sounds(pak, os.path.join(outdir, '.snd'))
    write_qmap(os.path.join(outdir, stem + '.qmp'), stem, d,
               dict(OUT, **models, **sbar, **sounds,
                    **{'texr.raw': qmap_texr, 'texs.raw': qmap_texs, 'pal.raw': qmap_pal}))

main()
