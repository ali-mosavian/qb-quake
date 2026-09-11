# Notes for working on this

Hard-won things, mostly the kind that cost an hour before they cost a minute.

## Rules

The short list. Where one of these has a long-form note further down --
most do, because most were learned the expensive way -- it points there
rather than saying it twice.

### Code: principles

These apply whether the file is `.bas` or `.py`.

**DRY: one fact in one place.** A value or a rule that is true twice is
declared once and read twice. **SRP: one module, one subsystem.** Listing
a file's procedure prefixes should collapse to one -- see **Layout** and
**Splitting a module**, where this is checked mechanically. **Open/closed:
a new idiom is a new case, not an edit to the cases already there.** A
`select case` gains a branch; the branches it already has do not change
shape to accommodate it. The ini parser is the worked example of where
this does NOT pay -- see **What was deliberately not done** -- so apply
it where it earns its keep, not everywhere reflexively.

### Code: the renderer

**`snake_case`, and this is a deliberate divergence.** The sibling BASIC
project bans underscores because two of its three compilers reject them;
we build with VBDOS alone, on evidence (see **Toolchain**), so the
constraint does not reach us and every procedure here is already
`r_draw_world`, `pl_trace`, `mod_find_spawn`. `PascalCase` for UDTs. Do
not "fix" one convention into the other -- see **Names** under House
rules.

**No type sigils. Declare the type.** `as integer`, not `%`. The one
exception is uGL's own spelling of its names (`uglMapEx&`), which is the
library's, not ours.

**A procedure does what its name says, on what it is given.** Everything
it uses is a parameter or a local; no procedure reads a global. State
travels in UDTs, and UDTs of UDTs. Arrays are the one forced exception,
because BASIC cannot put them in a TYPE.

**Bail early; do not nest.** Guard clauses and `exit sub` beat an `if`
wrapping the body.

**Names say what the thing is, in as few words as do that.** A `2` or a
`b` suffix means the distinction was never given a word.

### Code: the tools

`tools/*.py` are standalone scripts run directly -- there is no
`pyproject.toml`, no uv lock, no ruff config and no pytest suite today.
The rules below are for what gets written or touched from here:

- Python 3.13+, and write 3.13: `match`/`case` over `if`/`elif` chains,
  `StrEnum` for string-constant sets (a bare name in `case` captures
  everything, so constants must be dotted), `X | None`, type aliases,
  walrus where it shortens.
- Type annotations on every parameter and return. None of the current
  seventeen tools has one, so this is a rule about new code, not a claim
  about old.
- Functions over classes; a class earns its place only when behaviour and
  state travel together. Data is `@dataclass(slots=True)`, `frozen=True`
  unless it mutates.
- Functions are pure. No module-level code that does work.
- A comprehension where it fits: a `for`+`append` with no real branching
  is a comprehension not yet written as one.
- ruff / ruff-format / isort, line length 120, double quotes, one import
  per line.
- **No function docstrings, and no comments that restate the code** -- a
  comment must carry a fact the code does not. The MODULE docstring
  stays: in this repo it is the tool's usage text, and `imgdiff.py` is
  the model.
- If a Python test suite appears: pytest, no test classes, parametrize
  wherever one assertion runs over a set. The gates today are `make test`
  and `tools/check.sh`, not pytest.

### The gates

    make test           lint, header deps, the qgl suite -- native, ~15s
    tools/check.sh      the above, then build, bench and compare
    tools/check.sh --churn   two runs of one binary under eviction

`make test` needs no DOS toolchain and no VBDOS, which is what makes it
worth running between edits: a failure there names an assertion instead
of producing a picture that came out wrong for reasons unknown.
`check.sh` runs it first for the same reason.

### Writing

**Commit messages.** Conventional commits, `type(scope): description`,
plus a body. The subject says what changed; the body says what it was and
why. Both short. No `Co-Authored-By` -- the user is the author.

**Replies in session are held to the same rule, and it is the one most
often missed.** Say the thing and stop. The finding first, no preamble,
and no closing paragraph recommending next steps unless a decision is
actually open. PR bodies, docs and comments likewise.

**Report what was measured, not what was expected.** If six runs were
meant and three ran, say three.

### Working

**Watch DOSBox, do not wait for it -- and check often, not once.** A
launched run gets `dosbox_status`, a screenshot, the text screen and
`dosbox_where` checked repeatedly WHILE it is in flight, not started and
then read once at the end. A picture answers in one glance what a timeout
cannot answer at all: loading screen, black screen, error, or a frame
that rendered and stopped. This is the MUST rule -- see House rules and
**Drive DOSBox hands-on**. Every inspection freezes the CPU; resume with
`dosbox_continue` and confirm `cpuRunning` before reading anything from
the next check.

**In QB, one call per frame beats many small ones.** A C port of
`d_draw_faces`'s per-face MATH, called once per face, moved e1m7's
38.773ms setup phase to 38.672ms -- six pairs, medians, -0.100ms. The
arithmetic was never the cost; 497 crossings a frame were. Port the
whole loop and cross once, or do not bother.

**Measure, do not reason, about cost.** DOSBox charges per instruction and
models no latency, so intuitions about what is expensive are worthless
here. Six runs per arm, interleaved, medians -- see **One run per side is
not a measurement**.

**Round trip before trusting a rewrite.** Read the thing, write it back,
compare bytes, and only then believe the transform. `-dumptex` reading
every atlas cell back through its own view is this rule, and it is what
proved the atlas right while the fault was elsewhere.

**Fixtures are real output, never generated.** Reference images come from
a known-good build; BSP and asset fixtures are real map data. A fixture
you synthesised tests your idea of the format.

**Verify in a build directory you made from clean.** An incremental
`$(BUILD)` accumulates files nothing produces any more, and it keeps
running while a fresh checkout cannot: `data/assets` is generated and
untracked, nothing regenerated `soldier.geo`, and every clean build died
in `mdl_load` with `runtime error 9 at line 0` while the old directory
ran fine on a copy made by hand months earlier. `make assets` builds the
monster too now, and `mdl_load` says which file is missing.

**A fix starts with a failing test.** Reproduce it, watch it fail, then
fix. New code does not need the test first, but the coverage has to be
real. `tools/check.sh --churn` was written this way: it failed on the
pool build before anything was changed.

**Test behaviour, not implementation.** `sc_selftest` checks the
allocator's invariants and passed with both of this session's bugs
present; the test that caught them compares two frames.

**Mutation-check every fix.** Put the bug back and confirm something
notices. Forcing `sc_find` to always miss is the form this takes here --
it made a nondeterministic render byte-identical, which is what named the
hit path.

**When the source measures clean and it still misbehaves, stop measuring
the source and check what was BUILT.** A stale `uglv.lib`, a shared build
directory, an unresolved external that LINK emitted an EXE around
anyway -- see **Build directories: never share one**.

**Consult an Opus-model agent for review at every iteration, not just
the ends of a task.** Before writing code, after writing it, after each
round of changes while iterating, and whenever stuck -- not only at the
start and finish. Resume the same agent across rounds rather than
starting fresh each time, so it keeps the thread of what it already
reviewed. Fall back to Fable if Opus is unavailable or fails.

## House rules

These are not suggestions. Apply them to anything you touch, and do not
introduce new violations even where the surrounding code still has them.

**Never wait blind on DOSBox. Drive it.** This is a MUST, not a
preference, and it is the single most expensive rule to ignore in this
repo -- it has cost hours, repeatedly, in one session alone.

A run that has not returned tells you NOTHING. `timeout N` and then
guessing is not a diagnosis. The moment a run does not come back, attach
and look:

    dosbox_status        -- is the CPU even running? cpuRunning/debuggerFrozen
    dosbox_screenshot    -- then Read the png. Loading screen? Black? Error?
    dosbox_text_screen   -- text mode
    dosbox_where         -- WHICH ROUTINE, by name, once a MAP is loaded
    dosbox_regs          -- sampled twice: do CS:EIP move? moving = slow, not hung

Check the screen and the running state REGULARLY while a run is in
flight, not once at the end. A picture answers in one glance what a
timeout cannot answer at all, and `dosbox_where` names the routine
outright.

Two traps that make the blind approach worse than useless:

- **Every inspection FREEZES the CPU and does not resume it.** A
  screenshot of a frozen guest is black and means nothing. Resume with
  `dosbox_continue` (it times out waiting for a stop that never comes --
  that is fine) and check `dosbox_status` before believing any reading.
- **A stale `process_exit` notification holds a newly launched program
  frozen.** Always confirm `cpuRunning` before concluding anything.

**The build carries CodeView symbols, and the emulator reads them by
itself.** `DEBUGINFO=1` is the default and threads through all four
tools -- BC `/Zi`, BCC `-v`, jwasm `-Zi`, LINK `/CO`. Any one of them
missing gives nothing: the records have to survive from the OBJ into the
tail of the EXE. Then `dosbox_debug_prepare { verifySymbol: "d_draw_faces" }`
answers `source: "codeview"` and `dosbox_where` names the routine, the
source file and the line rather than `LMEM+0x943`. The EXE goes
345K -> 577K and the frame is byte-identical, so this costs disk and not
the conventional memory that is actually scarce. `DEBUGINFO=0` for a
lean build.

Note `dosbox_debuginfo { op: "status" }` times out on this program --
`sym_list` asks for a million symbols. Resolve names one at a time
instead; that works.

**The MCP owns port 2159 and cannot be moved, so use
`tools/dbgsock.py`.** The MCP fixes its port for the life of the server
(`DOSBOX_MCP_PORT`), and other worktrees' sessions take 2159 -- every
launch here then comes back "debug socket did not open" and there is
nothing to do about it from inside the session. The GUEST reads
`DOSBOX_DEBUG_PORT`, so launching it ourselves gets a socket nobody can
claim:

    tools/dbgsock.py launch build/vbd-dbg/dosbox-viz.conf --port 2170
    tools/dbgsock.py where
    tools/dbgsock.py send '{"cmd":"resolve","spec":"d_faces.c:712"}' \
                          '{"cmd":"bp_set","seg":X,"off":Y}'

`where` answers with the file and line -- `d_mdl.obj:mdl_draw+0x5F9,
d_mdl.bas line 406` -- for BASIC as well as C and asm. Every command
freezes the CPU exactly as the MCP's do; `{"cmd":"continue"}` resumes.
Default port is 2170 so it never fights the MCP.

**Link with `/MAP` so the debugger can name things.** Without it
`qrender.map` carries segments only and the best the debugger can say is
`LMEM+0x943`; with it there are 2,545 publics and the same address comes
back as `B$FCompactMove`. `tools/dosbox.sh` passes it.

**There is no `COMMON` any more.** Every array is declared once in
`main.bas` with `dim`, and travels as a parameter. The blocks that used to
hold them -- `/map_a/`, `/world/`, `/surf/`, `/ent_s/`, `/drw_a/`,
`/vis_a/`, `/scr_s/`, and the rest -- are gone. If you find yourself adding
one back, the thing you want is a parameter.

**The compiler can prove it.** `main.bas` declares the application state
with `dim`, not `dim shared` -- module-level code sees it, procedures do
not. Anything that reaches gets `Variable not declared` at the build. That
is what turned "probably converted" into a fact. `tools/qbglob.py` finds
them before the build does.

**No function reads a global.** Everything a procedure uses is a parameter
or a local. This is the rule the rest follow from. A module-level
`DIM SHARED` counts as a global to the procedures in that module -- owning
state in the right module is an improvement, not compliance.

**State goes in UDTs, and UDTs of UDTs.** Group related scalars into a type
and pass the type, so a call site says what it is handing over instead of
listing eight things. Nested types work (`Leaf.bound as BoundBox` already
relies on it), so compose rather than flatten.

**Arrays cannot be UDT members**, so they are passed as parameters:
`sub walk ( n as integer, nodes() as BspNode )`. That is the compromise the
language forces, and it is the only reason an array appears in a signature.

**Measured, not assumed: parameters are cheap.** Converting
`r_recursive_world_node` -- the hottest recursion in the renderer -- from
eleven globals to twelve parameters cost **+0.15ms of an 81.5ms frame,
+0.2%**, six runs interleaved per arm. An array passes as a 2-byte
descriptor offset and a UDT as a far pointer. "It would be too slow in QB"
is not a reason; measure it the way that number was measured.

**Names.** `snake_case` for procedures, parameters and variables.
`PascalCase` for UDTs. Descriptive but short -- `Leaf`, not `leaf2`; a name
carrying a `2` or a `b` suffix means the distinction it is drawing was never
given a word.

**Disk record vs runtime record is `Disk` + the name.** The BSP file's
layout and the narrowed thing kept in memory are two types, and the suffix
scheme -- `leaf`/`leaf2`, `node`/`nodeb`, `cliptmp`/`clipnode` (reversed
from the others, which nobody could have guessed) -- never said which was
which. `DiskLeaf` loads, `Leaf` is what the renderer walks. This is Quake's
own `dleaf_t`/`mleaf_t` split with words instead of letters.

**Never delete with a `sed` line range.** `sed '/^declare sub foo ( _/,/^)$/d'`
was meant to remove one forward declaration. The declaration ends `)`, the
definition ends `) static`, so the range ran past its target to the next
bare `)` in the file and took 640 lines with it. Use a script that finds
both ends of the construct, and diff against a copy before writing to
`src/`.

**Renaming a type is not renaming an identifier.** A type appears only as
`type X` or `as X`, and `tools/qbtype.py` rewrites exactly those.
`model` was simultaneously a type, a parameter of `r_draw_world` and a
field of `PlatEnt`; a general identifier rename corrupts the last two.

**Quake-style subsystem prefix on every procedure.** `pl_move.bas` is the
model: `pl_trace`, `pl_gravity`, `pl_hull_check`. The prefix names the
subsystem, not the file -- `d_surf.bas` carries both `sc_` (the cache) and
`sb_` (surface building), which is correct because they are two subsystems.
An unprefixed name like `point_side_of_node` does not say whose it is;
`r_node_side` does.

**Multi-parameter signatures are one parameter per line**, declare and
definition alike. Single-parameter and no-parameter procedures stay on one
line -- three lines to say `( byval cnt as long )` reads worse, not better.

    declare function r_node_side ( _
        byval node_idx as integer, _
        pt as u3dVector3f, _
        nodes() as nodeb, _
        planes() as plane2 _
    ) as integer

`tools/qbsig.py` does this to whole files. It joins continuations ONLY for
lines that begin a signature: an earlier version joined every `_`-continued
line and re-split just the signatures, which flattened multi-line
expressions into single ones and ran at BC's 255-character limit.

**No type sigils. Declare the type.**

    function r_plane_dist ( pt as u3dVector3f, pl as plane2 ) as single

not `r_plane_dist!`. Same for parameters and locals: `as integer`,
`as long`, `as single`. `DEFINT`-style suffixes scattered through a
signature are the reader's problem, and `%`/`&`/`!`/`#`/`$` do not survive
being read aloud. The one exception is calling into uGL, whose own headers
still declare `uglMapEx&` -- the sigil there is the library's spelling of
the name, not ours.

**A procedure does what its name says, on what it is given.** If it is
called `classify_point` it takes a point -- not a camera it reaches into for
one. And the name has to answer "against what?": `point_side_of_plane` says
what `classify_point` only gestures at.

**Docstrings earn their place.** A banner block on a function whose name
already says it is noise, and noise is what stops the next person reading
the blocks that matter. Comment what is not in the code: why the axes swap,
why single and not double, which trap this avoids. `r_plane_dist` had a
fourteen-line header over three lines of arithmetic; two lines of it were
worth keeping.

**A parameter shadows a `COMMON SHARED` of the same name.** Verified, not
assumed: `pl_init` was called with a scratch `PlayerState` while the global
`pl.pos.x` was set to -999. The parameter came back with the spawn position
and the global was untouched. So a signature may reuse the global's name and
the body needs no edit -- which is what made converting `pl_move` and `ent`
a change to signatures and call sites only.

**A declare belongs in the narrowest place that can see it.** Not every
procedure needs a shared header. If one module calls it, declare it there;
if a module calls its own, declare it locally. Headers carry only what is
genuinely cross-module.

This is not tidiness. Forcing every module to include the whole header
chain -- which is what a shared header full of declares eventually demands,
since a declare may only name types the includer has seen -- ends in

    BC : Out of memory

BC's symbol table is finite and every module got every type. Narrow
declares keep it under the limit. `tools/qbplace.py` places by the latest
type a declare names; the single-caller ones do not go in a header at all.

**Includes have a canonical order.** A declare may only name types the
including module has already seen, so `q_*.bi` go in dependency order:

    bspfile.bi  q_env  q_map  q_vis  q_draw  q_scr  q_cam  q_pl  q_ent

`World` lives in `q_map.bi`, so a declare naming it cannot sit in
`bspfile.bi`. BC reports the mismatch as `TYPE not defined` pointing at the
DEFINITION, which reads as though the definition is wrong.

**Refresh declares with `tools/qbdecl.py` after any signature change.** A
declare drifted from its definition is the most common build break here,
and BC again points at the definition. The tool rewrites each declare from
its `.bas`, leaving it in whichever header it was in.

**Drop a global the moment it stops being read.** Passing data instead of
reaching for it only pays once the declaration goes; a `COMMON` entry that
every procedure now receives as a parameter is worse than before, because it
looks live. Re-check the block after each conversion.

**Leave what you touch better.** A procedure you are editing for another
reason is a procedure you may fix: flatten a nest, split a routine that does
two things, name a variable properly. `mod_find_spawn` was six levels deep
inside one loop; the block parsing came out as `mod_spawn_from_block` and
nothing nests past two now. Keep it to the code you were already in.

**Comments are short, and say what the code cannot.** No banner block on a
function whose name already says it. Comment the swap, the trap, the reason
for `single` -- not the obvious. `r_plane_dist` carried fourteen lines over
three of arithmetic; two were worth keeping. This applies to commit messages
and to anything else written here.

**Bail early; do not nest.** Guard clauses and `exit sub` beat an `if` that
wraps the body. Keep procedures tight and small enough to read whole.

## Layout

    src/main.bas      host_init / host_main / host_shutdown   (Quake host.c)
    src/sys.bas       command line, stuff.ini, sys_error       (Quake sys_*.c)
    src/model.bas     mod_load_* lump readers                  (Quake model.c)
    src/mod_tex.bas   texture headers, preprocessed bitmaps
    src/r_bsp.bas     traversal + visibility                   (Quake r_bsp.c)
    src/d_faces.c     the rasteriser                           (Quake d_*.c)
    src/d_turb.bas    the liquid turbulence table, all that is left of d_poly
    src/view.bas      where the camera is and looks            (Quake view.c)
    src/in_main.bas   keyboard, mouse, the toggles             (Quake in_*.c)
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

Both were reproduced through the mgl-era serial build, which is gone
with the library; the evidence is this note.

**mgl is not linked, mounted or included any more.** `src/qgl/` is the
whole graphics layer, and nothing under `tools/` reaches for a `$MGL`
tree. The notes below that name `uglv.lib` are history, kept where the
lesson outlives the library.

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
   same trap, and so are `pos`, `seg`, `tab` and `left` -- each cost a build
   here, as a parameter or a local, with an error pointing at the next line.
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

**This trap does not always "vanish in seconds with empty stdout" -- it can
look exactly like a slow, nondeterministic hang instead**, which is the more
dangerous shape because it reads as a completely different bug class.
`d_surf.bas`'s light-style table (`dim shared ls_tab(LS_MAXSTYLE) as
LightStyle`, a small fixed-size array, under `'$DYNAMIC`, in a non-main
module) compiled clean and then hung on every run — not a crash, sustained
90-100% CPU for minutes, `run.out` and `error.log` both empty. The hang
point varied: sometimes inside the first few loop iterations, sometimes two
frames in, never the same place twice. That variability was the tell once
recognised: every write was landing in whatever happened to occupy that
segment of the far heap at the time, which differs run to run, so the
FIRST thing corrupted (and therefore where the symptom eventually surfaced)
differs too. Genuine logic bugs give a repeatable failure point; this gave
a different one on every run.

Two false leads cost real time before the allocation was even suspected:
`byval` on a `string` parameter (no precedent anywhere in this codebase,
genuinely untested territory, but changing it made no difference), and a
string-literal argument to a byref string parameter (also no difference).
`sys_mem_mark`'s existing `memtrace.txt` — already open-appending a line
per load phase, already proven safe — is what actually localised it: it
narrowed the hang to strictly between the `mapclose` and `surfcache` marks
without adding any new instrumentation, and a probe between `sc_init` and
`ls_init` placed the fault inside `ls_init` with certainty. Only then did
rereading `'$STATIC`/`'$DYNAMIC` in this file turn up the real cause.

Fixed the same way `sc_slot()` right next to it already does it: declare
`ls_tab()` empty and `redim ls_tab(LS_MAXSTYLE) as LightStyle` as the first
line of `ls_init`, a SUB, which runs wherever it is called from — unlike
the bare module-level `DIM` it replaced, which only ever ran in `main.bas`.

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

**A far-to-near pointer cast compiles silently and drops the segment.**
`cam_plane_dist( campos, (Plane *)pl )` where `pl` is `Plane far *` reads
plane data from whatever sits at that offset in DS. No warning, no crash:
22 polygons drawn where 153 belonged, a plausible frame with most of the
level missing. Near-to-far is safe -- it adds DS. Audit the other
direction.

**A defensive guard that changes control flow is a behaviour change.**
`if ( vcnt < 3 ) continue;` added to a port looked like bounds checking.
BASIC had no such test: the face flowed on to the clipper and was
rejected there, and on the way it still passed the lightmap gate and
took a cached surface. Same picture, five fewer `sc_find` calls a frame,
and a diverged cache. Port the control flow, not just the arithmetic.

**BASIC's `int()` is FLOOR; a C cast truncates toward zero.** They differ
by one for a negative argument.

**MASM logical-line limit is 512 chars** including continuations. Expanding
tabs to spaces in µGL's asm pushed a `local` block over it.

**A far pointer to a BASIC array cannot be hoisted out of a loop.** The
runtime relocates far-heap arrays, so `VARSEG`/`VARPTR` are only good until
the next thing that allocates. `d_poly` computed

    gv_dst = clng( varseg( gv_buf(0) ) ) * 65536& + _
             (clng( varptr( gv_buf(0) ) ) and 65535&)

once per frame, on the comment's reasoning that "VARSEG/VARPTR on a DIM
SHARED array cannot move" -- which stopped being true when `gv_buf` became a
parameter. It moved mid-frame. Every `memCopy` after the move landed on the
old address, `gv_buf` kept the FIRST face's record, and so every face read
one lightmap header, asked for one surface size, and shared a single cached
surface. Whole faces drew flat black.

Take the address per face. Two `VARSEG`/`VARPTR` on a drawn face cost
nothing measurable, and `D_POLY_CODE` came out 100 bytes SMALLER.

The tell was that it hid completely from every isolated test: `-dumpsurf`
built byte-perfect surfaces, the atlas read back byte-perfect through its
views, the unlit path was pixel-identical, and the assets were identical to
the reference's -- because none of those go through the cached pointer. What
found it was tracing the same per-face values out of BOTH builds and diffing
the traces; `geom_row`, `geom_ofs` and the source pointer matched, and only
the copied CONTENTS were frozen, which points at the destination and nothing
else. Reach for the two-sided trace earlier than this did.

**A latent bug of this kind surfaces on a memory change, and looks like the
memory change.** Nothing about the texture atlas was wrong; it freed 42K of
conventional memory, the far heap laid out differently, and an existing
cached pointer that had always happened to stay valid stopped doing so. Do
not assume the new code is at fault because the symptom arrived with it.

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

## Build directories: never share one

**Always point a build at a path unique to your worktree/session.** More
than one agent works in these trees at once. Two processes writing one
`BUILD` interleave their objects, and LINK still emits an EXE around an
unresolved external -- `int 3` at the call site -- so the symptom is a
run that "compiles clean and prints nothing", not a build error. Hours
went into that when the library rules did it.

    BUILD=$PWD/build/vbd-<tag>       renderer objs, the EXE   (make)
    VBD_OUT=$PWD/build/vbd-<tag>     BENCH.BMP, bench.txt     (check.sh)

`VBD_OUT` matters for a subtler reason: `check.sh` compares `BENCH.BMP`
against the reference and reads ticks from `bench.txt`. Two runs sharing
that directory can have the picture from one run and the timing from the
other, and the comparison still "passes".

`make -j8` is safe: one parallel make orders its own rules. The unsafe
thing is two separate `make` PROCESSES in one directory. Anything
reporting TIMINGS sets `CORE=normal` explicitly: the recompiler throws
its translations away when a filler patches immediates into its own
inner loop.

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

**A viz window takes keystrokes.** `autolock=true` means a stray key
reaches the guest, and the renderer's toggles are single letters -- `L`
flips lightmaps, `B` culling, `F1`/`F2` mip and perspective. A screenshot
that looks wrong may be a toggle, not a regression: read the status bar
before believing it. `L lm off` with `Hit / built 0/0` is the lightmap
toggle, not broken lightmaps.

**Drive DOSBox hands-on, do not wait on files**

## Benchmarking a change to the frontend

**Use `-nodraw`.** It runs the BSP walk, PVS and visibility and skips
rasterising. A change to the walk -- paging the node tree, reordering the
recursion -- moves the frontend and not the fill, and a full-frame timing
buries it: fill dominates, so a large regression in the walk shows up as
a small one overall and a small one is invisible.

**But check it is not measuring the clock.** On dm3ish the frontend is
faster than the timer resolves, so `-nodraw` returns the tick floor and
not the code: three different builds all reported

    ft_mean 9.97680673249007   frames 1908

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

A before/after is only a measurement if the map, the flags, the cycles
and the core all match. State them when quoting one.

### One run per side is not a measurement

`ft_mean` over a campath run has a run-to-run spread of about **2.3 ms**
-- wider than most changes worth arguing about. It is also quantised:
the same handful of values recur across unrelated builds, so two runs
agreeing to ten decimals means the metric is coarse, not that the builds
are identical.

**Six runs per arm, interleaved A/B/A/B, and compare medians.** Not six
of one then six of the other: the host drifts, and a block design loads
that drift onto whichever arm ran second.

Build the other side in a worktree so both trees stay intact:

    git worktree add -q --detach /tmp/base <commit>
    cp -r data/assets /tmp/base/data/
    make -C /tmp/base BUILD=/tmp/base/build/o
    cp build/vbd-x/campath.bin /tmp/base/build/o/

    for r in 1 2 3 4 5 6; do
      for a in "base:/tmp/base:/tmp/base/build/o" "head:$PWD:$PWD/build/vbd-x"; do
        IFS=: read t rt out <<< "$a"
        VBD_OUT=$out QFLAGS="-lm -campath" $rt/tools/dosbox.sh run > /dev/null 2>&1
        echo "$t $(grep '^ft_mean ' $out/bench.txt | cut -d' ' -f2)"
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

**`-ticks N` now stops ON the tick, not past it.** It is tested once a
frame, after `host_advance` has already spent the frame's whole
accumulator, so a slow frame that ran three steps used to end the run at
903 rather than 900 -- and the camera was wherever those extra steps
carried it. Two runs of one binary differed by most of a room, which reads
exactly like a rendering bug. `host_advance` now checks the budget inside
its own loop, and `px`/`py`/`pz` and `anim_time` come back identical from
every run.

**Add `-ticks N` for a comparable frame.** The fixed timestep drives
`anim_time`, so a tick-bounded run pins it: `-bench 400 -ticks 120` gave
animtime 1.999995 and one md5 across three runs at 69, 68 and 68 frames. Every
A/B in this file that compares images uses `-ticks`.

**`check.sh`'s image comparison is a gate again, and was not one for a
while.** The stored reference was 320x200 against a build that renders
160x100, `BENCH` carried no `-ticks`, and the result was printed rather
than acted on -- three separate reasons the picture could not fail the
check. Meanwhile the screenshot itself was reading the qgl backbuffer
through mgl's `uglPGet` and returning full-frame noise, and no run said
so. `BENCH` is now `-lm -nostats -yaw 183 -bench 40 -ticks 60`, which is
byte-identical run to run, and a difference exits non-zero.

**A qgl Surface is no longer an mgl DC, and the compiler cannot say so.**
Both are a `long` handle in BASIC, so `uglPGet( h_dst_dc, x, y )` compiled
and ran; `SF_addrTB` sits at 38 where mgl's `DC_addrTB` is 32, so it read
its scanline pointers out of `zsf`/`zmode` and every pixel came back from
a random address. The symptom is specific and worth recognising: correct
palette, no geometry at all, and the SAME bytes whatever the camera does,
because it is not reading the frame. `sys.bas` already refused
`-spandraw` for this exact reason, one line away, and the screenshot was
missed anyway. Any remaining `ugl*` call taking a surface handle is the
same bug waiting.

**`make build` copies `data/stuff.ini` over `build/vbd/stuff.ini`.** Editing
the build copy does not survive a rebuild. This is how `sound.enabled = true`
kept coming back and re-arming the init hang, after the setting had apparently
been disabled -- and the symptom (title bar shows QRENDER, screen still at
`C:\>`) was misread three times as a config or command-line fault. The source
file now ships `false`.

**`defint a-z` is inert once every declaration is explicit**, and 65 of them
were. Proof rather than argument: removing all 65 produced a byte-identical
EXE. It only ever typed undeclared names, which `OPTION EXPLICIT` forbids,
and sigil-less function returns -- of which there were TWO, found later:
`sc_find` and `sc_alloc` both assign a `long` dc and declare no return
type, so they returned a **single**. BASIC hid it, converting back on
assignment; C declaring them `long` read DX:AX and got garbage. Both now
say `as long`. Check for an `as` clause before believing a return type.

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
game being units per seven seconds. What mgl delivered was 145.6 Hz: its
`tmrInit` programmed a PIT divisor of 8192 whatever was asked for. The PIT
is qgl's now -- `src/qgl/tmr.asm` hooks INT 8 at a real 1000 Hz and chains
the BIOS handler each time the divisor accumulates to 65536, so DOS's clock
keeps its 18.2 -- and `sys_time_init` still measures it against DOS's own
TIMER, because the emulator is still underneath it.

That measurement aligns both ends of its window to a TIMER edge, because
TIMER only ticks every 55ms: without the alignment the same binary measured
142.9 Hz on one run and 148.1 on the next, and the game ran 4% faster on one
of them. Aligned, three runs gave 144.0, 145.5, 144.0 on mgl's timer.

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
spawn it should peak **47.8** units above the resting height. Not the
45.56 that `v^2/2g` gives for Quake's 270 up and 800 down: a fixed 60Hz
step overshoots the continuous result, and the measurement is the
authority.

**Movement is Quake's, from `sv_user.c`.** Walking is `cl_forwardspeed`
200; 320 is `sv_maxspeed`, what `+speed` gets. `sv_edgefriction` doubles
friction over a drop and is ported. Before this, a flat 500 u/s^2 against
speed-proportional friction settled at `500/4 = 125` u/s -- the 320 cap
it carried was never reached, so "the cap is unchanged" was never the
same as "the speed is unchanged".

**Simulate id's code offline before trusting a movement port.** A Python
transcription of SV_Accelerate/SV_UserFriction predicts the whole curve
in seconds; ours then measured 197.9 and 199.8 u/s against a predicted
200, with a constant 63.9 unit offset that was the spawn fall under
SV_AirAccelerate's 30 u/s cap.

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

**A chain's frames sit anywhere in the lump.** e1m1 has `+0planet` at
55 and `+1..+3planet` at 70..72, `+0slip` at 56 and `+1..+6slip` at
73..78. `mod_link_anims` used to count the frames and link a contiguous
run from the first, which made `slip1`, `sliptopsd` and the `trigger`
texture frames of the planet and the button: the wall above the exit
showed the Earth. It now does what `Mod_LoadTextures` does -- finds
each frame by its digit, `+a..+j` as the alternate sequence, links a
ring -- and `d_faces.c` steps round the ring at 10 fps from the face's
own frame. dm3ish has no `+N` textures; the exit frame of
`tools/check.sh --e1m1` is where the chains are exercised.

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

Emits two 8-bit atlases -- `texr.bmp` raw indices, `texs.bmp` with colormap
row 0 applied -- plus `texofs.bld`, a `[id*4 + level]` table of byte offsets
into them. Already resampled to the fixed size the renderer wants and already
in the game palette. The Makefile regenerates them when the map, `base.dat`,
or the tool changes.

**Two atlases and eight views, not 648 dcs.** A dc costs conventional memory
for its struct and scanline table whatever its pixels cost -- 264 bytes
measured, and dm3ish made 160 of them. e1m1 would make 648, which is the
~171K that stops it loading. `mod_tex_raw`/`mod_tex_shaded` re-aim one view
per mip size with `uglSetView` instead: `mem textures` went 42,176 -> **0**
and `mem_avail` up 25,296.

**It costs 1.8% of the frame, and that is the trade.** Six runs per arm
interleaved on the dm3ish campath: 82.774ms before, 84.229ms after, medians,
spreads 0.000 and 0.213. The cost is a procedure call and a re-aim per face
where an array index used to do. Memoising the aim -- each view remembers
which cell it points at, and consecutive faces usually share a texture --
recovered only 0.14ms of it, so most of the remainder is the call itself.
Pinning `gv_buf` into DGROUP to make the address hoistable again was tried
and abandoned: a bounded `dim` in `main.bas` puts the DECLAREs after an
executable statement and BC rejects the file.

**A cell is a flat run of `cell*cell` bytes, not a window on the 8192-wide
image.** The fillers map one page and then walk the cell by the VIEW's bps,
which is the cell width -- `ul$fillView` strides by the view's own `bps` and
never the parent's. So the packer writes cells linearly and the BMP is just a
container for that byte stream. Sizes are 4096/1024/256/64 and each cell sits
at a multiple of its own size, so none straddles a 16K page.

**The placement is emitted, not re-derived.** mkassets owns the layout and is
free to pack in whatever order is tightest; deriving it twice is the bug the
luxel atlas already avoids by shipping its own table.

**`-dumptex` reads every cell back THROUGH ITS VIEW** with `uglPGet` and
writes `texdump.bmp`, a contact sheet of 20 columns by four stacked mips.
Diffing that against the atlas is what proves the views deliver the right
pixels with the renderer out of the way -- 108,800 texels, 0 mismatches. Do
this before suspecting the atlas: it was right, and the fault was a stale far
pointer in `d_poly` that the memory change merely exposed.

`tools/sbref.py` reads the atlas through the same table, so it stays a
reference for `uglBuildSurf` -- but note it reads the SAME assets the target
does, so it validates the builder and not the data. To check the data,
compare against the previous build's per-texture bmps.

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

**Bit-packing the conventional-memory records: tried, measured, reverted.**
`Node`, `Leaf`, `Face` and `ClipNode` are 22/22/10/6 bytes and cost 181,790
of conventional memory on e1m1. The field ranges leave real slack --
measured on e1m1: `plane_id` 0..1074 (11 bits), `child` -1531..2749 (13),
`lface_num` <= 230 (8), `cont` -4..-1 (4), `side` 0..1 (1), `bound`
-632..3096 (13 each). Packed to the bit that is 124,335, a 32% saving.

It does not pay, because **BASIC has no byte type**. A narrow field has to
be `as string * 1` and every read is `asc()` -- a string operation, not a
byte fetch. Two arms, six runs each, interleaved, dm3ish campath:

| change | saves on e1m1 | frame time |
|---|---|---|
| `cont`+`lface_num` -> 1 byte | 5,812 | **+0.64%** |
| `bound` -> 6 bytes, quantised | 25,686 | **+15.4%** |

The bounds are the instructive one. Quantising to 32 units from -4096 and
rounding OUTWARD is provably safe -- a box only grows, so `r_cull_box` culls
less than it might have, never more -- and the unpack was hoisted out of the
plane loop into six locals, six multiply-adds per box instead of eighteen
reads. It still cost 14.3ms of an 83.6ms frame, because `r_cull_box` runs per
VISITED node and six `asc()` calls there is six string operations per node.
It also loosened culling enough to move the image (64 pixels with the surface
cache out of the picture) and push `sc_built` from 481 to 508.

If this is revisited, pack pairs of bytes into an `as integer` and split them
with `\ 256` and `and 255` -- integer arithmetic, no string handling. That
recovers `Leaf` 22->20 and nothing else, since no other pair of narrow fields
shares a record. Three kilobytes on e1m1. Not worth the churn.

The bounds half is done now, in C: `r_cull_box_c` unpacks six bytes to
six floats once per call and no `asc()` runs anywhere hot. See the e1m1
memory paragraph.

The wider lesson: none of this addresses why e1m1 fails. It dies creating a
64,048-byte backbuffer with **183,504 free**, and freeing another 5,776 did
not change that. Shrinking records is not the blocker.


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

**A mapped EMS pointer is only as good as its lock, and the lock has to
come before the next ACQUIRE -- not before the use.** mgl's four page
slots are an LRU pool now: `emsSlotAcquire` evicts the least recently used
UNLOCKED slot, so a pointer from `mod_lm_map`, `mod_cm_map` or
`mod_geom_map` stops being valid the moment anything else wants a window.
It still reads. It just reads another page, with no error anywhere.

`sb_build` holds two at once -- the face's luxel rect and the colormap --
across `uglBuildSurf`, which acquires two more of its own. Unpinned, the
colormap window went first and every texel came out of a wrong lookup:
the frame was RGB confetti with the geometry still perfectly correct.

Pin at the point of handout:

    lmp = mod_lm_map( g, lmy )
    lm_lock = mod_lm_lock            '' before anything else can acquire
    ...
    sbp.cmap_ptr = mod_cm_map( g )
    cm_lock = mod_cm_lock

Locking both AFTER both maps looks equivalent and is not: the colormap's
own acquire is itself allowed to take the luxel slot. That mistake cost a
build cycle and looked exactly like the unpinned case.

Two of four, never more. `emsSlotLock` refuses the LAST unlocked slot, so
the pool always keeps one in reserve; pinning two leaves the builder the
two it needs. Unlock only what locked, and there must be no `exit sub`
between the lock and the unlock.

**Pinning is necessary and is NOT sufficient, measured.** With both
windows pinned exactly as above, a campath run still renders a different
picture every time. The pinning is reverted in the tree rather than left
in looking like a fix -- and note it makes the squeeze worse, not better:
four windows want slots (destination, atlas, luxels, colormap) and pinning
two leaves the builder cycling the atlas through the other two.

## The wandering streaks were the MODEL, and the near plane was half of it

Long black diagonal bands across walls, moving as the camera moves. They
were read as a surface-cache fault for a long time. They are alias-model
triangles projected into screen-spanning slivers.

The bisect, all at campath tick 360 (`-campath -bench 4000 -ticks 360`),
which is the first frame that shows them, counting index-0 pixels below
the HUD bar:

| arm | stray pixels |
|---|---|
| lit, depth on | 138 |
| `-noz` | 138 |
| unlit -- `sc_built 0`, no surface cache at all | 138 |
| `-nocull` | 138 |
| `-nomip` | 138 |
| `-affine` | 138 |
| **`-nomdl`** | **0** |

Identical to the pixel across every renderer variable, and gone entirely
without the model. Two more measurements pinned what they are:

- **Clearing the backbuffer to 251 left them black.** So the filler
  WRITES those pixels; they are not cracks between polygons showing the
  cleared ground through.
- **Drawing the model `QGL_M_FLAT` in colour 251 turned them red.** So
  they are model triangles, and the fault is in the geometry, not in the
  skin fetch.

`mdl_draw` (`d_mdl.bas`) REJECTED vertices behind the near plane
(`if tw < z_near then mdl_okv(v) = 0`) and drew a triangle only when all
three survived. That is not clipping, and it was the obvious cause: a
triangle entirely in front but with one vertex a hair past `z_near` keeps
an enormous `rw = 1/tw` and projects to a sliver. `d_faces.c` does the
real thing for world faces (`clip_w`).

**Porting `clip_w` to the model made it WORSE -- 138 stray pixels to
381.** That is the interesting part, and it is why this note is longer
than the fix. The near clip was correct and it exposed more of the same
defect, because it kept triangles the old reject threw away.

A second false step is worth recording because it looked like a fix and
was a bug: the draw was `QGL_M_PTEX`, which wants u/w and v/w, so raw u,v
was "corrected" to divided ones (381 to 378, i.e. nothing). **The model
is drawn AFFINE.** It always was -- this module's own header names
`uglTriT`, mgl's affine textured triangle -- and the affine filler steps
u and v linearly in screen space, so raw coordinates were right all
along. It is `QGL_M_TEX` now, with raw u,v, and only `QGL_M_PTEX` owes
the divided pair.

**The cause is that clipping to the near plane does not bound the
projection.** A corner at `w = z_near` with a large `x` still projects to
tens of thousands of pixels: measured, the model reached screen x 76,750
on a 160-wide surface. qgl clips to the view rectangle -- `clip.asm`,
Sutherland-Hodgman on four edges -- but AFTER the divide, and that clip
does not DISCARD such a triangle, it stretches the surviving sliver across
the whole frame. That is the streak, and mgl behaves the same way; the
world path escapes it only because `r_cull_box` and the frustum keep
world faces off that ledge.

So the clip has to be five planes in CLIP space: `w >= z_near`, then
`|x| <= w` and `|y| <= w`, which is the view rectangle expressed before
the divide. With that, every projected corner lands inside [0,160] x
[0,100] (measured: x max exactly 160.0, min -4e-06) and the strays go to
zero.

The general rule, worth more than this bug: **clipping to the near plane
bounds w, not the projection.** Anything handing a projected polygon to a
rasteriser that clips in screen space owes it side planes too.

`tools/check.sh --model` is the regression test, `-noai` on the away arm
since the monsters wander -- by tick 360 a knight had reached a visible
leaf, `mdl_drawn 1` under an identical picture. Two viewpoints, because
one assertion cannot fail both ways: at campath tick 360 no entity is in
frame so the model must add NOTHING, and from a fixed camera 200 units in
front of spawned entity 1 it must add SOMETHING. Campath tick 240 was the
positive control first and is not one -- unlit the model contributes zero
pixels there, and the 185 it seemed to contribute with `-lm` were cache
noise. It runs UNLIT on purpose -- with `-lm` the two arms render a
different number of frames over the same ticks (drawing the model costs
time), which evicts the surface cache differently, `sc_evict` 10 against
2, and the frames then differ for reasons that are not the model's
geometry. That confound cost a false FAIL here before it was recognised.

**The loop is `d_alias.c` now.** Profiled with two models in view, the
BASIC triangle loop was 19.5 ms of a 27.1 ms model cost against 4.8 for
the raster calls it fed; in C, with each vertex tested against the five
planes and projected once so an inside triangle skips the clip, the
model costs 9.7. Same arithmetic in the same order: the frame is
byte-identical. Two things bcc taught on the way: a `static` named `cx`
becomes `DGROUP:cx[di]`, which TASM reads as the register, and a C file
named like a `.bas` file overwrites its object.

### And the other half was the clipper's ring walk, not the scanner

Stand next to a spawned model after the clip fix and the streaks were
still there -- filled wedges from a screen corner, not slivers. Every
measurement said the scanner: 179 polygons inside an 11x18 pixel box, all
in front of the near plane, and `qglRsPoly` answering 100 lines for one
of them. Two sessions went into `qgl$drawA`'s edge arithmetic on that
reading, and none of it was wrong.

What found it was a breakpoint on the BASIC line after the call, armed
only when `qz > 30`, and then reading `qgl$src` -- the clipper's output
-- against the caller's `qv`:

    qv      (142.2,54.7) (142.3,50.3) (120.0,50.6)      area -98, fine
    qgl$src (142.3,50.3) (142.2,54.7) (0,0, z 0, u 0, v 0)

The third vertex was never the caller's. `qglClPolyEx` walks the ring
from the topmost vertex with a signed step -- backwards for a CCW ring --
and wrapped by comparing the pointer against `vtx[0]` AFTER stepping,
unsigned. `qv` is a BASIC far-heap array and sits at offset 0 of its
segment, so `0 - 20` is `0FFECh`, "past the end", and the vertex came out
of whatever lay 64K above. Zeros here, hence the screen corner. World
faces never saw it because `d_faces.c`'s ring sits at a DS offset well
above 20, and the earlier live read of tri 39 happened to have its
topmost at index 2, which walks 2,1,0 and never wraps.

The wrap now happens BEFORE the step: at `vtx[0]` going backwards, jump
to one past the end and then subtract. `t09rs` case 13 hands the CCW
square in at `seg:0000` and failed all three of its assertions before
the fix; `tools/check.sh --model` reads 0 / 55 pixels against the 2125
it read before. The lesson is the second rule again: the runaway was
measured from the caller's side and the scanner's side, and never from
the buffer between them.

## The perspective half texel goes AFTER the divide, and mgl's does not

`-qgldiff` measures both rasterisers against the exact answer and asserts
qgl is no further from it than mgl. It passed at 28c3d56 with qgl at 6
and 2 texels off against mgl's 8 and 4, and failed from 47e3897 -- the
scanner rewrite "per mgl" -- at 9 and 4, for three commits.

The rewrite transcribed mgl's span start (`uglplxtp.asm` :820): half a
texel added to u/z and v/z as `0.5 * (1/z)` BEFORE the divide. After the
divide that is `0.5 * z(x) / z(start)`: half a texel at the left of the
span and two texels where 1/z has fallen to a quarter, which the 28c3d56
message had already measured and avoided. The flat 32768 after each
sub-span divide is back (`b8span.asm`, `PDIV`), and `t09rs` case 14 --
u constant while 1/z falls 4x across the span, every pixel must read the
same texel -- fails on mgl's arrangement and passes on this one.

`-qgldiff` read 8 and 4 against mgl: parity, not the 6 and 2, and the
assertion held on equality. mgl's arm is gone with the library, so 8
and 4 are now the bounds it asserts, with the coverage every case drew
when the two still agreed pixel for pixel. The remaining two texels are WHERE the span
is sampled: `65536 - frac` puts the first sample on the pixel's right
edge in the perspective path, whose converter adds no half pixel
(F2FX_tp2d). Sampling at the centre (`32768 - frac`) reads 7 and 3 --
measured, and not committed: it resamples every textured pixel half a
pixel over (48% of the bench frame) and is a fourth deviation from mgl.

`tools/ref/bench.bmp` moved with it: 564 of 16000 pixels, single texels
scattered over textured walls, no geometry. A reference regenerated for
a sampling change is the fix, not a regression, but say so each time.

## The file layer: one name space, drivers that register by linking

`src/qgl/file.asm` is what mgl's `uar*` was: `qglFileOpen` /
`qglFileOpenBas` / `qglFileSize` / `qglFileRead` / `qglFileWrite` /
`qglFileClose` on `"assets.zip::member"` and on plain names, and a
handle indexes a table there rather than the caller declaring a `UAR`
it only ever passes back. Which containers exist is the drivers'
business: a row of `FsDrv` -- check claims an open file by its header,
find turns a member name into a position and a size, write is 0 where
the format cannot, which is why a zip member refuses `qglFileWrite`
and a plain file takes it.

**A driver registers by being linked.** `QGL_FSDRV` puts its row in
segment `QGLFS$M`; file.asm brackets that segment with `QGLFS$A` and
`QGLFS$Z` and every open walks the bracket -- the trick DOS C runtimes
use for their initialiser tables, since nothing else runs before
BASIC's `main`. The one contract is link order: MS LINK lays a class
out in the order it meets its segments, so file.obj has to come before
every driver or the row lands in front of the bracket, unseen --
`QRENDER.MAP` with zip.obj first shows `QGLFS$M` at 47E26 and `QGLFS$A`
at 47E32. jwlink sorts the class by name, which is why the native
suite cannot demonstrate it. Both Makefiles list `file` first,
`qglFileDrivers` reports what the walk finds, and `t05file` asserts the
count.

`src/qgl/zip.asm` is the first driver, and the only one.

**Stored only, and `tools/mkassets.py` now writes stored.** mgl's reader
carries an inflate and a window table to drive it; deleting that is most
of the point. A member by any other method is REFUSED rather than read
as though it were stored -- the difference between a missing file and
plausible garbage. The archive goes 236,287 -> 570,377 bytes on disk,
which nothing here is measured in.

It walks the LOCAL headers rather than the central directory. Reaching
the directory means scanning backwards for a signature past a comment of
unknown length; walking forward from byte 0 needs no such guess, and
sixteen members is sixteen seeks, once.

**The extra field is the trap, and our own archive cannot catch it.**
mkassets writes no extra field, so the skip past one is dead code
against every asset we ship -- and a reader that forgets it lands 28
bytes into the data of any archive from any other tool. `t25zip` builds
a second archive with the SYSTEM `zip -0`, which stores a 28-byte
timestamp field on each local header, and diffs a read of it against the
same member extracted by `unzip`. Mutation-checked: drop the
`lh_xtralen` term and that case alone goes red.

`lm.bmp` is still loaded by `uglNewBMPEx`, which reads the archive
through mgl's own uar. That keeps working because mgl reads stored
members; it goes when the lightmap atlas becomes a Surface.

One thing this cost that was not the reader's fault: `t25zip`'s clamp
case asks for 4096 bytes of a 320-byte member and its buffer was 256,
so the 320 it correctly returned ran into the reference buffer behind
it and the compare two cases later failed. The reader was right for an
hour of looking at it. Size a test's buffer for the largest read the
test makes, not for the one the case in front of you does.

## Retiring mgl, module by module: screen.bas

`screen.bas` was the first module cut over, and it was not a port so
much as a repair: the HUD's panels, bevels, bars and graphs went through
`uglRectF`/`uglHLine`/`uglPset` onto `h_dst_dc`, which has been a qgl
Surface since bd04500. mgl reads its scanline table at `DC_addrTB` (32)
where a Surface keeps `SF_addrTB` (38), so every HUD write landed at an
address read out of `zsf`/`zmode`, and a `-stats` run never returned:
no frame, no `error.log`, killed at 150s and at 600s under both cores.
`tools/check.sh --hud` is that run -- two ticks, unlit, so the fps still
reads 0 and every counter is fixed, byte-identical run to run -- against
`tools/ref/hud.bmp`.

What replaced what: `uglRectF` -> `qglDrFill`, `uglHLine`/`uglVLine` ->
`qglDrHline`/`qglDrVline`, `uglRect` -> `qglDrRect`, `uglLine` ->
`qglDrLine`, `uglPset` -> `qglSfPset`, `uglShadeRect` -> `qglDrShade`,
all with the same argument order and the same inclusive corners.
`uglSetVideoDC(8BIT, 320, 200)` for the loading screen is `qglVgaInit`,
and the loading palette goes in through `qglVgaPalette`. At the time of
that cut `vid_init` still set the real mode through mgl afterwards; it
no longer does -- see the mode/palette/shutdown cut below.

The palette is no longer read back from the DAC. `mkassets.py` writes
`pal.raw` (768 bytes of `color/palette.lmp`) beside the atlases,
`scr_pal_load` reads it with a plain OPEN, `scr_pal_fit` is mgl's
`uglPalBestFit` in BASIC (6-bit channels, green 59 / red 30 / blue 11
squared, entry 0 never chosen), and the screenshot writes those bytes.
That moved `tools/ref/bench.bmp` by ZERO pixels and 254 palette entries:
the old reference carried mgl's 6-bit DAC read-back (every value a
multiple of 4), the new one the 8-bit palette. `imgdiff` says `DIFFER 0
of 16000` for that case, which is not IDENTICAL and not a picture change
either.

Two headers stay included for their types alone: `ugl.bi` for `RECT`,
which `mouse.bi` names, and `mouse.bi` for `MOUSEINF`, which `q_env.bi`
names. Those go when the input state does. `RGB` is a reserved word to
BC -- `type Rgb` fails with "Identifier expected" at every use and
nowhere near the definition -- hence `PalRgb`.

## Retiring mgl: the mode, the palette and the exit

`uglInit` stays and `uglEnd` stays -- mgl still owns the paged-array
stores, the lightmap atlas and `uglBuildSurf`, and `uglNew` refuses
before `uglInit` has filled the DC-type table. What went is everything
between them that touched the adapter: `uglSetVideoDC` -> `qglVgaInit`,
`uglRectF` on the video DC -> `qglDrFill` on `qglVgaScreen()`,
`uglPalSet` -> `qglVgaPalette`, and all five `uglRestore` ->
`qglVgaShutdown`.

**The mode is now brought up TWICE and the restore has to survive that.**
`scr_begin_loading` enters 13h for the loading screen and `vid_init`
enters it again for the run, and `qglVgaInit` recorded the current mode
on every call -- so the second one saved 13h as the mode to go back to
and the program would have exited into a graphics screen, where BASIC's
error text is drawn as pixels and a failed run looks exactly like a slow
one. It records on the first call only. `t26mode` is the regression: set
mode 3, init, init, shutdown, and read `0040:0049` -- the adapter's own
record of the current mode, not qgl's byte. Mutation-checked.

**Paging is gone, not disabled.** `display.pages` and
`display.usepaging` are out of `stuff.ini`, `EnvType` and the parser,
with `uglSetVisPage`/`uglSetWrkPage`. It was mgl's, it needed mgl to own
the mode, and the ini has shipped `usepaging = no` throughout -- so the
branch was dead before this and impossible after. `vid_update` takes
only `g` now; the backbuffer is the only destination there is.

**`mouseInit` takes the qgl screen Surface, and that is safe for two
specific reasons, not by luck.** `mouseReset` reads `xMin`/`yMin`/
`xMax`/`yMax`, which sit at identical offsets in `DC` and `Surface` --
the two structs are the same up to the scanline table, which is where
they diverge (38 against 32). And every mgl routine that would DRAW
through that handle -- `cursorPut`, `bakgrdGet`, `bakgrdPut`, the ISR's
own move path -- returns early while the cursor is hidden, which it is
from `mouseInit` onward because nothing here calls `mouseShow`. Adding a
`mouseShow` would put mgl's filler on a Surface at `DC_addrTB`, which is
the wandering-write bug in this file's other notes.

Dropping `Game.pal` and three `EnvType` fields moved `Game` under the C
side by eight bytes, and both hardcoded offsets -- `GAME_VIS_OFFSET` in
`r_walk.c`, `GAME_DLIGHT_OFFSET` in `sb_build.c` -- had to follow. The
startup assertion is what said so, by name and with the measured number
to paste in. Removing a field ahead of `vis` is a C change too.

`g.pal` and its `uglPalLoad` are gone with the rest: `pal.raw` and
`scr_pal_load` have been the palette since the screen.bas cut, and
`scr_hud_colors` is now `scr_pal_install` -- it puts those bytes in the
DAC and then best-fits the overlay against them, in that order, because
the second cannot run before the first.

## Retiring mgl: the paged-array stores

`uglArrLoad`/`uglArrMap` are `qglArLoadBas`/`qglArMap` in model.bas,
r_bsp.bas and pl_move.bas -- nodes, leaves and clipnodes, MEM first
and EMS on a refusal, as before. `qglArLoad` streams the member in
through `qglArWin`, a page payload at a time, so the seam padding is
the store's own arithmetic and not the loader's.

**The three stores came up all zeros, and every instrument agreed.**
Handles live, counts right, descriptors bound to the right segments,
the read reporting every byte -- and 17,820 bytes of nothing. `-qglarr`
passed on the same loader. The loader tested `qglArWin`'s pointer with
`or ax, dx` and stored `ax` AFTERWARDS, so the destination offset was
`0 | segment` and every read landed that many bytes past the window:
in the renderer 53,961 bytes past a 22,926-byte block, which is
somebody else's memory. What found it was the native `t27arload`
dumping the MEM store: its contents were the file shifted by exactly
7,459 bytes, and 7,459 is 0x1D23, the window's segment.

**`-qglarr` passed because it could not fail.** Its loader arm freed
the hand-filled EMS store first, and the loader's store got the same
pages back still holding the fixture; a loader writing nowhere near
the window read back a perfect copy. The hand-filled store now stays
alive across the loader arm. Both tests were watched to fail with the
bug put back.

## Retiring mgl: every EMS page goes through qglGemMap

mgl's `emsAlloc`/`emsMapEx`/`emsFree` and `uglNew(UGL.EMS)`/`uglMapEx`
map nothing now. The colormap, the luxel atlas and the geometry store
are `qglArLoadBas` EMS stores of one row per record -- 16384x1, 8192xN,
8192xN -- and `mod_cm_map`/`mod_lm_map`/`mod_geom_map` are `qglArWin`.
The model's vertex page is raw `qglGemAlloc`/`qglGemMap`, and ar.asm's
EMS backend is `qglGem*` too, so the native suite no longer needs an
`emsstub`. `lm.bmp` is `lm.bin`: the same bytes, top down, without a
header to un-flip.

**The per-slot record moved into `qglGemMap`.** mgl's `emsMapEx` kept
one and ar.asm leaned on it, asking for its page on every access; a
store keeping its own "I mapped page N here" is wrong the moment another
store sharing the slot takes the window. `qglGemFree` forgets the handle,
because EMM hands a freed number straight back to the next allocation
and a surviving record would answer its first map with the old page.
`t28gemmap` hooks INT 67h and counts function 44h, so "no remap" is a
number: the same page again costs none, a new page one, a slot 4 request
none and a 0. Both halves were watched to fail with the code put back.

**Two `@@:` in one loop is one label too many.** `qglGemFree`'s forget
loop ended `loop @B` with an `@@:` in front of `add bx, 2`, so it went
back to that one and only slot 0 was ever asked. Named labels for
anything a second jump targets -- the plan file says so, and this is why.

**Arm the case before trusting the mutant.** The first version freed
with page 1 on record and then asked for page 0, so the map issued
whatever the free had forgotten, and the forgetless mutant passed. The
test now maps page 0 before the free -- and with that armed, the real
code failed too, which is how the loop above was found.

## Retiring mgl: memory and the selftest that could not fail

`memCopy` is `qglMemCopy` (d_surf.bas, sb_build.c), `memAvail` is
`qglMemAvail(QGL_MEM_LARGEST)` in the memtrace and gone from bench.txt
-- `qgl_avail` had been beside it saying 64 bytes where it said
246,848, and the difference is BASIC's heap, not free memory --
`emsCheck` is `qglGemFrame`, and `-dumptex` reads its palette from
`pal.raw` instead of the DAC. The timer is `qglTmrInit`/`qglTmrTicks`/
`qglTmrShutdown`, `t29tmr` proving the BIOS chain and the restore, and
`qglTmrCycles` is the RDTSC that came from the sound mixer.
`uglInit`/`uglEnd` are gone from production too: what they did for us
was link the upper memory blocks and set strategy 81h, which is
`qglMemInit`/`qglMemShutdown` now, `t31meminit` reading both back
through DOS's own 58h queries. `-qgldiff` brings mgl up and ends it
itself, being a differential against mgl by design. The music player
-- snd.bas, `sound.enabled`, `mymod`, the HUD's VU meters -- is deleted
rather than ported, and with it the last mgl call in production; the
hang its init had is gone with it. `Env.sound` sat ahead of `vis`, so
both C offsets moved by two. The camera's matrices are `qglM4Persp`/`qglM4LookAt`/
`qglM4Conc` in `src/qgl/m4.asm`, mgl's `mdu3d.asm` FPU sequence kept
instruction for instruction because `tools/ref/bench.bmp` is a
byte-for-byte reference and a rounding that moves by an ulp moves it;
`t32m4` checks them on values a real4 holds exactly, and the bench
staying IDENTICAL is the real test. `u3dVector3f` folded into bspfile.bi's own
`Vec3`, the same three singles; `u3dMtrx` is `Mat4` beside it; `u3d.bi`
is out with the rest. `ugluCubicBez3D` is `v_bezier` in view.bas, the same
forward differencing in BASIC, and `ugl.bi`, `uglu.bi`, `dos.bi`,
`arch.bi`, `font.bi`, `pal.bi` and `ems.bi` are out of every module
but the three oracles; `PalRgb` moved to bspfile.bi so mod_tex reads
pal.raw through it instead of mgl's `tRGB`.

**And then the oracles' mgl halves and the library itself.** `-qgldiff`
keeps the exact-answer oracle and pins coverage and texel distance to
the figures of the last differential run; `-qglarr`'s reference is the
fixture read straight into a BASIC array, and its hand-fill maps pages
through `qglGemMap`. `UGLV.LIB` is off the LINK line with mgl's `U3D.OBJ`,
no tool mounts the mgl tree, `ugl-patch/` and the native mgl build are
deleted, and the qgl benches that raced mgl went with them. The bench
stayed IDENTICAL through every step.

**The depth buffer is conventional memory first, EMS on a refusal.**
With the per-texture DCs, the font DCs and the library gone the
memtrace shows 303,648 bytes in BASIC's far heap before it and 268,080
after: 160x100 of depth is 32,000 bytes, and a page the fillers no
longer map. 320x200 wants 128,000 and takes the EMS path as before.
The bench stayed IDENTICAL. A six-run interleaved campath A/B against
the EMS build was NOT a measurement: another emulator was running on
the host and the spread was 15ms an arm on a 54ms frame, medians 53.9
against 53.7. Repeat it on a quiet host before quoting a speed.

**`sc_selftest` wrote its row through mgl and read it back through
mgl, on a qgl Surface.** `uglRowWriteBuff`/`uglRowRead` take the
scanline table at `DC_addrTB`, 32, where a Surface keeps it at 38, so
both went through an address read out of the depth fields -- the same
wrong address, so the bytes came back equal and the test said 1 while
32 bytes landed somewhere else on every bench run. The write goes
through `qglSfWrRow` now and the readback through `qglSfPget`, which is
the surface's own pixel path and cannot agree with a write that missed
it; `check.sh` reads `sc_test` and wants 1. Aiming the write at row
126 reads -12 through that gate. Every other `-1..-55` was the same
instrument reporting on itself, so treat a green selftest as one
measurement, not fifty-five.

## Retiring mgl: the keyboard and the mouse

`src/qgl/kbd.asm` is mgl's INT 9 hook with the same table -- a word per
scancode, -1 down, word 0 the last code, `Keys` in `in.bi` keeping
TKBD's names so `g.env.keyboard.w` reads as before. `src/qgl/mouse.asm`
keeps its own cursor from the driver's mickeys, one pixel each, clipped
to the mode, and `qglMousePos` places it -- which is how the spawn yaw
and a teleport's facing are applied, so the clip range is part of the
picture. Both unhook on either exit; mgl did it from `uglEnd`'s queue.

**`t30in` drives the keyboard hook through the emulator, not a call.**
`run1.sh` types whatever a test's `keys` file says a second in, via
DOSBox-X's `AUTOTYPE`, and the test spins on the table until scancode
1Eh comes down and goes up, bounded by the BIOS tick. The mouse cannot
be moved headlessly, so `qglMouseEvent` is public and the test calls it
the way the driver does, mickeys in `si:di` and buttons in `bx`. Mutated
three ways: index by scancode instead of scancode*2, no word 0, no clip.

`AUTOTYPE` feeds the keyboard buffer from a host thread with no lock
against the emulation thread, and under load -- three gates and a
windowed run at once -- it dropped one release: down seen, up never,
the hook restored fine. The test types the key three times now, so a
later pair still shows both transitions; the assertion is unchanged.

**A multi-line mutation pattern misses a CRLF file.** The first clip
mutation "passed": its pattern spanned two lines with `\n` between,
matched nothing in a `\r\n` file, the assert failed inside a helper
the script did not stop on, and the unmutated source ran green. One
line per pattern, or match the line ending.

## Portal culling and the composite HUD

Ported from `alim/portal-culling`, which was written against mgl and the
flat `src/` layout; `docs/portal-culling.md` is its design note.

**The flood refines the PVS, so on and off must draw the same picture.**
`tools/mkportals.py` rebuilds the portals a compiled BSP no longer
carries and `mkassets.py` ships them as `portalidx.bld`/`portalref.bld`
in assets.zip, held to the PVS-subset check on every build -- a map whose
portals do not cover the PVS fails `make assets` rather than culling what
it should have drawn. `r_portal.c` floods from the camera's leaf every
frame with a shrinking screen rectangle and writes `pvs_now`, which the
walk reads instead of `pvs_buffer_b`; a negative return is a bail and the
PVS is copied through unchanged. `tools/check.sh --portal` is the gate:
the bench frame with and without `-noportal` must be IDENTICAL, and the
on run must report `portal_culled` above zero, or the identity is
vacuous. P toggles it, O outlines the portals the flood went through,
`-ptwire` starts with the outlines on.

**It is a net loss on dm3ish and is on by default anyway.** The branch
measured the campath at +4.03 ms with the flood on: the map is small and
the PVS already tight, so the flood costs more than the leaves it cuts
save. It is here for the maps where that reverses, and `-noportal` is
the A/B.

**`-comp` writes video memory once a frame.** The view is scaled into a
mode-sized conventional Surface, `scr_draw_hud` draws onto that at 1:1
-- it takes the destination's width and height now, not `x_res`/`y_res`
-- and one `qglDrBlit` carries the result to the screen. Without it the
overlay is drawn into the render target and magnified with the view.
`-bench`'s BENCH.BMP is still the render target, so under `-comp` it
carries no overlay; the HUD gate runs without `-comp` for that reason.

**Adding a field to `Env` or `RenderState` moves `GAME_VIS_OFFSET` and
`GAME_DLIGHT_OFFSET`**, in r_walk.c and sb_build.c: 4958/4942 became
4970/4954 here for `h_comp_dc`, three flags and `rdr.portal`. The
startup assertion says so, with the number to paste in.

## The game layer

The fight lives in `pl_move.bas` because it traces, and `pl_trace`'s
clip buffer is that module's `dim shared`: the shotgun (`pl_fire`), the
soldiers' think (`mdl_think`, 10 Hz on `anim_time`), the pickups and the
reset. The player's side of it is `Game.fight`, a `PlayerCombat` placed
AFTER `vis` so the C offsets stayed put; `MdlEnt` is an array element
and grows freely.

**The vertex page is the frame budget.** One EMS page holds the whole
model: 170 vertices x 3 bytes = 510 a frame, 32 frames = 16,320 of
16,384; the triangles are page 1 of the same handle, read by
`d_alias.c` through `CM_SLOT`. `stand,run,death,pain` fills it; the soldier's shoot set does
not fit, so a volley has no animation. `mkmdl.py` emits the frameset in
the order given and writes each set's count into the `.geo` header --
stand, run, death, pain, attack, by position -- so the Makefile's list
IS the frame layout and `MdlState` carries it. The knight's 108
vertices leave room for `attackb`, which is why it is the second
monster: `MdlEnt.kind` picks `g.mdl` or `g.kmdl`, every other spawn
is a knight, and `mdl_think` takes the `MdlState` it animates.

**The dog is the third kind, and it bites on the run.** dog.mdl has 236
vertices, so the page holds 23 frames: `stand:1,run,death,pain:1` --
mkmdl.py's `:n` keeps the first n of a set -- and no attack set. So
`mdl_think` bites from the run cycle: within 100 units with a clear
line, `(r+r+r)*8` once per 0.8 seconds, dog.qc's cycle without its
frames. Its run steps are dog_run's 16..64 a frame, which is why a dog
closes so fast. The leap is CheckDogJump and dog_leap2: 80 to 150
level units off with the player's body at its height, it faces them
and takes 300 forward and 200 up as a velocity, the one MOVETYPE_STEP
in the air here -- gravity at each 10 Hz think, a trace along the
velocity, the player's box met above 300 u/s bitten for 10 + 10 *
random once (Dog_JumpTouch), a stop while falling the ground and the
run again. It has no leap frames on the page, so it flies through its
run cycle. e1m1 on easy has one, at (88,1520,-200); the e1m1 gate counts
it by kind, and its tenth arm stands 120 units from it and wants
`pl_leaps` above zero. `MDL_MAXV` is 236 in
d_mdl.bas and d_alias.c both: at 191 the dog loaded past the BASIC
check and overran the C scratch, and e1m1 died in `runtime error 14`,
out of string space -- a corrupted near heap, not a full one. The
memtrace prints `fre("")` as its third column now, so the next
error 14 can be told from a real exhaustion in one look.

**The ogre and the demon are kinds 3 and 4**, `mon()` in main.bas
holding one MdlState a kind. The ogre's page is `stand:1,run,death,
pain:3,shoot` (169 vertices, 32 frames): it saws on the run within
ai_melee's 100, swing5..11's `(r+r+r)*4` every other think with no saw frames
on the page, and past melee range throws OgreFireGrenade from shoot
frame 2 at CheckAttack's 0.2 near and 0.05 mid. The grenade is a
`Spike` with `grenade` set: `pl_nails_tick` flies it under gravity,
bounces it off hull 1 at ClipVelocity's 1.5, and blows it up on the
player's box or at 2.5 s -- T_RadiusDamage's 40 less half the
distance, to the player alone. The demon's page is `stand:1,run,
death,pain:3,attacka` (143, 34 of 38): attacka's charge strides with
the claws on frames 5 and 11, 10 + 5 * random within 100, and
CheckDemonJump's leap from 100 to 200 level (past 200 one think in
ten), 600 forward and 250 up, 40 + 10 * random past 400 u/s -- the
dog's leap state with its own numbers, and both draw the run cycle
in the air now; the dog drew its last pain frame. e1m2 on easy has
four ogres and a demon; the e1m2 gate's fifth arm stands 146 units
before the ogre at (1790,-146) for six seconds and wants a bite with
the ogre hunting -- health under 100 or a death, since it kills in
that time and the respawn reads 100.

**The zombie and the wizard are kinds 5 and 6**, their four sounds at
`SND_MON2` since the table after the first five kinds' is taken;
`mdl_say` picks. The zombie's page is `stand:1,run:8,death,paina:8,
atta` (177 vertices, 30 frames): no death set, since zombie_die is a
gib -- a dead one with `ndeath` 0 is not drawn -- and no paine, so a
dropped one lies on paina's last frame. zombie_pain's rules are in
`mdl_damage`: the health back to 60 after every hit, so only one hit of
60 kills (the SSG's 56 does not, as in Quake); under 9 ignored; 25 or
more, or any hit, sets `pain_finished` -- three seconds down, or one
flinching -- and nothing flinches it again before. CheckAttack with a
th_missile alone (0.9 / 0.4 / 0.1) starts `atta`, and frame 13 throws
the gib: a `Spike` with `grenade` and `gib` set, ZombieFireGrenade's
600 toward the player with 200 up, that bites 10 where it lands on
the player's box, stops dead on a wall and goes out at 2.5 s with no
blast. The wizard (80 vertices, all 54 frames) flies: `mdl_flystep` is
SV_movestep's FL_FLY case -- a straight trace, 8 up or down toward 30
to 40 above the player while hunting, once more level when blocked --
and `mdl_spawn` does not drop it to the floor; WizardCheckAttack's 0.9
/ 0.6 / 0.2 starts `magatt`, frames 3 and 8 fire Wiz_FastFire's spikes
(hostile, 600, 9), two seconds to be ready. Its corpse stays in the
air. `tools/check.sh --e1m3`'s third and fourth arms stand inside
RANGE_MELEE of one of each -- outside it a wanderer must be facing the
player, and the zombie at (800,-216) wanders off in the first second --
and want health under 100 and the kind hunting.

**BC reads a user FUNCTION inside a CALL-less SUB's argument list as an
array.** `snd_play g, mdl_snd( ent.kind, 1 ), ent.pos` was `Argument-
count mismatch` at every site, the DECLARE in place and the function
compiling; `l = mdl_snd( ent.kind, 1 )` on the line before compiled.
Assign to a local first, or make the helper a SUB, as `mdl_say` is.

**A monster that only looks while standing never sees anyone.** The
port called FindTarget from `ai_stand` alone; id's `ai_walk` calls it
every frame too, and a player who fired within the second is noticed
from behind at RANGE_NEAR (`show_hostile`, W_Attack's `time + 1`;
RANGE_MID has that term commented out in ai.qc and still wants
infront). Before this, ten seconds beside a knight cost no health at
all: all eight were wandering, and a wanderer never looked.

**The first bench run in which anything hurt the player crashed with
`runtime error 9 at line 0`.** `scr_pal_shift`'s shifted palette was a
module-level `dim shared` under `'$DYNAMIC` in screen.bas, allocated on
first use behind a `ubound()` test -- and `ubound` of an array that was
never allocated is itself error 9. It is `redim`med in `scr_pal_load`
now, and `tools/check.sh --fight` stands ten seconds beside the knight
at (464,-40): health must drop and nothing may crash.

**Finding a `runtime error 9 at line 0` with the debugger.** Line 0 is
all BC says without line numbers, and `ON ERROR` swallows the address.
What worked: a conf whose autoexec stops at `C:\>` and `core=normal`
(breakpoints do not fire on the dynamic core), `dosbox_load_and_run_to`
the program with `B$RUNERR` as the name -- it stops at the entry with
symbols loaded -- then `bp_set B$RUNERR` and continue. At the stop
`[SP+2]` is the far return address into the BASIC module; subtract
`loadLinear` and the MAP's publics name the procedure. Ack the stale
`process_exit` first or the shell command is refused.

**`make assets` will not rebuild the model for a frameset change** --
the rule depends on the pak and the tool, not the Makefile. Delete
`data/assets/soldier.geo` first, and check `nframe` in the header.

**The HUD's footer draws under `-nostats` too**, so the status line and
the crosshair moved `tools/ref/bench.bmp` and `hud.bmp` -- by the text
rows and four centre pixels, checked with a bounding box each time.
The state messages do not: a bench, ticks or campath run starts in
`GS_PLAY`, where nothing is drawn but the crosshair.

**`cam.look_at` is a POINT once `v_update_camera` returns**, one unit
from `cam.pos` in the direction of the view; it is a direction only
inside that routine. The first shotgun aimed along the point and every
pellet flew from the origin; the view weapon built from it turned by a
position and drew nothing -- 0 triangles, `vmdl_loaded -1`, and the
memtrace's cap of 20 marks had hidden that the second `mdl_load` got
through at all. Subtract `cam.pos` first. `MEM_MARKS` is 40 now and
`mdl_load` names the step it stops at.

**The view weapon is v_shot from the PAK**, `mdl_draw_view`: the model
at the eye, turned by the view's yaw and pitch -- `mdl_draw_tris` takes
the pitch as a cos/sin pair, applied in model space before the yaw --
and drawn last with depth off, as Quake does. `shot2..` play at 10 Hz
from the shot. `-noview` leaves it out, which the model gate needs:
its away tick asks that the soldiers add nothing. Both references
carry the gun now.

**`weapon_supershotgun` is v_shot2 and W_FireSuperShotgun**: the
pickup is an item kind that puts it in hand with five shells, `1` and
`2` choose (W_ChangeWeapon, `pl_select_weapon`), and a shot is 14
pellets at 0.14 by 0.08 for two shells, 0.7 to be ready -- or the
shotgun's six with one shell left. `fight.items` holds the weapons
owned as bits and `fight.weapon` the one in hand. mkmdl.py writes
`<name>.vtx` and `<name>.skn` beside the `.geo` now: the old
`<name[:5]>vtx.bin` cut v_shot and v_shot2 to the same v_sho. In hand
it shows as a band four rows deep above the bar, 40 pixels: its top
edge is 6 units under the eye 14 forward, and this view's centre is
the frame's, where Quake's is the centre of the rows above the bar --
8 rows higher on 100. Rendering above the bar instead of under it would
move every reference; not done.

**`weapon_nailgun` is v_nail and W_FireSpikes**: the pickup brings 30
nails and `item_spikes` 25 or 50, capped at 200; `3` chooses it; a
nail every 0.2 s leaves 16 up and 4 to alternating sides at 1000 u/s
and lives in `nail()`, `PL_NAILS_MAX` of them (`Spike`, no gravity:
MOVETYPE_FLYMISSILE). `pl_nails_tick` steps each along its velocity
through `pl_trace` -- hull 1, so a wall stops it 16 early, as the
pellets -- bites the first monster on the way for 9 (spike_touch),
fires a shootable trigger or secret door, and ends it on a wall or at
six seconds. In flight it is a two-unit box, no spike.mdl. The bar's
ammo is the weapon in hand's, `SB_NAILS` cell 19. The e1m1 gate's
fourteenth arm stands on the nailgun with fire held a second and wants
27 nails: 30 less three shots.

**`weapon_grenadelauncher` is v_rock and W_FireGrenade**: the pickup
brings five rockets and `item_rockets` 5 or 10, capped at 100; `4`
chooses it; a grenade every 0.6 s leaves at 600 along the aim and 200
up, the ogre's `Spike` with `grenade` set and `dmg` 120 -- the ogre's
carries its own 40 in `dmg` now. `pl_grenade_tick` is either side's
MOVETYPE_BOUNCE, split out of `pl_nails_tick`: what it can hurt over
the step blows it up (the player's box for an ogre's, a monster's for
the player's), else gravity, a hull-1 trace, the bounce; the fuse is
2.5 s and `pl_grenade_explode` is T_RadiusDamage to the player and,
for the player's own, every monster standing. `SB_ROCKET` is cell 20
of the bar's band, the last that fits in 512. `tools/check.sh --e1m3`'s
second arm stands on e1m3's launcher and fires at the ceiling (`-pitch
89` looks up) for four seconds: rockets under 5 and a blast felt from
the grenades falling back (health -70 the first time,
so a death counts too). The launcher's model and code ran e1m3 out
of string space (3.2K after depth, error 14 in the first frame); cut:
`SC_NBLK` 1024 to 512, the bound its own comment gave (7K), `pt_idx`
freed when the portal table bails (3K on e1m3), `item()`'s backpack
room the map's monster count instead of 48 (0.8K) -- 14.5K after
depth on e1m3.

**`weapon_supernailgun` and `weapon_rocketlauncher` are v_nail2 and
v_rock2**, `5` and `6`, `PL_IT_SNG` and `PL_IT_RL`. The super nailgun
is W_FireSuperSpikes through `pl_fire_nail`: with two nails a shot
from the middle for 18 and weapons/spike2, with one the nailgun's
nail; a nail carries its own `dmg` now. `pl_fire_rocket` is
W_FireRocket, a `Spike` with `rocket` set, 1000 straight along the
aim from 8 before the origin, 0.8 to be ready; `pl_nails_tick` flies
it as a nail and where it stops -- a monster hit for 100 + 20 *
random, the box, a switch, a wall -- `pl_grenade_explode` blasts 120
from there (T_MissileTouch); one that hits nothing is gone at 5 s,
unexploded, as SUB_Remove leaves it. Both quad in the tick. And
`pl_nail_free` clears the flags of the slot it hands out: a nail
fired into a spent grenade's slot kept `grenade` and bounced. The
e1m4 gate's second arm stands on the map's super nailgun with fire
held a second and wants weapon 64 and 49 nails, its 30 and the pack
beside it less three shots; e1m4's rocket launcher is deathmatch-only, so the launcher's arm
waits for e1m5. That arm found `pl_items_drop` tracing the origin
itself through hull 1: an item the map put within 24 of its floor
started inside the grown solid, and where a room lay under it within
256 -- the super nailgun's, 192 down -- it fell through, while one
dropped from higher stopped 24 above the floor and floated. It
traces from `PL_FEET` above the origin now, SV_ClipMoveToEntity's
offset of the hull's clip_mins against the item's mins, and lands
the origin on the floor.
The view models load lazily: v_shot at host_init and the rest the
first time their weapon is in hand (`host_view_load`, from the tick).
Each costs the far heap 600 bytes, and with all six loaded at init
e1m4 read 3,984 after the depth buffer and died in error 14 at the
bench write -- which `run_frame` took as a run, since a 54-byte
header-only BENCH.BMP existed; it wants 1,000 bytes now.

**The shambler is kind 7**, `stand:1,run,death,pain,magic` on its
page (144 vertices, 36 of the 37 frames that fit), health 600. It
smashes on the run in RANGE_MELEE, sham_smash10's (r+r+r)*40 landed
as the swing starts, once per 1.2 s, and past that -- ready, a clear
line, within 600 -- runs the magic set: `mdl_bolt` on frames 5, 8
and 9 is CastLightning, a line from 40 up toward 16 above the
player's origin traced 600 through the world and LightningDamage's 10
where it crosses the player's box; nothing is drawn for it. sham_pain
flinches only when random() * 400 is under the hit. Its four sounds
sit at SND_MON2 + 8; melee1, smack and sboom follow the rocket's
sgun1. e1m5 is in `MAPS`: `tools/check.sh --e1m5` is its spawn
frame, the shambler arm (128 units before it, past the shut door that
hides it from farther off: the lightning, then the smash, a hit and
hunting) and the rocket launcher arm (on it, one rocket fired straight
down). That rocket stops on hull 1's floor at the origin -- a rocket
is traced as the nails are, and id's 8 forward would start one aimed
at the floor inside the grown solid and carry it through unstopped,
so it leaves from the origin -- and its blast is T_RadiusDamage's,
halved for its owner (`head == attacker`): 59 at the feet, health 41,
as the gate reads. The rule reaches the grenade launcher too.

**e1m6, e1m7 and e1m8 are in `MAPS`**, each smaller than e1m4 in every
lump, with spawn-frame gates. `sv_gravity` is the map's now:
`fight.gravity`, from the ents header, which mkassets sets to 100 for
e1m8 as world.qc does and 800 otherwise; the player's fall, a leap
and a grenade all read it. The e1m8 gate holds jump from the spawn,
which hangs 630 over its floor, and at tick 400 wants the body over
-600: the jump goes 364 up by v^2/2g against 48 under 800. `peak_z`
read 0 on any map under z 0 -- nothing set it -- so `pl_init` starts
it at the spawn, and the gate wants e1m8's -104. Not ported: Chthon (`monster_boss`, no kind; e1m7 ships
without it), `trigger_monsterjump` -- e1m6's one sits at the foot of a
targeted door and no easy-skill monster can reach it, so no arm;
`func_wall` draws as any solid brush model.

**The powerups are thirty-second clocks on `fight`**: the quad
(`quad_until`) makes every pellet and nail four times (T_Damage's
super_damage_finished), the envirosuit (`suit_until`) turns the slime
off and lava down to a bite a second, the pentagram (`pent_until`)
makes `pl_damage` return -- T_Damage's invincible_finished, protect3
two seconds apart while it does; e1m8's gate stands on its own. Slime and lava hurt at all now,
`pl_env_damage`, PlayerPreThink's 4 and 10 a water level; e1m1 has 112
slime leaves and no lava. `misc_explobox` is an item that is shot, not
taken: 20 health against the pellets and nails (`pl_box_ray`, its brush
plus the touch slack), then barrel_explode -- 160 less half the
distance to the player through the armor and to every monster standing,
CanDamage's line not asked. Drawn as its 30x30x62 box, and solid:
`pl_trace.c` keeps a table of up to eight boxes (`pl_boxes_sync`) and
sweeps every trace against each one grown by the player's hull-1 box,
so the monsters walk round it too. Four e1m1 arms: the quad taken,
two seconds in the slime pool, the box shot from 100 units.

**Pickups are the map's own `item_health`/`item_shells`**, shipped in
`ents.bin` after the hides, dropped to the hull floor at load, and drawn
as flat boxes by `mdl_draw_box` in `d_alias.c` -- six quads, no clip
beyond "any corner behind the near plane drops the box", which at ten
units wide means the player is in it. A box far down the hall is in
the bench frame: 24 pixels at the centre. `item_armor1` and `item_armor2`
are two more kinds, 100 at 0.3 and 150 at 0.6: armor_touch takes one
only when type * value beats what is worn, and `pl_damage` is T_Damage's
split, the armor taking ceil(type * damage) and losing its type with its
last point. The bar shows the icon and the count at 0 and 24 while any is
worn -- Quake draws a 0 there too, left out so the references stand.
`trigger_secret` is a once with "You found a secret area!" unless the map
says, counted in `fight.secrets`; six on e1m1. The e1m1 gate's last two
arms stand in `*44` and on the green armor.

**The b_*.bsp pickups are textured crates.** Health, shells, nails,
rockets and the exploding box are Quake's own brush models, six-face
boxes from the origin with two to five 32-pixel textures; mkassets
(`crate_src`, given the PAK as its fifth argument) cuts each one the
map uses into a `CrateModel` in ents.bin -- the size and five faces,
the bottom left on the floor, each an atlas id, a +N frame count and
four corners as (axis bits, u*32, v*32) bytes -- and appends the
textures to the map's atlas after its own, frames consecutive, so
`mod_tex_shaded` aims at them as at any cell (q_map.bi's `ofs(1023)`
holds 256; e1m1 uses 81 + 23). `mdl_draw_crate` in d_alias.c draws
the five quads through the mip views, affine as the models are, the
chain stepped at 10 Hz; an item's `crate` is -1 for the kinds Quake
draws as alias models -- armor, keys, weapons, powerups -- which stay
flat spinning boxes. A crate stands still, centred on the origin as
the touch and the exploding box's trace already are, where Quake's
spans origin to origin + size. Its cost is the record, 92 bytes a
model used, and the cells in EMS. Every image reference moved with
it, the crates being in most of them.

**The status bar is Quake's own, out of gfx.wad.** `tools/mkgfx.py`
writes `sbar.raw` and `sbnum.raw` -- the bar, the digits, the shells
icon and the five faces -- with the qpic's 255 kept transparent: the bar
is textured differently under every slot, so nothing can be composited
offline. Everything lives in ONE EMS surface, 512 wide because an EMS
row must divide 16K: the untouched bar in rows 0..23, the twenty
cells side by side in 24..47, the composed bar in 48..71, which a
320-wide view aimed at row 48 hands to the blit. `scr_sbar_paint`
copies the bar band over the working band and pokes each cell's opaque
pixels through the read window (slot 0) and the write window (slot 1),
only when health, shells or the face change; `scr_sbar_draw` scales the
result into the bottom twelfth of the render target. The far-heap
tables this replaced -- rows, cells, spans -- were 28K, which e1m1 does
not have. Traps: the wad's names are uppercase; a `const SBAR_FACE` and
a `dim sbar_face` are the same name to BC; the scaled blitter's 8.8 step
was a 16-bit divide that truncated any source wider than 255
(`t15blit` case 7); a `get` reads the whole fixed string, so a 576-byte
cell buffer swallows 576 bytes of a 320-byte bar row; and `p \ 65536`
on a far pointer truncates TOWARDS ZERO, so a window at E000h -- a
negative long -- came out one paragraph high and every digit was read
sixteen bytes off. `scr_seg_of` subtracts the low half first.

**Sound is a Sound Blaster at 220h, polled.** `src/qgl/dsp.asm` is
Quake's snd_dos.c on the SB16 path: reset, version 4 or nothing, a
4096-byte ring from `qglMemAlloc` aligned to 4096 so it never crosses a
DMA page, filled with 128 (silence is not zero), DMA channel 1 in
auto-init -- the mode byte is 59h; 58h is channel 0, and `t34dsp` fails
on it -- and the DSP playing 8-bit unsigned mono at 11025 in blocks of
half the ring. Nothing waits for the interrupt: `qglDspPos` reads the
count register (flip-flop cleared, interrupts off) and `snd_mix.c`
paints a quarter second past it once a frame, between the tick and the
render, where no one holds an EMS window; a stub on IRQ 7 acknowledges
the block ends or the BIOS's iret leaves the PIC's in-service bit set.
The samples are `tools/mksnd.py`'s `snd.raw`, every wav the ported
QuakeC plays back to back at the DSP's own rate, in one EMS handle read
through `PAGE_SLOT`; `sndtab.raw` is the (offset, length) table in the
order of `q_pl.bi`'s `SND_*`, and `snd_init` refuses a count that
disagrees. A sound starts at Quake's distance falloff from where it
began, once, mono; eight channels, the one with least left is stolen.
The map's `ambient_*` points -- e1m1 has four comp_hum and a drone --
ship after the items in ents.bin and loop from sample 0 on 32 static
channels -- e1m2 has 20 drips and swamps, e1m4 31 -- placed from the
player every frame at ATTN_STATIC, three a thousand units; one out of
earshot costs the mixer its pointer arithmetic and nothing else.
`snd_loops` counts them. mksnd refuses a wav whose cue point is not
0, since the mixer knows no other loop start.
The ring and the mixer's scratch are one DOS block, not DGROUP -- that
is BASIC's string space -- and with the code they cost the e1m1 far
heap 16K. `-nosound` leaves the card alone; a machine without one fails
the reset and plays nothing. Every conf pins `[sblaster]` to the
emulator's own 220/IRQ 7/DMA 1, `[mixer] nosound=true` still advances
the DMA, and `viz` turns the sound on. `snd_started` and `snd_under` are
in bench.txt; the two underruns a lit run always shows are the first
frames, which build every surface.

**The mixer's scratch is dsp.asm's to size, and snd_mix.c checks it.**
`DSP_SCRATCH` was 1792 for a 1024-byte paint buffer, a 512-byte table
and 8 channels of 14; the 32 static channels ran 304 bytes past the
DOS block, and the 71 sounds past the 64-record table into the
channels, whose clear then zeroed records 64 and up. dm3ish never
noticed; e1m2 hung in BASIC's heap compactor once two more models
moved the block, with nothing in run.out and no error.log -- the
shape AGENTS.md's `B$FCompactMove` note describes. `snd_mix_setup`
takes `qglDspScratchBytes()` and returns -1 when its layout does not
fit, which `snd_init` reports (`0x0053`). A trace that stops at a
model's marks may just be `MEM_MARKS` -- 64 now; 40 ran out at the
eighth model's triangles.

## e1m1: the first id map

`tools/check.sh --e1m1` pulls `maps/e1m1.bsp` out of the shareware PAK,
builds its assets into `$VBD_OUT/e1m1-assets`, and compares two frames
with `tools/ref/e1m1-spawn.bmp` and `e1m1-exit.bmp`: the hall from the
spawn, and the exit slipgate from its approach. 5,516 faces, 2,750 nodes 62 deep, 1,531 leaves, a 40,843-byte
PVS, a portal table past 64K. Five things stood between the loader and a
frame, and the first is not e1m1's at all.

**DOSBox-X's dynamic core gets BASIC's long compare wrong.** BC routes
every `long` compare through the runtime's `B$CPI4`, which compares the
high words and, when they agree, turns the low words' carry into a sign
bit through `lahf`/`shr`/`shl`/`or`/`sahf`. On `core=dynamic` -- the
pinned core -- that sequence answered `23760 >= 40843` true and
`40843 > 32767` false; `core=normal` answered both right. Same binary.
The loader took the conventional-memory branch it could not afford and
the trace showed 41K leaving the far heap with every guard "passing";
three spellings of the compare all agreed, which is the second rule's
tell. `src/qgl/cpi4.asm` replaces the routine: the low words get their
sign bits flipped and a plain signed `cmp`, no flag surgery. The runtime
keeps `B$CPI4` in one module with `B$CMI4`, `B$MUI4`, `B$DVI4` and
`B$RMI4`, so all five live there or LINK pulls the module and reports
`L2025`; the three arithmetic ones are far jumps to the runtime's own
`__aFl*`, which `tfw.asm` stubs with an `int 3` for the native suite.
`t33cpi4` runs the six cases through BC's own calling sequence under
run1.sh's dynamic core and failed on the two straddling ones with the
original code in place. Every long compare in this program went through
that routine, so any past oddity involving one is suspect.

**BASIC links a 4K stack, and the C walk recursing 62 deep ran through
it** into the string space above: `String space corrupt`, raised from
`B$CompactSB` under `d_draw_faces` -- lazily, at the next compaction,
nowhere near the write. `tools/link-qr.sh` passes `/STACK:8192`. dm3ish
is 42 deep and never came close. e1m3 is 85 deep and ran 8K out too,
and a bigger stack comes straight out of the far heap (16K was `Out
of memory` at load), so `r_walk_rec`'s frame shrank instead: the
context it needs lives in one struct reached through a pointer and
the leaf and emit halves are their own routines, so the recursion
holds a node pointer and a side.

**A map whose portal table does not load must still walk its PVS.**
`pt_ref` is 6,624 x 7 x 2 bytes on e1m1, past a BASIC array's 64K, so
`r_load_portals` bails and `pt_ok` stays 0 -- and the walk reads
`pvs_now`, which only the flood writes. `pvs_count 78`, the offline
decode's number, and `polys 0`. The copy from `pvs_buffer_b` now also
runs when `pt_ok` is 0.

**Decide a store's placement by `qglMemAvail`, never by a refusal.**
`qglMemAlloc` answers a DOS refusal by shrinking BASIC's heap through
`B$SETM` and retrying, so "DOS refused, go to EMS" never fires -- the
allocation succeeds out of the memory the map needs. The PVS goes to EMS
when DOS's largest block is smaller than it, read through `PAGE_SLOT` by
`mod_pvs_page`, and `r_mark_leaves` steps its offset across the 16K
seams. The depth buffer decides the same way.

**Nodes, leaves and clipnodes cannot go to EMS.** `r_walk.c` and
`pl_trace.c` index those stores through flat far pointers; an EMS store
gives them one page and a cycle in `pl_hull_contents_c` that never
returns. Tried, hung, reverted.

**What the memory went on, and what was cut.** Conventional memory is
BASIC's far heap (334K) plus the UMB pool (82K), and `qglMemAlloc` makes
them one pool. The faces store takes 56K of UMB; the far heap goes
bsp_arrays 79K, leaves 34K, marksurf 14K, nodes 60K, clipnodes 32K,
textures 17K, surface cache 57K, models 12K. Cut so far: the status bar's
28K into its EMS surface, `face_mdl` (11K) into the bits above
`Face.side`'s one, written at load by `ent_load_teleports` and read back
as `side >> 1` in `d_faces.c`, and `CacheSlot.cls` (11K), which only the
selftest read and `sc_bord` already held per block. Then, for the dog:
a model's triangles into page 1 of its EMS handle (20K, the four arrays
and their plumbing gone), `Plane.ptype` (3.6K, never read), the campath
arrays only under `-campath` (3K). The nailgun and the powerups then ran
the far heap to 7.9K and `Out of string space` -- every kilobyte of code
is a kilobyte of far heap -- so the node and leaf bounds are six bytes:
`mkassets.py`'s `bound_bytes` writes `(v + 4096) / 32` a coordinate, the
min rounded down and the max up, `PackedBounds`; `r_cull_box_c` unpacks
to six floats up front and `r_leaf_bound` for the spawn scatter. Node
and Leaf are 16 bytes, 25.6K back: 33.5K of far heap after the depth
buffer with `MDL_MAX_ENTS` at 48 and three view models loaded, 17.6K
once the sound layer took its ring and its code, 16.3K with the
ambients. A box
only grows, so the walk marks a few more leaves: the world's pixels did
not move on any reference, but a pickup in the far doorway of
`tools/ref/bench.bmp` is drawn now and `hud.bmp`'s leaf counter reads
391 for 376 -- both regenerated, 20 and 12 pixels. The oracles are out
of the production link: `qglstub.bas` answers their flags with `0x0060`
and `make ORACLES=1` builds the EXE `check.sh` runs them from, 13K of
code. `sc_slot` is one integer a face now -- the block's generation tag
and style epoch sit on the block, `sc_btag`/`sc_bstag`, since they
describe its content and a face keeps only its block -- 22K back on
e1m2's 5,516 faces less 4K on the blocks. e1m2 plays: far heap after
the depth buffer 23,024 with eight models and the sound layer.

e1m3 (5,274 faces, 2,942 nodes 85 deep, 1,689 leaves; 7.3K after depth
with the zombie and the wizard loaded) loaded with 1K
and died in its first frame with 7K, and three cuts got it to 5.8K
after the depth buffer: the per-face frame stamp is a bit
(`pflag()` is faces/16 integers, `r_pflag_clear` zeroes it a frame,
the walk sets and `d_faces.c` tests a bit -- 10K), the monster kinds
loaded are the ones the map's ents.bin names (`ent_monster_kinds`,
soldier and knight on a map with none) and `mdl_ent()` is the map's
count (6K), and the surface cache's drawing views are one a HEIGHT
re-shaped to the class at every use (`qglSfViewShape`, five views)
where they were one a class, 22 of them made at the first face of
each class -- past the load trace, which is why the first frame died
with 7K to spare and nothing in the trace said so (6K). A lazily
made thing is invisible to a trace taken at load; count what the
first frame makes too.

**e1m4 (6,120 faces, 3,193 nodes, 1,817 leaves, 6,948 clipnodes) is
18K bigger than e1m3 in the far heap, and two cuts paid for it.** The
leaf face list is a `qglArLoadBas` MEM store now, as the leaves are:
`qglMemAlloc` takes the UMB pool before it shrinks BASIC's heap, and
the faces store leaves 26K of it, so the list's 13K (16K on e1m4)
costs the far heap 16 bytes -- the walk reads it through the bound
descriptor as before. `MapStore.lfaces` holds the handle, which moved
`GAME_VIS_OFFSET` and `GAME_DLIGHT_OFFSET` by four. And the disk
texture headers, 40 bytes a texture, are erased once the anim chains
are linked. e1m3 reads 30.4K after the depth buffer with both, e1m4
8.7K. e1m4's rebuilt portals miss 152 of 1,230 PVS leaves, so mkassets
ships it an index of zeros instead of failing -- `r_load_portals`
leaves `pt_ok` 0 and the PVS alone draws, as it does on any map whose
table passes 4,681 refs. `tools/check.sh --e1m4` is its spawn frame.

**`ubound()` of an array never made is error 9, and per-map loading
found one.** `mdl_ent()` and `nail()` were sized inside `if ( mon(
MDL_KIND_ARMY% ).loaded )`, which every map had satisfied until e1m3
-- ogres and a demon, no soldier -- and the first frame's `for mdl_i
= 0 to ubound( nail )` was `runtime error 9 at line 0`. Both are
sized before the gate now. What found it, after the debugger's stack
read as garbage: a `tk_mark` writing a tag to a file, open/append/
close, before each stage of the tick and the render -- three builds,
the last one marking each item -- and the run stopped between the
items and the nails. `tools/check.sh --e1m3` is the gate, the spawn
frame against `tools/ref/e1m3-spawn.bmp`; the run died on it before
the fix.

**A black lit world with every counter normal is a missing allocation.**
The surface builder's 16K conventional scratch was taken at the first
lit face by shrinking BASIC's heap, and short of it every lit surface
stayed zeros: `polys` and `sc_built` as always, the unlit frame right,
no error anywhere. A session went on EMS slot theories before the unlit
frame pointed at the builder. `sc_store_open` runs from `host_init` now
and `qglSbReserve` takes the block there, `0x0046` if it cannot. The
e1m1 spawn and exit arms are the regression test; both failed on it.

**Four files make a map's assets, not one.** mkassets writes assets.zip
and, beside it, texr.raw, texs.raw and pal.raw -- the atlases qgl reads
with plain INT 21h. e1m1's zip staged over dm3ish's atlases drew every
texture as some other one, since the offset table indexes whatever
atlas is there: a yellow hazard floor at the spawn, the slipgate pad
brown. `mod_load_textures` refuses an atlas shorter than its table
(`0x0018`), and the gate copies all four in and all four back.

**Every `trigger_*` brush is a volume.** Only `trigger_teleport` hid its
submodel; e1m1's `trigger_changelevel` drew as a column of the
`trigger` texture in front of the exit. `parse_entities` hides them all.

**The spawn yaw is mirrored.** `angle 90` is +y in the map and `-yaw
270` looks down +y here, so `ent_load_spawn` sets `360 - angle`. The
monster ring `main.bas` scatters on a map with no monsters of its own
is seeded from the map's angle as before, so the crowd the fight and
model gates stand beside stays put. The gate aims with `-yaw 270`.

**The map's monsters come from ents.bin, and the skill is the assets'.**
`mkassets.py map base out [skill]` keeps every entity its skill allows
-- NOT_EASY 256, NOT_MEDIUM 512, NOT_HARD 1024, on monsters, items and
triggers alike; nightmare is hard's set -- and `make assets SKILL=2`
builds a hard dm3ish. Easy is the default and what every gate plays.
e1m1 has 10 monsters on easy, 23 on normal, 42 on hard; `MDL_MAX_ENTS`
is 48 for it. The monsters ship with origin and angle, first in the file;
`ent_load_monsters` spawns them through `mdl_spawn` and faces them the
map's way (a model's yaw is Quake's, CCW from +x, no mirror). Nine
soldiers and a dog on e1m1. A map with none, dm3ish, still gets the scattered crowd of
`MDL_CROWD`, eight. The e1m1 image arms run `-noai`: a soldier
behind the exit camera shot the player inside the second and the
health digits moved the frame. `tools/ref/e1m1-spawn.bmp` moved by 13
pixels with this: the old one carried a sliver of the scattered crowd
at its right edge, and the map's own soldiers stand nowhere near.

## Doors

`func_door` is doors.qc without sounds, keys and damage. mkassets
resolves each one offline -- `travel` is `movedir * (size along it -
lip)`, SetMovedir's -1 up and -2 down, speed 100, wait 3, lip 8 unless
the map says -- and `ent_door_init` puts the brush at the shut end, or
the open end for DOOR_START_OPEN. A door with a targetname waits for a
trigger; the rest open by touch: `spawn_field` is the
brush grown 60 in x and y and 8 in z, and the player's box in it sends
the door's whole linked group out. `ent_link_doors` is LinkDoors, brushes
that touch unless DOOR_DONT_LINK, so both halves of e1m1's first double
door go when one is reached. Open, the door holds `wait` seconds and
comes back; a touch while closing sends it out again, which is also what
keeps it off a player standing in the way. 14 doors on e1m1, four by
touch.

`func_door_secret` is the same array with two legs: back `t_width`
along the angle's right (or down), a second's pause, then `t_length`
along its forward, resolved offline as `mid` and `travel`; speed 50,
wait 5, open_once stays, and the way home is the same legs reversed
with the same pause. It fires only from rest (fd_secret_use), a touch
says its message and nothing else (secret_touch), and one without a
targetname takes damage: `pl_fire` runs each pellet against its brush
as it does the shootable switch. Seven on e1m1, four of them shot, the
rest by their triggers. Not ported: its own targets, blocking damage.
`tools/check.sh --e1m1`'s eighth arm shoots `*43` level from 60 units
and wants its brush 60 aside.

**The brush offset is a `Vec3` now, not a z.** Doors slide along any
axis, so `BrushModel.ofs` carries all three: `d_faces.c` adds it to every
vertex, `pl_trace.c` subtracts it from both ends of the sweep, and
`ent_find_node` sorts the box where it is. Plats use `.ofs.z`.

**`func_train` rides the plat array** (`PlatEnt.kind`), and the map's
`path_corner`s are `ent_corner()` in ent.bas, each with its `nxt`.
mkassets resolves the route offline; func_train_find puts the brush's
mins on the first corner, a train with a targetname waits there for
its trigger (train_use, from `ent_use_targets`), the rest go at once.
`ent_move_train` is train_next/train_wait/SUB_CalcMove: a straight line
to the next corner at speed, the corner's wait there (id's -1 is a wait
of nothing: `ltime + wait` is past), and the rider carried sideways and
up by the same delta (`ent_mover_ridden`). e1m2's two lifts end on a
pair of corners at one point, and bounce between them standing still.
`tools/check.sh --e1m2`'s first arm stands on their button and wants
both at that corner. Not ported: the ratchet sounds, blocking damage.

**Keys.** `item_key1`/`item_key2` are item kinds: taken once into
`fight.items` as `PL_IT_KEY1`/`KEY2`, "You got the silver key" (the
worldtype's word: key, runekey, keycard), misc/medkey or runekey, and
-- as every pickup does now, SUB_UseTargets -- the item's `target`
fired: e1m2's key opens door *49. A door with DOOR_SILVER_KEY (16) or
DOOR_GOLD_KEY (8) has no spawn field, like a targeted one: touching
its brush without the key says its message -- mkassets puts door_touch's
"You need the silver key" there when the map gives none -- and plays
doors/medtry two seconds apart; with it the key is spent, meduse, and
the group goes. Base's key wavs are registered, so worldtype 2 plays
the rune set. Keys never carry to the next map (SetChangeParms). Not
ported: the bar's key icons -- the cell band is 512 wide and full.
The e1m2 gate's second arm stands on the key, the third walks at the
key doors without it.

**`trap_spikeshooter` is a trigger kind**: used, it arms
(`ENT_TRIG_ARMED`) and `pl_traps_tick` sends a hostile spike from its
origin along its movedir at 500, weapons/spike2, 9 or 18 for
SUPERSPIKE. A hostile spike is walked as a POINT through hull 0
(`pl_point_contents` a step at a time) rather than traced through hull
1: its origin sits 8 units off its wall, inside hull 1's grown solid,
and the hull-1 trace ended it before it flew -- the first run read
health 100 with six spike sounds. It bites the player's box
(spike_touch), not monsters, and passes brush entities. The nail step
divides by each nail's own speed now, not the nailgun's 1000. The e1m2
gate's fourth arm stands in the trap's trigger for 2.5 s and wants
health under 100.

**A monster with a `target` patrols** (walkmonster_start_go's
th_walk): `EntsMon.first` is its path_corner in ent.bas's corner table,
`MdlEnt.patrol` keeps it for the respawn and `corner` is the one bound
for. `mdl_patrol_to` sets the goal and the facing (t_movetarget), the
walk is the run cycle at `MDL_PATROL_STEP` a think -- army_walk's
average stride, 18 u/s, since no walk frames fit the page -- and
arrival within 24 takes the next corner, stands the corner's wait, or
stands for good at a corner with no target. FindTarget runs every
think of the walk as before, and a hunt ends the patrol. The e1m1
gate's patrol arm runs ten seconds with the AI on and wants a soldier
between (950,2048) and (1200,2048); the run read 1105.

**BC miscompiles a store of a single into a member of an indexed
element when it is the second such store in a row.** `door(k).model = m`
then `door(k).speed = dr.speed`: the second keeps `k*70` cached in AX,
loads the value into AX:DX, then adds the member offset to AX and stores
through it -- the value lands at `base + low word of the value + 26`. A
speed of 400.0 has a low word of 0, so every door's speed was written
into door 0 and the others read 0: the second half of the double door
sat "opening" for ever at offset zero. The third store reloads the
cached offset from `[bp-1Ah]` and is right, which is why `hold` beside
it was. The listing is what showed it (`bclst.sh`, `ENT_DOOR_INIT`);
`ent_door_init` fills a local `DoorEnt` and stores the element whole.
Any load that fills a record member by member into an indexed element
is suspect; check the listing for `add ax,` right after a load into AX.

`tools/check.sh --e1m1`'s third frame is the test: `-walk` from
(330,576) at the first double door must carry the player through it,
px below 190; a door that does not open stops them at 272.03.

## Triggers and buttons

`trigger_once`, `trigger_multiple`, `trigger_counter` and `func_button`
are one array, `trig()`, since all four do one thing: fire a target.
mkassets turns every targetname into a number, so a door's `targeted`
is its name's id and `ent_use_targets` is a loop over ids, never a
string compare. A touch in a trigger's volume fires its target and says
its message; once is a multiple with wait -1, a multiple re-arms after
wait (0.2); a counter fires its own target when used `count` times (2).
A button slides in when touched and fires when it ARRIVES, as
`button_wait` does, holds `wait` seconds (-1 stays), and comes back.
A trigger with health (e1m1's `*16`, a wall switch) is shot, not
touched: `pl_fire` runs every pellet against such boxes short of what
it stopped at plus `PL_HALF`, and the first hit fires it (multi_killed).
The margin is there because `pl_trace` walks hull 1, the player's, so
a wall stops a pellet 16 units early, and e1m1's switch volume stands
8 units off its wall: without it four shots at the switch fired
nothing. A point trace through hull 0 is the real fix. Nothing in
`delay`, `killtarget` or sounds. `-fire` holds the trigger for a
headless shot and `-pitch D` aims it up or down, as `-yaw` aims it
round: the default view looks 11 degrees down, mouse y 110 of 200.

A message is a centerprint: `ent_say` puts it in `g.fight.msg` for two
seconds and the overlay draws it where the state messages go, under
`-nostats` too. A targeted door says its own when its brush is touched
(door_touch), which is why such a door's field is the brush plus two
units where a touch door's is grown 60. `tools/ref/e1m1-exit.bmp`
carries "Walk into the slipgate to exit." because its camera stands in
that trigger; the reference is what proves the text draws.

`killtarget` removes: a trigger's use puts every trigger named by it in
DONE before its target fires, which is SUB_UseTargets' order. e1m1 uses
it twice, each a trigger_once that removes the hint trigger it also
names, so the hint is never said again once the player has passed. A
door or a monster named by a killtarget stays; `delay` is not ported.
The ninth e1m1 arm stands in `*54` and wants `*51` DONE.

`trigger_changelevel` is the level's end: touching it is `GS_EXIT`,
the view cut to the map's first `info_intermission` at its mangle
(`ent_intermission`: noclip, held still, no gun), LEVEL COMPLETE with
the worldspawn's message -- the map's title -- above it and the kills,
secrets and time under it, and fire starts the map over: `pl_game_reset`
puts the monsters, items and player back, on foot and facing the
spawn's way, and `ent_reset` every door shut and every trigger and
button as it loaded. A map with no info_intermission looks from its
start, as Quake does. The slipgate arm wants the exit at (-112,704).

**The next map is a new process.** Fire held two seconds into the
intermission (IntermissionThink) runs `host_next_level`: the kit to
`CARRY.BIN` by SetChangeParms' rules -- keys and powerups dropped,
health 50..100, 25 shells at least -- and `NEXT.BAT`, `call GOMAP.BAT
e1m2` then `qrender.exe e1m2.bsp -carry` with the run's own flags (-lm,
-nosound, -bench, -ticks, the -no* set, -fire; never -at or -yaw), and
the host loop ends on `GS_NEXT`. GOMAP.BAT copies `MAPS\<map>\*.*` --
the bsp and its four asset files, `make maps` builds `data/maps/<map>/`
for every map in `MAPS` and the build stages them -- over the ones
beside the exe; dosbox.sh's run.bat copies NEXT.BAT to RUN1.BAT,
deletes it and calls it while one is written, since a batch deleted
while it runs is "Batch file missing". `-carry` reads CARRY.BIN over
`pl_reset_player`. The map's `map` key rides in ents.bin's header, and
bench.txt says `map`. The e1m1 gate's last arm walks into the slipgate
with fire held and the soldier awake and wants e1m2's bench with the
damage carried: e1m1's shells 25 and fire's 14 shots read `pl_shells
11` there.

`tools/check.sh --e1m1`'s fourth frame walks into the first button:
the plunger floor (`*3`, a door targeted by `*4`) must go down with the
player on it, pz below -100 by tick 240. The sixth walks and jumps
into the slipgate -- its pad is 32 units up, past the 18 a step climbs
-- and wants `gs_state 4`. The seventh fires at `*16` from 108 units
and wants door `*15`, the bridge it lifts, off its -64.

## `-nostats` makes the picture deterministic

With the HUD off the renderer is **byte-identical run to run** -- one
binary, two runs, `imgdiff` reports IDENTICAL. An 8-to-40 pixel spread
that looks like surface-cache churn is the overlay, not the cache. Every
A/B on an image wants `-nostats`, because it turns "within noise" into an
exact test. The churn below is real, but it is what `--churn` provokes,
not what a still frame shows.

## The surface cache draws a different picture every run

**Closed by 8e57e79, as far as `--churn` can see.** The picture varied
because `d_faces.c` walked BASIC's far-heap arrays through pointers taken
once at entry, and the heap compacts under the calls inside the loop; two
runs then compacted at different faces. With every pointer re-taken per
face, `--churn` gives two byte-identical frames over 266 frames. Note it
now reports `sc_evict 0` -- the campath does not evict on qgl's 4MB store
-- so reuse after eviction is untested, and the bisection below is kept
for whoever next sees a varying picture.

`tools/check.sh --churn` reproduced it: one binary, `-ticks 900` so the
camera stops in the same place, two runs, ~68% of pixels different. A wall
that is tan brick in one run is dark with red and green streaks in the
next.

What the bisection established, each step a measurement:

| test | result | what it rules out |
|---|---|---|
| `-lm` off | byte-identical x3 | the campath, physics and tick loop |
| flush every frame | byte-identical, `sc_built` equal too | anything within one frame |
| `sc_find` forced to always miss | byte-identical x3, and CORRECT | the builder, under any eviction history |
| ownership check on hit | never fires (`0`) | a block changing hands behind a slot |
| overlap scan at alloc, 1070 runs | never fires (`0`) | two live faces allocated the same bytes |
| re-read after forcing the window elsewhere | same bytes | a stale EMS page on the READ side |
| fingerprint at build, checked on hit | **48-110 mismatches** | nothing: the bytes really do change |

So the builder is right, the allocator's books are right, and the bytes of
a cached surface are overwritten between the build and the reuse. Forcing
every face to rebuild hides it completely, which is why a fixed camera --
which evicts nothing and rebuilds nothing -- has never shown it.

**The clobbering write is megabytes from where it belongs.** Watch one
cached surface and re-read it after every later build: the surface at
granule 15040 was destroyed by the build of a face at granule **7072**,
both order 5. Not adjacent, so not an overrun -- a write landing in the
wrong EMS *page*, which is the `gv_dst` failure again. The builder streams
the atlas across many pages while holding a pointer to its destination,
and the pool may take the destination's slot to map the next atlas page.

Pinning the destination page across `uglBuildSurf` took the hit-time
mismatches from 48-110 to **0** and cost about 12% of the frame rate --
and the picture still varies, so there is at least one more path. The fix
belongs in `uglBuildSurf` itself: re-derive the destination pointer per
row instead of holding it, exactly as `d_poly` now re-takes `gv_dst` per
face.

**A run in four dies before writing anything** -- empty `run.out`, no
`error.log`, no `bench.txt`. Unrelated to the above and still unexplained;
`--churn` retries rather than call it a failure.

The slot NUMBER stays with whoever owns the resource -- `mod_lm_lock` and
`mod_cm_lock` live in `model.bas` next to the maps they pin, and callers
pin by name. Nobody names a slot they do not own; that is the whole point
of the pool.

Two sites are safe and worth knowing why, so they are not "fixed" by
mistake: `d_poly`'s per-face geometry copy and `sb_fetch` both go from map
straight to `memCopy` with nothing but integer arithmetic in between.
`hud_shade` is safe only because its destination is the MEM backbuffer --
see the note there.


- **`render.scale` wedges under `core=dynamic`, draws correctly under
  `core=normal`.** The view is rendered into a small backbuffer and blown up
  to fill the screen; `uglPutScl` does the magnification. Under
  `cycles=75000 core=dynamic` the program stops responding -- black screen,
  Esc dead. Under `core=normal` the identical binary draws the scaled view.

  What it is NOT, all tested:
  - not our computed values: hardcoded `160, 100, 3.0, 3.0` hangs too
  - not the position: `uglPutScl` takes the TOP-LEFT, whatever its header
    comment says about a "center col" -- `h_precalc` passes x,y straight to
    `DC_CLIP_SCL`, which measures width as `xmax-x+1`. Confirmed on screen.
  - not clipping or an off-by-one at the edge: a whole-number scale putting
    the rect strictly inside the mode (192x192 at 64,4) hangs just the same
  - not one entry point: `uglBlitScl` hangs identically
  - not self-modifying code as such -- the texture mappers patch immediates
    into their own inner loops and run fine under dynamic

  Where it ends up: sampling under the debugger caught it once in
  `ugl_text` near `UGLBUILDSURF` and once spinning in `B$FCompactMove`, the
  VBDOS runtime's local-heap compactor (`lcompact.asm`, LMEM segment). That
  loop deserves a note of its own:

      097A  inc bx              ; block header 0xFFFF -> 0x0000
      097B  add si,bx           ; si += 0, no carry
      097D  jnc 0x943           ; loops instead
      097F  call B$CorruptHeap  ; the check it should have reached

  The runtime DOES guard against a runaway heap walk, on the carry out of
  `add si,bx`. A header of `0xFFFF` is the one value that defeats it, because
  `inc bx` wraps to zero and never carries -- so it spins instead of
  reporting a corrupt heap. Worth knowing whenever this codebase wedges with
  no output: that is what it looks like.

  **`/MAP` on the LINK line is what made any of this readable.** Without it
  `qrender.map` carries segments only and the debugger can say
  `LMEM+0x943` but not which routine that is; with it there are 2,545
  publics and the same address resolves to `B$FCompactMove`.


- ~~`clpBuffer` in `model.bas`~~ hardened to `'$STATIC`.
- ~~Remaining cuts~~ done — `main.bas` is 427 lines: `doInit`, `doMain`,
  `doEnd`, `ExitError`. All ten modules carry `OPTION EXPLICIT`.

## Dynamic lighting

A single light follows the player (`g.rdr.dlight`, updated in `host_tick`
from `g.pl.pos` every tick) and brightens nearby luxels live, additively,
on top of whatever a face's baked lightmap and light style already
produced -- Quake's own dynamic-light effect, minus the emitters this
renderer has no rockets or muzzle flashes to drive. `DL_RADIUS#` in
main.bas is Quake's own rocket-light radius, 200 units, picked for no
better reason than fidelity to the source.

**Reuses the light-style scratch buffer (`ls_scratch` in `d_surf.bas`)
rather than adding a second one.** A face gets copied in, scaled by its
style if non-neutral, and now also has the light's falloff added per
luxel, all in the one pass -- the two effects were never going to collide
since both only fire for faces already taking the rare, non-neutral path.

**Coordinate space needed checking before any of the geometry math got
written, not after.** `PlayerState.pos` documents itself as BSP space,
Z-up; `Plane.norm`/`.dist` and `TexInfo.vecs`/`.vect` had to be confirmed
the same way, since a mismatch here is exactly the kind of thing that
compiles, runs, and silently produces wrong numbers. Two facts settled
it, read out of working code rather than assumed: `d_poly.bas` dots
`vecs`/`vect` against `vx,vy,vz` taken straight from `gv_buf` -- raw BSP
vertex data, before the Y-swap to renderer space happens a few lines
later -- so `vecs`/`vect` are BSP-space and want an UNSWAPPED point.
`r_cam_plane_dist`, by contrast, dots a Y-up point against a Plane with
the swap baked into the dot product itself (`pt.y*pl.norm.z +
pt.z*pl.norm.y`), which is the opposite convention on the opposite kind
of input. The two must never be mixed: this feature uses `g.pl.pos`
(already Z-up, no swap) with `vecs`/`vect` and its own plain,
un-swapped `Plane` dot product throughout, and never touches
`r_cam_plane_dist` at all.

**A dynamically lit face has to rebuild every frame it stays in range,
not just the first.** The light's own falloff is computed inside
`sb_build`, but the decision to skip the cache has to happen earlier, in
`d_poly.bas`, before `sc_find` ever runs -- a plain style-epoch match
would otherwise paper over the fact that the face needs redrawing. Forced
by overwriting `lm_stag` with `-1` (a value `ls_epoch` never returns)
whenever the face's plane is within radius. That also gives, for free,
exactly one extra rebuild the frame the light leaves -- the stale `-1`
from the last lit frame no longer matches the real epoch computed once
the light is gone, so it misses once more and washes the glow back out,
then settles. No separate "was lit last frame" flag needed.

**Verified the same way the style-scale math was: unit tests for the
formula (`ls_add_dlight`, hand-computed including a 3-4-5 triangle for an
exact check), then confirmed against real runs on two independently
converted maps.** Neither dm3ish nor e1m7 gives any way to eyeball this
in isolation, so `sc_dlit` (builds the light actually reached) is a
permanent counter, not scaffolding -- `-campath` on dm3ish shows several
hundred over one walk, and pixel-diffing e1m7's `-bench` frame
before/after the feature landed shows 69% of pixels uniformly brighter,
no noise, consistent with an additive light near the camera in a tight
corridor.
