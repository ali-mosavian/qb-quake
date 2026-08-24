---
type: reference
title: Surface cache descriptor sharing, uGL views, and standalone mgl testing
tags: [basic, mgl, ugl, ems, debugging, dosbox-x, surface-cache]
---

# Surface cache descriptor sharing, uGL views, and standalone mgl testing

Lightmap rendering needed a surface cache; the cache needed to stop
spending conventional memory per cached surface; that needed a new uGL
primitive; validating the new primitive needed a standalone test harness
that didn't already exist. This covers all four, the texture store the
same primitive then made possible, and the bug in that primitive which
took four passing standalone tests to corner.

## The DC-per-surface memory bug (fixed)

A `uglNew`'d DC costs `sizeof(DC) + yRes*4` bytes of **conventional**
memory for its scanline address table (`DC_addrTB`) — not EMS, not far
heap, DGROUP-adjacent conventional memory. The first surface cache gave
every cached surface its own DC. On dm3ish that was 228 DCs in two
frames against a pool sized for up to 1,200 (`SC_PERCLS=48` × 25 size
classes) — 350-670 KB of conventional memory that doesn't exist. The
symptom was "String space corrupt" after rendering correctly for a
while: DGROUP genuinely ran out from under BASIC's own string heap.

Shrinking `SC_PERCLS` to 12 made the symptom go away, but that's
treating the symptom — the real fix is that surfaces shouldn't own DCs
at all.

## uglNewView / uglSetView / uglDelView

New uGL primitives (`mgl/src/ugl/uglview.asm`), numpy's `.view()`
semantics: a DC with its own shape and clipping over a **parent's**
pixels, no memory of its own, nothing copied.

```basic
uglNewView&( src, ofs, xRes, yRes )   '' a view over src's pixels
uglSetView%( dc, ofs )                 '' re-aim it -- no alloc, no copy
uglDelView ( dc )                      '' frees struct+table, never pixels
```

**Why `uglDelView` instead of teaching `uglDel` to recognize a view**:
that needs a `base` field in the `DC` struct, which moves `DC_addrTB`
and forces reassembling all 31 modules that reference that offset —
against a `uglv.lib` already known stale versus `src/` (see
`mgl-lib-stale-vs-headers` memory). Keeping this a pure addition to the
library, not a struct change, was the deciding factor.

**Why aiming is cheap**: every uGL texture filler (`uglplxt`,
`uglplxtp`, `uglpltpg`, `uglplxtg`) does `xor si, si` before `rdAccess`
— drawing only ever reads `addrTB[0]`. So `uglSetView` for *drawing*
is one dword write. Only the *builder* path (`uglRowRead`/`uglPSet`,
which go through `uglDCAccessRd`/`Wr` and index per scanline) needs the
whole table filled, and that cost is noise beside the builder's own
per-texel loop.

**EMS/MEM addrTB encoding**, reverse-engineered from `ems_New`/`mem_New`
to write `ul$fillView`: an entry is a dword, low word addresses a
"bank", high word an offset inside it.
- `DC_EMS`: low = `handle | (logical_page << 8)`, offset wraps at 16K,
  page +1 on wrap. The page must be **added** to the handle word
  (`add dh, al`), matching `ems_New`'s accumulating `adc dh, 0` —
  writing it (`mov dh, al`) destroys the handle's own high byte. This
  file previously argued the two were equivalent "since real handles
  are small (<256)"; that reasoning was wrong and cost most of a
  session. See the EMS handle bug below.
- `DC_MEM`: low = far segment, offset wraps at 64K, segment +0x1000 on
  wrap (paragraphs).

**Store shape matters**: shaping the store DC 16384 wide keeps its own
scanline table tiny — `bps` is capped at one EMS page (`ems_New`
rejects `bps > EMS_PGSIZE`), so a 16384-wide DC is exactly one page per
scanline. A 1.5 MB store at that shape costs 96 entries, 384 bytes.
Shaped 128 wide instead, the *parent's own* table would be 49 KB —
larger than the saving the whole exercise exists to make. General rule:
when introducing a shared backing store, its own descriptor cost has to
be checked, not just the per-user savings.

**Result**: dm3ish's surface cache went from 228 DCs to 21 (one per
size class, made once). Verified: `sc_selftest%` still passes with the
store swapped in for the old pool, pixel-identical render, 40-frame
walk with lightmaps clean — though note that this verification passed
*while the EMS handle bug below was live*, because the cache both
writes and reads through views. Correct output through a broken
accessor is not evidence the accessor works.

## The uglNewView EMS handle bug (found late, root cause of it all)

`uglNewView`/`uglSetView` addressed the **wrong EMS handle** for any
parent that was not one of the first allocations. One line in
`ul$fillView`:

```asm
mov     dx, es:[DC.hnd]
mov     dh, al          ;; WRONG -- al is the logical page
```

`ems_New` encodes a scanline address as `handle | (logical_page << 8)`
and *accumulates* the page onto the handle word with `adc dh, 0`. So
the page is **added** to the handle's high byte, not written over it.
`mov dh, al` discards that high byte, which is zero only while EMS
handles stay under 256 — true for the first few allocations of a
program and false later. The fix is `add dh, al`.

This is why every symptom moved around. A view over an early DC worked;
a view over a DC allocated after the loading screen, the font and the
lightmap atlas read somebody else's pages. In qrender the texture store
read back 227 where 45 was expected — 227 being whatever the neighbour
happened to hold, which is also why the render showed *valid textures
on the wrong surfaces* rather than noise.

**It was live in the surface cache too, silently.** The cache writes
surfaces through views and draws through views, both with the same
wrong base — self-consistent, so it rendered correctly and "verified
pixel-identical" while addressing another handle's memory. A test that
writes and reads through the same broken accessor cannot see the break;
only comparing a view against an *independent* read of the parent can.

## Texture store consolidation (done)

The 160 t\*/r\* texture DCs are now one image per texel set plus one
view per mip size:

- `tools/mkassets.py` packs every texture and mip into a single 2048
  wide image at the exact byte offset the renderer aims a view at, and
  emits `texofs.bld` beside it. 2048 because a store row must divide
  the 16K EMS page evenly (8 rows to a page) and uGL's BMP loader caps
  a scanline at 8192 bytes.
- `mod_load_textures` does one `uglNewBMPEx` per store. No per-texture
  load at all, so the 160 DC allocations *and* the 160 alloc/free
  cycles of uGL's 10K BMP scratch buffer are both gone — the churn was
  fragmenting the heap even though every DC was freed again.
- `h_textr_dc` holds a byte offset now, not a DC. `tex_indx` is
  `mipidx*4 + miplevel`, so its low two bits are the mip, which is the
  view to aim.

Offsets are emitted rather than recomputed on the target: an offset
table and the code that reads it have to move together, which is the
lesson `clip.bld` already taught once.

Result on dm3ish, verified pixel-identical to the previous build on a
deterministic `-ticks 60` run (`-bench N` is *not* deterministic — it
counts frames, so a different `dt` walks the camera somewhere else and
~97% of pixels differ for no reason):

| | DCs | conventional bytes for scanline tables | asset files |
|---|---|---|---|
| before | 160 | ~12.3 KB (~24.6 KB with `-lm`) | 160 |
| after | 1 store + 4 views | ~0.9 KB (~1.7 KB with `-lm`) | 3 |

## How the isolation kept lying

Four standalone tests passed while the bug was live. Each was wrong in
a way worth recognising again:

1. **Never the failing combination.** One test put views over a
   `uglNew` DC; another loaded via `uglNewBMPEx` and read the DC
   *directly*. qrender does views over a `uglNewBMPEx` DC — the one
   pairing nothing covered.
2. **Always the first allocation.** Every test allocated its subject
   first, which is precisely where a handle-high-byte bug is invisible.
   Adding three throwaway `uglNew(UGL.EMS, ...)` DCs before the subject
   reproduced it on the first try. **If a bug appears only inside a
   real program, make the repro allocate like one before concluding the
   library is fine.**
3. **A palette that hid a remap.** A synthetic BMP filled with a
   grayscale `(i,i,i)` palette round-trips identically even if the
   loader is colour-matching, because nearest-match on grey *is* the
   identity. It "proved" `BMPOPT.NO332` was honoured; it proved
   nothing. Test data has to be able to fail.
4. **Self-consistent read-back.** Writing a pattern through a view and
   reading it back through the same view passes no matter where the
   view points. The check that mattered was view-vs-direct.

The false conclusions these produced, in order, were: the library
rebuild is fine, `uglview.asm` is fine, `uglPutBMPEx` is broken on wide
images, and `uglNewBMPEx` must be remapping the palette. All four were
wrong, and each cost a rebuild cycle.

**Read the harness before the guest.** A run under
`SDL_VIDEODRIVER=dummy` that never wrote `ran.txt` was called a hang
for most of a session; it was `qrender.exe` invoked *without* `-bench`,
which runs interactively forever waiting for a keypress that headless
has no way to send. Nothing was wrong with headless mode at all — the
same batch with `-bench 60` had already produced a full `run.out` and
`ran.txt` earlier in the same session.

## Standalone mgl test harness: six ways to fool yourself

None of these produced a hard, obvious signal — each one manifested as
"looks like it built, produces no useful output," which is exactly the
failure mode that had to be told apart from a genuine guest hang. In
order of how long each one cost:

1. **CRLF, again.** Files written by tooling default to LF; BC.EXE
   needs CRLF and does not always hard-error on LF — it can silently
   mis-tokenize across the "line break," producing a clean compile
   (`0 Severe Error(s)`) whose object is subtly wrong, or a confusing
   error several lines away from the real one (`Print "line 2"` flagged
   as a syntax error when line 1 was the actual LF). qrender's own
   `qblint.py` catches this in-tree; nothing catches it for files
   written to `mgl/src/test/` or a scratch directory. Check
   `content.count(b'\n') - content.count(b'\r\n') == 0` before handing
   any `.bas`/`.bi`/`.asm` to BC or MASM, every time, no exceptions.
2. **`$INCLUDE` paths are relative to the compiler's CWD, not the
   source file's location.** `mgl/src/test/*.bas` uses `'..\..\inc\*'`
   because `mk4vbd.bat` is meant to be run from inside that directory.
   Compiling the same source from an unrelated scratch `C:` mount (this
   session's setup, to isolate a test from qrender's own tree) breaks
   those relative includes with `$INCLUDE-file access error` — which
   BC.EXE then cascades into dozens of unrelated-looking "Type
   mismatch"/"Array not dimensioned" errors on every later line that
   used an undefined type. Use `M:\INC\*.bi` (absolute, via the `M:`
   mount) for anything not physically compiled from mgl's own tree.
3. **BC's object-file destination must be explicit.** `BC.EXE flags
   file.bas;` without `, file.obj` appears to succeed (no error text
   visible) but produces a tiny, wrong object — silently, because BC
   is prompting for missing parameters in a context with nothing to
   answer them, headless under DOSBox-X. Always
   `BC.EXE flags file.bas, file.obj; >> bc.out` and always check
   `bc.out` for the `N Severe Error(s)` line, not just whether an
   `.obj` file exists — an existing-but-wrong `.obj` passes a bare
   `if not exist` check.
4. **`/E` is a multi-module-project flag, not a general optimization
   flag.** Copied from qrender's own Makefile (`bc='...BC.EXE /O /FPi
   /R /G3 /E'`, correct there because qrender links many `.bas` modules
   together) into a standalone single-file test, it produced an EXE
   that linked and "ran" (`exit_code=0`, fast) but executed **none** of
   the program's own code — no output from even the first `Print`
   statement, in a program with no DGROUP pressure and no plausible
   reason to fail that early. mgl's own `mk4vbd.bat` (for exactly this
   kind of standalone test) omits `/E`: `bcv /o /fpi /r /g3 %1.bas;`.
   Match the test-harness convention, not the multi-module one.
5. **The full `uglv.lib` needs `/SEG:800` to link at all**, once it
   carries every module (151+, ~284 KB after `uglview.asm` landed):
   `LINK.EXE ... fatal error L1049: too many segments` without it.
   `mk4vbd.bat`'s own link line already has `/seg:800`; missing it is
   invisible until link time, and by then two of the four gotchas above
   have usually already been chased and fixed, so it reads like
   "well THIS time it's really something new" rather than "one more
   flag missing from the copied command line."
6. **DOS 8.3 filenames apply to scratch test files too.** A test file
   named `serialtest.bas` (10-character base) failed `BC.EXE` outright
   with `Input file not found` — not a compile error, a file-not-found,
   even though the file was sitting right there on the mounted drive.
   DOSBox-X's mounted drives enforce the same 8.3 limit real DOS does;
   nothing about a scratch/test context exempts it. Renamed to
   `comtst.bas` (6 chars), no other change, and it compiled immediately.
   Keep standalone test basenames to 8 characters on principle rather
   than re-discovering this per test.

**The general lesson, not specific to any one of these**: a standalone
test that builds without a visible compiler error and then produces no
useful output is not evidence the code under test is broken. Check the
build log's own severe-error count explicitly, verify with a
trivial `Print "x"` **through the exact same harness** before trusting
a "clean" result from anything more complex, and don't reuse flags
copied from a different build context (multi-module vs. standalone)
without checking what they actually mean.

## COM1 serial logging: validated, working

`serial1=file file:<path> timeout:<ms>` in DOSBox-X's `[serial]`
section captures whatever the guest writes to the UART, independent of
disk I/O — useful in principle for a hang that might be corrupting the
guest's own file-I/O state, since a frozen-mid-write disk log looks
identical to "never got there." d32x's own convention
(`src/rt/16/serial.inc`) is raw port I/O at 0x3F8-0x3FD, not BASIC's
`OPEN "COM1:"`, which goes through DOS's own COM driver — another layer
a suspected-corruption test shouldn't lean on. Init sequence: `OUT
&H3FB,&H83` (DLAB=1) → `OUT &H3F8,&H01` / `OUT &H3F9,&H00` (divisor low/
high, 115200 baud) → `OUT &H3FB,&H03` (DLAB=0, 8N1) → `OUT &H3FC,&H03`
(DTR+RTS) → `OUT &H3F9,&H00` (no interrupts). Send byte: busy-wait
`(INP(&H3FD) AND &H20) = 0` (LSR THR-empty bit) then `OUT &H3F8,byte`.

Validated end-to-end with a minimal test (`comtst.bas`, six-char
basename — see pitfall 6 above; the original 10-char `serialtest.bas`
never got the chance to run at all): console `Print` checkpoints plus
raw UART init/send of `"hello from serial" + Chr$(13) + Chr$(10)`. The
resulting `serial1=file` capture matched byte-for-byte:
`68656c6c6f2066726f6d2073657269616c0d0a` = `hello from serial\r\n`. The
channel works; the earlier "never appeared" result was the 8.3-filename
bug preventing the test from compiling at all, not a serial or DOSBox-X
config problem.

## dosbox-x debug-socket notes from this session

- A write watchpoint (`dosbox_bp_set kind:write`) requires `core=normal`
  and reliably killed the debug socket on `continue_report` in this
  build, twice, with no crash log written — a tooling limitation, not
  informative about the guest. Fall back to print/serial bisection.
- `dosbox_debug_state`'s `processExit` can report a clean `exit_code=0`
  for a batch of THREE DOS processes (BC.EXE, LINK.EXE, the compiled
  EXE) with a shared, deceptively-identical-looking notification
  pattern across runs — don't read "same PSPs, same exit codes" as
  "the same thing happened again" without checking the actual build
  artifacts (`bc.out`, object sizes, wall-clock timestamps); a
  fast-failing build and a successfully-run test can produce
  superficially similar exit-notification sequences.
- `dosbox_text_screen` reading mid-run (after a `pause` inserted into
  the autoexec batch, before the final `exit`) was the one channel that
  actually worked reliably for seeing guest console output in this
  investigation, once the five build-harness bugs above stopped
  producing false negatives.
