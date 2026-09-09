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

declare function qglSfInit () as integer
declare function qglSfNew ( byval wid as integer, byval hgt as integer, _
                              byval whr as integer ) as long
declare function qglSfPget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare sub qglSfPset ( byval s as long, byval x as integer, _
                          byval y as integer, byval c as integer )
declare sub qglSfFree ( byval s as long )
declare sub qglClRect ( byval x0 as integer, byval y0 as integer, _
                          byval x1 as integer, byval y1 as integer )
declare sub qglRsPoly ( byval d as long, _
                        seg v as any, _
                        byval cnt as integer, _
                        byval mode as integer, _
                        byval src as long )
declare sub qglDrFill ( byval d as long, byval x0 as integer, _
                          byval y0 as integer, byval x1 as integer, _
                          byval y1 as integer, byval col as integer )

declare function qgl_diff_texel ( byval x as integer, byval y as integer, _
                                  byval kind as integer ) as integer
declare sub qgl_diff_fill_tex ( byval mtex as long, byval qtex as long, _
                                byval kind as integer )
declare function qgl_diff_delta ( byval dc as long, byval s as long, _
                                  byval lo as integer ) as integer
declare function qgl_diff_plane ( byval f0 as single, byval f1 as single, _
                                  byval f2 as single, v() as QVertB, _
                                  byval x as single, byval y as single ) as single
declare function qgl_diff_want ( v() as QVertB, byval kind as integer, _
                                 byval px as integer, byval py as integer ) as integer
declare function qgl_diff_dev ( byval dc as long, byval s as long, _
                                v() as QVertB, byval kind as integer, _
                                byval mine as integer ) as integer
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
declare function qglDiffAll () as integer

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
            qglSfPset qtex, x, y, c
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
            q = qglSfPget( s, x, y )
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
    elseif ( shape = 1 ) then
        v(0).x = 20.0  : v(0).y = 12.0 : v(0).z = 1.0
        v(0).u = 0.0   : v(0).v = 0.0
        v(1).x = 104.0 : v(1).y = 30.0 : v(1).z = 0.5
        v(1).u = 1.0   : v(1).v = 0.0
        v(2).x = 52.0  : v(2).y = 80.0 : v(2).z = 0.25
        v(2).u = 0.0   : v(2).v = 1.0
    else
        '' THE SAME SCREEN TRIANGLE AS shape 1, carrying what the
        '' perspective path is actually fed: z holds 1/z, and u and v
        '' hold u/z and v/z. Both of those are linear in screen space,
        '' which is the whole reason the pipeline divides per span
        '' instead of interpolating u directly.
        ''
        '' The texture corners still land on the vertices -- (u/z)/(1/z)
        '' recovers 0, 1 and 0 -- so this differs from the affine case
        '' only in the interior, which is exactly where perspective
        '' correction is visible and nowhere else.
        ''
        '' Depths 1, 4 and 2 are a wide enough spread to separate the
        '' two: a near-constant z makes affine and perspective agree and
        '' the case would pass without the correction existing.
        v(0).x = 20.0  : v(0).y = 12.0 : v(0).z = 1.0
        v(0).u = 0.0   : v(0).v = 0.0
        v(1).x = 104.0 : v(1).y = 30.0 : v(1).z = 0.25
        v(1).u = 0.25  : v(1).v = 0.0
        v(2).x = 52.0  : v(2).y = 80.0 : v(2).z = 0.5
        v(2).u = 0.0   : v(2).v = 0.5
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
            if ( qglSfPget( s, x, y ) <> 0 ) then n = n + 1
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
            if ( uglPGet( dc, x, y ) <> qglSfPget( s, x, y ) ) then n = n + 1
        next x
    next y
    qgl_diff_pixels = n
end function

''
'' A quantity that is linear over the triangle, at any (x,y). Three
'' points fix a plane, which is the whole reason u/z, v/z and 1/z are
'' what gets interpolated and u is not.
''
function qgl_diff_plane ( byval f0 as single, byval f1 as single, _
                          byval f2 as single, v() as QVertB, _
                          byval x as single, byval y as single ) as single
    dim dx1 as single
    dim dy1 as single
    dim dx2 as single
    dim dy2 as single
    dim det as single

    dx1 = v(1).x - v(0).x : dy1 = v(1).y - v(0).y
    dx2 = v(2).x - v(0).x : dy2 = v(2).y - v(0).y
    det = dx1 * dy2 - dx2 * dy1
    qgl_diff_plane = f0 _
        + ( ( (f1-f0)*dy2 - (f2-f0)*dy1 ) / det ) * ( x - v(0).x ) _
        + ( ( dx1*(f2-f0) - dx2*(f1-f0) ) / det ) * ( y - v(0).y )
end function

''
'' THE EXACT ANSWER, in floating point, owing nothing to either
'' rasteriser: interpolate u/z, v/z and 1/z over the plane, divide, and
'' that is the texel.
''
'' Both renderers approximate it -- mgl divides every 16 pixels and so
'' does qgl -- so neither is the other's reference, and asserting they
'' agree byte for byte would assert that qgl reproduces mgl's error
'' rather than that it is right. Measured: with qgl dividing at every
'' pixel it moved AWAY from mgl, which is what says the remaining
'' difference is two approximations and not a fault.
''
function qgl_diff_want ( v() as QVertB, byval kind as integer, _
                         byval px as integer, byval py as integer ) as integer
    dim zp as single
    dim f as single

    zp = qgl_diff_plane( v(0).z, v(1).z, v(2).z, v(), px, py )
    if ( kind = 0 ) then
        f = qgl_diff_plane( v(0).u, v(1).u, v(2).u, v(), px, py )
    else
        f = qgl_diff_plane( v(0).v, v(1).v, v(2).v, v(), px, py )
    end if
    qgl_diff_want = ( int( ( f / zp ) * DIFF_TW + 0.5 ) and (DIFF_TW - 1) )
end function

''
'' How far one renderer strays from that, at worst, over the pixels both
'' drew. The distance is taken the short way round the texture: an
'' overshoot of one texel past the last column reads as 63 otherwise,
'' and a wrap is not a large error.
''
function qgl_diff_dev ( byval dc as long, byval s as long, _
                        v() as QVertB, byval kind as integer, _
                        byval mine as integer ) as integer
    dim x as integer
    dim y as integer
    dim got as integer
    dim e as integer
    dim worst as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( uglPGet( dc, x, y ) <> 0 and qglSfPget( s, x, y ) <> 0 ) then
                if ( mine <> 0 ) then
                    got = qglSfPget( s, x, y )
                else
                    got = uglPGet( dc, x, y )
                end if
                e = ( got - qgl_diff_want( v(), kind, x, y ) ) and (DIFF_TW - 1)
                if ( e > DIFF_TW \ 2 ) then e = DIFF_TW - e
                if ( e > worst ) then worst = e
            end if
        next x
    next y
    qgl_diff_dev = worst
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
                   " qgl"; qglSfPget( s, x, y )
    next x
    y = y + 20
    for x = 30 to 80 step 10
        print #fh, "        y="; y; " x="; x; " mgl"; uglPGet( dc, x, y ); _
                   " qgl"; qglSfPget( s, x, y )
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
    dim em as integer
    dim eq as integer

    qgl_diff_tri v(), t(), shape
    qgl_diff_fill_tex mtex, qtex, kind

    uglClear mdst, 0
    if ( mode = QGL_M_PTEX ) then
        uglTriTP mdst, t(0), 0, mtex
    else
        uglTriT mdst, t(0), 0, mtex
    end if

    qglDrFill qdst, 0, 0, DIFF_W - 1, DIFF_H - 1, 0
    qglClRect 0, 0, DIFF_W - 1, DIFF_H - 1
    qglRsPoly qdst, v(0), 3, mode, qtex

    mn = qgl_diff_mgl_drew( mdst )
    qn = qgl_diff_qgl_drew( qdst )
    df = qgl_diff_pixels( mdst, qdst )

    if ( mn = 0 ) then bad = bad + 1
    if ( qn = 0 ) then bad = bad + 1

    if ( mode = QGL_M_PTEX ) then
        '' Two approximations of the same exact answer, so the test is
        '' which one is further from it -- not whether they agree.
        '' Bounded by mgl rather than by a number picked here, because a
        '' fixed tolerance is a number nobody can defend and this one
        '' says exactly what it is for: replacing mgl must not lose
        '' accuracy.
        em = qgl_diff_dev( mdst, qdst, v(), kind, 0 )
        eq = qgl_diff_dev( mdst, qdst, v(), kind, 1 )
        if ( eq > em ) then bad = bad + 1
        print #fh, "   "; nm; " mgl"; mn; " qgl"; qn; " differ"; df; _
                   "   off-exact mgl"; em; " qgl"; eq
    else
        '' Affine is exact in both, so anything but identity is a fault.
        if ( df <> 0 ) then bad = bad + 1
        dlo = qgl_diff_delta( mdst, qdst, 1 )
        dhi = qgl_diff_delta( mdst, qdst, 0 )

        '' AND THE ORACLE IS CALIBRATED HERE. Shape 0 holds 1/z flat at
        '' 1, so an affine renderer is exact on it and the reference
        '' must agree with both -- a reference with the sample point,
        '' the rounding or the wrap wrong shows up as a deviation right
        '' here, and the perspective verdict below would be worth
        '' nothing without it.
        ''
        '' Only shape 0. Shape 1's vertices carry PLAIN u and v, which
        '' is what an affine caller passes, so a reference that divides
        '' by z is answering a different question; it reads 32, the
        '' furthest two texels can be apart, and means nothing. Only
        '' data in the perspective convention can be held to it.
        if ( kind < 2 and shape = 0 ) then
            em = qgl_diff_dev( mdst, qdst, v(), kind, 0 )
            eq = qgl_diff_dev( mdst, qdst, v(), kind, 1 )
            if ( em > 1 or eq > 1 ) then bad = bad + 1
            print #fh, "   "; nm; " mgl"; mn; " qgl"; qn; " differ"; df; _
                       " delta"; dlo; ".."; dhi; " off-exact"; em; eq
        else
            print #fh, "   "; nm; " mgl"; mn; " qgl"; qn; " differ"; df; _
                       " delta"; dlo; ".."; dhi
        end if
    end if
    if ( kind < 2 ) then qgl_diff_probe mdst, qdst, shape, fh
    qgl_diff_case = bad
end function

''
'' Every case, and the total. Printing is here rather than in the caller
'' so the flag's handler stays one line.

''
function qglDiffAll () as integer
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
    if ( qglSfInit() = 0 ) then
        print #fh, "   note EMS unavailable; the surfaces here are conventional"
    end if
    qdst = qglSfNew( DIFF_W, DIFF_H, QGL_SURF_CMEM )
    qtex = qglSfNew( DIFF_TW, DIFF_TW, QGL_SURF_CMEM )

    if ( mdst = 0 or mtex = 0 or qdst = 0 or qtex = 0 ) then
        print #fh, "   FAIL a store is missing: mdst"; mdst; " mtex"; mtex; _
                   " qdst"; qdst; " qtex"; qtex
        print #fh, "RESULT FAIL"
        close #fh
        qglDiffAll = 1
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

    '' The same vertices through the affine path FIRST. If that matches
    '' and the perspective one does not, the data reaches both
    '' rasterisers identically and only the correction differs -- which
    '' is what stops a perspective failure being read as a bad fixture.
    bad = bad + qgl_diff_case( QGL_M_TEX,  mdst, mtex, qdst, qtex, 2, 2, _
                               "persp-in af", fh )
    bad = bad + qgl_diff_case( QGL_M_PTEX, mdst, mtex, qdst, qtex, 0, 2, _
                               "persp   u  ", fh )
    bad = bad + qgl_diff_case( QGL_M_PTEX, mdst, mtex, qdst, qtex, 1, 2, _
                               "persp   v  ", fh )

    qglSfFree qtex
    qglSfFree qdst

    if ( bad = 0 ) then
        print #fh, "RESULT PASS"
    else
        print #fh, "RESULT FAIL"
    end if
    close #fh
    qglDiffAll = bad
end function
