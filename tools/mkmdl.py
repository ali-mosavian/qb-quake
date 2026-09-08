#!/usr/bin/env python3
"""mkmdl.py -- emit one Quake alias model as loadable geometry + a skin.

The counterpart to mkspr.py: instead of pre-rendering the model to sprites,
this ships the triangles so the renderer can transform them per frame. It
exists to make the comparison measurable -- same monster, same map, sprites
against real geometry.

    tools/mkmdl.py PAK0.PAK soldier out/

Emits (DOS 8.3 names, since the loader opens them by name):

    <name>.geo   header (incl. a per-model vertex scale/origin, fitted to
                 the frames actually kept), triangles with per-corner UV
                 as fixed-point Integers, then one vertex array per
                 animation frame as raw BYTES -- the same trivertx_t
                 compression the .mdl file itself already uses.
    <name>skn.raw  the skin: sw*sh palette indices, top-down, no header

UVs are normalised 0..1 -- uGL's own convention, and the patched library
scales by xRes rather than xRes-1 (see ugl-patch/README.md). The `onseam`
flag is resolved here, not on the target: a seam vertex used by a back-
facing triangle takes the +skinwidth/2 column, which is a property of the
triangle, so the u belongs to the CORNER and not to the vertex.
"""

from __future__ import annotations

import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdlview as mdl  # noqa: E402


def resample_skin(skin) -> tuple[int, int, np.ndarray]:
    # POWER OF TWO, both axes. The textured fillers mask u and v with
    # (size-1), so a 300x194 skin has no mask that works and every
    # textured polygon rasterises nothing -- silently, with no error from
    # the library. The world textures already obey this: mkassets.py
    # resamples every one into 64/32/16/8 cells for exactly this reason.
    #
    # It must also fit one scanline (<= 8192) and stay <= 16,384 bytes
    # (one EMS page), which is qglRsPoly's own limit on a texture: the
    # texel base is a patched immediate and no filler remaps mid-polygon.
    # Within that, pick the POT pair closest to the skin's own aspect
    # ratio, largest area first among equally-close ones -- an even
    # POT/POT search, not a guess, since which pair wins depends on the
    # source image's shape.
    MAX_BYTES = 16384
    target_ratio = skin.width / skin.height
    best = None
    pots = [2**k for k in range(0, 14) if 2**k <= 8192]  # 1..8192
    for w in pots:
        for h in pots:
            if w * h > MAX_BYTES or w > 8192:
                continue
            dist = abs((w / h) - target_ratio)
            score = (dist, -(w * h))  # closest ratio, then largest area
            if best is None or score < best[0]:
                best = (score, w, h)
    sw, sh = best[1], best[2]
    yi = (np.arange(sh) * skin.height // sh).clip(0, skin.height - 1)
    xi = (np.arange(sw) * skin.width // sw).clip(0, skin.width - 1)
    return sw, sh, skin.pixels[yi][:, xi]  # nearest neighbour: stays in palette indices


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__)
        return 1
    pak, name, outdir = sys.argv[1:4]
    # Optional 5th arg: comma-separated frame-name prefixes, for callers
    # tight on memory (qb-quake's own conventional-memory budget -- see
    # mgl/docs/issues/ems-texture-and-zbuffer-dropouts.md's "MEM, not EMS"
    # skin fix, which trades EMS's texture-read bug for conventional-
    # memory pressure instead). Default unchanged: stand/walk/run.
    frameset = sys.argv[4].split(",") if len(sys.argv) == 5 else ["stand", "walk", "run"]
    os.makedirs(outdir, exist_ok=True)

    blob, entries = mdl.read_pak(pak)
    m = mdl.parse_mdl(mdl.pak_read(blob, entries, f"progs/{name}.mdl"), name)
    uv = mdl.build_uv(m)                     # [tri][corner][u, v], normalised
    skin = m.skins[0]

    # Core anims only, same set mkspr.py bakes -- all 114 frames of the
    # soldier is 116 KB of vertices, and the comparison only ever plays
    # stand/walk/run.
    import re
    frames = [f for f in m.frames
              if re.sub(r"\d+$", "", f.name) in frameset]
    if not frames:
        frames = list(m.frames)

    # Vertices as BYTES, one per axis -- the same trivertx_t compression
    # the .mdl file itself already uses -- packed into an 8-bit BMP (one
    # row per frame, uglNewBMPEx's own EMS path), NOT a BASIC string and
    # NOT a uglArrLoad array. Both of those were tried and both hit a
    # hard ceiling this session: a space$()'d string put ~8KB in BOTH
    # conventional memory and BASIC's own separate, much smaller "string
    # space" pool (runtime errors 14 and 7 going from 8 frames to 16);
    # uglArrLoad's store table is UA_MAX=4 slots, ALL of them already
    # taken by this renderer's own faces/nodes/leaves/clips arrays, so a
    # 5th uglArrNew call is refused regardless of size or memory type.
    # An EMS bitmap DC is a different resource entirely -- the skin and
    # Z-buffer already prove more than 4 of THOSE coexist -- read back
    # with uglMapEx + PEEK exactly like d_surf.bas's own lightmap/
    # geometry atlas rows, not through uglArrMap at all.
    allv = np.concatenate([f.verts for f in frames], axis=0)  # [n*frames, 3]
    vmin = allv.min(axis=0)
    vmax = allv.max(axis=0)
    vscale = np.where(vmax > vmin, (vmax - vmin) / 255.0, 1.0)

    UV_SCALE = 32767   # fixed-point Integer UV, 0..32767 = 0.0..1.0

    sw, sh, res = resample_skin(skin)

    # sw/sh, NOT skin.width/skin.height: the loader creates a Surface of
    # exactly this size and the source image's own dimensions would be a
    # fact it has no use for. They were written here before anything read
    # them, which is how they stayed wrong for free.
    out = bytearray(struct.pack("<4sHHHHH", b"QMDL", len(m.tris), len(m.st),
                                len(frames), sw, sh))
    out += struct.pack("<6f", *vscale.tolist(), *vmin.tolist())
    for t, (_ff, a, b, c) in enumerate(m.tris):
        out += struct.pack("<3h", a, b, c)
        for k in range(3):
            uf = float(np.clip(uv[t, k, 0], 0.0, 1.0))
            vf = float(np.clip(uv[t, k, 1], 0.0, 1.0))
            out += struct.pack("<2h", round(uf * UV_SCALE), round(vf * UV_SCALE))

    geo = os.path.join(outdir, f"{name[:8]}.geo")
    open(geo, "wb").write(bytes(out))

    # Flat, no header -- cnt*3 bytes, frame-major -- read whole with a
    # single uarReadH straight into a memAlloc'd conventional-memory
    # block (model.bas's own pvs.bin does the identical thing), then
    # PEEK'd. Conventional memory, not EMS: the earlier EMS-bitmap design
    # worked, but this is simpler and this data is small enough (8,160
    # bytes for the soldier's stand+run set) to just live in DOS memory
    # like the PVS lump already does.
    vtxbuf = bytearray()
    for f in frames:
        q = np.clip(np.rint((f.verts - vmin) / vscale), 0, 255).astype(np.uint8)
        vtxbuf += q.tobytes()
    vtxpath = os.path.join(outdir, f"{name[:5]}vtx.bin")
    open(vtxpath, "wb").write(bytes(vtxbuf))

    # Raw palette indices, top-down, no header: the .geo already carries
    # sw and sh, and a second copy in a BMP header is a second place for
    # them to be wrong. qgl has no BMP reader and does not want one --
    # the world atlas ships as texr.raw/texs.raw for the same reason.
    skn = os.path.join(outdir, f"{name[:5]}skn.raw")
    open(skn, "wb").write(res.tobytes())

    print(f"{name}: {len(m.tris)} tris, {len(m.st)} verts, {len(frames)} frames")
    print(f"  {os.path.basename(geo):<14} {len(out):,} B  (header + tris {len(m.tris)*18:,})")
    print(f"  {os.path.basename(vtxpath):<14} {len(vtxbuf):,} B  "
          f"(flat, memAlloc'd conventional memory -- see mdl_load in d_mdl.bas)")
    print(f"  {os.path.basename(skn):<14} {skin.width}x{skin.height} -> {sw}x{sh} "
          f"= {sw*sh:,} B (power of two, both axes)")
    for i, f in enumerate(frames[:4]):
        print(f"    frame {i}: {f.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
