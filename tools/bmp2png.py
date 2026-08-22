#!/usr/bin/env python3
"""Convert a screenshot written by ugluBMPSave to PNG, optionally upscaled.

    tools/bmp2png.py build/vbd/SCRN0.BMP out.png [scale]

The renderer writes 8-bit BMPs with the Quake palette attached, at 320x200,
which is a 1.2:1 pixel aspect on real hardware. Scale defaults to 3 with
nearest-neighbour so texel detail stays legible.
"""
import sys
from PIL import Image

src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else "out.png"
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 3

im = Image.open(src)
print(f"{src}: {im.format} {im.mode} {im.size}")
im = im.convert("RGB")
if scale != 1:
    im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
im.save(dst)
print(f"wrote {dst} ({im.width}x{im.height})")
