option explicit
''
'' qglarr.bas -- -qglarr. The paged-array store, against a real fixture.
''
'' A MEM store is one flat window: perpg = cnt, so the single map every
'' caller does at load binds the whole array. An EMS store is windowed at
'' 16,384 bytes, so that same single map binds only the first page -- and
'' every element past it reads whatever is mapped there now,
'' successfully and wrongly. q_map.bi:223 states the contract the
'' traversal does not keep.
''
'' faces.pag is the fixture because it is real map data that CROSSES the
'' boundary: 22,926 bytes against a 16,384-byte window. clip.pag was the
'' first choice and is 9,888 -- one window, so it would have proved
'' nothing, and the guard below is what said so rather than a green tick.
''
'' The record size here is the store's unit, not the Face layout: this
'' tests the STORE, and a round trip only needs both sides to read the
'' same file the same way.
''
'' mgl's MEM store is the reference. It is the path production takes and
'' the one whose flatness is established, and using it rather than a
'' second qgl store means a fault common to both cannot pass.
''

defint a-z

'' dos.bi FIRST: arch.bi says so in its own header.
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'ems.bi'

const ARR_WIN = 16384
const ARR_REC = 6
const ARR_SLOT = 2              '' mgl reads through 0, writes 1, depth 3

const QGL_AR_MEM = 0
const QGL_AR_EMS = 1

const NPROBE = 16
const NFIX = 3                  '' the three that must be named, not sampled

'' 6 bytes, ClipNode's shape. bspfile.bi is not included for it -- the
'' store cares about the size and nothing else, and pulling the whole
'' BSP header chain in here is what exhausts BC's symbol table.
type ArrRec
    a as integer
    b as integer
    c as integer
end type

declare function qglArNew ( byval typ as integer, byval elsz as integer, _
                              byval cnt as long, byval slot as integer ) as long
declare function qglArMap ( byval h as long, a() as any, _
                              byval idx as long ) as long
declare function qglArWin ( byval h as long, byval idx as long ) as long
declare function qglArHandle ( byval h as long ) as integer
declare function qglArPerpg ( byval h as long ) as integer
declare function qglArPages ( byval h as long ) as integer
declare sub qglArFree ( byval h as long )
''
'' The archive reader, qgl's. mgl's uar carried an inflate and a UAR the
'' caller had to declare and then only pass back; every member is stored
'' now, and a handle is enough.
''
'' flname is NOT byval: VBDOS passes a plain "as string" parameter as a
'' near pointer to its descriptor, which is what the assembly's s:word
'' wants.
''
declare function qglZipOpenBas ( flname as string ) as integer
declare function qglZipSize ( byval h as integer ) as long
declare function qglZipRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglZipClose ( byval h as integer )

declare function qglArrAll () as integer
declare function qgl_arr_count ( n as long ) as integer
declare function qgl_arr_fill ( byval h as long, byval cnt as long ) as integer

'' The fixture's element count, off the archive rather than off a loaded
'' map: -qglarr runs before mod_open, which is the only point at which
'' all of the store slots are still free.
function qgl_arr_count ( n as long ) as integer
    dim u as integer
    dim sz as long

    qgl_arr_count = 0
    n = 0
    u = qglZipOpenBas( "assets.zip::faces.pag" )
    if ( u = 0 ) then exit function
    sz = qglZipSize( u )
    qglZipClose u
    if ( sz <= 0 ) then exit function
    n = sz \ ARR_REC
    qgl_arr_count = -1
end function

''
'' Streams the fixture into a store one window at a time, through the
'' accessor. This is uglArrLoad's job done by the caller: the archive
'' reader is mgl's and proven, and what qgl owns is where the bytes land.
''
'' A page carries perpg * ARR_REC bytes, NOT ARR_WIN. 16384 \ 6 is 2730
'' records = 16,380, and the remaining 4 bytes are padding the store
'' leaves alone so that no record straddles a page. Reading a full window
'' per page would split the record on the seam and shift every later one
'' by four bytes -- which looks exactly like a mapping bug and is not.
''
function qgl_arr_fill ( byval h as long, byval cnt as long ) as integer
    dim u as integer
    dim pg as integer
    dim npg as integer
    dim perpg as long
    dim payload as long
    dim remain as long
    dim want as long
    dim p as long
    dim hnd as integer
    dim sg as integer

    qgl_arr_fill = 0
    perpg = qglArPerpg( h )
    npg = qglArPages( h )
    hnd = qglArHandle( h )
    if ( perpg <= 0 or npg <= 0 or hnd = 0 ) then exit function
    payload = perpg * ARR_REC
    remain = cnt * ARR_REC

    u = qglZipOpenBas( "assets.zip::faces.pag" )
    if ( u = 0 ) then exit function

    for pg = 0 to npg - 1
        ''
        '' emsMapEx DIRECTLY, by explicit page index, at offset 0. NOT
        '' qglArMap: a test whose write path and read path share the
        '' mapping arithmetic cannot see a fault in it. Pinning the page
        '' to 0 moved the loader and the reader together -- the file was
        '' written contiguously across the page frame and read back from
        '' the same addresses -- and the round trip still agreed, so a
        '' mutation that broke paging outright stayed green.
        ''
        sg = emsMapEx( hnd, pg, ARR_SLOT )
        if ( sg = 0 ) then
            qglZipClose u
            exit function
        end if
        p = clng( sg ) * 65536
        want = payload
        if ( want > remain ) then want = remain
        if ( qglZipRead( u, p, want ) <> want ) then
            qglZipClose u
            exit function
        end if
        remain = remain - want
    next pg

    qglZipClose u
    if ( remain <> 0 ) then exit function
    qgl_arr_fill = -1
end function

function qglArrAll () as integer
    dim lg as integer
    dim i as integer
    dim cnt as long
    dim perpg as long
    dim h as long
    dim hq as long
    dim mapped as long
    dim p as long
    dim idx(NPROBE) as long
    dim ref(NPROBE) as long
    dim got(NPROBE) as long
    dim nlo as integer
    dim nhi as integer
    dim badlo as integer
    dim badhi as integer
    dim firstbad as long
    dim bad as integer
    dim t0 as single
    dim ptr(NFIX) as long
    dim a(0) as ArrRec

    lg = freefile
    open "qglarr.log" for output as #lg

    if ( qgl_arr_count( cnt ) = 0 ) then
        print #lg, "   FAIL faces.pag would not size"
        print #lg, "RESULT FAIL"
        close #lg
        qglArrAll = 1
        exit function
    end if

    perpg = ARR_WIN \ ARR_REC
    print #lg, "   faces.pag"; cnt; "recs of"; ARR_REC; "="; cnt * ARR_REC; "bytes"
    print #lg, "   one window holds"; perpg; "recs ="; perpg * ARR_REC; "bytes"

    if ( cnt <= perpg ) then
        print #lg, "   FAIL fixture does not cross a window; it proves nothing"
        print #lg, "RESULT FAIL"
        close #lg
        qglArrAll = 1
        exit function
    end if

    ''
    '' The three that must be named rather than sampled: the last record
    '' of page 0, the first of page 1, and the last of the array. They
    '' cover the record/padding seam and the final page's allocation, so
    '' a store that is simply too small cannot pass as a mapping fault.
    ''
    idx(0) = perpg - 1
    idx(1) = perpg
    idx(2) = cnt - 1
    for i = NFIX to NPROBE - 1
        if ( i < NFIX + ( NPROBE - NFIX ) \ 2 ) then
            idx(i) = ( clng(i) * perpg ) \ NPROBE
        else
            idx(i) = perpg + ( ( clng(i) - NFIX ) * ( cnt - perpg ) ) \ NPROBE
            if ( idx(i) > cnt - 1 ) then idx(i) = cnt - 1
        end if
    next i
    for i = 0 to NPROBE - 1
        if ( idx(i) < perpg ) then nlo = nlo + 1 else nhi = nhi + 1
    next i

    ''
    '' the reference: mgl, MEM, flat, one window
    ''
    redim a(0) as ArrRec
    h = uglArrLoad( "assets.zip::faces.pag", UGL.MEM, ARR_REC, cnt, 0 )
    if ( h = 0 ) then
        print #lg, "   FAIL no mgl MEM store for the reference"
        print #lg, "RESULT FAIL"
        close #lg
        qglArrAll = 1
        exit function
    end if
    erase a
    mapped = uglArrMap( h, a(), 0 )
    for i = 0 to NPROBE - 1
        ref(i) = clng( a( idx(i) ).a ) * 65536 + ( clng( a( idx(i) ).b ) and 65535 )
    next i
    uglArrFree h

    ''
    '' the subject: qgl, EMS, windowed, read through the accessor -- one
    '' map per requested index, which is the contract
    ''
    redim a(0) as ArrRec
    hq = qglArNew( QGL_AR_EMS, ARR_REC, cnt, ARR_SLOT )
    if ( hq = 0 ) then
        print #lg, "   FAIL qglArNew refused an EMS store"
        print #lg, "RESULT FAIL"
        close #lg
        qglArrAll = 1
        exit function
    end if
    print #lg, "   qgl store: perpg"; qglArPerpg( hq ); " pages"; qglArPages( hq )

    if ( qgl_arr_fill( hq, cnt ) = 0 ) then
        print #lg, "   FAIL the fixture would not stream into the store"
        print #lg, "RESULT FAIL"
        qglArFree hq
        close #lg
        qglArrAll = 1
        exit function
    end if

    erase a
    firstbad = -1
    for i = 0 to NPROBE - 1
        p = qglArMap( hq, a(), idx(i) )
        if ( p = 0 ) then
            print #lg, "   FAIL qglArMap refused element"; idx(i)
            print #lg, "RESULT FAIL"
            qglArFree hq
            close #lg
            qglArrAll = 1
            exit function
        end if
        got(i) = clng( a( idx(i) ).a ) * 65536 + ( clng( a( idx(i) ).b ) and 65535 )
        if ( i < NFIX ) then ptr(i) = p
    next i

    '' The pointer the accessor handed back, per named probe. If these do
    '' not move between page 0 and page 1 the store is not paging, and a
    '' green result would be measuring something other than the remap.
    for i = 0 to NFIX - 1
        print #lg, "     ptr at"; idx(i); " ="; ptr(i)
    next i
    ''
    '' TEARDOWN, deliberately exercised. qglArFree must detach the
    '' descriptor before releasing the memory behind it, or this erase
    '' hands B$FHDealloc a pointer into memory BASIC never owned and the
    '' run ends "Far heap corrupt" -- after the log is written, which is
    '' why it was invisible until a screenshot caught it on screen.
    ''
    qglArFree hq
    erase a
    redim a(0) as ArrRec

    for i = 0 to NPROBE - 1
        if ( ref(i) <> got(i) ) then
            if ( idx(i) < perpg ) then badlo = badlo + 1 else badhi = badhi + 1
            if ( firstbad < 0 ) then firstbad = idx(i)
        end if
    next i

    print #lg, "   named: last of pg0"; idx(0); " first of pg1"; idx(1); _
               " last"; idx(2)
    for i = 0 to NFIX - 1
        if ( ref(i) <> got(i) ) then
            print #lg, "     MISMATCH at"; idx(i); " want"; ref(i); " got"; got(i)
        else
            print #lg, "     ok at"; idx(i)
        end if
    next i
    print #lg, "   probes"; nlo; "below the window,"; nhi; "at or above"
    print #lg, "   mismatch vs mgl MEM: below"; badlo; " above"; badhi
    if ( firstbad >= 0 ) then print #lg, "   first at element"; firstbad

    if ( badlo <> 0 ) then
        print #lg, "RESULT FAIL wrong INSIDE the first window -- not the"
        print #lg, "       paging bug, something worse"
        bad = 1
    elseif ( badhi <> 0 ) then
        print #lg, "RESULT FAIL wrong past the first window: the store is"
        print #lg, "       not remapping on the requested index"
        bad = 1
    else
        print #lg, "RESULT PASS qgl EMS matches mgl MEM across the window"
        print #lg, "       boundary, on both sides and at the last record"
    end if

    close #lg

    '' -qglarr only: hold so status, text_screen, screenshot and where
    '' can all land while the program is still live. The result is
    '' already on disk; this only keeps the process up to be looked at.
    t0 = timer
    while ( timer - t0 < 25.0 )
    wend

    qglArrAll = bad
end function
