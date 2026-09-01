---
type: index
title: Knowledge base
tags: [index]
---

# Knowledge base

Project-specific knowledge bundle for qb-qrender ([OKF](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/HEAD/okf/SPEC.md)
format). Standalone — no dependency on any other bundle.

- [dos-mcb-memory-diagnosis.md](dos-mcb-memory-diagnosis.md) — how to walk DOS's MCB chain live
  in the dosbox-x debugger when `memAvail&`/`SETMEM`/`FRE` don't explain a hang; pitfalls
  (4096-byte read cap, false-positive signature scans, arithmetic slips, video-memory-as-MCB);
  identifying a block by content vs. by size; cross-checking BASIC's own heap usage against its
  array declarations
- [qrender-memory-map.md](qrender-memory-map.md) — the method's output on a live run: the full DOS
  MCB chain for `qrender.exe` (which blocks are ours, which are BASIC's own heap growth, which is
  free), and the complete array-by-array breakdown of BASIC's far heap, validated to within 0.13%
  of the measured figure
- [map-data-compression.md](map-data-compression.md) — every compression applied to the level
  data (~89 KB reclaimed on dm3ish): the tmp-type invariant, range-verified long→integer
  narrowing, the unsigned-in-int16 wrap, Q13.3 vertices (and the one-map-sizing lesson),
  per-face 4-bit lightmaps with reconstruction-fit assignment; plus the measured rejections
  (texinfo fixed point, Huffman, perceptual quantization, global-palette dithering) and the
  verification methodology
- [span-rendering.md](span-rendering.md) — a complete Quake-style global-edge-list span
  renderer, built, made correct, and benchmarked against the existing polygon path: 56.75 vs
  47.97 ms/frame, 18% SLOWER, and slower still like-for-like since the span arm writes no depth;
  the frame decomposition that explains it (per-polygon setup 13.2 ms and invariant to the
  architecture, fill 8.3, all per-scanline work only 2.5) and the overdraw measurements that
  undercut the premise (dm3ish 1.42x, e1m7 1.56x yet WORSE, because more smaller polygons cost
  more to resolve than the fill they save); the four optimisation rounds that cut the resolve 54%
  (fixed point and near arrays, linked AEL with merge/step/repair in one walk, integer depth key,
  clamp-the-vertices-not-the-derivatives); two measurement corrections worth keeping (a
  per-crossing RDTSC bracket cost a third of what it reported; "608 ticks/scanline" was an
  artifact of deriving cost by subtraction instead of bracketing); the four bugs isolated tests
  found and the one they structurally could not (~8 shared texture views re-aimed per face, which
  deferred drawing invalidates); and the near-collinear clipped-polygon fit that was silently
  dropping whole faces
- [real-mode-flat-addressing.md](real-mode-flat-addressing.md) — whether segment 0 plus a 32-bit
  offset reaches 1MB in real mode: DOSBox-X says yes, bochs says #GP in four independent
  configurations including a genuine V86 one, and bochs is right; why V86 cannot be made to do it
  (the limit is imposed by the mode, and entering V86 reloads all six segment registers) and what
  does work instead (DPMI flat selector, VCPI, or no memory manager); the finding that a DPMI host
  does NOT put the CPU in V86 — neither `CWSDPMI -P` resident nor after a real client activated
  it, only HIMEM+EMM386 reported PE=1; three ways this test was vacuous before it wasn't (target
  under 64K, uniform region where 0 == 0 "passed", and both arms secretly identical until SMSW
  proved it); and the general lesson that any low-level assumption verified only under DOSBox is
  unverified
- [surface-cache-and-standalone-testing.md](surface-cache-and-standalone-testing.md) — the
  DC-per-surface conventional-memory bug and its fix (`uglNewView`/`uglSetView`/`uglDelView`,
  numpy-style views added to uGL, 228 DCs → 21 on dm3ish); the `ul$fillView` EMS handle bug that
  hid inside it (the logical page must be *added* to the handle word, not written over it, or a
  view addresses another allocation once handles pass 255) and why the surface cache rendered
  correctly anyway; the 256-page ceiling on any EMS DC (`ems_New`'s page counter is one byte,
  4 MB max at 16384 wide — found by growing the cache to 16 MB and getting the same corruption
  signature back); the texture store this unblocked, written then REVERTED because it corrupts
  lightmapped surfaces (unlit byte-identical, `-lm` 87.9% different — and the one-angle `-lm`
  check that let it through); the lightmap "streaks" traced to `sc_mipfloor` forcing large faces
  to a coarser surface mip than the texture path, which box-averages a one-texel groove into
  pixels *brighter* than colormap row 0 can produce — plus the 269-pixel over-bright count that
  makes it measurable and the eight hypotheses it eliminated; four ways a *passing* standalone test can be
  vacuous — never exercising the failing combination, always allocating first, test data that
  cannot fail, and read-back through the same broken accessor; six ways one can look like it
  built and ran while silently not doing either (CRLF, `$INCLUDE` path scope, BC's object-name
  requirement, the `/E` flag, `/SEG:800`, DOS 8.3 filenames); and validated DOSBox-X serial-port
  logging (raw UART I/O) as a debugging channel independent of disk I/O
