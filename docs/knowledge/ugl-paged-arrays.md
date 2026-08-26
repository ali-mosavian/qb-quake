# uglArr* -- paged arrays with native QB indexing

Backs a BASIC array with EMS or conventional memory and keeps `arr(i)`,
`arr(i,j)` and `arr(i,j,k)` working. The point is that the call sites do
not change: the same walk compiles against a resident array and a paged
one, and the backing store is chosen at runtime.

Mechanism and hazards: [qb-array-remapping.md](qb-array-remapping.md).

## API

    uglArrNew1D&  (typ, a(), cnt, slot)           -> handle, 0 on refusal
    uglArrNew2D& (typ, a(), c0, c1, slot)        -> handle, 0 on refusal
    uglArrNew3D& (typ, a(), c0, c1, c2, slot)    -> handle, 0 on refusal
    uglArrMap&  (h, idx)                        -> far pointer, 0 if bad
    uglArrFree   h                              -> free the store

Three operations. New takes the array's descriptor over, Map makes an
element reachable, Free releases both. There is one New per rank because
a descriptor is exactly sized when it is compiled and its rank cannot be
changed afterwards; Map and Free are rank-independent.

`typ` is `UGL.EMS` or `UGL.MEM`. `UGL.XMS` is declared and refused.
`slot` is the EMS physical page and is ignored by `UGL.MEM`.

**Pass the array, not an address.** `a()` hands over the descriptor, and
the element size is read from it -- so uGL cannot be told one size while
BASIC believes another. On the BASIC side declare it `a() As Any`.

What the compiler pushes is a 2-BYTE descriptor offset, not a far
pointer, so the asm takes it as a `word`. Getting that wrong is unusually
hard to diagnose: declaring it `dword` shifts every parameter by two, and
because the offset is the low word, the array, the counts, the element
size and the slot all still read correctly. Only the FIRST parameter --
furthest from bp -- runs off the end of the frame, so the symptom is one
wrong argument rather than five.

## 1. One dimension

    '' One element. The DIM exists so the compiler emits a descriptor.
    redim nds_buffer(0) as nodeb

    h_nds = uglArrNew1D&( UGL.EMS, nds_buffer(), wld.nds_count, NODE_SLOT )
    if ( h_nds = 0 ) then
        '' No EMS. Nothing below this line changes.
        h_nds = uglArrNew1D&( UGL.MEM, nds_buffer(), wld.nds_count, 0 )
    end if
    if ( h_nds = 0 ) then sys_error "0x0020, no room for the node tree"

    erase nds_buffer        '' REQUIRED -- see below

Then index with a global element number:

    sub r_recursive_world_node ( byval nodenr as integer )
        ...
        dummy = uglArrMap&( h_nds, nodenr )
        pid   = nds_buffer(nodenr).planeid      '' native syntax
        ...
    end sub

`uglArrMap` is a no-op when the element is already reachable, which the
page-fault measurements say is the overwhelmingly common case -- 5 faults
a frame against roughly 670 node visits on e1m1, 12 in the worst frame of
any shipped Quake map. So what costs is the CALL, not the mapping.

## 2. The ERASE rule

    ***  ERASE the array between New and the first Map.

That is not ceremony. It is what takes the descriptor out of the far
heap's chain, and only BASIC can do it correctly. Left in the chain,
`B$FHCompact` walks into a descriptor aimed at memory it does not own and
moves it. `uglArrFree` leaves the descriptor in the state BASIC treats as
already deallocated, so a stray ERASE afterwards returns at once.

## 3. Two and three dimensions

The stub declares the RANK and the LOWER BOUNDS. New supplies the counts
and BASIC never allocates the elements:

    redim t(1 to 1, 0 to 0) as rec              '' one element, not 1200
    h_t = uglArrNew2D&( UGL.EMS, t(), 40, 30, LM_SLOT )
    erase t

    '' Map takes the LINEAR index; index the array with its real bounds.
    for i = 1 to 40
        for j = 0 to 29
            dummy = uglArrMap&( h_t, (i-1) * 30& + j )
            x = t(i, j).tag
        next j
    next i

Under `/R` the LAST subscript varies fastest, so the linear index is

    2-D   (i-l0)*c1 + (j-l1)
    3-D   (i-l0)*c1*c2 + (j-l1)*c2 + (k-l2)

Iterate the last subscript innermost or every step strides by a whole
dimension and the window thrashes.

Lower bounds are preserved. New recomputes the lower-bound term of
`AD_oAdjusted` from the real counts -- it cannot be captured from the
stub, whose own `oAdjusted` encodes c1 = c2 = 1. A wrong-rank stub is
refused rather than writing DM[1] over whatever follows the descriptor.

## 4. Backing types are not interchangeable

    typ        map costs               conventional    writes
    UGL.MEM    nothing                 the whole store direct
    UGL.EMS    an INT 67h remap        ~16 bytes       direct
    UGL.XMS    declared, refused

`UGL.MEM` earns its place beyond a fallback: it makes the paged and
resident paths identical, so a differential test can run the same walk
twice and diff the results. That is the test that catches offset
arithmetic, which is where the bugs are -- a single-store test agrees
with whatever the implementation happens to do.

Store layout is PAGE padded, not element padded: page p begins at store
byte p*16384 and holds (16384 \ elemSize) elements. For a 22-byte record
that wastes 16 bytes a page rather than 10 bytes an element -- 64 bytes
against 27,500 on e1m1's node tree.

## 5. `/D` is useful here

New writes the real element count into `DM_cElements`, and `/D` routes
array accesses through `B$HARY`, which bounds-checks against the LIVE
descriptor. So a `/D` build catches an out-of-array subscript on a paged
array exactly as it would on a resident one.

Narrowing that to a per-PAGE guard -- setting `DM_iLbound = pbase` and
`DM_cElements = perpg` on each map, so an out-of-window subscript traps
instead of reading a plausible wrong element -- is possible but NOT
implemented. `/D` costs a far call per access either way, so it belongs
in a debug configuration.

## Do not

- `REDIM` a live array. `B$RDIM` calls `B$ERAS`, which deallocates
  through the descriptor -- into memory BASIC does not own. Nothing makes
  REDIM harmless; Free first.
- Reuse the stub array for anything else while its handle is live.
- Assume a subscript order. It is `/R` row-major in this project; read
  the stride from the descriptor if that is ever in doubt.
- Trust a test that only checks values read back through `arr(i)`. Those
  work off Map's side effect on the descriptor and pass even when the
  returned handle is garbage. Assert that a deliberately BAD handle
  returns 0 -- that is the check that catches a broken return.
