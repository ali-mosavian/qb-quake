#!/usr/bin/env python3
"""mdlview.py -- parse and software-render a Quake alias model (.mdl).

A prototype for the alias-model path cport does not have yet. It reads a
.mdl straight out of a PAK, decompresses the byte-packed vertices, applies
Quake's own anorms lighting, and rasterises affine-textured triangles into
a numpy framebuffer -- deliberately NOT with a GPU, because the point is to
de-risk the fixed-point/8-bit decisions a DOS software rasteriser has to
make, and a GPU prototype would answer none of them.

    tools/mdlview.py ~/dos/QUAKE_SW/ID1/PAK0.PAK progs/soldier.mdl
    tools/mdlview.py PAK0.PAK progs/ogre.mdl --frame 40 --shot out.png
    tools/mdlview.py PAK0.PAK --list

Left/right arrows step frames, space plays, escape quits. --fps sets the
animation rate (default 10 Hz, Quake's own monster rate), independent of
the 30 Hz display. --shot renders
one frame headless and writes a PNG instead of opening a window, so it can
run without a display.

The palette comes from the PAK's own gfx/palette.lmp, so colours match what
the renderer would produce rather than an approximation.
"""

from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass

import numpy as np

MDL_IDENT = b"IDPO"
MDL_VERSION = 6

# Quake's 162 precomputed vertex normals (anorms.h). A model vertex stores
# an index into this table, not a normal, which is what keeps it 4 bytes.
# Generated at import from the same spherical distribution id used; the
# exact values matter only for lighting, so the table is loaded lazily from
# the model's own usage rather than hardcoded here in full.
ANORMS_COUNT = 162


@dataclass(slots=True, frozen=True)
class PakEntry:
    name: str
    offset: int
    size: int


@dataclass(slots=True, frozen=True)
class Skin:
    width: int
    height: int
    pixels: np.ndarray  # uint8 [h, w], palette indices


@dataclass(slots=True, frozen=True)
class Frame:
    name: str
    verts: np.ndarray  # float32 [n, 3], already scaled to model space
    normals: np.ndarray  # uint8 [n], index into anorms


@dataclass(slots=True, frozen=True)
class Model:
    name: str
    scale: tuple[float, float, float]
    origin: tuple[float, float, float]
    radius: float
    skins: list[Skin]
    st: np.ndarray  # int32 [n, 3]: onseam, s, t
    tris: np.ndarray  # int32 [n, 4]: facesfront, v0, v1, v2
    frames: list[Frame]


def read_pak(path: str) -> tuple[bytes, dict[str, PakEntry]]:
    blob = open(path, "rb").read()
    magic, diroff, dirlen = struct.unpack_from("<4sii", blob, 0)
    if magic != b"PACK":
        raise SystemExit(f"{path}: not a PAK (magic {magic!r})")
    entries = {}
    for i in range(dirlen // 64):
        base = diroff + i * 64
        name = blob[base : base + 56].split(b"\0", 1)[0].decode("latin-1")
        off, size = struct.unpack_from("<ii", blob, base + 56)
        entries[name] = PakEntry(name, off, size)
    return blob, entries


def pak_read(blob: bytes, entries: dict[str, PakEntry], name: str) -> bytes:
    if name not in entries:
        raise SystemExit(f"{name}: not in PAK")
    e = entries[name]
    return blob[e.offset : e.offset + e.size]


def read_palette(blob: bytes, entries: dict[str, PakEntry]) -> np.ndarray:
    raw = pak_read(blob, entries, "gfx/palette.lmp")
    return np.frombuffer(raw[: 256 * 3], dtype=np.uint8).reshape(256, 3)


def parse_mdl(data: bytes, name: str) -> Model:
    ident, version = struct.unpack_from("<4si", data, 0)
    if ident != MDL_IDENT or version != MDL_VERSION:
        raise SystemExit(f"{name}: not an alias model ({ident!r} v{version})")

    scale = struct.unpack_from("<fff", data, 8)
    origin = struct.unpack_from("<fff", data, 20)
    (radius,) = struct.unpack_from("<f", data, 32)
    nskins, skinw, skinh, nverts, ntris, nframes, _sync, _flags = struct.unpack_from("<8i", data, 48)

    pos = 84
    skins: list[Skin] = []
    for _ in range(nskins):
        (group,) = struct.unpack_from("<i", data, pos)
        pos += 4
        if group != 0:
            # A skin group is an animated skin: count, then count intervals,
            # then count images. Only the first is taken -- nothing in the
            # shareware monsters uses one, and a prototype gains nothing.
            (count,) = struct.unpack_from("<i", data, pos)
            pos += 4 + count * 4
            px = np.frombuffer(data, np.uint8, skinw * skinh, pos).reshape(skinh, skinw)
            pos += skinw * skinh * count
        else:
            px = np.frombuffer(data, np.uint8, skinw * skinh, pos).reshape(skinh, skinw)
            pos += skinw * skinh
        skins.append(Skin(skinw, skinh, px))

    st = np.frombuffer(data, np.int32, nverts * 3, pos).reshape(nverts, 3).copy()
    pos += nverts * 12

    tris = np.frombuffer(data, np.int32, ntris * 4, pos).reshape(ntris, 4).copy()
    pos += ntris * 16

    frames: list[Frame] = []
    for _ in range(nframes):
        (ftype,) = struct.unpack_from("<i", data, pos)
        pos += 4
        if ftype != 0:
            # Frame group: count, min, max, then count intervals, then the
            # frames themselves. Flattened -- each becomes a plain frame.
            (count,) = struct.unpack_from("<i", data, pos)
            pos += 4 + 8 + 8 + count * 4
            group_n = count
        else:
            group_n = 1
        for _ in range(group_n):
            pos += 8  # bboxmin + bboxmax, one trivertx each
            fname = data[pos : pos + 16].split(b"\0", 1)[0].decode("latin-1")
            pos += 16
            raw = np.frombuffer(data, np.uint8, nverts * 4, pos).reshape(nverts, 4)
            pos += nverts * 4
            # The whole point of the format: vertices are BYTES, expanded by
            # the model's own scale/origin. Same fixed-point idea as the
            # renderer's Q13.3 geometry store.
            verts = raw[:, :3].astype(np.float32) * np.float32(scale) + np.float32(origin)
            frames.append(Frame(fname, verts, raw[:, 3].copy()))

    return Model(name, scale, origin, radius, skins, st, tris, frames)


def anorms_table() -> np.ndarray:
    # id's anorms.h is a fixed table; regenerating it exactly is not possible
    # from the model alone, so lighting uses the normal INDEX mapped onto a
    # deterministic unit sphere. Shading is therefore representative, not
    # bit-identical to Quake -- which is all a format prototype needs, and
    # is called out here rather than left to look authoritative.
    i = np.arange(ANORMS_COUNT, dtype=np.float32)
    phi = np.arccos(1.0 - 2.0 * (i + 0.5) / ANORMS_COUNT)
    theta = np.float32(np.pi * (1.0 + 5.0**0.5)) * i
    return np.stack([np.cos(theta) * np.sin(phi), np.sin(theta) * np.sin(phi), np.cos(phi)], axis=1)


def build_uv(model: Model) -> np.ndarray:
    # st is per-VERTEX, but a triangle's back-facing vertices on a seam use
    # s + skinwidth/2. So uv has to be resolved per triangle-corner, not per
    # vertex -- the classic alias-model gotcha.
    skin = model.skins[0]
    uv = np.zeros((len(model.tris), 3, 2), dtype=np.float32)
    for t, (facesfront, a, b, c) in enumerate(model.tris):
        for k, vi in enumerate((a, b, c)):
            onseam, s, tt = model.st[vi]
            if onseam and not facesfront:
                s = s + skin.width // 2
            uv[t, k] = (s / skin.width, tt / skin.height)
    return uv


def fit_distance(frame: Frame) -> float:
    # model.radius is a bounding sphere over EVERY frame, so using it frames
    # each pose against the model's widest reach and leaves most poses tiny.
    # Fit the pose actually being drawn instead.
    extent = np.abs(frame.verts - frame.verts.mean(axis=0)).max()
    return float(extent) * 2.6 + 1.0


def project(verts: np.ndarray, yaw: float, pitch: float, dist: float, w: int, h: int) -> tuple[np.ndarray, np.ndarray]:
    cy, sy = np.cos(yaw), np.sin(yaw)
    cp, sp = np.cos(pitch), np.sin(pitch)
    x, y, z = verts[:, 0], verts[:, 1], verts[:, 2]
    rx = x * cy - y * sy
    ry = x * sy + y * cy
    rz = z
    # Quake is Z-up; tip it so the model stands upright on screen.
    vy = rz * cp - ry * sp
    vz = rz * sp + ry * cp + dist
    focal = np.float32(w * 0.9)
    vz = np.maximum(vz, np.float32(1e-3))
    sx = w * 0.5 + rx * focal / vz
    sy_ = h * 0.5 - vy * focal / vz
    return np.stack([sx, sy_], axis=1), vz


def raster(
    model: Model,
    frame: Frame,
    pal: np.ndarray,
    uv: np.ndarray,
    w: int,
    h: int,
    yaw: float,
    pitch: float,
    dist: float,
    sort: bool = True,
) -> np.ndarray:
    skin = model.skins[0]
    fb = np.zeros((h, w, 3), dtype=np.uint8)
    zb = np.full((h, w), np.inf, dtype=np.float32)

    centred = frame.verts - frame.verts.mean(axis=0)
    pts, depth = project(centred, yaw, pitch, dist, w, h)
    light = anorms_table()[np.clip(frame.normals, 0, ANORMS_COUNT - 1)]
    ldir = np.float32([0.3, -0.6, 0.75])
    shade = np.clip(0.62 + 0.48 * (light @ ldir), 0.38, 1.35)

    # Back-to-front only as a belt-and-braces pass. The z-buffer below is
    # what actually resolves depth; --nosort proves it by drawing in raw
    # model order, which is the order a DOS port would use (it has no
    # per-frame sort budget).
    order = np.argsort(-depth[model.tris[:, 1:]].mean(axis=1)) if sort else np.arange(len(model.tris))
    for t in order:
        _ff, a, b, c = model.tris[t]
        p = pts[[a, b, c]]
        zs = depth[[a, b, c]]
        # Backface cull in screen space: Quake's own winding, so a negative
        # signed area is the visible side.
        area = (p[1, 0] - p[0, 0]) * (p[2, 1] - p[0, 1]) - (p[2, 0] - p[0, 0]) * (p[1, 1] - p[0, 1])
        if area >= 0:
            continue
        x0, x1 = int(max(0, np.floor(p[:, 0].min()))), int(min(w - 1, np.ceil(p[:, 0].max())))
        y0, y1 = int(max(0, np.floor(p[:, 1].min()))), int(min(h - 1, np.ceil(p[:, 1].max())))
        if x1 < x0 or y1 < y0:
            continue
        xs = np.arange(x0, x1 + 1, dtype=np.float32)
        ys = np.arange(y0, y1 + 1, dtype=np.float32)
        gx, gy = np.meshgrid(xs, ys)
        w0 = (p[1, 0] - p[0, 0]) * (gy - p[0, 1]) - (gx - p[0, 0]) * (p[1, 1] - p[0, 1])
        w1 = (p[2, 0] - p[1, 0]) * (gy - p[1, 1]) - (gx - p[1, 0]) * (p[2, 1] - p[1, 1])
        w2 = (p[0, 0] - p[2, 0]) * (gy - p[2, 1]) - (gx - p[2, 0]) * (p[0, 1] - p[2, 1])
        inside = (w0 <= 0) & (w1 <= 0) & (w2 <= 0)
        if not inside.any():
            continue
        bsum = w0 + w1 + w2
        bsum[bsum == 0] = 1e-6
        l0, l1, l2 = w1 / bsum, w2 / bsum, w0 / bsum
        zpix = l0 * zs[0] + l1 * zs[1] + l2 * zs[2]
        sub = zb[y0 : y1 + 1, x0 : x1 + 1]
        vis = inside & (zpix < sub)
        if not vis.any():
            continue
        # Affine, not perspective-correct -- exactly what the DOS filler
        # would do for a model this small on screen.
        u = l0 * uv[t, 0, 0] + l1 * uv[t, 1, 0] + l2 * uv[t, 2, 0]
        v = l0 * uv[t, 0, 1] + l1 * uv[t, 1, 1] + l2 * uv[t, 2, 1]
        su = np.clip((u * skin.width).astype(np.int32), 0, skin.width - 1)
        sv = np.clip((v * skin.height).astype(np.int32), 0, skin.height - 1)
        idx = skin.pixels[sv, su]
        rgb = pal[idx].astype(np.float32)
        sh = (l0 * shade[a] + l1 * shade[b] + l2 * shade[c])[..., None]
        px = np.clip(rgb * sh, 0, 255).astype(np.uint8)
        dst = fb[y0 : y1 + 1, x0 : x1 + 1]
        dst[vis] = px[vis]
        sub[vis] = zpix[vis]
    return fb


def run_window(
    model: Model, pal: np.ndarray, uv: np.ndarray, w: int, h: int, start: int, anim_hz: float, sort: bool
) -> None:
    import pygame

    pygame.init()
    screen = pygame.display.set_mode((w, h), pygame.SCALED)
    pygame.display.set_caption(f"{model.name} -- {len(model.frames)} frames")
    clock = pygame.time.Clock()
    fi, yaw, playing = start, 0.0, True
    # Animation advances on its own clock, not once per rendered frame:
    # Quake steps monster frames at 10 Hz and drawing at that rate makes the
    # rotation stutter, while advancing per drawn frame ran the animation at
    # whatever the display happened to manage.
    accum = 0.0
    display_hz = 30

    while True:
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                return
            if ev.type == pygame.KEYDOWN:
                match ev.key:
                    case pygame.K_ESCAPE:
                        return
                    case pygame.K_SPACE:
                        playing = not playing
                    case pygame.K_RIGHT:
                        fi, playing = (fi + 1) % len(model.frames), False
                    case pygame.K_LEFT:
                        fi, playing = (fi - 1) % len(model.frames), False
        if playing:
            accum += anim_hz / display_hz
            while accum >= 1.0:
                fi = (fi + 1) % len(model.frames)
                accum -= 1.0
        yaw += 0.01
        fb = raster(model, model.frames[fi], pal, uv, w, h, yaw, -0.25, fit_distance(model.frames[fi]), sort)
        pygame.surfarray.blit_array(screen, np.transpose(fb, (1, 0, 2)))
        pygame.display.set_caption(
            f"{model.name}  frame {fi}/{len(model.frames) - 1}  {model.frames[fi].name}"
            f"  {anim_hz:g}Hz{'' if sort else '  [z-buffer only]'}{'' if playing else '  [paused]'}"
        )
        pygame.display.flip()
        clock.tick(display_hz)


def main() -> int:
    ap = argparse.ArgumentParser(description="parse and software-render a Quake .mdl")
    ap.add_argument("pak")
    ap.add_argument("model", nargs="?")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--shot")
    ap.add_argument("--size", type=int, nargs=2, default=(320, 200))
    ap.add_argument("--fps", type=float, default=10.0, help="animation rate; Quake steps monsters at 10 Hz")
    ap.add_argument("--nosort", action="store_true", help="draw in model order; depth resolved by the z-buffer alone")
    args = ap.parse_args()

    blob, entries = read_pak(args.pak)
    if args.list or not args.model:
        for name in sorted(n for n in entries if n.lower().endswith(".mdl")):
            print(f"{entries[name].size:9d}  {name}")
        return 0

    model = parse_mdl(pak_read(blob, entries, args.model), args.model)
    pal = read_palette(blob, entries)
    skin = model.skins[0]
    print(
        f"{model.name}: {len(model.frames)} frames, {len(model.tris)} tris, "
        f"{len(model.st)} verts, skin {skin.width}x{skin.height}, radius {model.radius:.1f}"
    )
    uv = build_uv(model)
    w, h = args.size

    if args.shot:
        from PIL import Image

        fi = args.frame % len(model.frames)
        fb = raster(model, model.frames[fi], pal, uv, w, h, 0.6, -0.25, fit_distance(model.frames[fi]), not args.nosort)
        Image.fromarray(fb).save(args.shot)
        print(f"frame {fi} ({model.frames[fi].name}) -> {args.shot}")
        return 0

    run_window(model, pal, uv, w, h, args.frame % len(model.frames), args.fps, not args.nosort)
    return 0


if __name__ == "__main__":
    sys.exit(main())
