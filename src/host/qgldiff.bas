option explicit
''
'' qgldiff.bas -- qgl's rasteriser against mgl's, on the same triangle.
''
'' -qgldiff runs this and exits.
''
'' t10ref already draws every polygon twice, but both times through qgl's
'' own scanner and its own gradients: it proves the patched fillers agree
'' with the reference filler and cannot say a word about the scan
'' conversion above them. A wrong edge walk, a wrong half-pixel
'' convention or a wrong gradient is identical in both of its arms.
''
'' mgl is a genuinely independent implementation -- its own scanner, its
'' own gradients, its own fillers -- so this is the arm that can see
'' those. It runs here, in BASIC inside qrender.exe, rather than in the
'' qgl suite, because UGLV.LIB is a __CMP__=VBD build: mgl's cold paths
'' call into the BASIC runtime, and a free-standing test that stubs them
'' is testing a different program. This one is the shipping build.
''
'' The library is the PATCHED one. Stock mgl scales normalised UVs to
'' texels by xRes-1 instead of xRes, so one repeat advances 63 texels
'' across a 64-wide texture; ugl-patch/README.md is that fix, and a
'' differential against the stock library would be measuring the bug.
''
'' Both drew SOMETHING is asserted apart from both drew the SAME. Two
'' empty destinations match perfectly.
''

defint a-z

'$include: 'ugl.bi'
'$include: 'qgl.bi'

const DIFF_W = 128
const DIFF_H = 96
const DIFF_TW = 64

'' qgl's vertex. x and y are screen, z is 1/z, u and v are normalised
'' over the texture -- the same five mgl's vector3f carries in its first
'' five fields, which is why one set of numbers fills both.
type QVertB
    x as single
    y as single
    z as single
    u as single
    v as single
end type

declare function qgl_sf_init () as integer
declare function qgl_sf_new ( byval wid as integer, byval hgt as integer, _
                              byval whr as integer, byval slot as integer ) as long
declare function qgl_sf_pget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare sub qgl_sf_pset ( byval s as long, byval x as integer, _
                          byval y as integer, byval c as integer )
declare sub qgl_sf_free ( byval s as long )
declare sub qgl_cl_rect ( byval x0 as integer, byval y0 as integer, _
                          byval x1 as integer, byval y1 as integer )
declare sub qgl_rs_tex ( byval s as long )
declare sub qgl_rs_mode ( byval m as integer )
declare sub qgl_rs_poly ( byval d as long, seg v as any, byval cnt as integer )
declare sub qgl_dr_fill ( byval d as long, byval x0 as integer, _
                          byval y0 as integer, byval x1 as integer, _
                          byval y1 as integer, byval col as integer )

declare function qgl_diff_texel ( byval x as integer, byval y as integer, _
                                  byval kind as integer ) as integer
declare sub qgl_diff_fill_tex ( byval mtex as long, byval qtex as long, _
                                byval kind as integer )
declare function qgl_diff_delta ( byval dc as long, byval s as long, _
                                  byval lo as integer ) as integer
declare sub qgl_diff_probe ( byval dc as long, byval s as long, _
                             byval shape as integer, byval fh as integer )
declare sub qgl_diff_tri ( v() as QVertB, t() as TriType, byval shape as integer )
declare function qgl_diff_mgl_drew ( byval dc as long ) as integer
declare function qgl_diff_qgl_drew ( byval s as long ) as integer
declare function qgl_diff_pixels ( byval dc as long, byval s as long ) as integer
declare function qgl_diff_case ( byval mode as integer, byval mdst as long, _
                                 byval mtex as long, byval qdst as long, _
                                 byval qtex as long, byval kind as integer, _
                                 byval shape as integer, nm as string, _
                                 byval fh as integer ) as integer
declare function qgl_diff_all () as integer

''
'' The texture, and it is an INSTRUMENT rather than a pattern.
''
'' kind 0 is a ramp in u alone and kind 1 a ramp in v alone, so a pixel's
'' value IS the texel column or row that was sampled and the difference
'' between two renderers reads directly as a sampling offset. kind 2 is
'' the usual no-two-alike pattern, which catches an error in either axis
'' but cannot say which axis or by how much -- and, wrapping at 255, it
'' turns a one-texel offset into a difference of 255 as readily as 1.
''
function qgl_diff_texel ( byval x as integer, byval y as integer, _
                          byval kind as integer ) as integer
    select case kind
        case 0
            qgl_diff_texel = x
        case 1
            qgl_diff_texel = y
        case else
            qgl_diff_texel = ( ( y * 8 + x ) and 255 )
    end select
end function

sub qgl_diff_fill_tex ( byval mtex as long, byval qtex as long, _
                        byval kind as integer )
    dim x as integer
    dim y as integer
    dim c as integer

    '' `c` first: BC reads a parenthesised function call inside a call
    '' statement's argument list as that statement's own argument list
    '' and reports an argument-count mismatch.
    for y = 0 to DIFF_TW - 1
        for x = 0 to DIFF_TW - 1
            c = qgl_diff_texel( x, y, kind )
            uglPSet mtex, x, y, c
            qgl_sf_pset qtex, x, y, c
        next x
    next y
end sub

''
'' The extreme of (mgl - qgl) over the pixels BOTH drew: lo nonzero for
'' the smallest, zero for the largest. Both, against a ramp texture, say
'' how far apart the two samplings are and whether the gap is constant.
''
'' 1 and 0 rather than TRUE and FALSE: this module includes only ugl.bi
'' and qgl.bi, and neither declares them.
''
'' Only where both drew: a pixel one of them left blank is a coverage
'' difference, which the drawn counts already report, and letting it into
'' this figure would swamp the number it exists to show.
''
function qgl_diff_delta ( byval dc as long, byval s as long, _
                          byval lo as integer ) as integer
    dim x as integer
    dim y as integer
    dim m as integer
    dim q as integer
    dim e as integer
    dim best as integer
    dim seen as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            m = uglPGet( dc, x, y )
            q = qgl_sf_pget( s, x, y )
            if ( m <> 0 and q <> 0 ) then
                e = m - q
                if ( seen = 0 ) then
                    best = e
                    seen = 1
                elseif ( lo <> 0 ) then
                    if ( e < best ) then best = e
                else
                    if ( e > best ) then best = e
                end if
            end if
        next x
    next y
    qgl_diff_delta = best
end function

''
'' One triangle, in both spellings, from one set of numbers. Not axis
'' aligned, and 1/z differs at every vertex, so u, v and 1/z all vary
'' along both edges and across every span -- which is what makes the
'' perspective arm differ from the affine one at all.
''
sub qgl_diff_tri ( v() as QVertB, t() as TriType, byval shape as integer )
    if ( shape = 0 ) then
        '' A RIGHT TRIANGLE ON THE AXES, 64 pixels on a side against a
        '' 64 texel texture and 1/z flat. Every gradient is then exactly
        '' one texel per pixel or exactly zero, so the profile can be
        '' read by eye and a wrong slope needs no arithmetic to see.
        v(0).x = 20.0 : v(0).y = 20.0 : v(0).z = 1.0
        v(0).u = 0.0  : v(0).v = 0.0
        v(1).x = 84.0 : v(1).y = 20.0 : v(1).z = 1.0
        v(1).u = 1.0  : v(1).v = 0.0
        v(2).x = 20.0 : v(2).y = 84.0 : v(2).z = 1.0
        v(2).u = 0.0  : v(2).v = 1.0
    else
        v(0).x = 20.0  : v(0).y = 12.0 : v(0).z = 1.0
        v(0).u = 0.0   : v(0).v = 0.0
        v(1).x = 104.0 : v(1).y = 30.0 : v(1).z = 0.5
        v(1).u = 1.0   : v(1).v = 0.0
        v(2).x = 52.0  : v(2).y = 80.0 : v(2).z = 0.25
        v(2).u = 0.0   : v(2).v = 1.0
    end if

    t(0).v1.x = v(0).x : t(0).v1.y = v(0).y : t(0).v1.z = v(0).z
    t(0).v1.u = v(0).u : t(0).v1.v = v(0).v
    t(0).v2.x = v(1).x : t(0).v2.y = v(1).y : t(0).v2.z = v(1).z
    t(0).v2.u = v(1).u : t(0).v2.v = v(1).v
    t(0).v3.x = v(2).x : t(0).v3.y = v(2).y : t(0).v3.z = v(2).z
    t(0).v3.u = v(2).u : t(0).v3.v = v(2).v
end sub

function qgl_diff_mgl_drew ( byval dc as long ) as integer
    dim x as integer
    dim y as integer
    dim n as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( uglPGet( dc, x, y ) <> 0 ) then n = n + 1
        next x
    next y
    qgl_diff_mgl_drew = n
end function

function qgl_diff_qgl_drew ( byval s as long ) as integer
    dim x as integer
    dim y as integer
    dim n as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( qgl_sf_pget( s, x, y ) <> 0 ) then n = n + 1
        next x
    next y
    qgl_diff_qgl_drew = n
end function

function qgl_diff_pixels ( byval dc as long, byval s as long ) as integer
    dim x as integer
    dim y as integer
    dim n as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( uglPGet( dc, x, y ) <> qgl_sf_pget( s, x, y ) ) then n = n + 1
        next x
    next y
    qgl_diff_pixels = n
end function

''
'' What each renderer put at four points inside the triangle. A range
'' says how far apart two samplings are; only the values themselves say
'' in which direction, which is the difference between a half-pixel
'' convention and a mapping that is turned around.
''
sub qgl_diff_probe ( byval dc as long, byval s as long, _
                     byval shape as integer, byval fh as integer )
    dim x as integer
    dim y as integer

    '' Two scanlines, so the profile shows the gradient in BOTH axes. A
    '' single row cannot tell a wrong du/dx from a wrong du/dy.
    if ( shape = 0 ) then
        y = 30
    else
        y = 40
    end if
    for x = 30 to 80 step 10
        print #fh, "        y="; y; " x="; x; " mgl"; uglPGet( dc, x, y ); _
                   " qgl"; qgl_sf_pget( s, x, y )
    next x
    y = y + 20
    for x = 30 to 80 step 10
        print #fh, "        y="; y; " x="; x; " mgl"; uglPGet( dc, x, y ); _
                   " qgl"; qgl_sf_pget( s, x, y )
    next x
end sub

''
'' One drawing mode through both rasterisers. Returns the failure count.
''
function qgl_diff_case ( byval mode as integer, byval mdst as long, _
                         byval mtex as long, byval qdst as long, _
                         byval qtex as long, byval kind as integer, _
                         byval shape as integer, nm as string, _
                         byval fh as integer ) as integer
    dim v(2) as QVertB
    dim t(0) as TriType
    dim bad as integer
    dim mn as integer
    dim qn as integer
    dim df as integer
    dim dlo as integer
    dim dhi as integer

    qgl_diff_tri v(), t(), shape
    qgl_diff_fill_tex mtex, qtex, kind

    uglClear mdst, 0
    if ( mode = QGL_M_PTEX ) then
        uglTriTP mdst, t(0), 0, mtex
    else
        uglTriT mdst, t(0), 0, mtex
    end if

    qgl_dr_fill qdst, 0, 0, DIFF_W - 1, DIFF_H - 1, 0
    qgl_cl_rect 0, 0, DIFF_W - 1, DIFF_H - 1
    qgl_rs_tex qtex
    qgl_rs_mode mode
    qgl_rs_poly qdst, v(0), 3

    mn = qgl_diff_mgl_drew( mdst )
    qn = qgl_diff_qgl_drew( qdst )
    df = qgl_diff_pixels( mdst, qdst )
    dlo = qgl_diff_delta( mdst, qdst, 1 )
    dhi = qgl_diff_delta( mdst, qdst, 0 )

    if ( mn = 0 ) then bad = bad + 1
    if ( qn = 0 ) then bad = bad + 1
    if ( df <> 0 ) then bad = bad + 1

    print #fh, "   "; nm; " mgl"; mn; " qgl"; qn; " differ"; df; _
               " delta"; dlo; ".."; dhi
    if ( kind < 2 ) then qgl_diff_probe mdst, qdst, shape, fh
    qgl_diff_case = bad
end function

''
'' Every case, and the total. Printing is here rather than in the caller
'' so the flag's handler stays one line.
''
'' AFFINE ONLY, for now. QGL_M_PTEX is still an alias for the affine
'' fillers -- b8span.asm's table says so -- so a perspective case here
'' would assert a difference that is not a fault yet. It arrives with
'' the implementation.
''
function qgl_diff_all () as integer
    dim fh as integer
    dim bad as integer
    dim mdst as long
    dim mtex as long
    dim qdst as long
    dim qtex as long
    '' A FILE, not PRINT and a redirect: BASIC's PRINT goes to the
    '' display, and by here the display is a graphics mode.
    fh = freefile
    open "qgldiff.log" for output as #fh

    mdst = uglNew( ugl.mem, ugl.8bit, DIFF_W, DIFF_H )
    mtex = uglNew( ugl.mem, ugl.8bit, DIFF_TW, DIFF_TW )
    if ( qgl_sf_init() = 0 ) then
        print #fh, "   note EMS unavailable; the surfaces here are conventional"
    end if
    qdst = qgl_sf_new( DIFF_W, DIFF_H, QGL_SURF_CMEM, 0 )
    qtex = qgl_sf_new( DIFF_TW, DIFF_TW, QGL_SURF_CMEM, 0 )

    if ( mdst = 0 or mtex = 0 or qdst = 0 or qtex = 0 ) then
        print #fh, "   FAIL a store is missing: mdst"; mdst; " mtex"; mtex; _
                   " qdst"; qdst; " qtex"; qtex
        print #fh, "RESULT FAIL"
        close #fh
        qgl_diff_all = 1
        exit function
    end if

    '' `c` first: BC reads a parenthesised function call inside a call
    '' statement's argument list as that statement's own argument list
    '' and reports an argument-count mismatch.
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 0, 0, _
                               "flat-z  u  ", fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 1, 0, _
                               "flat-z  v  ", fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 2, 0, _
                               "flat-z     ", fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 0, 1, _
                               "affine  u  ", fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 1, 1, _
                               "affine  v  ", fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 2, 1, _
                               "affine     ", fh )

    qgl_sf_free qtex
    qgl_sf_free qdst

    if ( bad = 0 ) then
        print #fh, "RESULT PASS"
    else
        print #fh, "RESULT FAIL"
    end if
    close #fh
    qgl_diff_all = bad
end function
