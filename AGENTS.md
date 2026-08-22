# Notes for working on this

Hard-won things, mostly the kind that cost an hour before they cost a minute.

## Layout

    src/main.bas      host_init / host_main / host_shutdown   (Quake host.c)
    src/sys.bas       command line, stuff.ini, sys_error       (Quake sys_*.c)
    src/model.bas     mod_load_* lump readers                  (Quake model.c)
    src/mod_tex.bas   texture headers, preprocessed bitmaps
    src/r_bsp.bas     traversal + visibility                   (Quake r_bsp.c)
    src/d_poly.bas    the rasteriser                           (Quake d_*.c)
    src/view.bas      where the camera is and looks            (Quake view.c)
    src/in_main.bas   keyboard, mouse, the toggles             (Quake in_*.c)
    src/snd.bas       sound device and loading music           (Quake snd_*.c)
    src/screen.bas    overlay, font, screenshot        (Quake draw.c/screen.c)
    src/vid.bas       video mode, back buffer, present         (Quake vid_*.c)
    src/common.bas    tokeniser + config                       (Quake common.c)
    src/bspfile.bi    on-disk structures + cross-module DECLAREs (Quake bspfile.h)
    src/q_*.bi        one COMMON block per subsystem           (Quake quakedef.h)
    attic/            superseded rewrite, out of the build

Every module holds exactly one subsystem, which the prefixes make checkable:
list the routines in a file and their prefixes should collapse to one.
`screen.bas` is the single exception, holding `draw_` and `scr_`, which is
what Quake does too.

Quake uses both conventions and so does this: prefixed families for subsystems
(`r_`, `d_`, and in Quake also `cl_`, `sv_`, `snd_`, `in_`, `vid_`, `sys_`),
bare names for standalone units (`model.c`, `common.c`, `screen.c`, `host.c`).

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

## Splitting a module

Six cuts took `main.bas` from 2918 lines to 979. Two of them failed first, both
for the same reason, and the failure mode is nasty: **builds clean, links
clean, then the program exits in about 25 seconds with empty stdout and no
`error.log`.** An unallocated array faults before the BASIC runtime can print
anything.

Run these four checks before building. They are cheap and each one has caught
a real bug:

1. **Every `COMMON` array is allocated somewhere.** `COMMON SHARED` can only
   declare `name()`, so an array with a real bound in its `DIM` loses it.
   Caught `hTextrDC( 256*4 )`.
2. **Every non-main module-level array under `'$DYNAMIC` is `REDIM`med.**
   See the rule below. Caught `texoffs( 256 )` and `hFontChar(255)`; still
   flags `clpBuffer` as latent.
3. **Every cross-module call has a `DECLARE` in `bspfile.bi`**, in both
   directions. Within one module BASIC auto-declares its own `SUB`s; across a
   boundary it does not. Caught `drwLoadingBar`.
4. **Each module includes `bspfile.bi` and each `q_*.bi` exactly once.** Two
   identical `COMMON` blocks is "Duplicate definition" on every line. Caught a
   copied include list.
5. **Never name a variable after a BASIC intrinsic.** `rnd` for the render
   state failed with "Simple or array variable expected" -- `RND` is the
   random-number function. `timer`, `screen`, `date`, `time`, `error` are the
   same trap.
6. **Every `COMMON` variable's type is defined by an include that precedes
   `q_*.bi`, not one that follows it.** BC reads includes in file order,
   so a type declared in a `.bi` included *after* `q_*.bi` does not exist
   yet when the `COMMON` line naming it is parsed — "TYPE not defined". Because
   the include order is identical in every module, this fails the same way in
   all of them at once, which is a useful tell that it's this and not a
   per-module mistake. Caught `mymod as UGMMOD`, where `q_*.bi` came
   before `mod.bi` (which defines `UGMMOD`) in the include list of all ten
   modules. Fixed by moving `mod.bi` earlier everywhere, not by moving the
   `COMMON` line — `q_*.bi` has to stay includable from anywhere.

Then split on **data ownership**, not on which routines feel related. Measure
which variables each candidate group uses exclusively — the rasteriser touches
47 shared variables but owns 15, and all 15 are the per-vertex scratch that
must stay `'$STATIC`.

Make the extractor **assert when a routine it was told to move has no
definition**, rather than skipping quietly. That is how four dead declarations
turned up in `bspfile.bi` — `ClipBBoxToFrustum`, `ClipToPlane`,
`fontPrintChar`, and `ugluBMPSave`, which was declared *and called* but never
existed anywhere and had kept the program from linking at all.

## BASIC / VBDOS

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

**A module-level `DIM` under `'$DYNAMIC` never executes outside the main
module.** It is an *executable statement*, and module-level code only runs in
the main module — anywhere else the array is simply never allocated, and the
first write faults hard enough that the runtime never prints anything. The
program just vanishes: exits in seconds, empty stdout, no `error.log`.

Non-main modules must declare their arrays under `'$STATIC`, or guarantee
something `REDIM`s them at runtime (a `REDIM` does allocate). This bit twice:
`hFontChar(255)` in `screen.bas` and almost certainly `texoffs( 256 )` in the
abandoned texture cut. `model.bas` survives the same shape only by accident —
`txcBuffer` is `REDIM`med, and `clpBuffer` is read solely through
`len( clpBuffer(0) )`, which the compiler folds for a fixed-size UDT.

Together with the rule above it, that is the pair to watch when moving code
between modules: **storage that silently stops existing.** Both link cleanly
and fail at run time.

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

**`on errror goto HandleErr`** (three r's) was *not* a syntax error: BASIC also
has a computed `ON n GOTO`, so it parsed as "branch to the zeroth label" and
fell through. Runtime error trapping had never worked, and it was left that
way deliberately — fixing the spelling would have routed every error to a
generic message, worse than the runtime's specific one.

**`OPTION EXPLICIT` changed the calculus and the typo is now fixed.** The same
three-r typo that was a harmless no-op under implicit declaration became a
*hard compile error* once every module required `errror` to be declared —
`ON n GOTO` needs `n` to be a real variable. Rather than declare a dummy
`errror` just to keep the bug alive, it is now `on error goto HandleErr`,
which finally does what it always looked like it did.

**MASM logical-line limit is 512 chars** including continuations. Expanding
tabs to spaces in µGL's asm pushed a `local` block over it.

**Python's `open(f,'wb')` truncates before the write runs.** A `TypeError` on
the following line leaves the file at zero bytes. This emptied `main.bas`
during a rename; recovered from git. Read bytes, transform, write bytes — and
never open for writing until the new content exists.

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

## Harness: benchmark mode

    qrender.exe dm3ish.bsp -bench 500

Renders a fixed number of frames, writes `bench.bmp` and `bench.txt`
(frames/seconds/lastfps/polys/tris), and exits. Headless, no debugger socket,
~33s end to end. Use it instead of CPU sampling.

Baseline, dm3ish, 320x200, stats on, mips on, perspective:

| build            | wall (500f) | doInit | per frame |
|------------------|-------------|--------|-----------|
| runtime resample | 33s         | ~18s   | 35ms      |
| preprocessed     | 21s         | 0.11s  | 35ms      |

`-bench` writes `load.txt` with a per-phase breakdown of `doInit`. On the
preprocessed build every phase rounds to 0.05s or less; the whole of load is
about a tenth of a second.

**Do not read "wall minus render" as load.** Three runs separate the fixed
cost from the per-frame cost:

| bench | wall  |
|-------|-------|
| 20    | 4.0s  |
| 200   | 10.3s |
| 500   | 20.8s |

That is 35ms a frame and **3.3s of fixed overhead**, only 0.11s of which is
the program's own startup. The rest is DOSBox booting and `ugluBMPSave`
writing 65,000 bytes one at a time at the end of the run. Attributing that
residual to "load" is what made the bsp lumps look like the next bottleneck
when they were already about 0.4s of a 0.5s load.

**CPU sampling proves a process is busy, not that it renders.** Several runs
were reported as verified on the strength of "92% CPU sustained" when the
program had never left the DOS prompt. Only a frame count or a picture is
evidence.

**Every screenshot of the first frame is byte-identical** -- fixed spawn, no
animation, `mousePos` forced. Seven consecutive verification screenshots had
the same md5. An identical picture cannot distinguish a working build from one
that never rebuilt; the fps and frame count in `bench.txt` can.

**`make build` copies `data/stuff.ini` over `build/vbd/stuff.ini`.** Editing
the build copy does not survive a rebuild. This is how `sound.enabled = true`
kept coming back and re-arming the init hang, after the setting had apparently
been disabled -- and the symptom (title bar shows QRENDER, screen still at
`C:\>`) was misread three times as a config or command-line fault. The source
file now ships `false`.

**`defint a-z` is inert once every declaration is explicit**, and 65 of them
were. Proof rather than argument: removing all 65 produced a byte-identical
EXE. It only ever typed undeclared names, which `OPTION EXPLICIT` forbids,
and sigil-less function returns, of which there were none.

**VBDOS accepts `FUNCTION name (args) AS type`**, so the classic `%`/`$`
return sigils are not required. QB 4.5 does not, which is why the original
used them.

**`COMMAND$` uppercases the whole command line.** Flag comparisons must fold
case; `-bench` arrives as `-BENCH`.

## Player physics

`pl_move.bas`, ported from softquake's `bsp_trace.c` and `pl_move.c`, which
are Quake's `SV_RecursiveHullCheck` and `SV_FlyMove`.

**The hulls are pre-expanded.** The clipnodes lump is a second set of bsp trees
over the same planes, each grown by a bounding box, so the player is traced as
a *point* through hull 1 rather than as a box through the world. That is why
collision needs no box maths at all.

**Two coordinate spaces meet here, and only here.** The renderer is Y-up; the
bsp is Z-up. `mod_find_spawn` already swaps when it reads the spawn origin.
`pl.pos` is Z-up and authoritative, and the last three lines of `pl_move`
convert it back for `cam.pos`. Do not do the swap anywhere else.

**`-walk` holds forward** so the collision response can be tested headlessly.
From the dm3ish spawn, 200 frames of it should travel ~400 units, drift
sideways where it meets a wall, and descend to a floor with `onground` true
and `vz` zero. A run that ends with x and y unchanged means the trace is
reporting solid everywhere; one that ends with a huge negative z means it fell
through the world.

**The simulation runs at a fixed 60 Hz, whatever the renderer manages.**
`host_advance` takes the frame's real elapsed time, adds it to an accumulator,
and spends it in whole `HOST_DT` steps, carrying the remainder. So a frame runs
one step, or two, or none -- but every step is the same length.

That is what makes it deterministic rather than merely framerate-independent.
Time-based updates alone still integrate a walk in a few long steps at 12 fps
and many short ones at 45, and the two drift apart, because a long step
overshoots a wall a short one stops against. `-ticks N` stops after N
simulation steps rather than N frames, which is the test:

    44 fps  220 frames  301 ticks   209.348   -287.9687  184.0313
    12 fps   64 frames  300 ticks   209.4243  -287.9687  184.0313
     4 fps   61 frames  300 ticks   209.4243  -287.9687  184.0313

The 12 and 4 fps runs agree to every digit across an 11x spread. The 44 fps
run differs in x alone because it ran one extra tick, worth about 0.08 units.

**`HOST_MAXSTEPS` caps the steps one frame may run**, or a frame slower than
`HOST_DT` asks for more steps, which make the next frame slower still, and the
accumulator runs away. At the cap the game runs in slow motion, which is
survivable; without it, it stops.

**The frame is `host_tick` then `host_render`.** One changes the world and
draws nothing; the other draws and changes nothing. `host_tick` takes dt as a
parameter rather than reading `scr.frame_time`, so a caller can hand it a
different step -- a fixed one, or a halved one for a sub-tick -- without the
routine knowing.

**Time, not frames.** Everything that moves multiplies by `scr.frame_time`,
measured once at the top of the frame by `sys_frame_time`. Nothing may advance
by a per-frame constant -- noclip flew at 3 units a frame for years, which
means it flew at whatever speed the framerate happened to give it.

**The frame clock calibrates itself, and has to.** Asking uGL for a 1 kHz
timer and dividing the counter by 1000 gave a dt seven times too small: the
physics was frame-rate independent but ran in slow motion, every speed in the
game being units per seven seconds. What the timer actually delivers is about
144 Hz, and that is a property of uGL and the emulator underneath it, not
something to hardcode. `sys_time_init` measures it against DOS's own TIMER.

That measurement aligns both ends of its window to a TIMER edge, because
TIMER only ticks every 55ms: without the alignment the same binary measured
142.9 Hz on one run and 148.1 on the next, and the game ran 4% faster on one
of them. Aligned, three runs give 144.0, 145.5, 144.0.

**`-jump` holds jump, `-walk` holds forward**, and `peakz` records the highest
point reached, so a jump is provable from a headless run: from the dm3ish
spawn it should peak about 46 units above the resting height, which is
`v^2/2g` for Quake's 270 up and 800 down.

**A resting z always ends in .03125.** That is `PL_CLIP_EPS`, the distance the
trace stops short of a surface. Seeing it is how you know a landing is a real
trace stop rather than a coincidence.

## Assets

    make assets          # or: python3 tools/mkassets.py <map.bsp> <base.dat> data/assets

Emits one 8-bit BMP per texture per mip level, `t<idx>m<lvl>.bmp`, already
resampled to the fixed size the renderer wants and already in the game
palette. `texLoadAll` hands each straight to `uglNewBMPEx`; the Makefile
regenerates them when the map, `base.dat`, or the tool changes.

Three things this has to get right, all found the hard way:

**Apply colormap row 0 on the way in.** The original read every miptex byte as
`colmap[byte]`, not as a palette index. In this data set row 0 is nowhere near
the identity -- 221 of 256 entries differ -- so skipping it shifts nearly every
texel. Frame comparison against the old path caught it: 0% identical before,
99.2% after.

**`BMPOPT.NO332` on the load.** Without it uGL remaps the image into its own
3-3-2 palette and destroys indices that are already correct.

**`uglBlit` does not exist in the VBD library.** It is declared in `ugl.bi`,
which is why an atlas-per-mip design compiled; LINK resolved the call to an
`int 3` and the program died on the first blit. `uglNewBMPEx`, `uglPutBMP`,
`uglPut` are all present. Check a symbol is really in `uglv.lib` before
building on it -- `ugluBMPSave` was the same trap earlier in this project.

**LINK emits an EXE even with an unresolved external**, so the harness's
"did an exe appear" test reported PASS for a build that could not run.
`tools/dosbox.sh` now greps `link.out` and reports LINKERR.

**Names beginning with `FN` are reserved** for `DEF FN` user functions. `dim
fname as string` fails with "Simple or array variable expected", and the use
sites report "FUNCTION not defined".

## Shared state

`q_*.bi` groups the cross-module scalars into one struct per subsystem
rather than leaving them loose, so a use site says which subsystem it is
reading:

    env   EnvType      configuration, from stuff.ini and the command line
    wld   MapState     the map: header, file handle, lump counts
    ldr   LoadState    loading-screen percentage and DC
    vis   VisState     frameStamp, ordCount
    rdr   RenderState  cull/mip/mode toggles and the per-frame counters
    cam   CamState     eye, lookAt, spawn yaw, view mode, script handle
    scr   ScreenState  fps, stats toggle, benchmark seconds

Member offsets are compile-time constants, so this is free even in
`bspDrawFaces` -- measured, no change in frames/seconds/fps.

`pal` and `mymod` stay loose: a struct of one member is ceremony.

**Named COMMON blocks, one per subsystem, in one header each.**
`COMMON SHARED /map_s/ ...` is the FORTRAN style QuickBASIC inherited: each
named block is shared independently, so a module declares only the blocks it
uses. Blank `COMMON` cannot do that -- it requires every module to declare the
same variables in the same order.

That is only worth anything if the headers are split, which is the point:

    q_env.bi    env                       8/10 modules
    q_map.bi    wld ldr + the 12 arrays   6/10
    q_vis.bi    vis bitarray frustum      5/10
    q_draw.bi   rdr + texture handles     6/10
    q_scr.bi    scr                       4/10
    q_cam.bi    cam                       5/10
    q_snd.bi    mymod pal                 4/10

38 block declarations instead of the 70 a single shared header forces.
`common.bas` parses stuff.ini and now sees `env` alone, where before it saw
every map array and the frustum. Add a block to a module only when that module
genuinely needs it.

**Arrays cannot go in a TYPE**, so the twelve `COMMON` arrays stay loose. That
is a language limit, not an oversight.

**Renaming needs a lexer, not a regex.** A plain word-boundary substitution
rewrote HUD text (`"Renderd rnd.polys:"`) and the `bench.txt` keys, because it
matched inside string literals and comments. `/tmp/qbrename.py` splits each
line into code and non-code first. It also folds case: BASIC does not
distinguish `camLookAt` from `CamLookAt`, and a case-sensitive pass left half
the sites behind and the build broken.

**Regress against the in-program counters, not wall clock.** Repeated runs of
the same binary spanned 9.4s to 11.7s; `frames`/`seconds`/`lastfps` were
identical every time.

## What was deliberately not done

**The ini parser is not table-driven.** It was on the plan as the one place
OCP is reachable in a language without function pointers, and on inspection it
is not worth it. A key-to-index table still needs a `SELECT CASE idx` to
perform the assignment, which is the same branch count split across two
places -- worse, not better. The version that genuinely generalises (parse
into a value array, apply in one block) is a rewrite of a 150-line cold-path
routine for thirteen keys that change about once a decade.

What was worth taking out of it was the duplication: three keys each spelled
their own two-branch yes/no test, and each had the same hole.

## Method

**Linking clean proves nothing** for a `COMMON SHARED` change — binding errors
are runtime failures. Every module cut needs a *run*.

**When something looks broken, A/B against the last known-good build under the
identical harness before diagnosing.** Four separate times a harness artifact
was mistaken for a code fault here. The A/B settles it in one cycle; reasoning
about each anomaly in isolation cost about a dozen.

**A real bug fixed with no change in symptom means the wrong cause, not a
doomed approach.** The texture cut took three attempts. On the first I found
`hTextrDC` losing its bound to `COMMON`, fixed it correctly, saw no
improvement, and concluded the cut was hopeless — when the evidence actually
said there was a second, different fault. It only became findable when
`screen.bas` failed identically and gave a second data point to triangulate
from. Two failures with one signature are worth more than one failure studied
twice.

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

- **`sound.enabled = true` hangs at init.** Root cause still unknown; the
  setting now ships disabled so the hang cannot be armed by accident.
- ~~`clpBuffer` in `model.bas`~~ hardened to `'$STATIC`.
- ~~Remaining cuts~~ done — `main.bas` is 427 lines: `doInit`, `doMain`,
  `doEnd`, `ExitError`. All ten modules carry `OPTION EXPLICIT`.
