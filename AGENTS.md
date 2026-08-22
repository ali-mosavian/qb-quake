# Notes for working on this

Hard-won things, mostly the kind that cost an hour before they cost a minute.

## Toolchain

**VBDOS 1.0 only.** Not a preference:

- QB 4.5 — `BC.EXE` reports `Out of memory`, 0 bytes free, *before parsing the
  program body*. It does so identically with 608K conventional free, so memory
  is not the constraint.
- PDS 7.1 — rejects every `_` line continuation in `src/bsp_pvs.bi`
  (`Formal parameter specification illegal`) and cascades to 113 errors.
  Underscore continuation is a VBDOS extension.

`make evidence` reproduces both on demand.

**µGL must be the patched library in `ugl-patch/`**, not the stock one. See
`ugl-patch/README.md` — µGL scaled normalised UVs to texels by `xRes-1`
instead of `xRes`, so one repeat advanced 63 texels across a 64-wide texture
and every face drifted in proportion to its own UV magnitude.

**To rebuild µGL, build from the 0.23b source drop, not from `mgl/src`.** The
shipped `uglv.lib` is byte-identical to 0.23b's, while `mgl/src` has diverged
from its own binary. Modules assembled from the newer tree link without error
and then render a **black screen**. Assembler is **MASM 6.11d** — plain 6.11
fails on the `misc/` clippers with a macro forward-reference error, and 6.14
is Windows-only so it will not run under DOSBox.

## BASIC / VBDOS

**`defint a-z` means an undeclared name is a silent integer zero, not an
error.** This is the single most productive bug family in this codebase. Real
ones found here:

| symptom | cause |
|---|---|
| textures misaligned per face | `texiCount` never `dim shared`; `bspAlloc` read 0 and did `redim texInfBuff(-1)` |
| Quake palette never installed | `pal` written in one routine, read as 0 in another |
| FPS counter stuck at 1 | `fps1` local to a routine entered once per frame |
| screenshots overwrote each other | `screenie` reset to 0 every call |

When splitting routines out of a long one, audit every name the original
*assigned* — not just the `dim`-declared ones. `texiCount` and `fps1` were
both implicit.

**`DIM SHARED` is module scope only.** Across separately-compiled modules you
need `COMMON SHARED`, declared identically in every module (keep it in
`src/qshared.bi` and include that everywhere). Two rules:

- `COMMON` must precede every executable statement — a dynamic `DIM` counts.
- It declares the variables itself; no preceding `DIM`.

**An array with a real bound cannot survive migration to `COMMON`.**
`dim shared hTextrDC( 256*4 )` was a genuine allocation that nothing redims;
`COMMON SHARED` can only say `hTextrDC()`, i.e. zero elements. Needs an
explicit `redim` in the owning module. Arrays declared `( 1 )` are fine —
they are placeholders and something already redims them.

**`COMMON` arrays are always descriptor-addressed.** Do not move the
renderer's `'$STATIC` scratch there; it is in DGROUP for direct addressing on
purpose. Split on *data ownership* — the render routines touch 47 shared
variables but own 19 exclusively.

**`x` and `x()` are different names.** `dim shared vtx as vertex` and
`dim shared vtx(31) as tritype` coexist legally. A name-based refactor will
conflate them.

**`MOD` rounds its operands to integers; `int()` truncates.** Mixing them in
the same expression skews by up to half a unit — that was the duplicated
column on the 32×32 sign textures.

**`on errror goto HandleErr`** (three r's, line ~191) is *not* a syntax error:
BASIC also has a computed `ON n GOTO`, so it parses as "branch to the zeroth
label" and falls through. **Runtime error trapping has never worked.** Left
as-is deliberately — fixing the spelling routes every error to a generic
message, which is worse than the runtime's specific one.

**MASM logical-line limit is 512 chars** including continuations. Expanding
tabs to spaces in µGL's asm pushed a `local` block over it.

## Harness

Verification runs go through **plain DOSBox with a redirect**, not the MCP.
The debug socket is for inspecting a program you deliberately stopped.

- **The MCP freezes the guest CPU on a critical notification.** A stale
  `process_exit` will hold a newly launched program frozen. Always check
  `cpuRunning` before drawing any conclusion from a CPU reading — a frozen
  guest looks exactly like an idle one. This cost the most time of anything
  in this repo.
- **A config whose `[autoexec]` ends in `exit` quits DOSBox** the moment
  `continue` lets it finish. That is not a program failure.
- **`autotype` → `s` has never once produced a screenshot here.** Its silence
  carries no information.
- The debug socket needs `core=normal` and a *fixed* cycle count. Under
  `cycles=max` the guest starves it and `break`/`text_screen` time out.

**A failed run looks exactly like a slow one.** `ExitError` ends in `sleep`,
so the program sits there; the message is drawn as *pixels* if `uglRestore`
left a graphics mode (invisible to `text_screen`), BASIC's `PRINT` targets the
display rather than redirected stdout, and a screenshot needs a frame the idle
guest never renders. `ExitError` now writes `error.log` first — but note that
only catches explicit `ExitError` calls. An untrapped runtime error terminates
directly and prints to **stdout**, so always capture `> run.out` too.

- DOS command lines cap at 127 chars. `LINK` past that loses the trailing `;`
  that suppresses its prompts and blocks on input with an empty log; `LIB`'s
  `&` continuation misparses in a response file. Use response files for LINK,
  one invocation per module for LIB.
- `LIB`'s `-+` replace does not match µGL's lowercase module names. Delete
  (`-name`) then add (`+NAME.OBJ`) as two steps.
- The built exe's mtime comes from the DOS guest's clock. `make` stamps it
  afterwards or its bookkeeping goes wrong in whichever direction the skew runs.

## Method

**Linking clean proves nothing** for a `COMMON SHARED` change — binding errors
are runtime failures. Every module cut needs a *run*.

**When something looks broken, A/B against the last known-good build under the
identical harness before diagnosing.** Four separate times a harness artifact
was mistaken for a code fault here. The A/B settles it in one cycle; reasoning
about each anomaly in isolation cost about a dozen.

**Measure, do not infer.** "Ran for 150s" read off a background task hitting
its timeout was wrong; sampling CPU showed it exited in under 30.

Two techniques that paid for themselves:

- **Step logging.** Insert a `dbgMark "name"` before each step of a long
  routine, writing to a file with open/close each time so it survives a
  non-returning error. Located the `texiCount` subscript bug in two runs.
- **Control builds.** Compile the pre-change version alongside and compare
  error counts. Separated 3 pre-existing defects from 14 introduced ones in a
  single pass.
- **Offline analysis.** Parsing the BSP in Python to check lump counts,
  texture sizes and per-face UV ranges answers questions in seconds that cost
  minutes per emulator round trip.

## Open

- **`sound.enabled = true` hangs at init** — spins with interrupts off before
  any video mode change, so the screen sits at `C:\>` while the title bar says
  the program is running. Not root-caused. `data/stuff.ini` still ships `true`.
- **The texture module split is unfinished.** `texLoadOffsets`,
  `palLoadColormap` and `texLoadAll` against a five-variable interface. It
  builds, links, passes the allocation and declare audits, then exits inside
  30s — before the ~90s texture conversion would finish, and *without printing
  anything*, which rules out both `ExitError` and an untrapped runtime error.
  Confirmed a real regression by A/B, not a harness artifact.
