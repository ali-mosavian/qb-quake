# Remapping a QB array onto memory BASIC does not own

Pointing a BASIC array at an EMS window lets the paged-map design keep
array syntax on the hot path instead of a PEEK per field. It works, and
the rules for doing it safely come from the QuickBASIC runtime source at
`/Users/alim/work/ms/msdos_60/45/runtime/`, not from experiment.

## The descriptor

`runtime/inc/array.inc`:

    +0   FHD_oData      offset of data
    +2   FHD_hData      segment of data
    +4   FHD_pNext      DGROUP offset of the next FHD  <- the chain
    +6   FHD_cPara      paragraph count of the entry
    +8   AD_cDims       dimension count
    +9   AD_fFeatures   1=far 2=huge 40h=static 80h=string
    +10  AD_oAdjusted   the offset indexing actually adds
    +12  AD_cbElement   bytes per element
    +14  DM_cElements, DM_iLbound  (per dimension)

`AD_oAdjusted` is the field that matters. array.inc states the element
address is

    (((k*c2 + j)*c1) + i) * elementsize + AD_oAdjusted

so patching `FHD_oData` alone moves nothing. A first version of the test
did exactly that and passed, because both its arrays sat at offset 0 in
their own segments and only the segment ever needed to change. Always
patch `FHD_hData` **and** `AD_oAdjusted`.

## Why a live array cannot simply be repointed

`B$FHCompact` (`rt/fhinit.asm:921`) walks the `FHD_pNext` chain, calls
`B$FHMove` on each entry and rewrites its `FHD_hData`. An array left in
that chain while pointing at the EMS frame would have the page frame's
contents moved into the far heap.

It also checks that segments do not increase down the chain and raises
`B$ERR_FHC` if they do. An EMS frame segment is above every far-heap
segment, so the failure is loud rather than silent -- but it is still a
failure, and `stfree.asm:142` reaches the compactor from string handling,
so it is not only REDIM that can trigger it.

`B$ERAS` (`rt/dynamic.asm:587`) deallocates *through* the descriptor, and
`B$RDIM` calls `B$ERAS` first. Either on a remapped array hands the
allocator a pointer it does not own.

## The safe construction

DIM the array with one element so a descriptor exists, then ERASE it.
`B$FHDealloc` unlinks it from the chain (`rt/fhinit.asm:853`) and zeroes
`FHD_hData`. The descriptor now sits in DGROUP **orphaned**: the
compactor cannot reach it and BASIC believes it unallocated. Patch that
one freely.

Rules that remain:

- never DIM/REDIM/ERASE that array again. DIM errors on a non-zero
  `FHD_hData` (`B$ERR_DD`); ERASE would deallocate the EMS window.
- `DM_cElements` describes the original size, so bounds checking would be
  wrong. This build compiles without it; a `/D` build would not.
- restore or re-zero `FHD_hData` before program exit if anything walks
  descriptors at shutdown.

## Locating the descriptor

Scan DGROUP for `FHD_oData`/`FHD_hData` matching the array's data
address, and confirm against `AD_cbElement` and `DM_cElements`. Matching
the address alone finds coincidental word pairs; matching all four does
not. See `mgl/src/test/arrmap.bas`, which proves the remap by reading a
second array through the first array's name at a non-zero offset.

## Subscript order is a compiler switch, not a language property

`array.inc` gives the element address as

    (((k - l3)*c2 + j - l2)*c1 + i - l1) * elementsize + AD_oAdjusted

which reads as column-major: the FIRST subscript varying fastest. Measured
behaviour is the opposite -- `a(2,2)` lands five elements along in a
`a(1 TO 4, 2 TO 6)` array, so the LAST subscript varies fastest and the
first strides by the second dimension's count.

That is not a contradiction and not an undocumented quirk. It is `/R`:

    /R    Store arrays in row-major order

and this project compiles with it (`/O /FPi /R /G3 /E`). array.inc
documents the default; `/R` flips it. The hand-flattened
`h_rawtx_dc(mi*4 + mip)` in mod_tex.bas is row-major for the same reason.

The consequence for any paged-array helper: a routine that derives a
linear index from the DM table is assuming `/R`, and would silently
mis-index for a caller compiled without it. Either the order is passed in
or the caller supplies the linear index it computed under its own
convention -- which is why uglArrMap takes one.

## What the generated code actually does

From `BC /A` listings of `x = a(i)` on a dynamic array (BND.BAS).

Without `/D`, fully inlined, and it reads exactly the two fields
uglArrMap patches:

    mov   bx,i%
    shl   bx,1             ; * cbElement
    mov   si,offset a%
    add   bx,0Ah[si]       ; + AD_oAdjusted   (+10)
    mov   es,02h[si]       ;   FHD_hData      (+2)
    es: mov ax,[bx]

With `/D`, every access becomes a call:

    push  i%
    push  01h              ; subscript count
    mov   bx,offset a%     ; the descriptor
    call  B$HARY

and `B$HARY` (rt/dynamic.asm:299) checks

    SUB  AX,[BX].DM_iLbound
    CMP  AX,[BX].DM_cElements

against the LIVE descriptor. So setting `DM_iLbound = pbase` and
`DM_cElements = perpg` on each map turns an out-of-page subscript into a
runtime error instead of a plausible wrong element -- the page guard is
real, not incidental. It costs a far call per access, so it belongs in a
debug configuration, not a shipped build.

Note `B$HARY` is documented as the HUGE array helper, yet `/D` routes an
ordinary dynamic array through it. `/Ah` may therefore give the same
guard without `/D`'s other costs; unverified.

## Compiler switches, by version

Captured from each compiler's own `/?` screen under DOSBox, except QB 4.5
which has no help switch -- `/?` and `/HELP` are both "Option unknown",
its BC.EXE is unpacked and carries no option text, and the list below was
established by feeding each switch to it and seeing which it rejected.

                          QB 4.50   PDS 7.10   VBDOS 1.00
    /A    asm listing        y          y          y
    /Ah   huge arrays        y          y          y
    /C:n  COM buffer         y          y          y
    /D    run-time checks    y          y          y
    /E    ON ERROR           y          y          y
    /Es   EMS sharing        -          y          y
    /FPa  alt math           y          y          y
    /FPi  x87 math           y          y          y
    /G2   286 codegen        -          y          y
    /G3   386 codegen        -          -          y
    /MBF  MS binary format   y          y          y
    /O    stand-alone EXE    y          y          y
    /R    row-major arrays   y          y          y
    /S    no string compr.   y          y          y
    /T    terse warnings     y          y          y
    /V    ON EVENT / stmt    y          y          y
    /W    ON EVENT / label   y          y          y
    /X    RESUME NEXT        y          y          y
    /Zd   limited CodeView   y          y          y
    /Zi   full CodeView      y          y          y
    /Ot   quick call opt     -          y          y
    /Fs   far strings        -          y          -
    /Lr   DOS/OS2 real       -          y          -
    /Lp   OS/2 protected     -          y          -
    /Z    PWB-style errors   -          y          -
    /FBr  restricted browse  -          y          -
    /FBx  extended browse    -          y          -
    /Ib:n ISAM buffers       -          y          y
    /Ie:n non-ISAM EMS       -          y          y
    /Ii:n ISAM indexes       -          y          y

`/D`, `/R`, `/X` and `/Ah` are in all three, so nothing above depends on
VBDOS specifically.

`/X` (RESUME NEXT) is worth knowing about here beyond convenience: with
`/D` making an out-of-page subscript a trappable error, `/X` is what lets
a handler continue past it -- so a test can enumerate violations rather
than dying on the first.

QB 4.5's full option list is in QB45QCK.HLP, which is QuickHelp
compressed behind an `LN` magic. mini-qb's tools/view_help.py reads
already-extracted markdown, not .hlp, and no extractor for that format
was found in the tree.
