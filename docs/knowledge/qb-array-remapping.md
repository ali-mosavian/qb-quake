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
