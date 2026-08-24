---
type: reference
title: Surface cache descriptor sharing, uGL views, and standalone mgl testing
tags: [basic, mgl, ugl, ems, debugging, dosbox-x, surface-cache]
---

# Surface cache descriptor sharing, uGL views, and standalone mgl testing

Lightmap rendering needed a surface cache; the cache needed to stop
spending conventional memory per cached surface; that needed a new uGL
primitive; validating the new primitive needed a standalone test harness
that didn't already exist. This covers all four, plus the texture-store
work that is still mid-debug.

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
  page +1 on wrap. Real handles are small (<256), so overwriting the
  high byte of a handle-seeded `dx` is equivalent to what `ems_New`
  does with an accumulating `adc dh,0` — same result, simpler code.
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
walk with lightmaps clean.

## Texture store consolidation (in progress, currently hangs)

Applying the same trick to the 160 t\*/r\* texture DCs (46 KB of
descriptors) via `tex_stash&`: load through `uglNewBMPEx` as before,
row-copy into a shared `tx_store`, free the temporary DC. This is
**currently broken** — a `-nostats -bench 60` run of dm3ish hangs
partway through `sys_time_init`'s busy-wait for `TIMER` to tick, which
is the signature of something freezing the BIOS tick counter at
0040:006C via a wild write, not a normal DOS-level hang.

Ruled out, in order:
- Sound (DOSBox mixer `nosound=true` and qrender's own `env.sound`,
  already false by default in `stuff.ini`) — same hang either way.
- Watchpoint tooling itself — arming a `write` watchpoint and
  continuing kills the dosbox-x debug socket instantly, no crash log;
  a tooling problem, not a guest one. Abandoned that path.
- Many repeated alloc/copy/free cycles exhausting something — hangs
  with exactly **one** `tex_stash` call (1 texture, 1 mip, 64 rows).
- The view machinery — a version of `tex_stash` that copies into a
  **plain fresh `uglNew`'d DC** (zero view calls) hangs identically.
- The row-copy logic and the rebuilt library themselves — see below,
  proven fine in isolation.

**The standalone test — same "withview" library, same `uglNewBMPEx` +
64-row copy — runs clean and verifies byte-correct.** So the bug is
not in `uglview.asm`, not in the library rebuild, and not in
`uglRowRead`/`uglRowWriteBuff` as such. It is something specific to
qrender's own context at the point `tex_stash` runs there (DGROUP
pressure from the rest of the program, interaction with state the
standalone test never sets up, or a difference between the *actual*
call site's DC sizes/sequencing and what the repro exercises). Not yet
found — the standalone repro needs to be grown toward qrender's actual
call pattern (loop over real mip sizes rather than a fixed 64×64,
inside a program that has also loaded a real map) rather than debugged
further inside qrender itself, since print/serial bisection inside the
full program had already been exhausted without narrowing further than
"before `sys_time_init`, after `mod_load_textures`".

## Standalone mgl test harness: five ways to fool yourself

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

**The general lesson, not specific to any one of these**: a standalone
test that builds without a visible compiler error and then produces no
useful output is not evidence the code under test is broken. Check the
build log's own severe-error count explicitly, verify with a
trivial `Print "x"` **through the exact same harness** before trusting
a "clean" result from anything more complex, and don't reuse flags
copied from a different build context (multi-module vs. standalone)
without checking what they actually mean.

## COM1 serial logging: set up correctly, still unproven here

`serial1=file file:<path> timeout:<ms>` in DOSBox-X's `[serial]`
section captures whatever the guest writes to the UART, independent of
disk I/O — useful in principle for a hang that might be corrupting the
guest's own file-I/O state, since a frozen-mid-write disk log looks
identical to "never got there." d32x's own convention
(`src/rt/16/serial.inc`) is raw port I/O at 0x3F8-0x3FD (115200 8N1, no
interrupts), not BASIC's `OPEN "COM1:"`, which goes through DOS's own
COM driver — another layer a suspected-corruption test shouldn't lean
on.

Implemented (`SerialInit`/`SerialStr` in the current `rowio.bas`, raw
`OUT`/`INP`) but never actually validated end-to-end this session — the
log file never appeared during testing, and the eventual working repro
used console `Print` + a disk `result.txt` instead (safe once the
build-harness bugs above were fixed and the guest was confirmed not to
hang in the isolated case). Whether the gap was DOSBox-X config, guest
UART init, or something else is still open. Worth resolving before
leaning on it for the texture-store hang above, since that is exactly
the "disk I/O might itself be compromised" scenario this channel exists
for.

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
