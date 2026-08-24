---
type: recipe
title: Diagnosing DOS conventional/UMB memory exhaustion via the MCB chain
tags: [dosbox-x, memory, basic, mcb, debugging]
---

# Diagnosing DOS conventional/UMB memory exhaustion via the MCB chain

When a `memAlloc`/`REDIM` of a modest size (10s of KB) hangs or silently
corrupts state with no error, and BASIC's own `SETMEM`/`FRE`/`memAvail` don't
explain why, the fix is to stop trusting those numbers and walk DOS's own
memory ledger — the MCB (Memory Control Block) chain — directly in the
debugger. This found a case where 328 KB of "free" memory (per `memAvail`)
coexisted with 9 KB of *actually* free memory (per DOS).

## Why the high-level numbers lie

- `memAvail&` (mgl's implementation) returns `MAX(DOS's largest free block,
  QuickBASIC's far-heap size via B$SETM(0))` — i.e. it can report the **size**
  of BASIC's heap, not how much of it is free.
- `SETMEM(0)` / `FRE(-1)` report BASIC's own far-heap arena size / free tail
  only. `memAlloc()` calls that succeed via DOS directly (not through BASIC's
  heap) never touch this number.
- Neither number reflects DOS's global memory state, which is the actual
  constraint `int 21h/48h` allocation calls run into.

## The method

1. **Get the live PSP.** `dosbox_get_load_info` returns `pspSeg` for the
   running EXE. Its own MCB is at `pspSeg - 1`.
2. **Read one MCB header** (16 bytes) with `dosbox_mem_read`:
   `sig(1) owner_psp(2 LE) size_paragraphs(2 LE) reserved(3) name(8)`.
   `sig` is `'M'` (0x4D, more follow) or `'Z'` (0x5A, last in chain).
   `owner=0` means free.
3. **Walk forward**: `next_segment = this_segment + 1 + size_paragraphs`.
   Read the next header there. Repeat until `sig='Z'`.
4. **A `'Z'` MCB with `size=0` is the top of DOS's entire allocatable
   universe** — not a bug, just where the ledger ends. If it lines up with a
   fixed window (e.g. the EMS page frame segment), that's expected and
   correct, not a leak.
5. **Sum every free (`owner=0`) block found.** That sum, not `memAvail`, is
   what a new `int 21h/48h` allocation actually has to work with.

## Pitfalls hit doing this

- **`dosbox_mem_read` caps at 4096 bytes/call.** Don't try to slurp the whole
  arena in one read; walk MCB-by-MCB (16 bytes each) or use
  `dosbox_mem_search` (see below) to find candidate headers first.
- **A raw byte-pattern search for `0x4D`/`0x5A` without alignment produces
  overwhelming false positives** — ordinary data inside a program's own
  486 KB block contains plenty of stray `0x4D` bytes. Always pass
  `align: 16` (MCB headers only ever start on a paragraph boundary), and
  even then, false positives happen inside video-memory content (VGA
  framebuffer bytes at 0xA000-0xBFFF can coincidentally equal `0x5A`) — only
  a byte at a paragraph boundary that also produces a *self-consistent
  forward chain* (next computed address lands on another valid header) is
  real.
- **Hex/decimal arithmetic slips are the #1 source of wasted time.**
  `segment × 16` for the linear address, `this_segment + 1 + size` for the
  next header — get one digit wrong once and the "MCB" you read next is
  garbage, which looks exactly like a corrupt chain. When a read comes back
  all-zero or nonsensical mid-walk, re-derive the address from the *previous
  MCB's own printed hex string* instead of trusting mental arithmetic.
- **Video memory (0xA000-0xCBFF-ish) is walkable but is not real allocatable
  RAM** — DOSBox-X's DOS represents it as one large MCB owned by PSP 8
  ("DOS itself") specifically so normal allocators skip over it as a unit.
  Seeing this is confirmation the walk is on track, not an anomaly.
- **A `'Z'`-terminated MCB with `size=0` sitting exactly at a device window
  segment (e.g. `0xE000` for `EMS_READPAGE`) is DOS correctly refusing to
  offer that address range** — the mandatory EMS page frame, video hole, or
  similar. Don't chase it as a bug.

## Identifying blocks by content, not just size

Size alone is ambiguous (many small structs coincide in byte count). Two
disjoint origins produce MCBs that must be told apart:

- **Explicit `memAlloc()` calls** (mgl) prepend mgl's own small `MEM` header
  (`_size`/`prev`/`next`) *before* the payload the caller sees. Peek the first
  16 bytes past the DOS MCB header — if it looks like two small pointer-ish
  words followed by a size and zero padding, that's mgl's header; the real
  payload starts right after it.
- **BASIC's own automatic far-heap growth** (triggered internally whenever an
  ordinary `REDIM` outgrows the current heap) has **no such header** — the
  MCB's data area *is* the array's raw storage directly.

To identify an unlabeled block, peek its data and match it against a known
struct layout or known first-bytes:
- An mgl DC struct reads `bpp(1) p2b(1) xRes(2) yRes(2) bps(2) pages(2) ...`
  — plausible small integers (e.g. `xRes=yRes=64, pages=1`) confirm a texture
  atlas DC.
- Raw application data (e.g. lightmap luxels) can be confirmed byte-for-byte
  against a known reference (the source file on disk, or a value the program
  itself printed earlier).

## Cross-checking against BASIC's own array declarations

Once suspicious blocks are identified as "BASIC's own heap growth" rather
than an explicit `memAlloc`, the *entire* far-heap-used figure
(`SETMEM(0) - FRE(-1)`) can be independently reconstructed and validated:
grep every `REDIM`/`DIM SHARED ... AS <type>` in the source, look up each
`TYPE`'s byte size field-by-field, multiply by the live element count (read
from the loaded data, e.g. lump byte-counts ÷ record size), and sum. A
correct enumeration should land within a few hundred bytes of the measured
figure — the residual is per-array descriptor overhead in BASIC's own
allocator, not missing accounting.

See [qrender-memory-map.md](qrender-memory-map.md) for this method's full
output on a live run.
