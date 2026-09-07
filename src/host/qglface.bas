option explicit
''
'' qglface.bas -- one real face, replayed into isolated buffers.
''
'' TEMPORARY, -qglface. Both renderers get the SAME frozen record, so a
'' difference here is scan conversion or the filler. It says nothing
'' about the adapter: mgl's production input is never captured.
''
'' COVERAGE IS NOT "pixel <> 0" -- index 0 is a byte a real texture may
'' sample. Each renderer draws twice, over backgrounds 0 and 255, and a
'' pixel is covered if it differs from the background in EITHER pass: an
'' uncovered pixel takes the background both times, and a sampled byte
'' cannot be both 0 and 255.
''
'' The oracle fetches the expected byte from the real texture. Comparing
'' a palette byte against a texel index only works for qgldiff's ramp.
''

defint a-z

'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'qgl.bi'

const FW = 160
const FH = 100
const FSLOT = 2

type FaceVtx
    x as single
    y as single
    z as single
    u as single
    v as single
end type

declare function uglDcSize ( byval dc as long, byval sel as integer ) as long

declare function qglFaceCnt () as integer
declare function qglFaceTex () as long
declare sub qglFaceFetch ( seg dst as any )

declare function qglSfScratch ( byval n as integer ) as long
declare function qglSfNew ( byval wid as integer, byval hgt as integer, _
                              byval whr as integer, byval slot as integer ) as long
declare function qglSfPget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare sub qglSfFree ( byval s as long )
declare sub qglDrFill ( byval d as long, byval x0 as integer, _
                          byval y0 as integer, byval x1 as integer, _
                          byval y1 as integer, byval col as integer )
declare sub qglClRect ( byval x0 as integer, byval y0 as integer, _
                          byval x1 as integer, byval y1 as integer )
declare function qglRsTex ( byval s as long ) as integer
declare sub qglRsMode ( byval m as integer )
declare sub qglRsPoly ( byval d as long, seg v as any, byval cnt as integer )
declare function qglSfAdoptEms ( byval dc as long, byval slot as integer, _
                                    byval s as long ) as integer

declare function qf_plane ( byval f0 as single, byval f1 as single, _
                            byval f2 as single, v() as FaceVtx, _
                            byval x as integer, byval y as integer ) as single
declare function qf_want ( v() as FaceVtx, byval dc as long, _
                           byval tw as integer, byval th as integer, _
                           byval x as integer, byval y as integer ) as integer
declare function qf_in ( v() as FaceVtx, byval n as integer, _
                        byval px as single, byval py as single, _
                        byval wind as single ) as integer
declare function qf_area ( v() as FaceVtx, byval n as integer ) as single
declare function qf_bit ( m() as integer, byval i as long ) as integer
declare sub qf_set ( m() as integer, byval i as long )
declare function qglFaceAll () as integer

'' twice the signed area, whose sign is the winding. Taken from the
'' polygon rather than assumed, so the judge does not inherit either
'' renderer's idea of which way round the vertices go.
function qf_area ( v() as FaceVtx, byval n as integer ) as single
    dim i as integer
    dim j as integer
    dim s as single

    for i = 0 to n - 1
        j = ( i + 1 ) mod n
        s = s + ( v(i).x * v(j).y - v(j).x * v(i).y )
    next i
    qf_area = s
end function

'' Is the point inside the convex polygon? A signed half-plane test per
'' edge, independent of both renderers: it knows the vertices and nothing
'' about how either one walks them.
''
'' The tie -- a point exactly on an edge -- goes to the top-left rule, so
'' two polygons sharing an edge neither gap nor draw it twice. It is
'' formal here: these coordinates never land exactly on an edge.
function qf_in ( v() as FaceVtx, byval n as integer, _
                 byval px as single, byval py as single, _
                 byval wind as single ) as integer
    dim i as integer
    dim j as integer
    dim ex as single
    dim ey as single
    dim cr as single

    qf_in = 0
    for i = 0 to n - 1
        j = ( i + 1 ) mod n
        ex = v(j).x - v(i).x
        ey = v(j).y - v(i).y
        cr = ( ex * ( py - v(i).y ) - ey * ( px - v(i).x ) ) * wind
        if ( cr < 0.0 ) then exit function
        if ( cr = 0.0 ) then
            '' top-or-left, with the edge oriented the winding's way
            if ( ey * wind > 0.0 ) then
            elseif ( ey = 0.0 and ex * wind < 0.0 ) then
            else
                exit function
            end if
        end if
    next i
    qf_in = -1
end function

'' eight bits a word: 2^7 is 128, where bit 15 would have been 32768 and
'' overflowed a signed integer
function qf_bit ( m() as integer, byval i as long ) as integer
    qf_bit = ( ( m( i \ 8 ) and ( 2 ^ ( i mod 8 ) ) ) <> 0 )
end function

sub qf_set ( m() as integer, byval i as long )
    m( i \ 8 ) = m( i \ 8 ) or ( 2 ^ ( i mod 8 ) )
end sub

'' linear over the face's plane; the face is planar so any three fix it
function qf_plane ( byval f0 as single, byval f1 as single, _
                    byval f2 as single, v() as FaceVtx, _
                    byval x as integer, byval y as integer ) as single
    dim a as single
    dim b as single
    dim c as single
    dim e as single
    dim dt as single

    a = v(1).x - v(0).x : b = v(1).y - v(0).y
    c = v(2).x - v(0).x : e = v(2).y - v(0).y
    dt = a * e - c * b
    if ( dt = 0.0 ) then
        qf_plane = f0
    else
        qf_plane = f0 + ( ( (f1-f0)*e - (f2-f0)*b ) / dt ) * ( x - v(0).x ) _
                      + ( ( a*(f2-f0) - c*(f1-f0) ) / dt ) * ( y - v(0).y )
    end if
end function

'' the byte the real texture holds at the exact u,v for this pixel.
'' qgldiff's convention, calibrated there: integer pixel coordinates,
'' round to nearest texel, wrap by AND.
function qf_want ( v() as FaceVtx, byval dc as long, _
                   byval tw as integer, byval th as integer, _
                   byval x as integer, byval y as integer ) as integer
    dim zp as single
    dim uu as long
    dim vv as long

    zp = qf_plane( v(0).z, v(1).z, v(2).z, v(), x, y )
    if ( zp = 0.0 ) then
        qf_want = -1
        exit function
    end if
    uu = int( ( qf_plane( v(0).u, v(1).u, v(2).u, v(), x, y ) / zp ) * tw + 0.5 )
    vv = int( ( qf_plane( v(0).v, v(1).v, v(2).v, v(), x, y ) / zp ) * th + 0.5 )
    qf_want = uglPGet( dc, uu and (tw-1), vv and (th-1) )
end function

function qglFaceAll () as integer
    dim lg as integer
    dim n as integer
    dim i as integer
    dim x as integer
    dim y as integer
    dim bi as long
    dim dc as long
    dim d0 as long
    dim qt as long
    dim v(15) as FaceVtx
    dim t(15) as vector3f
    dim mm(1999) as integer
    dim qm(1999) as integer
    dim mcov as integer
    dim qcov as integer
    dim mbad as integer
    dim qbad as integer
    dim xr as integer
    dim fx as integer
    dim fy as integer
    dim tw as integer
    dim th as integer
    dim a as integer
    dim w as integer
    dim bad as integer
    dim wind as single
    dim ic as integer
    dim ih as integer
    dim ocov as integer
    dim hcov as integer
    dim omx as integer
    dim oqx as integer
    dim hmx as integer
    dim hqx as integer
    dim ofx as integer
    dim ofy as integer
    dim qfx as integer
    dim qfy as integer

    lg = freefile
    open "qglface.log" for output as #lg

    n = qglFaceCnt()
    dc = qglFaceTex()
    if ( n < 3 or dc = 0 ) then
        print #lg, "   FAIL nothing captured: n"; n; " dc"; dc
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if

    qglFaceFetch v(0)

    '' uglDcSize ends in `dec ax`, so it answers xRes-1; the patched
    '' uglplxtp.asm scales by xRes. The wrap below is an AND, so refuse
    '' anything that is not a power of two.
    tw = uglDcSize( dc, 0 ) + 1
    th = uglDcSize( dc, 1 ) + 1
    print #lg, "   face n"; n; " tex"; tw; "x"; th
    print #lg, "   oracle: integer pixel, nearest texel, AND wrap"
    if ( (tw and (tw-1)) <> 0 or (th and (th-1)) <> 0 ) then
        print #lg, "   FAIL texture not a power of two"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if

    for i = 0 to n - 1
        print #lg, "     v"; i; v(i).x; v(i).y; v(i).z; v(i).u; v(i).v
        t(i).x = v(i).x : t(i).y = v(i).y : t(i).z = v(i).z
        t(i).u = v(i).u : t(i).v = v(i).v
    next i

    ''
    '' mgl: one destination, two backgrounds
    ''
    d0 = uglNew( ugl.mem, ugl.8bit, FW, FH )
    if ( d0 = 0 ) then
        print #lg, "   FAIL no mgl buffer"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if
    for i = 0 to 1
        if ( i = 0 ) then a = 0 else a = 255
        uglClear d0, a
        uglPolyTP d0, t(0), n, 0, dc
        for y = 0 to FH - 1
            for x = 0 to FW - 1
                w = uglPGet( d0, x, y )
                if ( w <> a ) then
                    bi = clng(y) * FW + x
                    if ( qf_bit( mm(), bi ) = 0 ) then
                        qf_set mm(), bi
                        mcov = mcov + 1
                        if ( w <> qf_want( v(), dc, tw, th, x, y ) ) then
                            mbad = mbad + 1
                        end if
                    end if
                end if
            next x
        next y
    next i
    uglDel d0

    ''
    '' qgl, the same way, after the mgl buffer is gone
    ''
    d0 = qglSfNew( FW, FH, QGL_SURF_CMEM, 0 )
    qt = qglSfScratch( 0 )
    if ( d0 = 0 ) then
        print #lg, "   FAIL no qgl buffer"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if
    if ( qglSfAdoptEms( dc, FSLOT, qt ) = 0 ) then
        print #lg, "   FAIL texture would not adopt"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if
    if ( qglRsTex( qt ) = 0 ) then
        print #lg, "   FAIL qglRsTex refused"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if
    qglClRect 0, 0, FW - 1, FH - 1
    qglRsMode QGL_M_PTEX

    for i = 0 to 1
        if ( i = 0 ) then a = 0 else a = 255
        qglDrFill d0, 0, 0, FW - 1, FH - 1, a
        qglRsPoly d0, v(0), n
        for y = 0 to FH - 1
            for x = 0 to FW - 1
                w = qglSfPget( d0, x, y )
                if ( w <> a ) then
                    bi = clng(y) * FW + x
                    if ( qf_bit( qm(), bi ) = 0 ) then
                        qf_set qm(), bi
                        qcov = qcov + 1
                        if ( w <> qf_want( v(), dc, tw, th, x, y ) ) then
                            qbad = qbad + 1
                        end if
                    end if
                end if
            next x
        next y
    next i
    qglSfFree d0

    '' The oracle is evaluated here rather than stored: it is a pure
    '' function of x and y, and two more 4,000-byte masks in DGROUP is
    '' the cost that already forced mb() out of this routine.
    ''
    '' TWO sample points, because the sample point is exactly what is in
    '' question. Row j covers y in [j, j+1), so its centre is j+0.5 and
    '' that is the geometrically right one; the integer point is logged
    '' beside it to say which convention each renderer actually walks.
    wind = qf_area( v(), n )
    if ( wind > 0.0 ) then wind = 1.0 else wind = -1.0

    fx = -1
    ofx = -1
    qfx = -1
    for y = 0 to FH - 1
        for x = 0 to FW - 1
            bi = clng(y) * FW + x
            ic = qf_in( v(), n, x + 0.5, y + 0.5, wind )
            ih = qf_in( v(), n, csng(x), csng(y), wind )
            if ( ic ) then ocov = ocov + 1
            if ( ih ) then hcov = hcov + 1

            if ( qf_bit( mm(), bi ) <> qf_bit( qm(), bi ) ) then
                xr = xr + 1
                if ( fx < 0 ) then
                    fx = x
                    fy = y
                end if
            end if
            if ( ic <> qf_bit( mm(), bi ) ) then
                omx = omx + 1
                if ( ofx < 0 ) then
                    ofx = x
                    ofy = y
                end if
            end if
            if ( ic <> qf_bit( qm(), bi ) ) then
                oqx = oqx + 1
                if ( qfx < 0 ) then
                    qfx = x
                    qfy = y
                end if
            end if
            if ( ih <> qf_bit( mm(), bi ) ) then hmx = hmx + 1
            if ( ih <> qf_bit( qm(), bi ) ) then hqx = hqx + 1
        next x
    next y

    print #lg, "   coverage mgl"; mcov; " qgl"; qcov; " mask xor"; xr
    if ( fx >= 0 ) then print #lg, "   first disagreement at"; fx; fy
    print #lg, "   oracle centre cov"; ocov; " xor mgl"; omx; " qgl"; oqx
    if ( ofx >= 0 ) then print #lg, "     first vs mgl at"; ofx; ofy
    if ( qfx >= 0 ) then print #lg, "     first vs qgl at"; qfx; qfy
    print #lg, "   oracle integer cov"; hcov; " xor mgl"; hmx; " qgl"; hqx
    print #lg, "   off exact: mgl"; mbad; " qgl"; qbad

    '' The oracle decides, not mgl. mgl is a second implementation with
    '' its own conventions; only the half-plane test is independent of
    '' both.
    if ( oqx <> 0 ) then
        print #lg, "RESULT FAIL qgl coverage differs from the oracle --"
        print #lg, "       qgl scan conversion is wrong"
        bad = 1
    elseif ( xr <> 0 ) then
        print #lg, "RESULT PASS-ORACLE qgl matches the oracle and mgl"
        print #lg, "       does not; the mgl divergence is expected"
        bad = 0
    elseif ( qbad > mbad ) then
        print #lg, "RESULT FAIL same input and coverage, qgl further"
        print #lg, "       from exact -- gradients or filler"
        bad = 1
    else
        print #lg, "RESULT PASS for the scanner on this face. The"
        print #lg, "       adapter is NOT tested here."
    end if

    close #lg

    '' -qglface only: hold in mode 19 so text_screen, screenshot and
    '' where can all land while the program is live. The measurement is
    '' already written; this only keeps the guest up to be looked at.
    dim t0 as single
    t0 = timer
    while ( timer - t0 < 120.0 and timer >= t0 )
    wend

    qglFaceAll = bad
end function
