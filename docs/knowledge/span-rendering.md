---
type: investigation
title: Quake-style span rendering, measured against the polygon rasteriser
tags: [renderer, spans, r_span, ugl, overdraw, benchmarking, negative-result]
---

# Quake-style span rendering, measured against the polygon rasteriser

A complete global-edge-list span renderer was built, made correct, and
benchmarked against the existing per-polygon path. **It is 18% slower**, and
the reason is structural rather than an implementation detail that more work
would fix. This records the numbers, the four optimisation rounds that got it
there, the bugs found on the way, and what would have to change for the verdict
to flip — so nobody rebuilds it on the assumption that Quake's architecture is
obviously faster.

## The verdict

Four interleaved pairs, one binary flag-selected (`-spandraw`), identical
`UGLV.LIB` and `campath.bin`, dm3ish, pinned machine:

| per frame | polygon path | span path |
|---|---:|---:|
| `ft_mean` | **47.97 ms** | **56.75 ms** |
| frames over the campath | 356 | 308 |

Within-arm spread ~1.2 ms against an 8.8 ms gap. That is 4 runs per arm, not
the 6 the benchmarking rule asks for, but the separation is 7× the spread.

The span arm is *further* behind than it looks: `uglSpanBegin` forces
`UGL_Z_OFF`, so it writes no depth at all while the polygon arm writes it per
pixel. Dropping the Z buffer was separately measured at ~4.5 ms/frame, so
like-for-like the gap is nearer 13 ms.

## Why it loses

The frame decomposes (dm3ish, per frame, RDTSC inside the mapper):

| | ms | share |
|---|---:|---:|
| per-polygon setup, outside the scanline loop | **13.2** | **55%** |
| fill (`optFiller`) | 8.3 | 35% |
| all per-scanline work | 2.5 | 10% |

Resolving to spans costs ~23 ms and removes ~8 ms of avoidable fill. And the
largest item — per-polygon setup, ~4,700 ticks × ~208 polygons — is **invariant
to the architecture**: you resolve the same polygons either way.

Overdraw is the other half of the answer. It is a property of the map, not of
the code, and it is small:

| map | overdraw | edges/frame | crossings/frame | covered px/frame |
|---|---:|---:|---:|---:|
| dm3ish | 1.418 | 493 | 3,410 | 15,767 |
| e1m7 | 1.556 | 557 | 4,100 | 15,990 |

e1m7 has *more* overdraw and comes out **worse** (ratio of resolve to avoidable
fill 1.20 vs dm3ish's 1.06). Its geometry is more, smaller polygons: the same
screen area described with 20% more crossings, so the resolve cost grows faster
than the fill it saves. More overdraw does not imply spans win.

## The four optimisation rounds

Resolve cost fell 54% before the drawing was added. All interleaved A/B,
medians, same library both sides.

| round | change | `pt_span` | resolve total |
|---|---|---:|---:|
| — | starting point | 14.47 | 17.82 |
| A | 16.16 fixed point; AEL unpacked into near parallel arrays; measurement cruft deleted | 10.42 | 13.98 |
| B | doubly-linked AEL with sentinels; merge instead of re-sort; step/expire/repair in one walk | 6.98 | 10.55 |
| C | depth key = polygon emission index (integer), single-scan `toggle_active` | 5.81 | 9.35 |
| D | emit: per-vertex clamp, one integer magnitude test, `ceil_row` hoisted | 5.79 | **8.15** |

Round A's biggest single win was removing a call to `F_FTOL@` per crossing —
`(short)float` is a **helper call** in this build, confirmed in the link map,
not an instruction.

Round D's leverage came from proving two clamps unnecessary rather than making
them cheaper: clamping *vertices* to ±8192 (instead of the values derived from
them) means row `y0i`'s centre always lies in `[ylo, yhi)`, so `xstart` is a
convex combination of `xlo` and `xhi` and cannot escape; and `u_step` is only
read on an edge alive two rows or more, which bounds the slope. Six clamps
became two.

## Corrections worth keeping

**A per-crossing RDTSC bracket cost 1.25 ms of a 7.85 ms sweep** — a third of
what it reported. `toggle_active` was measured at 3.66 ms; removing the bracket
dropped `sweep` by 1.25, putting its true cost between 2.41 and 3.66. Anything
finer than a per-frame phase must be measured by *removing the work*, not by
timing it in place.

**"608 ticks per scanline" was wrong.** It came from subtracting `fill` from
`mappers` and attributing the remainder to per-scanline work. Bracketing the
whole outer loop showed 55% of it never enters the scanline loop at all. Real
per-scanline overhead is ~166 ticks. Derive costs by bracketing, not by
subtraction.

**Host load did not contaminate any of it.** All four rounds were measured with
a stray DOSBox running for 10 hours at 6% CPU. Re-measuring on a quieter host
reproduced `bucket`, `merge` and `step` within 1%, and two runs agreed to three
decimal places. `cycles=75000` pins the emulated machine and both `ft_mean` and
the RDTSC counters measure emulated time, exactly as the pinning rule claims.

## Bugs the isolated tests found, and the renderer could not

Three tests live in the mgl worktree's `src/test/` (`runtest.sh` gained
`EXTRAOBJ`/`EXTRALIB` so a test can link qrender's own object and its C
runtime):

- `spantst` — one span lands at the right address and nowhere else
- `spanpoly` — a perspective triangle matches `uglPolyTP` within a documented
  sub-texel tolerance
- `spanrsp` — `r_span.c` end to end, two overlapping quads, the nearer one
  taking the whole overlap

They found, in order:

1. **`uglSpanBegin` returned the wrong value** — the z-mode restore clobbered
   `ax` after the filler address was stashed. Invisible in the renderer, which
   ignores the return.
2. **`es:di` did not address the destination.** `wrBegin` *indexes the scanline
   table with `di` on entry* (it was passed junk), and a table entry is
   **segment in the low half, offset in the high half** — the reverse of the
   first reading. The segment is not constant across a dc, so it must come from
   the entry per span, via `wrSwitch` when it differs from `current`. This was
   corrupting the BASIC heap in the renderer and presenting as a wedge in
   `B$ONERR` with no output at all.
3. **u and v must be texels/z, not normalised/z** — `uglPolyTP` scales by the
   texture's own size where it builds gradients, above the level these entry
   points work at.

And one bug the isolated tests structurally *could not* find, because they each
create real per-texture dcs: **the texture handles are ~8 shared views,
re-aimed per face with `uglSetView`.** `d_poly` draws each face while its view
still points at the right cell; a sweep draws after the whole face loop has
re-aimed it hundreds of times. The aim has to travel with the handle
(`sc_view_ofs()` for the cache path, `g.wld.tex.ofs[]` for the atlas path) and
be restored before each polygon's spans.

## Getting it correct

Against the polygon path on a fixed frame, the span renderer reached: 0.0%
grossly wrong pixels, 94.9% within a small colour distance, 30.9% identical.
The residual is sub-texel sampling convention — the driver samples from each
scanline's true fractional edge, resolved spans have integer ends.

The fix that mattered most was **not fitting the plane through vertices 0, 1,
2**. `d_clip_z` hands over clipped polygons whose leading vertices are often
nearly collinear on screen — a wall at a grazing angle is the usual one — so
the determinant test rejected them and *whole faces were silently not drawn*.
Picking the best-conditioned triple (farthest vertex from the first, then the
one farthest off that line: two linear scans) took grossly-wrong pixels from
1.9% to 0.0%. Every isolated test used well-conditioned triangles, which is why
none of them caught it.

## What would have to change

- **Group spans per polygon.** Sweep order changes polygon ~545 times a frame
  against d_poly's 208 faces, so gradient patching and window setup happen 2.6×
  more often. Quake accumulated spans per surface and drew them together.
- **Move the per-span call inside the assembly.** ~545 far calls a frame cross
  a language boundary Quake's span loop did not.
- **Find geometry with real overdraw.** Neither map has it. The campath average
  is 1.42×; a high-overdraw viewpoint was never measured and is the one
  experiment that could still change the arithmetic.

Even executed perfectly, per-scanline work is only ~10% of mapper time, so the
first two win single-digit milliseconds against a 23 ms resolve. The honest
summary is that this compares *our span implementation* against *a mature,
tuned polygon rasteriser* — it is not a verdict on Quake's architecture, whose
advantage came from the whole pipeline being built around spans, including a
rasteriser whose per-span setup was free because it was already in the loop.
