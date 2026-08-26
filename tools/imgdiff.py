#!/usr/bin/env python3
"""imgdiff.py -- compare a run's screenshot against a stored reference.

The renderer's bench mode drives a scripted camera for a fixed number of
frames, so the same build renders the same last frame every time. That
makes a byte-comparison of BENCH.BMP a regression test for anything that
touches geometry, texturing or the surface cache -- which is most of what
gets changed around here, and the sort of breakage that has previously
been caught by looking at the screen rather than by a test.

    tools/imgdiff.py --save ref.bmp build/vbd/BENCH.BMP     store a reference
    tools/imgdiff.py ref.bmp build/vbd/BENCH.BMP            compare

Exits non-zero on any difference. Prints how many pixels differ and the
worst palette-index delta, because "12 pixels differ by 1" and "40,000
pixels differ by 200" want different reactions.
"""
import sys, struct, shutil


def read_bmp(path):
    d = open(path, 'rb').read()
    if d[:2] != b'BM':
        raise SystemExit(f"{path}: not a BMP")
    off, = struct.unpack_from('<I', d, 10)
    w, h = struct.unpack_from('<ii', d, 18)
    bpp, = struct.unpack_from('<H', d, 28)
    pal = d[54:off]
    return w, h, bpp, pal, d[off:]


def main(argv):
    if len(argv) == 4 and argv[1] == '--save':
        shutil.copyfile(argv[3], argv[2])
        print(f"reference saved: {argv[2]}")
        return 0
    if len(argv) != 3:
        raise SystemExit(__doc__)

    ref, got = argv[1], argv[2]
    rw, rh, rb, rpal, rpx = read_bmp(ref)
    gw, gh, gb, gpal, gpx = read_bmp(got)

    if (rw, rh, rb) != (gw, gh, gb):
        print(f"DIFFER geometry: reference {rw}x{rh}x{rb}, got {gw}x{gh}x{gb}")
        return 1

    # The palette is worth checking separately: a shifted palette makes
    # every pixel "wrong" in a way that says nothing about the geometry.
    if rpal != gpal:
        n = sum(1 for a, b in zip(rpal, gpal) if a != b)
        print(f"DIFFER palette: {n} of {len(rpal)} bytes")

    n = worst = 0
    for a, b in zip(rpx, gpx):
        if a != b:
            n += 1
            d = abs(a - b)
            if d > worst:
                worst = d

    if n == 0 and rpal == gpal:
        print(f"IDENTICAL  {rw}x{rh}x{rb}, {len(rpx)} bytes")
        return 0

    total = len(rpx)
    print(f"DIFFER  {n} of {total} pixels ({n * 100.0 / total:.2f}%), "
          f"worst index delta {worst}")
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
