"""
texquant.py -- resample a paletted texture and map it back to the palette.

Lanczos3 in RGB (Pillow, the texture tiled 3x3 so its edges wrap) with a
0.6 unsharp mask after it -- halving reads soft otherwise -- then
Floyd-Steinberg in OKLab choosing by dL^2 + dC^2 + 4 dH^2, the colormap's
matcher. Colours are what the DAC shows, 6 bits a channel. The diffusion
loop is fsdither.c, compiled into build/ on first use.
"""
import ctypes
import os
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
LIB_SRC = HERE / "fsdither.c"
LIB = HERE.parent / "build" / "fsdither.so"

type Palette = list[tuple[int, int, int]]

SHARPEN = 0.6
# 3x3 binomial, (dx, dy, weight of 16)
BINOMIAL = ((0, 0, 4), (-1, 0, 2), (1, 0, 2), (0, -1, 2), (0, 1, 2),
            (-1, -1, 1), (1, -1, 1), (-1, 1, 1), (1, 1, 1))

M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def fs_lib() -> ctypes.CDLL:
    if not LIB.exists() or LIB.stat().st_mtime < LIB_SRC.stat().st_mtime:
        LIB.parent.mkdir(parents=True, exist_ok=True)
        # several maps build at once: compile aside, then swap in whole
        tmp = LIB.with_name(f"fsdither.{os.getpid()}.so")
        subprocess.run(["cc", "-O2", "-shared", "-fPIC", "-o", str(tmp), str(LIB_SRC)], check=True)
        os.replace(tmp, LIB)
    lib = ctypes.CDLL(str(LIB))
    f32, u8 = ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_ubyte)
    lib.fs_dither.argtypes = [f32, ctypes.c_int, ctypes.c_int, f32, ctypes.c_int, u8]
    lib.fs_dither.restype = None
    return lib


def dac(pal: Palette) -> np.ndarray:
    return (np.asarray(pal, np.int64) >> 2) * 255 / 63


def oklab(rgb: np.ndarray) -> np.ndarray:
    s = rgb / 255
    linear = np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)
    return np.cbrt(linear @ M1.T) @ M2.T


def unsharp(img: np.ndarray, amount: float) -> np.ndarray:
    blur = sum(w * np.roll(np.roll(img, dy, 0), dx, 1) for dx, dy, w in BINOMIAL) / 16
    return img + amount * (img - blur)


def magic(x: float) -> float:
    ax = abs(x)
    if ax <= 0.5:
        return 0.75 - ax * ax
    return 0.5 * (ax - 1.5) ** 2 if ax <= 1.5 else 0.0


MKS_SHARP = np.array([-1, 6, -35, 204, -35, 6, -1]) / 144


def mks_matrix(n_in: int, n_out: int) -> np.ndarray:
    # Magic Kernel Sharp 2021: the quadratic B-spline stretched to the output
    # spacing, then a 7-tap sharpen on the output grid. Rows wrap: a texture tiles.
    s = n_in / n_out
    k = max(s, 1.0)
    m = np.zeros((n_out, n_in))
    for i in range(n_out):
        c = (i + 0.5) * s - 0.5
        for j in range(int(np.floor(c - 1.5 * k)), int(np.ceil(c + 1.5 * k)) + 1):
            m[i, j % n_in] += magic((j - c) / k)
    m /= m.sum(1, keepdims=True)
    sharp = np.zeros((n_out, n_out))
    for i in range(n_out):
        for t, w in enumerate(MKS_SHARP):
            sharp[i, (i + t - 3) % n_out] += w
    return sharp @ m


def resample_mks(img: np.ndarray, dw: int, dh: int) -> np.ndarray:
    sh, sw, _ = img.shape
    my, mx = mks_matrix(sh, dh), mks_matrix(sw, dw)
    return np.clip(np.einsum("yi,ijc,xj->yxc", my, img, mx), 0, 255)


def resample_rgb(src: bytes, sw: int, sh: int, dw: int, dh: int, rgb_pal: np.ndarray,
                 sharpen: float = SHARPEN, kernel: str = "lanczos") -> np.ndarray:
    img = rgb_pal[np.frombuffer(src, np.uint8)[:sw * sh]].reshape(sh, sw, 3).astype(np.float32)
    if kernel == "mks":
        return resample_mks(img.astype(np.float64), dw, dh)
    tiled = np.tile(img, (3, 3, 1))
    out = np.empty((dh, dw, 3), np.float32)
    for c in range(3):
        big = Image.fromarray(np.ascontiguousarray(tiled[:, :, c])).resize((3 * dw, 3 * dh), Image.Resampling.LANCZOS)
        out[:, :, c] = np.asarray(big)[dh:2 * dh, dw:2 * dw]
    return np.clip(unsharp(out, sharpen), 0, 255)


def quantize(rgb: np.ndarray, lab_pal: np.ndarray) -> bytes:
    h, w, _ = rgb.shape
    img = np.ascontiguousarray(oklab(rgb.astype(np.float64)), np.float32)
    pal = np.ascontiguousarray(lab_pal, np.float32)
    out = np.zeros(w * h, np.uint8)
    f32, u8 = ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_ubyte)
    fs_lib().fs_dither(img.ctypes.data_as(f32), w, h, pal.ctypes.data_as(f32), len(pal), out.ctypes.data_as(u8))
    return out.tobytes()


def resample_indices(src: bytes, sw: int, sh: int, dw: int, dh: int, pal: Palette) -> bytes:
    rgb_pal = dac(pal)
    return quantize(resample_rgb(src, sw, sh, dw, dh, rgb_pal), oklab(rgb_pal))
