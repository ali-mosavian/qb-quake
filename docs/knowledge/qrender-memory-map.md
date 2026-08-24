---
type: reference
title: qrender.exe DOS memory map (dm3ish, live walk 2026-08-24)
tags: [dosbox-x, memory, basic, mcb, lightmaps, surface-cache]
---

# qrender.exe DOS memory map — dm3ish, live walk 2026-08-24

Snapshot from a live MCB walk (method: [dos-mcb-memory-diagnosis.md](dos-mcb-memory-diagnosis.md)),
taken mid-frame during normal rendering, colormap load disabled (that's the
16 KB allocation that was hanging — see the finding at the bottom). Will go
stale as the surface-cache/lightmap work moves data around; re-walk rather
than trust this once `lm_base`/`lm_info` move to XMS.

## The headline number

**DOS's entire allocatable universe (conventional + linked UMB) had 9,312
bytes free**, against `memAvail&` reporting ~260,000 — because `memAvail&`
measures BASIC's far-heap *size*, not DOS's actual free memory. See the
method doc for why.

## DOS MCB chain (segment order = allocation-time order is NOT guaranteed —
identified by content, not position)

| segment | owner | size | identity | confirmed by |
|---|---|---|---|---|
| 0x0813 | qrender | 486,320 B | program image + code + BASIC's initial far-heap capacity | PSP match |
| 0x7ECF | qrender | 64,032 B | BASIC's own heap growth (level-array `REDIM`s outgrowing initial capacity) | no mgl header; raw packed-array byte patterns |
| 0x8E72–0x8E80 | qrender | 80/112/304 B | unidentified — presumed further small BASIC heap-growth fragments | not chased |
| 0x8E94 | qrender | 71,328 B | **`lm_base`** (lightmap luxel blob, `d_surf.bas`) | first bytes `66 64 65 66 67 65` — byte-identical to `data/assets/lmdat.bin` |
| 0x9FFF | **DOS (PSP 8)** | 180,224 B | video framebuffer + ROM hole, 0xA000–0xCBFF | address range matches real hardware map |
| 0xCC00 | qrender | 528 B | `polyb()` (`d_poly.bas`, fixed `u3dVector4f(33)`) | exact size match: 16×33 |
| 0xCC22 | qrender | 16,400 B | font glyph atlas (`h_font_char`, 256×8×8 via `uglNewMult`) | leading bytes decode as an 8×8 DC struct; size matches `uglNewMult`'s own formula |
| 0xD024 | qrender | 1,040 B | `poly()` (`d_poly.bas`, fixed `u3dVector4f(65)`) | exact size match: 16×65 |
| 0xD066 | qrender | 848 B | unidentified | content inconclusive |
| 0xD09C | qrender | 36,704 B | **`lm_info`** (lightmap face table, `d_surf.bas`) | decodes as a real record: `tmin_s=-496, tmin_t=-176, lm_w=4, lm_h=2, styles={0,255,255,255}` |
| 0xD993–0xD9FB | qrender | 112/288/112/848/288 B | unidentified — presumed small BASIC heap-growth fragments | not chased |
| 0xD9B6 | **free** | 224 B | | |
| 0xDA0E | **free** | 9,088 B | | |
| 0xDC47–0xDFF30 | qrender | ~15,232 B total, 78 blocks, cycling 304/176/112/80 B | one small DC struct per (texture × mip) loaded by `mod_load_textures` | leading bytes decode as an EMS DC struct (xRes=yRes=64, pages=1) |
| 0xDFFF | **free, size 0** | — | **chain terminator — top of DOS's arena, exactly at the EMS `rdSegm`/`0xE000` page-frame boundary** | `sig='Z'`, correct/expected, not a bug |

**Total free anywhere: 224 + 9,088 = 9,312 bytes.**

## BASIC's own far heap: array-by-array (validated)

`SETMEM(0) - FRE(-1) = 248,672 B` measured used, at the same snapshot. Full
enumeration of every `REDIM`/`DIM SHARED ... AS <type>` in the source,
multiplied by live element counts, sums to **249,005 B — within 333 bytes
(0.13%)**, which is per-array allocator overhead, not missing accounting.

| category | bytes | share |
|---|---|---|
| level data (`tri_buffer`, `vtx_buffer`, `edg_buffer`, …) | 213,279 | 86% |
| surface cache (`sc_slot`, `sc_pool`) | 18,658 | 7.5% |
| texture/entity module data | 11,132 | 4.5% |
| `d_poly.bas` fixed buffers | 5,936 | 2.4% |

Largest individual arrays: `vtx_buffer` 39,864 B, `tri_buffer` 36,688 B,
`edg_buffer` 23,080 B, `ledg_buffer` 23,036 B — the raw BSP topology of a
2,293-face map. This is inherent to loading the map at all, not something the
lightmap work added.

This session's own additions (`lmt_buffer` 9,172 B + `sc_slot`/`sc_pool`
18,658 B) total 27,830 B, ~11% of the heap — real, but a fifth the size of
the level data around it.

**This table is a separate ledger from the MCB chain above.** BASIC's far
heap lives entirely inside the 486 KB base MCB + the 64 KB growth MCB.
`lm_base`, `lm_info`, the font atlas, and the texture DC structs are
`memAlloc()`'d into their *own* distinct MCBs and never touch this table —
which is exactly why moving them to XMS won't show up here at all.

## The finding that mattered

A `memAlloc`/`REDIM` of the 16 KB colormap table (`colmap.bld`, `[shade][index]`
LUT for the surface builder) hung the program with **no error**, at a point
where `memAvail&` still reported ~260,000 bytes free. The MCB walk showed why:
DOS had 9,312 bytes free, full stop — a 16 KB request is arithmetically
impossible to satisfy honestly. `bas_malloc` (mgl, `dosmem.asm`)'s retry path
— shrink BASIC's own heap via `B$SETM`, then retry `int 21h/48h` — can hand
back a block that doesn't correspond to real headroom once the arena is this
fragmented; writing into it (which a bare `REDIM` does, to zero it) then
corrupts whatever's actually there. No amount of `SETMEM`/`memAvail`
inspection would have shown this; only the MCB walk did.

**Fix:** move `lm_base` (71,328 B) and `lm_info` (36,704 B) to XMS — the two
big `memAlloc`'d blocks that don't need to be conventional/UMB memory at
all — reclaiming 108 KB and leaving the 16 KB colormap (and future growth)
comfortable headroom. UMB is already linked (`umb=true`, DOSBox-X default)
and already fully consumed by the allocations above; it is not an available
lever, and relying on it further would be fragile outside this specific
emulator config anyway (real DOS-era UMB availability depends entirely on
EMM386/QEMM + chipset shadow RAM).
