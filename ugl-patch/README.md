# µGL UV-scale patch

The renderer depends on a **patched µGL**. Link against `uglv.lib` in this
directory, not the stock one.

## What was wrong

µGL takes texture coordinates normalised to 0..1 per repeat and scales them to
texels itself, which is what lets one UV set serve all four mip levels. But it
scaled by **`xRes-1`**, not `xRes`:

```asm
movzx   eax, gs:[DC.xRes]
dec     eax                     ;; eax= xRes-1
shl     eax, 16
fild    uf
fmul    es:[bx].VEC3F.u         ;; u_fx = (xRes-1) * u
```

One repeat therefore advances 63 texels across a 64-wide texture instead of 64,
so the texture phase drifts one texel per repeat. Because each face has its own
UV magnitude, each is offset by a different amount — faces far from the texture
origin are visibly misaligned against their neighbours. dm3ish's worst faces sit
at 41 repeats, i.e. ~41 texels of drift, about 0.64 of a texture.

The same off-by-one is in the 2002 release and in the newer tree, so it is
longstanding rather than a local modification.

## The patch

`uv-scale.patch` removes the two `dec` instructions from each of four modules,
so the scale is the full texture size and one repeat spans it exactly:

| module | routine | what it scales |
|---|---|---|
| `ugl/uglplxtp.asm`  | `calc_gradients` | perspective gradient |
| `ugl/uglplxt.asm`   | `calc_gradients` | affine gradient |
| `misc/mscshtp.asm`  | `F2FX_tp2d`      | perspective span start |
| `misc/mscshta.asm`  | `F2FX_t2d`       | affine span start |

Both halves must move together: the gradient and the span start have to agree
on the scale, or the texture steps correctly but from the wrong offset.

## Rebuilding

**Build from the µGL 0.23b source drop, not from a newer `mgl/src`.** The
shipped `uglv.lib` is byte-identical to 0.23b's, while `mgl/src` has diverged
from it — splicing modules assembled from the newer tree into that library
links without error and then renders a black screen.

Assembler: **MASM 6.11d**. Plain 6.11 fails on the `misc/` clippers with a macro
forward-reference error, and 6.14 is Windows-only so it will not run under
DOSBox.

```
ML.EXE /c /Cp /D__CMP__=VBD /I <src>\INC /I <src>\UGL /I <src>\MISC /Fo <name>.OBJ <name>.ASM
LIB.EXE UGLV.LIB -<name>;          rem module names in the library are lowercase
LIB.EXE UGLV.LIB +<NAME>.OBJ;
```

`LIB`'s `-+` replace operator does not match these module names; delete and add
as two steps. Keep each invocation on its own command line — DOS caps it at 127
characters and `LIB`'s `&` continuation misparses in a response file.
