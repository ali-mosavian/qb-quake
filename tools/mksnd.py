#!/usr/bin/env python3
"""mksnd.py -- the game's sound effects out of the PAK, as one raw stream.

    tools/mksnd.py PAK0.PAK out/

Emits, for snd.bas:

    snd.raw     every wav's samples back to back, 8-bit unsigned mono at
                11025 Hz -- the rate the DSP is run at, so nothing resamples
    sndtab.raw  a count, then (offset, length) as two longs per sound, in
                SOUNDS order, which is q_pl.bi's SND_* order

A wav named twice is stored once; the table just points at it again.
"""

from __future__ import annotations

import os
import struct
import sys

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
    # doors.qc's sounds 1..4: the stop, then the move
    "doors/drclos4", "doors/doormv1", "doors/hydro1", "doors/hydro2",               # 44..47
    "doors/stndr1", "doors/stndr2", "doors/ddoor1", "doors/ddoor2",                 # 48..51
    # func_door_secret's sounds 1..3: noise1, noise2, noise3
    "doors/latch2", "doors/winch2", "doors/drclos4",                                # 52..54
    "doors/airdoor1", "doors/airdoor2", "doors/airdoor2",                           # 55..57
    "doors/basesec1", "doors/basesec2", "doors/basesec2",                           # 58..60
    # func_button's sounds 0..3
    "buttons/airbut1", "buttons/switch21", "buttons/switch02", "buttons/switch04",  # 61..64
    "ambience/comp1", "ambience/drone6",                                            # 65, 66 the ambients
    "misc/medkey", "misc/runekey",                                                  # 67, 68 a key taken, by worldtype (base is registered)
    "doors/medtry", "doors/meduse", "doors/runetry", "doors/runeuse",               # 69..72 a key door refused, opened, by worldtype
    "ambience/drip1", "ambience/swamp1", "ambience/swamp2",                         # 73..75 more ambients
    "plats/train1", "plats/train2",                                                 # 76, 77 a train's stop and move
    "weapons/spike2",                                                               # 78 the spike shooter
    "demon/djump", "weapons/grenade", "weapons/bounce",                             # 79..81 the leap, the grenade thrown and bounced
    "zombie/z_idle", "zombie/z_shot1", "zombie/z_pain", "zombie/z_gib",             # 82..85 kinds 5 and 6, SND_MON2
    "wizard/wsight", "wizard/wattack", "wizard/wpain", "wizard/wdeath",             # 86..89
    "shambler/ssight", "shambler/sattck1", "shambler/shurt2", "shambler/sdeath",    # 90..93 kind 7
    "weapons/sgun1",                                                                # 94 the rocket launcher
    "shambler/melee1", "shambler/smack", "shambler/sboom",                          # 95..97 the smash, its hit, the lightning
    "items/protect", "items/protect3",                                              # 98, 99 the pentagram taken, a hit it turned
]


def wav_samples(name: str, wav: bytes) -> bytes:
    if wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
        raise SystemExit(f"{name}: not a wav")
    at, fmt, data, loop = 12, None, None, 0
    while at + 8 <= len(wav):
        cid, size = struct.unpack_from("<4sI", wav, at)
        body = wav[at + 8 : at + 8 + size]
        match cid:
            case b"fmt ":
                fmt = struct.unpack_from("<HHIIHH", body, 0)
            case b"data":
                data = body
            case b"cue ":
                # the first cue point's sample offset, where Quake's loop rejoins
                loop = struct.unpack_from("<I", body, 24)[0]
        at += 8 + size + (size & 1)
    if fmt is None or data is None:
        raise SystemExit(f"{name}: no fmt or data chunk")
    if loop and name.startswith("ambience/"):
        # doors/doormv1 and the like loop too, in Quake; here they play once
        raise SystemExit(f"{name}: loops from sample {loop}; snd_mix.c loops an ambient from 0")
    tag, channels, rate, _, _, bits = fmt
    if (tag, channels, rate, bits) != (1, 1, RATE, 8):
        raise SystemExit(f"{name}: want PCM mono {RATE} Hz 8-bit, got {fmt}")
    return data


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    pak, outdir = sys.argv[1:3]
    blob, entries = mdl.read_pak(pak)
    stream, placed = bytearray(), {}
    for name in SOUNDS:
        if name not in placed:
            samples = wav_samples(name, mdl.pak_read(blob, entries, f"sound/{name}.wav"))
            placed[name] = (len(stream), len(samples))
            stream += samples
    table = [placed[name] for name in SOUNDS]
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "snd.raw"), "wb").write(bytes(stream))
    tab = struct.pack("<h", len(table)) + b"".join(struct.pack("<ll", o, n) for o, n in table)
    open(os.path.join(outdir, "sndtab.raw"), "wb").write(tab)
    print(f"  snd.raw        {len(stream):,} B   sndtab.raw  {len(table)} sounds")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
