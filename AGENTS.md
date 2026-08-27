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

**Look at the screen before theorising.** When a headless run does not
return, take a screenshot or read the text console *first*. The picture says
in one glance what a timeout cannot say at all: whether the program reached
the loading screen, which load stage it stopped on, whether it is showing an
error, or whether it rendered a frame and then stopped. Everything below
about failed-vs-slow is downstream of that one check, and skipping it has
repeatedly cost hours here — most recently a first-frame hang that was
diagnosed in seconds from a single screenshot of the loading bar sitting on
its last stage, after a long detour through timeouts, load averages and
blaming a concurrent session for contention.

Note the loading screen stays up until the first frame is presented, so
"frozen on the last load stage" means the first FRAME hung, not the loader.

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

## Rebuilding uGL

`tools/mglbuild.sh uglplxtg` rebuilds a module and swaps it into `uglv.lib`;
`--all` does all 151, `--list` prints the module-to-directory map it reads out
of the `.mk` ASMLIST declarations.

- **The shipped `uglv.lib` is stale against `src/`.** `uglTriTG`, `uglTriTPG`,
  `uglSetLUT` and `uglBlit` are all in the sources and in the module lists, and
  in none of the built libraries. A missing symbol means the library is old,
  not that the feature was never written -- the texture atlas design was
  abandoned on exactly the opposite assumption about `uglBlit`.
- **There is no dmake here.** mgl's makefiles are dmake's dialect (`.IF`, `:=`,
  `{list}.obj`, `$(mktmp ...)`); NMAKE and Borland MAKE cannot parse it and
  neither the toolchains nor mgl ship it. The recipes it would run are two
  commands, which is what the script issues.
- **The script updates the library module by module rather than rebuilding it**,
  which leaves the three C sub-libraries -- music, xsnd, snddrv, built with
  Borland `bcc` -- alone, so MASM is the only toolchain involved. The shipped
  library is preserved as `uglv.lib.orig`.
- **`ml` has no `/omf`** (MASM 6.11), and an invalid option aborts parsing of
  every option after it. `/omf /D__CMP__=VBD` therefore assembles with
  `__CMP__` undefined, and the error surfaces inside `lang.inc`, nowhere near
  the cause.
- `lib16` blocks on a prompt without a trailing `;`, the same as LINK.

## Build directories: never share one

**Always point a build at a path unique to your worktree/session.** More
than one agent works in these trees at once, and every library rule is

    rm -f X.LIB && jwlib X.LIB +objs...

so two processes building the same `BUILD` produce a library that is
missing whatever the other was mid-write on. It does NOT fail as a build
error. It surfaces later as

    error L2029: 'SOMESYMBOL' : unresolved external

naming a DIFFERENT module each time -- `uglarr`, then `emsmapex`, then
`uglz`. And because LINK still emits an EXE with `int 3` at the
unresolved call site, a test then "compiles clean and prints nothing",
which reads like a hang in the code under test. Hours went into that.

Three knobs, all defaulting to the old shared paths so nothing breaks:

    BUILD=$PWD/build/native-mgl-<tag>     uGL libraries (tools/native/Makefile)
    VBD_OUT=$PWD/build/vbd-<tag>          renderer objs, BENCH.BMP, bench.txt
    BUILD_TAG=<tag>                       mgl test dirs (src/test/runtest.sh)

`BUILD_TAG` defaults to a hash of `(mgl checkout, UGLLIB path)`, so a
unique `BUILD` gives unique test directories for free. Pick a tag once
per session and keep using it -- a tag containing `$$` changes every
command and forces a full rebuild each time.

`VBD_OUT` matters for a subtler reason: `check.sh` compares `BENCH.BMP`
against the reference and reads ticks from `bench.txt`. Two runs sharing
that directory can have the picture from one run and the timing from the
other, and the comparison still "passes".

## Building and testing in parallel

Both parallelise well once the output trees are separate:

    make -f tools/native/Makefile -j8 BUILD="$BUILD"     # ~11s from clean
    UGLLIB="$BUILD/UGLV.LIB" JOBS=8 src/test/runall.sh   # ~7s, 12 tests

`-j8` is safe: `UGLV.LIB` depends on the component libraries and each of
those on its objects, so make orders them. The unsafe thing is two
separate `make` PROCESSES, not one parallel make.

Tests parallelise because each gets its own `build/test/<tag>/<name>` and
only reads the shared library. `JOBS` defaults to half the cores -- every
test is a DOSBox at `cycles=max`, so oversubscribing makes each slower
rather than the set faster.

**Use the dynamic core.** `runtest.sh` and `runall.sh` default to
`CORE=dynamic`; `uarrtst` runs in ~2s under it against ~10min on
`core=normal`. Anything reporting TIMINGS must set `CORE=normal`
explicitly, because the recompiler throws away translations when mgl
patches immediates into its own inner loops.

## Drive DOSBox hands-on, do not wait on files

**Watch the emulator while it runs. Do not start a run and wait for a text
file to appear.** Waiting blind cost most of an afternoon here: three
separate "it is hung" conclusions were all a run that simply had not
finished, and a "control" that had died at load with `runtime error 53`
was read as evidence for an hour because nobody looked at the screen.

The MCP DOSBox tools attach to a conf that has a debugger section --
`tools/dosbox.sh viz <map>` emits one:

    tools/dosbox.sh viz dm3ish.bsp        # prints the conf path
    dosbox_launch { conf, headless: true }
    dosbox_screenshot { path }            # then Read the png
    dosbox_text_screen                    # text mode
    dosbox_regs                           # is it executing, or spinning?

What each answers, in seconds rather than minutes:

- **screenshot** -- is the picture right, and is the overlay advancing?
  Two identical captures a few seconds apart mean one frame is taking
  longer than that, NOT that it is stuck. Space them out before deciding.
- **regs** -- sampled twice, do CS:EIP move? Moving means slow, not hung.
  `ES` near the EMS frame (0xE000 + slot*0x400) says it is in a window.

**EVERY inspection FREEZES the CPU and does not resume it.** `dosbox_regs`,
`dosbox_where` and `dosbox_screenshot` all leave `cpuRunning: false,
debuggerFrozen: true` -- check with `dosbox_status`. Resume with
`dosbox_continue` (it will time out waiting for a stop that never comes;
that is fine, the CPU is running again). Forgetting this makes the
emulator look stalled BECAUSE YOU STALLED IT, and any wall-clock number
taken across an inspection is worthless. Sample for WHERE it is, never
for HOW LONG it took.
- **RUN.OUT / ERROR.LOG / ERRMEM.TXT** -- read these FIRST when a run
  produces nothing. An empty RUN.OUT with an ERROR.LOG beside it is a
  runtime error, not a hang.

## Benchmarking a change to the frontend

**Use `-nodraw`.** It runs the BSP walk, PVS and visibility and skips
rasterising. A change to the walk -- paging the node tree, reordering the
recursion -- moves the frontend and not the fill, and a full-frame timing
buries it: fill dominates, so a large regression in the walk shows up as
a small one overall and a small one is invisible.

**But check it is not measuring the clock.** On dm3ish the frontend is
faster than the timer resolves, so `-nodraw` returns the tick floor and
not the code: three different builds all reported

    ftmean 9.97680673249007   frames 1908

identical to eight decimals. Identical-to-many-decimals across builds
that differ is the tell, and 9.9768ms is 1/100.23s -- the tick, not the
work. `-nodraw` measures the frontend only on a map where the frontend
is slow enough to see; on a small one it measures `tickhz`. Confirm the
number moves when you deliberately make the walk slower before trusting
it to show that you made it faster.

**Always use the dynamic core.** It is the default everywhere and there
is no case for turning it off.

`dosbox/template.conf` pins the machine and every mode inherits it:

    core=dynamic
    cycles=75000
    priority=higher,normal        # [sdl]

These are THE settings. They are not tuning knobs -- a before/after is a
measurement only if both sides ran on the same emulated machine, and
`cycles=max` makes that machine vary with host load. CYCLES/CORE can
override, but only with a reason you can state, and never on one side of
a comparison.

Speed here is not a luxury: a run you can watch finish is a run you will
actually watch, and every wrong "it is hung" call today came from a
five-to-fifteen minute round trip on the interpreter.

**Pin the emulated CPU on BOTH sides of a comparison.**

`cycles=max` scales with whatever else the host is doing, so two runs of
the SAME build differ. Every mode inherits `dosbox/template.conf`'s
75000/dynamic for exactly this reason -- override both sides or neither.

A before/after is only a measurement if the map, the flags, the cycles,
the core AND the linked `UGLV.LIB` all match. Rebuilding uGL mid-session
silently makes the two sides different programs; `cmp` the two staged
`UGLV.LIB`s before quoting a number. State them when quoting one.

### One run per side is not a measurement

`ftmean` over a campath run has a run-to-run spread of about **2.3 ms**
-- wider than most changes worth arguing about. It is also quantised:
the same handful of values recur across unrelated builds, so two runs
agreeing to ten decimals means the metric is coarse, not that the builds
are identical.

**Six runs per arm, interleaved A/B/A/B, and compare medians.** Not six
of one then six of the other: the host drifts, and a block design loads
that drift onto whichever arm ran second.

Build the other side in a worktree so both trees stay intact, and point
both at the SAME library:

    git worktree add -q --detach /tmp/base <commit>
    cp -r data/assets /tmp/base/data/
    NATIVE_UGL=$PWD/build/native-mgl/UGLV.LIB \
      VBD_OUT=/tmp/base/build/o /tmp/base/tools/dosbox.sh build
    cp build/vbd-x/campath.bin /tmp/base/build/o/

    for r in 1 2 3 4 5 6; do
      for a in "base:/tmp/base:/tmp/base/build/o" "head:$PWD:$PWD/build/vbd-x"; do
        IFS=: read t rt out <<< "$a"
        NATIVE_UGL=$PWD/build/native-mgl/UGLV.LIB VBD_OUT=$out \
          QFLAGS="-lm -campath" $rt/tools/dosbox.sh run > /dev/null 2>&1
        echo "$t $(grep '^ftmean ' $out/bench.txt | cut -d' ' -f2)"
      done
    done

`git worktree remove --force` each one afterwards.

Three per arm is not enough. A 3v3 here produced a clean-looking +1.95ms
with no overlap between the arms, which did not survive n=6 -- the
medians then differed by 0.04ms. The confirming test is cheap and worth
running whenever a delta looks real: **bench the baseline against
itself**, perturbed only in layout -- add a never-called sub of about
the same code size to the module that grew, and rebuild. If the control
reproduces the "regression", the effect is not in your change. It did.

Before believing any delta, check what actually changed in the hot path:

    grep -E ' (D_POLY|D_SURF|SCREEN|PL_MOVE)_CODE' build/<dir>/QRENDER.MAP

Byte-identical segment sizes for the per-frame code mean no per-frame
work was added, whatever the timings say.

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

**`bench.bmp` is the LAST frame, and since liquids animate that is no longer
deterministic.** `-bench N` alone runs N frames of wall time, so `animtime`
lands wherever the host's speed puts it -- three runs of one unchanged binary
gave md5 8ff755af, 3ee2547c, 8ff755af, tracking animtime 5.933297 / 5.749966 /
5.933297. A changed md5 after a library swap means nothing on its own; it cost
a false alarm here.

**Add `-ticks N` for a comparable frame.** The fixed timestep drives
`anim_time`, so a tick-bounded run pins it: `-bench 400 -ticks 120` gave
animtime 1.999995 and one md5 across three runs at 69, 68 and 68 frames. Every
A/B in this file that compares images uses `-ticks`.

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

**Controls.** W/S forward and back, A/D strafe left and right, mouse looks,
mouse buttons also walk. Space jumps. F1 mips, F2 render mode, F3 birdseye,
F4 noclip, F5 screenshot, F12 stats, B backface culling.

Screenshot is F5 because S walks backwards. That is the only binding WASD
displaced.

**`-at X Y Z`, `-yaw D` and `-nostats` aim a headless run at a thing and get
the overlay out of the picture**, which is what makes a rendering bug
photographable without a keyboard. `-yaw` is mirrored relative to the map's
angle key: aim with `atan2(-dy, dx)`.

**`-jump` holds jump, `-walk` holds forward, `-strafe` holds strafe**, and `peakz` records the highest
point reached, so a jump is provable from a headless run: from the dm3ish
spawn it should peak about 46 units above the resting height, which is
`v^2/2g` for Quake's 270 up and 800 down.

**Water and lava live in hull 0, not the collision hulls.** The clipnodes are
built for a box to move through and carry only EMPTY and SOLID -- on dm3ish,
579 EMPTY and 1077 SOLID children and not one WATER. `pl_point_contents` walks
the render tree instead and reads the leaf's contents, which is why `leaf2`
keeps its `cont` field: an earlier version of the lump conversion dropped it as
unused, and it had to come back for this.

`pl_water_level` samples three heights up the body -- feet, waist, eyes -- for
0..3, which is what makes wading feel different from swimming.

**Quake encodes what a texture does in its name.** A leading `*` is a liquid,
a leading `+N` is one frame of an animation whose other frames share the name
after the digit. `mod_load_textures` classifies them and `mod_link_anims`
groups the chains; `d_draw_faces` applies both once per face, not per vertex.

A liquid is perturbed, not scrolled: each coordinate is displaced by a sine of
the *other* one, from a 256-entry table, which is what makes a surface roll
instead of slide. Quake's amplitude is 8 texels of 64 and its index is
`(other*0.125 + time) * 256/2pi`; ours works in normalised coordinates, so the
amplitude is 8/64 and the 0.125 absorbs the texture width.

**Those coordinates are normalised, not texels** -- `tw` and `th` are
reciprocals of the texture size. An earlier version scrolled by `time * 8`
there, believing it was texels, and moved the texture eight entire widths a
second: consecutive frames were uncorrelated, which looks like static and which
a two-frame diff reported as "no animation at all".

The perturbation is per vertex, which is as fine as this renderer goes. Quake
does it per span inside its own texture mapper, and uGL's mapper is not ours to
change.

dm3ish has two liquids and no `+N` textures at all, so the frame chains are
implemented and unexercised.

**Brush entities are submodels 1 upward.** `r_draw_world 0` draws the world;
`r_draw_brush_model` adds each other submodel to the same draw order without
resetting it, so entities sort against the world back to front rather than
being drawn over it.

Their leaves are not in the world's PVS -- that answers where the camera can
see from, and a lift is not part of it -- so `r_ignore_pvs` skips the
visibility test for them and lets the frustum decide alone.

A trigger volume is a submodel too, and must not be drawn: `mdl_draw` is false
for any submodel some `trigger_*` entity claims, or dm3ish hangs two slabs of
teleport texture in mid air.

~~Verified by A/B: looking at the func_plat, 176 polys with brush entities
against 170 without, and 10% of the frame's pixels different.~~ **Withdrawn.**
That A/B was taken from (-80, 700, 100), which is leaf 0, contents SOLID. It
measured nothing. See the note below on viewpoints.

**Ordering brush entities correctly without a depth buffer is not possible in
general, and it is worth knowing why before trying.** A BSP back-to-front walk
is not an approximation -- it is exact, and that is the theorem the tree exists
for (Fuchs, Kedem, Naylor 1980): every polygon lies on a plane in the tree, so
the traversal is a total depth order valid from any camera. That exactness
holds for **one** tree. A brush entity is a second, independent, moving tree,
and two trees admit no exact whole-object ordering: they can overlap
cyclically, and even without a cycle an entity straddling a world plane has
world faces both in front of part of it and behind another part.

The exact answers are (a) split the entity's polygons against world planes so
every fragment lands in one leaf -- which this pipeline cannot express, since
it addresses faces by index out of the face buffers and a fragment has no
index -- or (b) what Quake actually did, which is not to sort at all: the
software renderer builds a global edge list and resolves depth per span with
1/z (`R_DrawSurfaces`, `surf->key`). Quake never needed a whole-object order.
Do not cite Quake as precedent for a painter's algorithm; it is not one.

**What is here is (c): insert the whole entity at the right node.** It is an
approximation, and correct exactly when the entity does not straddle a plane
separating world geometry in front of it from world geometry behind it -- a
door in a doorway, a lift in a shaft. Say so rather than claiming the bug is
fixed.

`ent_find_node` descends the world tree with the entity's box and stops at the
deepest plane the box does not straddle; `r_emit_entities` draws it there,
between the far subtree and that node's own faces.

Three placements were tried, and the two failures are the instructive part.
The leaf holding the entity's *centre* is often solid -- a lowered lift sits
inside its own shaft -- and a solid leaf is never walked, so the entity
vanished. The **first visible leaf its box overlaps** was not merely
approximate but backwards: the walk reaches leaves far-to-near, so "first"
means "furthest", and everything the entity should hide is drawn after it.

**A viewpoint inside solid geometry makes every measurement from it
meaningless.** An A/B that seemed to prove entity rendering worked was taken
from a camera in leaf 0, contents SOLID. `ent_point_leaf` will tell you: leaf
contents -2 means the camera is in a wall, and the PVS from there answers
nothing.

**`-noents` is the reference image, and the only objective test here.** From a
viewpoint where the world fully occludes an entity, a correct renderer must
produce a frame *identical* to one drawn with no entities at all. That turns
"does it still overdraw" into a number instead of a squint. Generate the
viewpoints by walking the leaves in Python, keeping those whose centre has a
line to the entity that passes through SOLID, and sweep them.

**Occlusion means every point of the entity is hidden, not its centre.** The
first version of this test traced one ray, to the box centre, and called that
occluded. It let partly-visible entities count as failures and produced a
confident 0-versus-8 that measured nothing. The tell was that the two orderings
failed on nearly disjoint viewpoint sets -- 16 one way, 14 the other, 1 both.
Two orderings that disagree that way are not better and worse, they are drawing
a visible thing at two different depths. Sample the box on a 3x3x3 grid and
require every point blocked, and trace in 2-unit steps: at 1/200th of a 900-unit
range the step is 4.5 units and walks straight through a thin wall.

**Aim it at something that draws.** dm3ish has three submodels and only one of
them renders: `*3`, the func_plat. `*1` and `*2` are `trigger_teleport` volumes
that `mdl_draw` deliberately suppresses. Viewpoints aimed at those can never
leak either way, so they pad both counts with free passes -- which is what made
an early sweep read 0-versus-8 rather than 0-versus-19.

Aimed at the lift alone, 50 viewpoints where all 27 of its box samples are
hidden: **0 leaks with insertion-node ordering, 49 with `-badorder`.** Frame
rate is unchanged at 33-34 on the spawn bench, which needed `vis.ent_left` -- a
SUB call at every one of a few hundred visited nodes cost about 3%, an integer
compare costs nothing.

**The A/B that shows ordering is `-badorder`.** It puts brush entities back
after the world walk from the same build, so one binary renders both. Pair it
with `-at X Y Z`, `-yaw D` and `-nostats`; `-yaw` is the map's angle
convention mirrored -- the freelook math makes the eye direction
`(cos a, -sin a)` in bsp x,y, so aim with `atan2(-dy, dx)`, not `atan2(dy, dx)`.

Most viewpoints render identically either way, because ordering only shows
where world geometry stands between the eye and the entity. The one that
shows it on dm3ish is (-608, -544, 176) yaw 265, looking at the door at
(-640, -192): 241 pixels of 64,000, a dark sliver of the door's edge bleeding
through the wall. Small, but it is the whole bug.

**A moving brush entity is traced by moving the line, not the hull.** Its tree
sits where the compiler put it, so subtracting `mdl_zofs` from both ends of a
sweep asks a stationary tree the same question that moving the tree would ask
of a stationary line. `pl_trace` walks the world's hull and then every solid
submodel's; `tr` keeps the earliest hit by itself, since `pl_hull_check` only
writes when it beats `tr.frac`. `all_solid` is the exception -- each walk sets
it -- so it is gathered by hand.

The renderer does the same offset in the other direction: one add per vertex,
`polyb.y = vz + zofs`, because renderer y is bsp z.

**A plat carries its rider upward only.** A descending one is left to drop away
under the player, which is what it looks like in Quake, and what avoids pushing
them through the floor of the shaft on the last step down.

**Teleporters are entities, not geometry.** A `trigger_teleport` has no
origin: it carries `"model" "*1"`, meaning submodel 1, whose bounding box is
already in `mdl_buffer`. Its `"target"` names an `info_teleport_destination`,
which has the origin and facing. `ent.bas` reads both and pairs them, in two
passes, because a trigger can name a destination that appears later in the
text.

**An entity value arrives already split.** The block is tokenised with space
among the separators, so `"origin" "448 416 176"` is four tokens and the
"value" of origin is just `448`. `ent_vec` reads three consecutive tokens;
`ent_value` reads one. Getting this wrong teleports the player to
(448, 0, 0) -- x right, the rest zero, which is exactly what it looked like.

**`-at X Y Z` starts the player somewhere specific**, which is how the water is
tested at all: dm3ish's pool is at x 336..688, y -336..256, z -128..-16, a long
walk from the spawn. Dropped in at (500, 0, -60) the player should report
water_level 3, water_type -3, on_ground 0, and sink to about -104 with vz back
at 0.

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
    q_map.bi    wld ldr /world/ /surf/    6/10
    q_vis.bi    vis bitarray frustum      5/10
    q_draw.bi   rdr + texture handles     6/10
    q_scr.bi    scr                       4/10
    q_cam.bi    cam                       5/10
    q_snd.bi    mymod pal                 4/10

38 block declarations instead of the 70 a single shared header forces.
`common.bas` parses stuff.ini and now sees `env` alone, where before it saw
every map array and the frustum. Add a block to a module only when that module
genuinely needs it.

**Arrays cannot go in a TYPE**, so the shared arrays stay loose. That is a
language limit, not an oversight.

### What is shared, and what is merely global

`/map_a/` held 42 variables and is gone. What replaced it:

    /world/   h_nds nds_buffer pln_buffer mdl_buffer
              r_bsp, ent, pl_move, d_poly -- the BSP itself

    /surf/    tri_buffer h_tri tex_inf_buff gv_buf poly_flag order_list
              d_poly, d_surf (+1 line in main) -- the rasteriser pipeline

Everything else moved into the one module that reads it. The rule that
decides which is possible is the **access shape**, not the size:

- **An EMS dc reached by `uglMapEx`** encapsulates cleanly -- the reader
  wants a mapped pointer, not the handle. `cm_map`, `lm_map`, `geom_map`,
  `pvs_base`, `z_on`, `sc_held`. The slot constant moves with the resource.
- **A MEM store bound to a BASIC array**, or a plain `REDIM` array, cannot:
  an accessor gives up the native subscript that is the whole reason it is
  flat. Ownership is the only move and it needs a single reader.

**Discount the loader when counting readers.** `model.bas` appears in almost
every reader list, but its references are load-time writes. Hand the loading
to the owner -- `pl_load_hulls`, `rb_load_leaves`, `rb_load_lfaces` take a
count and do the rest -- and arrays that looked shared turn out to have one
reader. That is what freed `lfc_buffer`, `pvs_buffer_b` and `lef_buffer`.

**The remaining ten are not a to-do.** They could be procedure parameters --
BASIC passes `a() as nodeb` and subscripts normally inside -- but that puts a
descriptor indirection in `r_bsp`'s recursion and `d_poly`'s per-face loop.
Ten variables shared for a stated reason are not the problem the refactor
set out to fix. Measure on `pln_buffer` first if you revisit it.

**Splitting create from bind is what made any of this possible.** An array
has to be visible where it is subscripted and `REDIM` forces module level, so
every array had to be declared once, globally, whatever used it. Since
`uglArrNew` and `uglArrMap` are separate calls, a module declares a
one-element stub, hands it over, and owns the array outright.

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
