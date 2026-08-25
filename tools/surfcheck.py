#!/usr/bin/env python3
"""Diff a surface the TARGET built against sbref.py's reference.

    tools/surfcheck.py <face> <mip> [more faces...]

qrender is run with -dumpsurf, which composites one face through the real
sb_build -- the same asset files, the same uglMapEx call, the same pointer
arithmetic -- and writes the bytes to surfdump.bin. This compares that
against sbref.py computing the same surface in Python.

Why this and not the checks that already exist: all of those sit below the
seam that actually broke. sc_selftest checks the cache's bookkeeping.
mgl's surftst checks uglBuildSurf against a BASIC reference, but hands it
a pointer it built itself. The asset round-trip check reads the atlas in
Python and never runs target code at all. A truncating divide in sb_seg
put 56% of faces 16 bytes off their luxels with all three of them green;
only looking at the screen caught it. This closes that.

Faces are worth choosing deliberately: the atlas is 8192 wide, so a face
on an ODD scanline sits at offset 8192 inside its EMS page and one on an
EVEN scanline at offset 0. That parity is exactly what the sb_seg bug
turned on, so cover both. With no faces given, it picks a spread.
"""
import os, struct, subprocess, sys, types

ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT    = os.path.join(ROOT, 'build', 'vbd')
ASSETS = os.path.join(ROOT, 'data', 'assets')
DOSBOX = os.environ.get('DOSBOX_BIN') or os.path.expanduser(
    '~/work/other/dosbox-x-debug/src/dosbox-x')
MAP    = os.environ.get('MAP', 'dm3ish.bsp')


def sbref():
    src = open(os.path.join(ROOT, 'tools', 'sbref.py')).read()
    src = src.split("if __name__ ==")[0]
    m = types.ModuleType('sbref')
    m.__dict__['__file__'] = os.path.join(ROOT, 'tools', 'sbref.py')
    exec(compile(src, 'sbref.py', 'exec'), m.__dict__)
    return m


def face_table():
    return open(os.path.join(ASSETS, 'lmface.bin'), 'rb').read()


def pick_faces(n=6):
    """A spread of lit faces, half on odd atlas scanlines and half on even."""
    tab = face_table()
    odd, even = [], []
    for fid in range(len(tab) // 16):
        ay, ax, _s, _t, w, h, _a, _b = struct.unpack_from('<hH4h2H', tab, fid*16)
        if ay < 0 or w < 3 or h < 3:
            continue
        (odd if (ay & 1) else even).append(fid)
    half = max(1, n // 2)
    step = lambda L: L[::max(1, len(L)//half)][:half]
    return sorted(step(odd) + step(even))


def run_target(face, mip):
    """-dumpsurf builds the face and quits; returns (w, h, pixels)."""
    dump = os.path.join(OUT, 'surfdump.bin')
    for stale in (dump, os.path.join(OUT, 'SURFDUMP.BIN')):
        if os.path.exists(stale):
            os.remove(stale)
    with open(os.path.join(OUT, 'run.bat'), 'w', newline='\r\n') as f:
        f.write('@echo off\n')
        f.write(f'qrender.exe {MAP} -dumpsurf {face} {mip} > dump.out\n')
    conf = os.path.join(OUT, 'surfcheck.conf')
    tpl = open(os.path.join(ROOT, 'dosbox', 'template.conf')).read()
    for k, v in (('@CDRIVE@', OUT), ('@VDRIVE@', OUT), ('@MDRIVE@', OUT),
                 ('@BAT@', 'run.bat'), ('@PRE@', '')):
        tpl = tpl.replace(k, v)
    open(conf, 'w').write(tpl)
    subprocess.run([DOSBOX, '-nolog', '-conf', conf, '-exit'],
                   env={**os.environ, 'SDL_VIDEODRIVER': 'dummy'},
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=600)
    for cand in (dump, os.path.join(OUT, 'SURFDUMP.BIN')):
        if os.path.exists(cand):
            d = open(cand, 'rb').read()
            w, h = struct.unpack_from('<hh', d, 0)
            return w, h, d[4:4 + w*h]
    out = os.path.join(OUT, 'dump.out')
    msg = open(out).read().strip() if os.path.exists(out) else '(no output)'
    raise SystemExit(f"face {face} mip {mip}: target wrote no surfdump.bin\n  {msg}")


def main():
    if not os.path.exists(os.path.join(OUT, 'qrender.exe')):
        raise SystemExit("no build/vbd/qrender.exe -- run: tools/dosbox.sh build")
    ref = sbref()
    args = sys.argv[1:]
    if len(args) >= 2 and args[0].isdigit() and args[1].isdigit():
        pairs = [(int(args[0]), int(args[1]))]
    else:
        pairs = [(f, 1) for f in pick_faces()]

    tab = face_table()
    bad = 0
    for face, mip in pairs:
        ay, ax, *_ = struct.unpack_from('<hH4h2H', tab, face*16)
        parity = 'odd ' if (ay & 1) else 'even'
        tw, th, tpx = run_target(face, mip)
        rw, rh, rpx = ref.build(face, mip)
        if (tw, th) != (rw, rh):
            print(f"  FAIL face {face:5} mip {mip}  scanline {ay} ({parity})  "
                  f"target {tw}x{th} != reference {rw}x{rh}")
            bad += 1
            continue
        diff = sum(1 for a, b in zip(tpx, rpx) if a != b)
        tag = 'ok  ' if diff == 0 else 'FAIL'
        print(f"  {tag} face {face:5} mip {mip}  scanline {ay:3} ({parity})  "
              f"{tw}x{th}  {diff} of {tw*th} bytes differ")
        if diff:
            bad += 1
    print()
    print("RESULT PASS" if bad == 0 else f"RESULT FAIL -- {bad} of {len(pairs)} surfaces differ")
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
