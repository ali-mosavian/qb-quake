# qb-qrender

A Quake `.bsp` renderer written in BASIC, running in real-mode DOS.

Loads a Quake 1 map, walks the BSP, culls with the PVS and the view frustum,
and draws it with perspective-texture-mapped triangles through µGL — a DOS
game library by Ali Mosavian and av1ctor. Mip-mapped textures matched back
into the Quake palette, backface culling, BSP collision against the map, a
MOD soundtrack and a bitmap-font HUD.

```
bsp_pvs dm3ish.bsp
```

## Files

| | |
|---|---|
| `src/main.bas` | main module: init, frame loop, BSP traversal and the rasteriser |
| `src/common.bas`    | `stuff.ini` parsing and the string tokeniser |
| `src/bspfile.bi`  | BSP-on-disk structures, shared types, `declare`s |
| `src/quakedef.bi`  | the `COMMON SHARED` block — state that crosses modules |
| `data/stuff.ini`  | video mode, camera, sound settings |
| `data/base.dat`   | µAR archive: palette, colormap, 4x6 font, two MOD tracks |
| `data/dm3ish.bsp` | demo map |
| `ugl-patch/`      | **patched µGL** — link against this, not the stock library |
| `mkvbd.bat`       | build under DOS |
| `dosbox/`, `tools/` | build and run on a host without a DOS machine |

Sources are split into modules. `DIM SHARED` is module scope only, so state
that crosses a module boundary lives in `src/quakedef.bi` as `COMMON SHARED`;
everything else stays local to its module, which matters because `COMMON`
arrays are always descriptor-addressed and the renderer's scratch is
deliberately `'$STATIC` for direct addressing.

`bsp_pvs_refactored.bas` is a superseded rewrite kept for reference. It is not
built by `mkvbd.bat`. It has not been compiled; it uses `uglPalLoad` without
including `pal.bi`, so it carries that defect too.

See `AGENTS.md` for the toolchain constraints, the BASIC and DOSBox
gotchas behind them, and what is still open.

## Building

**It must be VBDOS 1.0.** This is not a preference:

- **QB 4.5** cannot compile the module at all. `BC.EXE` exhausts its workspace
  and reports `Out of memory` with 0 bytes free, before parsing a single line
  of the program body. Free conventional memory is not the constraint — it
  fails identically with 608K free.
- **PDS 7.1** parses the file but rejects every `_` line continuation in
  `bspfile.bi` with `Formal parameter specification illegal`, and cascades to
  113 errors. Underscore continuation is a VBDOS extension.

µGL is a separate tree and is **not** vendored here. Point `MGL` at it and
`VBD` at the VBDOS install:

```
set MGL=C:\MGL
set VBD=C:\VBDOS
mkvbd
```

`mkvbd.bat` sets `INCLUDE=%MGL%\INC` so BC resolves the `'$include`
directives, which is why the sources name the headers bare (`ugl.bi`,
`u3d.bi`, …) with no path of their own.

Two things about the link line are easy to get wrong:

- µGL's libraries are **split per compiler**. The VBDOS one is
  `lib/release/vbd/uglv.lib`, not a `lib/ugl.lib` — that path in µGL's own
  `mk4vbd.bat` refers to a flattened tree that isn't what ships here.
- **`u3d` is not inside `uglv.lib`.** It lives in `lib/addons/u3d.obj` and has
  to be named in the objects list, or the link fails on `U3DMTRX*`.

The program needs EMS. Under NT-family Windows or DOSBox, enable expanded
memory and run fullscreen — µGL's VESA probe wants a real video context.

### Building and running on a host

`tools/dosbox.sh` builds and runs this under DOSBox-X with no DOS machine, by
filling in `dosbox/template.conf` and dropping the results in `build/`:

```bash
tools/dosbox.sh build          # VBDOS
tools/dosbox.sh run            # against dm3ish.bsp
```

`build qb45` and `build pds` reproduce the two failures above. Paths come from
`MGL`, `TOOLCHAINS` and `DOSBOX_BIN`; see `dosbox/README.md`.

## Fixes this build needed

The program did not compile or link as it stood; three defects predate any
restructuring and are fixed here.

- **`pal.bi` was never included.** Nothing else in µGL pulls it in, so
  `uglPalLoad` was an undeclared array reference and `uglPalSet` could not
  parse as a sub call at all. Three of the compiler's errors were this one
  missing line.
- **`ugluBMPSave` did not exist.** `bspfile.bi` declares it, the screenshot
  key calls it, and it is in no µGL library. Neither is `ugluSaveTGA`, which
  `uglu.bi` declares — µGL's BMP routines only *load*. The link failed on
  `UGLUBMPSAVE`, which means the screenshot key had never worked. It is now
  implemented in `main.bas` as an 8-bit BMP writer.
- **Backface culling was inert.** The plane distance was computed with the
  opposite sign to the rest of the file, and all three branches assigned
  `drawply = 1`, so nothing was ever rejected while the HUD reported the
  switch as enabled.

### Runtime error trapping has never worked

Line 191 reads `on errror goto HandleErr` — three r's. That is not a syntax
error: BASIC also has a computed `ON n GOTO`, so it parses as "evaluate the
variable `errror`, which under `defint a-z` is an undeclared integer zero, and
branch to the zeroth label", which falls through every time. The handler at
`HandleErr` has never been installed, and untrapped runtime errors print the
runtime's own message instead.

**This is left as-is deliberately.** Correcting the spelling would route every
runtime error to `ExitError "0x1000, Unknown runtime error..."`, replacing a
specific diagnostic with a generic one. The typo is worth knowing about, not
worth fixing until the handler says something useful.

## Structure

There is no optimiser in VBDOS. A `SUB` call costs a stack frame and a
descriptor per argument, and nothing inlines it back out. So routines are
split on exactly one criterion — **how often they are entered**:

- **once at startup** — split as far as it stays readable. `doInit` is a list
  of named zero-argument steps.
- **once per frame** — still free. `camUpdate`, `inputToggles`, `drawHud`,
  `presentFrame`.
- **per node, face, vertex, triangle** — *not* split. `bspDrawFaces` is one
  250-line routine on purpose.

Splitting `doInit` this way has a second cost that is easy to miss. It turned
one procedure scope into 26, and under `defint a-z` an undeclared name is a
fresh integer zero rather than an error — so any value that used to flow from
one part of `doInit` to a later part reads as 0 once they are separate
routines, with no diagnostic at all. `pal` was lost exactly this way. Before
adding a step, check what the code around it *reads* as well as what it
writes.

The rule has a harder limit too, because violating it broke this build
once already: a routine boundary cannot cut through a block. `texLoadAll` is
one 200-line routine not because it does one thing, but because it is a single
`for i = 0 to numtex-1` loop — splitting it into upload/mip/average phases put
`for` and its `next` in different procedures.

Two other real-mode constraints shape the code. `defint a-z` means an
undeclared name silently becomes an integer zero rather than an error, so
every shared variable is declared. And map buffers live in `'$DYNAMIC` arrays
(far, allocated at load) while the per-frame renderer scratch lives after
`'$STATIC` in DGROUP, where it is addressed directly instead of through a
descriptor.
