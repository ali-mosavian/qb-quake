---
type: reference
title: Map-data compression — methods, results, and rejected approaches
tags: [basic, memory, compression, bsp, lightmaps, fixed-point]
---

# Map-data compression — methods, results, and rejected approaches

The far-heap pool that holds the level data ran ~9 KB from empty on dm3ish
(see [qrender-memory-map.md](qrender-memory-map.md)). This documents every
compression applied to close that gap, the methods behind them, the numbers
they were verified against, and — as importantly — the approaches that were
measured and rejected, so they don't get re-proposed.

Net result on dm3ish: level data 313,873 → 265,699 B, scratch arrays
16,384 → 5,258 B, lightmap blob 71,307 → 40,677 B. `memAvail&` during a
bench run rose from 257,520 to 287,520 B, and the far-heap total dropped
~89 KB against where the session started.

## The load-bearing invariant: the tmp-type pattern

`mod_open` derives every lump count as `wld.xxx_count = wld.head.xxx.size \
len(record)`, and `wld.head` is read live from the original `.bsp` at
runtime. So narrowing a live buffer's TYPE silently corrupts the count
derivation unless the divisor stays the ON-DISK record size. Every narrowed
type therefore keeps an unconverted twin whose only job is to be `len()`'d:
`fce as face`, `nodetmp`, `leaftmp`, `planetmp`, `clptmp`, `vtxtmp`,
`texinfotmp` (model.bas, top).

The other half of the invariant lives in `tools/mkassets.py`: the packer
must emit records at exactly the narrowed size, or `BLOAD` overruns the
buffer. This failure mode is real, not theoretical: a revert cycle once
left the packer emitting 8-byte clipnodes while the TYPE was 6 bytes — a
13,184-byte file BLOADed into a 9,888-byte array. No error at load; a hard
fault (bypassing `ON ERROR GOTO` entirely) on the first collision-hull walk
of frame 1, which from outside looked like a clean silent exit. The type,
the packer, and the tmp twin move together or not at all.

## Methods applied

### Dead-field elimination
- `face.lightmap` (LIGHTING-lump offset): nothing reads it — d_surf's
  `lm_info`/`lmtmin` replaced it. face 20 → 12 B (then 10, below).
- `texinfo.flags` (TEX_SPECIAL): a *compiler-only* hint. qbsp/light consume
  it; by the time a `.bsp` exists its effect is baked into each face's own
  `lightofs`/`styles` (unlit faces simply have `lightofs = -1`), and liquid
  detection here keys off the `*` texture-name prefix instead. Confirmed:
  no `.flags` read anywhere in src/. texinfo 40 → 34 B.

### long→integer after whole-corpus range verification
Verified against ALL 10 available maps (shareware e1m1–e1m8 + start.bsp,
extracted from PAK0.PAK, plus dm3ish) before narrowing:

| field | verified range | int16 headroom |
|---|---|---|
| `clipnode.planenum` | 2 .. 2,947 (e1m4) | 11x |
| `leaf.cont` | always ∈ {-1..-6} (CONTENTS_*) | vast |
| `texinfo.miptex` | 0 .. 72 (start.bsp) | 450x |

### Unsigned-in-int16 (two's-complement wrap)
`face.ledgeid` is an unsigned ledges index; e3m6 (retail) reaches 32,880 —
113 past signed int16. Packed as the two's-complement bit pattern
(`ledgeid - 65536` when ≥ 32768); the one read site (d_poly.bas) undoes it:
`if lid < 0 then lid = lid + 65536` into a LONG local. Shareware max is
only 29,342, but the wrap costs nothing and covers retail. face 12 → 10 B.

### Q13.3 fixed-point vertices (float32 → int16)
Vertices are floats on disk but ~99% integer-valued (BSP compiler output).
Stored as `round(coord * 8)` in an int16; dequantized per read by one
multiply (`* 1/8`) in the draw loop's only read site. 12 → 6 B/vertex,
19,932 B saved on dm3ish, zero measured fps cost.

**The Q12.4 → Q13.3 lesson**: dm3ish spans ±1,056, so Q12.4 (±2,048,
1/16-unit) looked comfortable — but checking the packer's bounds check
against the full shareware corpus found 6 of 9 real maps overflow it
(start.bsp and e1m1 reach ±3,216). Q13.3 (±4,096, 1/8-unit) covers all
with margin. Never size a format from one map. The bounds check in
`mkassets.py` errors loudly *at asset-build time* because the BC build is
overflow-unchecked at runtime — a wrapped coordinate would corrupt
geometry with no diagnostic at all.

### Lightmaps: per-face 4-bit linear quantization (71,307 → 40,677 B)
Each style plane stores `(base, range)` + 16 *linear* levels between its
own min/max, DXT-style, two nibble indices per byte, low nibble first.
`sb_build` rebuilds the 16-entry level table per cache miss:
`level(j) = base + (j*rng + 7) \ 15` — encoder (mkassets.py
`encode_plane`) and decoder (d_surf.bas) must use this exact formula.

Why per-face: a *global* 16-level palette (Lloyd-Max over the map
histogram) banded badly — adjacent levels sat ~15 apart, and the
renderer's bilinear reconstruction turned smooth gradients into plateaus.
Per-plane ranges are narrow (dm3ish median max−min = 34 → median step
~2.3), making the reconstruction visually exact for ~87% of planes.

Wide planes (range > 120) instead get a reconstruction-fit assignment:
ICM sweeps minimizing the *bilerp-reconstructed* error, whose quadratic
form (bilinear element mass matrix: self 4, edge 2, diagonal 1, /36) has
positive cross-couplings — neighbours erring in opposite signs cancel
through the interpolation, PWM-style. The 120 threshold is derived from
the display path: nearest-rounding error ≤ range/30 = 4 light values ≤
one row of the 64-row colormap — invisible by construction. Below it,
plain nearest beats the fit (alternation adds mottle for nothing).

Per-plane percentiles on dm3ish (2,204 lit planes): p50 range 34,
p75 75, p90 135, p95 162, p100 235; 13.1% exceed the threshold.

## Rejected approaches (measured, not guessed)

- **texinfo.vecs/vect as fixed point**: direction components span only
  ±2.0, but they multiply through `tw` (≤64) × vertex coords (≤3,216) —
  amplification ~205,824. Concrete demo (start.bsp, 45° wall, its largest
  vertex): Q3.13 → 6.48 texels of UV error; even spending the *entire*
  int16 range on ±2 (scale 16384) → 2.02 texels, still visible seam
  territory, and 3 components across the corpus sit exactly at ±2.0 and
  would clip. "Little loss" needs ~21 fractional bits — doesn't fit 16.
  Stays float32. (General rule extracted: quantization error that gets
  multiplied by world-space magnitudes is a different regime from error
  that stays additive; check the consumption chain before narrowing.)
- **miptex → 1 byte**: BASIC has no byte type; `string*1` + `ASC()` per
  access, to save ≤82 B/map. Not worth the access-pattern damage.
- **tmin_s/tmin_t below int16**: always multiples of 16 (floor(min/16)*16
  by construction — 0 exceptions in 89,382 sampled values), but /16 still
  spans -201..198, over a signed byte. 3-byte packing of the (s,t) pair
  (2×9 bits in 24) works arithmetically; deferred — it belongs with the
  lm_info raw-offset access style, and the lightmap subsystem was still
  moving.
- **Huffman on luxels** (incl. shared-table variant): order-0 entropy of
  the corpus is 6.8 bits/luxel → ceiling 1.18x on data that tolerates a
  lossy 2x. Independent killer: variable-length codes break the random
  2D access `sb_build`'s bilinear sampling needs (l00/l10/l01/l11 from
  two rows) — every cache miss would need a full decode into a scratch
  buffer first. Table strategy can't fix either problem.
- **Perceptual (row-space) quantization of luxels**: the light→row
  mapping `row = (65280 - light*264)\4 >> 8` is a near-uniform ~4:1
  compression (consecutive light values step rows by only 0 or 1; dead
  zones of just 12 values at the bright end, 3 dark). Lloyd-Max in
  row-space vs light-space: mean row error 0.949 vs 0.893 — a wash.
  Perceptual weighting needs a strongly nonlinear transform to exploit.
- **Global-palette + Floyd-Steinberg dithering**: kills the banding
  contours but replaces them with luxel-scale blotch (each luxel spans 16
  texels, so dither noise is low-frequency, and alternating levels 15
  apart rides a ±7 wave bilerp can't hide). Superseded by per-face
  ranges, which shrink the step itself instead of hiding it.

## Verification methodology

- Every structural change: `ctrl.conf` static run (`frames 2 polys 153
  tris 365` on dm3ish is the known-good signature) + pixel-diff of
  BENCH.BMP against the previous build (0 differing pixels expected for
  lossless tiers) + `walk_n.conf` (core=normal, fixed cycles — dynamic
  core timing is not comparable across launches) for fps and trajectory.
- Direct binary self-identification beats build-system trust:
  `host_bench_report` prints `clprec`/`clpcnt` (`len(clp_buffer(0))` and
  the derived count) precisely because a stale-mtime incident made two
  differently-built exes indistinguishable from outside.
- Lossy lightmap changes CANNOT be judged from renderer screenshots while
  the lightmaps aren't in the draw path — and not from raw luxel grids
  either: compare in the *reconstruction domain* (bilerp-upscaled, as
  `sb_build` samples), since nearest-neighbour viewing overstates banding
  and understates what interpolation recovers. Error metrics likewise:
  mean/max in bilerp space, not per-luxel.
