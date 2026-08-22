# qb-qrender

A Quake `.bsp` renderer written in QuickBASIC, running in real-mode DOS.

Loads a Quake 1 map, walks the BSP, uses the PVS to cull, and draws it with
perspective-texture-mapped triangles through µGL — a
QuickBASIC game library by Ali Mosavian and av1ctor. Mip-mapped textures,
frustum culling, backface culling, BSP collision against the map, a MOD
soundtrack and a bitmap-font HUD.

```
bsp_pvs mapname.bsp
```

## Files

| | |
|---|---|
| `bsp_pvs.bas` | the renderer |
| `bsp_pvs.bi`  | BSP-on-disk structures, shared types, `declare`s |
| `stuff.ini`   | video mode, camera, sound settings |
| `base.dat`    | µAR archive: palette, colormap, 4x6 font, two MOD tracks |
| `mkqb.bat`    | build with QuickBASIC 4.5 |
| `mkpds.bat`   | build with BASIC PDS 7.1 |

`bsp_pvs_refactored.bas` is a superseded rewrite kept for reference. It is not
built by either batch file.

## Building

µGL is a separate tree and is **not** vendored here. Point `MGL` at it and the
batch files do the rest:

```
set MGL=C:\MGL
mkqb
```

`mkqb.bat` sets `INCLUDE=%MGL%\INC` so BC resolves the `'$include` directives,
and links against `%MGL%\LIB\UGL.LIB`. Set `DEBUG=TRUE` to link the debug
build instead. µGL's own `mk4qb.bat` calls the tools `bcq` and `link16`; these
scripts use the stock `bc` and `link` names.

The program needs EMS. Under NT-family Windows or DOSBox, enable expanded
memory and run fullscreen — µGL's VESA probe wants a real video context.

## Structure

There is no optimiser in QuickBASIC. A `SUB` call costs a stack frame and a
descriptor per argument, and nothing inlines it back out. So routines here are
split on exactly one criterion — **how often they are entered**:

- **once at startup** — split as far as it stays readable. `doInit` is 35
  lines calling 28 named zero-argument steps.
- **once per frame** — still free. `camUpdate`, `inputToggles`, `drawHud`,
  `presentFrame`.
- **per node, face, vertex, triangle** — *not* split. `bspDrawFaces` is one
  250-line routine on purpose.

Two other real-mode constraints shape the code. `defint a-z` means an
undeclared name silently becomes an integer zero rather than an error, so
every shared variable is declared. And map buffers live in `'$DYNAMIC` arrays
(far, allocated at load) while the per-frame renderer scratch lives after
`'$STATIC` in DGROUP, where it is addressed directly instead of through a
descriptor.
