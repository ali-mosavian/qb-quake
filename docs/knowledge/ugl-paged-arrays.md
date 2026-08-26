# uglArr* -- paged arrays with native QB indexing

Backs a BASIC array with EMS, XMS or conventional memory and keeps
`arr(i)` / `arr(i,j)` working. The point is that the call sites do not
change: the same walk compiles against a resident array and a paged one,
and the backing store is chosen at runtime.

Mechanism and hazards: [qb-array-remapping.md](qb-array-remapping.md).

## API

    uglArrNew&   (typ, elemSize, count, slot)   -> handle, 0 on failure
    uglArrBind%  (h, SEG a(0))                  -> nonzero on success
    uglArrBind2% (h, SEG a(0,0), d0, d1)        -> two dimensions
    uglArrSeek    h, i                          -> element i reachable
    uglArrSeek2   h, i, j
    uglArrPtr&   (h)                            -> window pointer, for I/O
    uglArrSpan&  (h)                            -> bytes reachable from it
    uglArrPer%   (h)                            -> elements per window
    uglArrWindows% (h)                          -> how many can be live at once
    uglArrIdle    h                             -> make the array inert
    uglArrFree    h                             -> flush, free, deallocate safely

`typ` is `UGL.EMS`, `UGL.XMS` or `UGL.MEM`. `slot` is the EMS physical
page and is ignored by the others.

## 1. Load time

    '' One element only. The DIM exists so the compiler emits a
    '' descriptor; uglArrBind takes it over and orphans it.
    redim nds_buffer(0) as nodeb

    h_nds = uglArrNew&( UGL.EMS, len(nds_buffer(0)), wld.nds_count, NODE_SLOT )
    if ( h_nds = 0 ) then
        '' No EMS. Nothing below this line changes.
        h_nds = uglArrNew&( UGL.MEM, len(nds_buffer(0)), wld.nds_count, 0 )
    end if
    if ( h_nds = 0 ) then sys_error "0x0020, no room for the node tree"

    if ( uglArrBind%( h_nds, seg nds_buffer(0) ) = 0 ) then
        sys_error "0x0021, node descriptor not found"
    end if

Filling it reads straight into the window -- no staging buffer, which is
the whole point of not landing it in conventional memory first:

    dim f as FILE
    dim n as long, want as long

    if ( fileOpen( f, "nodes.bin", F4READ ) = 0 ) then
        sys_error "0x0022, nodes.bin missing"
    end if

    n = 0
    while ( n < wld.nds_count )
        uglArrSeek h_nds, n
        want = uglArrSpan&( h_nds )
        if ( want > (wld.nds_count - n) * clng( len( nds_buffer(0) ) ) ) then
            want = (wld.nds_count - n) * clng( len( nds_buffer(0) ) )
        end if
        if ( fileReadH( f, uglArrPtr&( h_nds ), want ) <> want ) then
            sys_error "0x0023, nodes.bin short read"
        end if
        n = n + want \ clng( len( nds_buffer(0) ) )
    wend
    fileClose f

## 2. The hot path

    sub r_recursive_world_node ( byval nodenr as integer )
        ...
        uglArrSeek h_nds, nodenr
        pid = nds_buffer(nodenr).planeid        '' global index, native syntax
        ...
    end sub

`uglArrSeek` is a no-op when the element is already reachable, which the
page-fault measurements say is the overwhelmingly common case -- 5 faults
a frame against roughly 670 node visits on e1m1, 12 in the worst frame of
any shipped Quake map. So what costs is the CALL, not the mapping. If a
null far call turns out to matter, hoist the test:

    if ( nodenr \ nds_per <> nds_cur ) then
        uglArrSeek h_nds, nodenr
        nds_cur = nodenr \ nds_per
    end if
    pid = nds_buffer(nodenr).planeid

with `nds_per = uglArrPer%( h_nds )` cached once. Measure before choosing:
the inline form duplicates state that can go stale.

## 3. Two dimensions

    redim lmt(0, 0) as integer          '' shape comes from uglArrBind2
    h_lmt = uglArrNew&( UGL.EMS, 2, clng(cols) * clng(rows), LM_SLOT )
    uglArrBind2 h_lmt, seg lmt(0, 0), cols, rows

    '' The LAST subscript varies fastest -- measured, see
    '' qb-array-remapping.md -- so iterate it innermost or every step
    '' strides by a whole dimension and the window thrashes.
    for c = 0 to cols-1
        uglArrSeek2 h_lmt, c, 0
        for r = 0 to rows-1
            t = lmt(c, r)
        next r
    next c

Lower bounds are preserved: `uglArrBind` captures the compiler's
`AD_oAdjusted - FHD_oData` delta and folds it back into every seek, so
`redim a(1 to 4, 2 to 6)` pages correctly. Getting this wrong reads a
fixed distance off the start of every element and is invisible on
0-based arrays.

## 4. Backing types are not interchangeable

    typ        seek costs              conventional    writes
    UGL.MEM    nothing                 the whole store direct
    UGL.EMS    an INT 67h remap        ~16 bytes       direct
    UGL.XMS    a 16K copy in, and a    a staging       write-back on
               16K copy back if dirty  buffer          page change

XMS has one read window and one write window, not four independent slots,
so two XMS-backed arrays evict each other on every seek. Ask before
assuming two can be live:

    if ( uglArrWindows%( h ) < 2 ) then
        '' page one array and keep the other resident
    end if

`UGL.MEM` earns its place beyond a fallback: it makes the paged and
resident paths identical, so a differential test can run the same walk
twice and diff the results. That is the test that catches offset
arithmetic, which is where the bugs are.

## 5. Teardown

    uglArrIdle h_nds     '' zeroes FHD_hData: a stray ERASE is now a no-op
    ...
    uglArrFree h_nds     '' flushes a dirty XMS page, frees the store, and
                         '' leaves the descriptor in the deallocated state

`uglArrFree` must force the XMS flush. `xm$MapWrite` only writes a dirty
page back when a DIFFERENT page is mapped, so without it the last page
written is lost at shutdown.

## Do not

- `REDIM` or `ERASE` a bound array. `B$RDIM` calls `B$ERAS`, which
  deallocates through the descriptor -- into memory BASIC does not own.
  `uglArrIdle` makes ERASE harmless; nothing makes REDIM harmless.
- Assume a subscript order. Read the stride from the descriptor.
- Compile with `/D`. `DM_cElements` is set to the real count by
  `uglArrBind`, but the store is not one BASIC allocation and bounds
  checking has no way to know that.
