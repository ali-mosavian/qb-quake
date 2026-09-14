"""
test-texquant.py -- the atlas quantizer keeps exact colours exact, and
dithers a gradient instead of banding it, and a halved edge stays sharp.

The cube it replaced mapped every texel to its nearest Euclidean RGB entry
with no diffusion: a smooth ramp came back as flat bands, each column off
its target by up to half a palette step.

  python3 tools/test-texquant.py [palette.raw]
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import texquant


def main() -> int:
    raw = Path(sys.argv[1] if len(sys.argv) > 1 else "data/maps/e1m1/pal.raw").read_bytes()[:768]
    pal = [tuple(raw[i * 3:i * 3 + 3]) for i in range(256)]
    rgb_pal = texquant.dac(pal)
    lab_pal = texquant.oklab(rgb_pal)
    fail = 0

    unique = [i for i in range(256) if sum((rgb_pal == rgb_pal[i]).all(1)) == 1]
    got = np.frombuffer(texquant.quantize(rgb_pal[unique].reshape(1, -1, 3), lab_pal), np.uint8)
    if list(got) != unique:
        print(f"FAIL: palette colours map elsewhere: {[(u, g) for u, g in zip(unique, got) if u != g][:5]}")
        fail = 1
    else:
        print(f"ok: {len(unique)} distinct palette colours map to themselves")

    k = unique[len(unique) // 2]
    flat = texquant.resample_indices(bytes([k]) * (32 * 48), 32, 48, 32, 32, pal)
    if set(flat) != {k}:
        print(f"FAIL: a flat texture of {k} resampled to {sorted(set(flat))}")
        fail = 1
    else:
        print("ok: a flat texture resamples to itself")

    # a hard edge half a texel off the halved grid, between two mid greys so
    # nothing clips: sharpening must keep more of its step than the same
    # resize without it. Only near that edge -- the wrap is an edge too, on
    # the grid, and hard either way.
    edge = bytes([5] * 25 + [10] * 23) * 48
    col_step = lambda img: float(np.abs(np.diff(img[:, 8:17, 1].mean(0))).max())
    sharp = col_step(texquant.resample_rgb(edge, 48, 48, 24, 24, rgb_pal))
    plain = col_step(texquant.resample_rgb(edge, 48, 48, 24, 24, rgb_pal, sharpen=0.0))
    if sharp <= plain * 1.1:
        print(f"FAIL: a halved edge stays soft, step {sharp:.1f} against {plain:.1f} unsharpened")
        fail = 1
    else:
        print(f"ok: a halved edge keeps its step, {sharp:.1f} against {plain:.1f} unsharpened")

    # the grey ramp, 0..15, as a smooth 256-wide gradient
    lo, hi = rgb_pal[0], rgb_pal[15]
    ramp = lo + (hi - lo) * (np.arange(256) / 255)[None, :, None]
    img = np.repeat(ramp, 64, axis=0)
    idx = np.frombuffer(texquant.quantize(img, lab_pal), np.uint8).reshape(64, 256)
    shown = texquant.oklab(rgb_pal[idx].mean(0).clip(0, 255))
    err = np.abs(shown[:, 0] - texquant.oklab(ramp[0])[:, 0]).mean()
    # dithered 0.0035; undiffused bands sit a quarter step off, 0.0125
    if err > 0.006:
        print(f"FAIL: the ramp bands, mean column lightness error {err:.4f}")
        fail = 1
    else:
        print(f"ok: the ramp dithers, mean column lightness error {err:.4f}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
