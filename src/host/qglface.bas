option explicit
''
'' qglface.bas -- one real face, replayed into isolated buffers.
''
'' TEMPORARY, -qglface. One real frozen face, replayed into an isolated
'' buffer and judged by an exact oracle: a half-plane test for coverage
'' and a plane-fitted u,v for the texel. Nothing here is a second
'' renderer, which is the point -- mgl was that until the atlas became
'' a qgl Surface and no mgl entry could read one.
''
'' COVERAGE IS NOT "pixel <> 0" -- index 0 is a byte a real texture may
'' sample. The face is drawn twice, over backgrounds 0 and 255, and a
'' pixel is covered if it differs from the background in EITHER pass: an
'' uncovered pixel takes the background both times, and a sampled byte
'' cannot be both 0 and 255.
''
'' The oracle fetches the expected byte from the real texture, through
'' the same view qglRsPoly samples, and scales u,v by that VIEW's size --
'' which is what the rasteriser scales by too. Getting that from the
'' parent atlas instead is a 128x error waiting to look like a
'' rasteriser bug.
''

defint a-z

'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'qgl.bi'

const OFSW = 3
const FW = 160
const FH = 100

type FaceVtx
    x as single
    y as single
    z as single
    u as single
    v as single
end type


declare function qglFaceCnt () as integer
declare function qglFaceTex () as long
declare function qglFaceOfs () as long
declare function qglSfViewAim ( _
    byval s as long, _
    byval ofs as long _
) as integer
declare sub qglFaceFetch ( seg dst as any )

declare function qglSfNew ( byval wid as integer, byval hgt as integer, _
                              byval whr as integer ) as long
declare function qglSfPget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare sub qglSfFree ( byval s as long )
declare sub qglDrFill ( byval d as long, byval x0 as integer, _
                          byval y0 as integer, byval x1 as integer, _
                          byval y1 as integer, byval col as integer )
declare sub qglClRect ( byval x0 as integer, byval y0 as integer, _
                          byval x1 as integer, byval y1 as integer )
declare function qglRsPoly ( byval d as long, _
                             seg v as any, _
                             byval cnt as integer, _
                             byval mode as integer, _
                             byval src as long, _
                             byval zsf as long, _
                             byval zmode as integer ) as integer
declare function qglSfSize ( byval s as long, byval sel as integer ) as integer

declare function qf_plane ( byval f0 as single, byval f1 as single, _
                            byval f2 as single, v() as FaceVtx, _
                            byval x as single, byval y as single ) as single
declare function qf_want ( v() as FaceVtx, byval dc as long, _
                           byval tw as integer, byval th as integer, _
                           byval x as single, byval y as single ) as integer
declare function qf_at ( v() as FaceVtx, byval dc as long, _
                         byval tw as integer, byval th as integer, _
                         byval x as single, byval y as single, _
                         byval du as integer, byval dv as integer ) as integer
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
                    byval x as single, byval y as single ) as single
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
'' x and y are the pixel CENTRE, which is the same sample point the
'' coverage test uses and the one rs.asm's half-pixel puts the walk on.
'' The old integer-corner convention came from qgldiff and was mgl's;
'' mixing it with a centre-based coverage test compared two different
'' questions and reported 79 of 101 pixels wrong for it.
'' Nearest texel, wrap by AND.
function qf_want ( v() as FaceVtx, byval dc as long, _
                   byval tw as integer, byval th as integer, _
                   byval x as single, byval y as single ) as integer
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
    qf_want = qglSfPget( dc, uu and (tw-1), vv and (th-1) )
end function

'' qf_want, offset by whole texels. Same plane fit, same wrap: the only
'' difference is where it looks, which is the question.
function qf_at ( v() as FaceVtx, byval dc as long, _
                 byval tw as integer, byval th as integer, _
                 byval x as single, byval y as single, _
                 byval du as integer, byval dv as integer ) as integer
    dim zp as single
    dim uu as long
    dim vv as long

    zp = qf_plane( v(0).z, v(1).z, v(2).z, v(), x, y )
    if ( zp = 0.0 ) then
        qf_at = -1
        exit function
    end if
    uu = int( ( qf_plane( v(0).u, v(1).u, v(2).u, v(), x, y ) / zp ) * tw + 0.5 ) + du
    vv = int( ( qf_plane( v(0).v, v(1).v, v(2).v, v(), x, y ) / zp ) * th + 0.5 ) + dv
    qf_at = qglSfPget( dc, uu and (tw-1), vv and (th-1) )
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
    dim v(15) as FaceVtx
    dim qm(1999) as integer
    dim qcov as integer
    dim qbad as integer
    dim tw as integer
    dim th as integer
    dim a as integer
    dim w as integer
    dim bad as integer
    dim wind as single
    dim rowstr as string
    dim ic as integer
    dim ih as integer
    dim ocov as integer
    dim hcov as integer
    dim oqx as integer
    dim hqx as integer
    dim du as integer
    dim dv as integer
    dim bestd as integer
    dim bestu as integer
    dim bestv as integer
    dim nmatch as integer
    dim qamb as integer
    dim qnone as integer
    dim ofs(80) as integer
    dim qfx as integer
    dim qfy as integer
    dim zm as integer

    lg = freefile
    open "qglface.log" for output as #lg

    n = qglFaceCnt()
    dc = qglFaceTex()
    '' The view is NOT re-aimed here, though the frozen face's own aim is
    '' captured (qglFaceOfs) and every later face re-aims this same view.
    '' Calling qglSfViewAim before the replay took coverage from 1758 to
    '' 0 on an unchanged face -- the poly stopped rasterising entirely,
    '' which no texture aim explains. Left out until that is understood;
    '' the replay runs right after the frame that froze the face, so the
    '' aim is at most a few faces stale.
    if ( n < 3 or dc = 0 ) then
        print #lg, "   FAIL nothing captured: n"; n; " dc"; dc
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if

    qglFaceFetch v(0)

    '' The VIEW's size, which is what qglRsPoly scales u and v by -- not
    '' the parent atlas's. The wrap below is an AND, so refuse anything
    '' that is not a power of two.
    tw = qglSfSize( dc, 0 )
    th = qglSfSize( dc, 1 )
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
    next i

    ''
    '' qgl against the oracle. There is no mgl arm any more: dc is a
    '' qgl view (mod_tex.bas / d_surf.bas) and no mgl entry can read
    '' one, so the half-plane test is the only second opinion left --
    '' which was always the one that decided anyway.
    ''
    d0 = qglSfNew( FW, FH, QGL_SURF_CMEM )
    if ( d0 = 0 ) then
        print #lg, "   FAIL no qgl buffer"
        print #lg, "RESULT FAIL"
        close #lg
        qglFaceAll = 1
        exit function
    end if
    qglClRect 0, 0, FW - 1, FH - 1

    for i = 0 to 1
        if ( i = 0 ) then a = 0 else a = 255
        qglDrFill d0, 0, 0, FW - 1, FH - 1, a
        '' Depth OFF, and a refusal is a failure: the texture is
        '' validated inside the draw now, so a bad one shows up here.
        zm = qglRsPoly%( d0, v(0), n, QGL_M_PTEX, dc, 0, QGL_Z_OFF )
        if ( zm < 0 ) then
            print #lg, "   FAIL qglRsPoly refused the texture"
            print #lg, "RESULT FAIL"
            close #lg
            qglFaceAll = 1
            exit function
        end if
        for y = 0 to FH - 1
            for x = 0 to FW - 1
                w = qglSfPget( d0, x, y )
                if ( w <> a ) then
                    bi = clng(y) * FW + x
                    if ( qf_bit( qm(), bi ) = 0 ) then
                        qf_set qm(), bi
                        qcov = qcov + 1
                        if ( w <> qf_want( v(), dc, tw, th, x + 0.5, y + 0.5 ) ) then
                            qbad = qbad + 1
                            ''
                            '' WHICH texel did it take? Sweep a small
                            '' offset window and record every (du,dv)
                            '' that would have matched. A bug is one
                            '' cell of this histogram carrying nearly
                            '' every mismatch; aliasing under
                            '' minification scatters it.
                            ''
                            '' ONE cell per pixel, the nearest offset that
                            '' matches. Incrementing every match instead
                            '' let a single pixel add up to 49 counts --
                            '' 256 palette values over 4096 texels collide
                            '' constantly -- so the totals exceeded the
                            '' pixel count and every distribution came out
                            '' flat. That reported "u drifts, v does not"
                            '' off pure noise.
                            bestd = 99
                            bestu = 0
                            bestv = 0
                            nmatch = 0
                            for du = -OFSW to OFSW
                                for dv = -OFSW to OFSW
                                    if ( w = qf_at( v(), dc, tw, th, _
                                                    x + 0.5, y + 0.5, _
                                                    du, dv ) ) then
                                        nmatch = nmatch + 1
                                        if ( abs(du) + abs(dv) < bestd ) then
                                            bestd = abs(du) + abs(dv)
                                            bestu = du
                                            bestv = dv
                                        end if
                                    end if
                                next dv
                            next du
                            if ( nmatch = 0 ) then
                                qnone = qnone + 1
                            else
                                if ( nmatch > 1 ) then qamb = qamb + 1
                                ofs( (bestv+OFSW)*(2*OFSW+1) + bestu+OFSW ) = _
                                    ofs( (bestv+OFSW)*(2*OFSW+1) + bestu+OFSW ) + 1
                            end if
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

    qfx = -1
    for y = 0 to FH - 1
        for x = 0 to FW - 1
            bi = clng(y) * FW + x
            ic = qf_in( v(), n, x + 0.5, y + 0.5, wind )
            ih = qf_in( v(), n, csng(x), csng(y), wind )
            if ( ic ) then ocov = ocov + 1
            if ( ih ) then hcov = hcov + 1

            if ( ic <> qf_bit( qm(), bi ) ) then
                oqx = oqx + 1
                if ( qfx < 0 ) then
                    qfx = x
                    qfy = y
                end if
            end if
            if ( ih <> qf_bit( qm(), bi ) ) then hqx = hqx + 1
        next x
    next y

    print #lg, "   qgl coverage"; qcov
    print #lg, "   oracle centre cov"; ocov; " xor qgl"; oqx
    if ( qfx >= 0 ) then print #lg, "     first vs qgl at"; qfx; qfy
    print #lg, "   oracle integer cov"; hcov; " xor qgl"; hqx
    print #lg, "   off exact:"; qbad; " of"; qcov
    '' Ambiguous ones matched more than one offset and were charged to the
    '' nearest; unmatched ones matched none in the window at all, which no
    '' texel shift explains. A large qnone says stop reading the histogram.
    print #lg, "   ambiguous:"; qamb; " unmatched:"; qnone
    ''
    '' The offset histogram, dv down and du across. One dominant cell
    '' names a constant texel shift; a spread means the face is
    '' minified past the point where an exact test can decide.
    ''
    print #lg, "   which texel it took (dv rows, du cols, -"; OFSW; "..+"; OFSW; ")"
    for dv = -OFSW to OFSW
        rowstr = "     "
        for du = -OFSW to OFSW
            rowstr = rowstr + right$( "     " + _
                ltrim$(str$( ofs( (dv+OFSW)*(2*OFSW+1) + du+OFSW ) )), 6 )
        next du
        print #lg, rowstr
    next dv

    '' The oracle decides. Coverage first -- a scan-conversion fault
    '' moves the silhouette -- then the texel, which is the mapping.
    '' Reported separately because they fail for different reasons and
    '' the first tells you not to read the second.
    if ( qcov = 0 ) then
        print #lg, "RESULT FAIL nothing was drawn -- no face was frozen"
        print #lg, "       whole and on screen, so nothing was judged"
        bad = 1
    elseif ( oqx <> 0 ) then
        print #lg, "RESULT FAIL qgl coverage differs from the oracle --"
        print #lg, "       qgl scan conversion is wrong"
        bad = 1
    elseif ( qbad <> 0 ) then
        print #lg, "RESULT FAIL coverage exact,"; qbad; "pixels sample"
        print #lg, "       the wrong texel -- gradients or uv scale"
        bad = 1
    else
        print #lg, "RESULT PASS coverage and every texel exact"
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
