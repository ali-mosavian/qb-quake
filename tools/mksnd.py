#!/usr/bin/env python3
"""mksnd.py -- the game's sound effects out of the PAK, block-scale coded.

    tools/mksnd.py PAK0.PAK out/

Emits, for snd.c:

    snd.bsc     every wav back to back as bsc4/32n -- 32 samples a block,
                one scale byte and sixteen of packed 4-bit codes, so 17
                bytes a block and 4.25 bits a sample. A block never
                straddles a 16K EMS page: 963 fit and the page's last 13
                bytes are padding, so the mixer reaches any block through
                one window with a divide and no second slot.
    snddec.raw  the 32 x 16 decode table, one signed byte an entry. The
                codec's contract, shipped rather than recomputed: a
                decoder building the ladder from its own exp() agrees
                with this one to whatever its libm does, and nothing in
                a DOS box would ever say that it does not.
    sndtab.raw  a count, then (offset, length, loop) per sound as two longs
                and a short, in SOUNDS order, which is snd.h's SND_*
                order. The offset is in SAMPLES and lands on a block; the
                length is the wav's own, or the cue's loop end, so the
                silence a block's tail is padded with is never played.
                loop is the cue's sample, where a looping sound rejoins,
                or -1 for a sound that plays once.

A wav named twice is stored once; the table just points at it again.
"""

from __future__ import annotations

import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mdlview as mdl  # noqa: E402

RATE = 11025

# q_pl.bi's SND_* constants are this list's indices
SOUNDS = [
    "weapons/guncock",                                                              # 0 the shotgun
    "weapons/shotgn2",                                                              # 1 the super shotgun
    "weapons/rocket1i",                                                             # 2 the nailgun
    "weapons/r_exp3",                                                               # 3 the exploding box
    "items/health1", "items/r_item1", "items/r_item2",                              # 4..6 health 15/25, 5, 100
    "items/armor1", "weapons/pkup", "weapons/lock4", "items/damage", "items/suit",  # 7..11 the other pickups
    "misc/secret", "misc/talk",                                                     # 12, 13
    "player/pain1", "player/pain2", "player/pain3",                                 # 14..16
    "player/death1", "player/plyrjmp8", "player/land", "player/land2",              # 17..20
    "player/slimbrn2", "player/lburn1", "player/lburn2",                            # 21..23
    "soldier/sight1", "soldier/sattck1", "soldier/pain1", "soldier/death1",         # 24..27
    "knight/ksight", "knight/sword1", "knight/khurt", "knight/kdeath",              # 28..31
    "dog/dsight", "dog/dattack1", "dog/dpain1", "dog/ddeath",                       # 32..35
    "ogre/ogwake", "ogre/ogsawatk", "ogre/ogpain1", "ogre/ogdth",                    # 36..39
    "demon/sight2", "demon/dhit2", "demon/dpain1", "demon/ddeath",                  # 40..43
    # doors.qc's sounds 1..4: noise1 the stop, then noise2 the move -- the move is the one with a cue
    "doors/drclos4", "doors/doormv1", "doors/hydro2", "doors/hydro1",               # 44..47
    "doors/stndr2", "doors/stndr1", "doors/ddoor2", "doors/ddoor1",                 # 48..51
    # func_door_secret's sounds 1..3: noise1, noise2, noise3
    "doors/latch2", "doors/winch2", "doors/drclos4",                                # 52..54
    "doors/airdoor2", "doors/airdoor1", "doors/airdoor2",                           # 55..57
    "doors/basesec2", "doors/basesec1", "doors/basesec2",                           # 58..60
    # func_button's sounds 0..3
    "buttons/airbut1", "buttons/switch21", "buttons/switch02", "buttons/switch04",  # 61..64
    "ambience/comp1", "ambience/drone6",                                            # 65, 66 the ambients
    "misc/medkey", "misc/runekey",                                                  # 67, 68 a key taken, by worldtype (base is registered)
    "doors/medtry", "doors/meduse", "doors/runetry", "doors/runeuse",               # 69..72 a key door refused, opened, by worldtype
    "ambience/drip1", "ambience/swamp1", "ambience/swamp2",                         # 73..75 more ambients
    "plats/train2", "plats/train1",                                                 # 76, 77 a train's stop and move
    "weapons/spike2",                                                               # 78 the spike shooter
    "demon/djump", "weapons/grenade", "weapons/bounce",                             # 79..81 the leap, the grenade thrown and bounced
    "zombie/z_idle", "zombie/z_shot1", "zombie/z_pain", "zombie/z_gib",             # 82..85 kinds 5 and 6, SND_MON2
    "wizard/wsight", "wizard/wattack", "wizard/wpain", "wizard/wdeath",             # 86..89
    "shambler/ssight", "shambler/sattck1", "shambler/shurt2", "shambler/sdeath",    # 90..93 kind 7
    "weapons/sgun1",                                                                # 94 the rocket launcher
    "shambler/melee1", "shambler/smack", "shambler/sboom",                          # 95..97 the smash, its hit, the lightning
    "items/protect", "items/protect3",                                              # 98, 99 the pentagram taken, a hit it turned
    "ambience/water1", "ambience/wind2",                                            # 100, 101 the leaves' water and sky
    "plats/plat1", "plats/plat2", "plats/medplat1", "plats/medplat2",               # 102..105 func_plat's 1, 2: move, stop
    "misc/r_tele1", "misc/r_tele2", "misc/r_tele3", "misc/r_tele4", "misc/r_tele5", # 106..110 play_teleport
    "misc/trigger1", "misc/h2ohit1",                                                # 111, 112
    "ambience/fire1", "ambience/fl_hum1", "ambience/buzz1",                         # 113..115 the lights' ambients
    "player/pain4", "player/pain5", "player/pain6",                                 # 116..118
    "player/death2", "player/death3", "player/death4", "player/death5",             # 119..122
    "player/h2odeath", "player/drown1", "player/drown2", "player/gasp1", "player/gasp2",   # 123..127
    "player/inh2o", "player/inlava", "misc/outwater", "player/h2ojump",             # 128..131
    "player/udeath", "player/gib",                                                  # 132, 133
    "items/damage2", "items/suit2", "items/protect2", "items/damage3",              # 134..137 powerups ending, the quad's shot
    "weapons/ric1", "weapons/ric2", "weapons/ric3", "weapons/tink1",                # 138..141 TE_SPIKE
    "misc/water1", "misc/water2",                                                   # 142, 143 a swim stroke
    "soldier/idle", "soldier/pain2", "knight/idle", "knight/sword2", "dog/idle",    # 144..148
    "ogre/ogidle", "ogre/ogidle2", "ogre/ogdrag", "demon/idle1",                    # 149..152
    "zombie/z_idle1", "zombie/z_hit", "zombie/z_miss", "zombie/z_fall", "zombie/z_pain1",  # 153..157
    "wizard/widle1", "wizard/widle2", "wizard/hit",                                 # 158..160
    "shambler/sidle", "shambler/melee2",                                            # 161, 162
    "boss1/out1", "boss1/sight1",                                                   # 163, 164 Chthon rising
]


# ---------------------------------------------------------------- bsc4/32n
# Block scale: one gain for 32 samples, chosen from a ladder of 32 so no
# block wastes up to 6 dB rounding its peak up to the next power of two.
# Decode is a table lookup -- the scale byte picks one of 32 rows and the
# 4-bit code indexes it -- which is the whole reason for the ladder being
# a fixed 32 rather than a per-block byte of anything finer.
BLK = 32
BITS = 4
NSCALE = 32
BLK_BYTES = 1 + BLK * BITS // 8
EMS_PAGE = 16384
BLK_PER_PAGE = EMS_PAGE // BLK_BYTES
CODE_HI = (1 << (BITS - 1)) - 1
CODE_LO = -(1 << (BITS - 1))


def scale_ladder() -> np.ndarray:
    return np.exp(np.linspace(0.0, np.log(128.0 / (CODE_HI + 0.5)), NSCALE))


def decode_table(g: np.ndarray) -> np.ndarray:
    nib = np.arange(1 << BITS)
    return np.clip(np.rint(np.outer(g, np.where(nib > CODE_HI, nib - (1 << BITS), nib))), -128, 127).astype(np.int8)


def bsc_encode(x: np.ndarray, g: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    blk = x.astype(np.int32).reshape(-1, BLK)
    peak = np.max(np.abs(blk), axis=1)
    sel = np.clip(np.searchsorted(g * (CODE_HI + 0.5), np.maximum(peak, 1)), 0, NSCALE - 1)
    q = np.clip(np.rint(blk / g[sel].reshape(-1, 1)), CODE_LO, CODE_HI).astype(np.int32)
    nib = (q & ((1 << BITS) - 1)).astype(np.uint8)
    return sel.astype(np.uint8), nib[:, 0::2] | (nib[:, 1::2] << 4)


def bsc_decode(sel: np.ndarray, packed: np.ndarray, tab: np.ndarray) -> np.ndarray:
    nib = np.empty((len(sel), BLK), np.uint8)
    nib[:, 0::2] = packed & ((1 << BITS) - 1)
    nib[:, 1::2] = packed >> BITS
    return tab[sel[:, None], nib]


def pack_pages(sel: np.ndarray, packed: np.ndarray) -> bytes:
    rec = np.empty((len(sel), BLK_BYTES), np.uint8)
    rec[:, 0] = sel
    rec[:, 1:] = packed
    npage = (len(sel) + BLK_PER_PAGE - 1) // BLK_PER_PAGE
    out = np.zeros((npage, EMS_PAGE), np.uint8)
    for p in range(npage):
        take = rec[p * BLK_PER_PAGE : (p + 1) * BLK_PER_PAGE].reshape(-1)
        out[p, : len(take)] = take
    tail = len(sel) - (npage - 1) * BLK_PER_PAGE
    return out.reshape(-1)[: (npage - 1) * EMS_PAGE + tail * BLK_BYTES].tobytes()


def wav_samples(name: str, wav: bytes) -> tuple[bytes, int]:
    if wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
        raise SystemExit(f"{name}: not a wav")
    at, fmt, data, loop, mark = 12, None, None, -1, None
    while at + 8 <= len(wav):
        cid, size = struct.unpack_from("<4sI", wav, at)
        body = wav[at + 8 : at + 8 + size]
        match cid:
            case b"fmt ":
                fmt = struct.unpack_from("<HHIIHH", body, 0)
            case b"data":
                data = body
            case b"cue ":
                # GetWavinfo: the first cue point's sample offset, where the loop rejoins
                loop = struct.unpack_from("<I", body, 24)[0]
            case b"LIST" if loop >= 0 and body[20:24] == b"mark":
                # and cooledit's mark after it, the loop's length
                mark = struct.unpack_from("<I", body, 16)[0]
        at += 8 + size + (size & 1)
    if fmt is None or data is None:
        raise SystemExit(f"{name}: no fmt or data chunk")
    tag, channels, rate, _, _, bits = fmt
    if (tag, channels, rate, bits) != (1, 1, RATE, 8):
        raise SystemExit(f"{name}: want PCM mono {RATE} Hz 8-bit, got {fmt}")
    if name.startswith("ambience/") and loop < 0:
        raise SystemExit(f"{name}: an ambient with no cue does not loop (S_StaticSound)")
    if loop > 32767:
        raise SystemExit(f"{name}: loop start {loop} past sndtab.raw's short")
    if mark is not None:
        data = data[: loop + mark]
    return data, loop


def report(name: str, x: np.ndarray, dec: np.ndarray, nbytes: int) -> tuple[float, float]:
    e = (dec - x).astype(np.float64)
    sig, err = float((x.astype(np.float64) ** 2).sum()), float((e ** 2).sum())
    snr = 10.0 * np.log10(sig / err) if err > 0 and sig > 0 else float("inf")
    print(f"  {name:<20} {len(x):>7,} smp {nbytes:>7,} B   rmse {np.sqrt(err / len(x)):5.2f}"
          f"   peak {int(np.abs(e).max()):>3}   snr {snr:5.1f} dB")
    return sig, err


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    pak, outdir = sys.argv[1:3]
    blob, entries = mdl.read_pak(pak)
    g = scale_ladder()
    tab = decode_table(g)

    sels, codes, placed = [], [], {}
    nblk, nsmp, sig, err = 0, 0, 0.0, 0.0
    for name in SOUNDS:
        if name in placed:
            continue
        pcm, loop = wav_samples(name, mdl.pak_read(blob, entries, f"sound/{name}.wav"))
        x = np.frombuffer(pcm, np.uint8).astype(np.int32) - 128
        padded = np.concatenate([x, np.zeros(-len(x) % BLK, np.int32)])
        sel, packed = bsc_encode(padded, g)
        dec = bsc_decode(sel, packed, tab).reshape(-1)[: len(x)].astype(np.int32)
        s, e = report(name, x, dec, len(sel) * BLK_BYTES)
        sig, err, nsmp = sig + s, err + e, nsmp + len(x)
        placed[name] = (nblk * BLK, len(x), loop)
        nblk += len(sel)
        sels.append(sel)
        codes.append(packed)

    stream = pack_pages(np.concatenate(sels), np.concatenate(codes))
    table = [placed[name] for name in SOUNDS]
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "snd.bsc"), "wb").write(stream)
    open(os.path.join(outdir, "snddec.raw"), "wb").write(tab.tobytes())
    open(os.path.join(outdir, "sndtab.raw"), "wb").write(
        struct.pack("<h", len(table)) + b"".join(struct.pack("<llh", o, n, lp) for o, n, lp in table))
    print(f"  snd.bsc {len(stream):,} B for {nsmp:,} samples ({8.0 * len(stream) / nsmp:.2f} bits each, "
          f"{100.0 * len(stream) / nsmp:.0f}% of raw), snr {10.0 * np.log10(sig / err):.1f} dB, "
          f"{len(table)} sounds")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
