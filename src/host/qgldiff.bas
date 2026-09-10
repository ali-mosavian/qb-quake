option explicit
''
'' qgldiff.bas -- qgl's rasteriser against the exact answer.
''
'' -qgldiff runs this and exits.
''
'' t10ref already draws every polygon twice, but both times through qgl's
'' own scanner and its own gradients: it proves the patched fillers agree
'' with the reference filler and cannot say a word about the scan
'' conversion above them. This arm can: the texture is a ramp, so a pixel
'' IS the texel column or row it sampled, and the exact texel at any
'' pixel is three planes and a divide in floating point, owing nothing to
'' the rasteriser.
''
'' Until ba52cdd this was a differential against mgl, an independent
'' scanner drawing the same triangles. The coverage and the texel bounds
'' asserted below are the figures from that run: every affine case
'' matched mgl pixel for pixel, and the perspective cases were 8 and 4
'' texels off the exact answer, mgl's own distance. A change that moves
'' a count moves the edge walk; one that widens a bound loses accuracy
'' mgl had.
''
'' Both drew SOMETHING is asserted apart from where they drew it. An
'' empty destination is a perfect match for nothing.
''

defint a-z

'$include: 'qgl.bi'

const DIFF_W = 128
const DIFF_H = 96
const DIFF_TW = 64

'' qgl's vertex. x and y are screen, z is 1/z, u and v are normalised
'' over the texture -- or u/z and v/z when the perspective path is fed.
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
declare sub qgl_diff_fill_tex ( byval qtex as long, byval kind as integer )
declare function qgl_diff_plane ( byval f0 as single, byval f1 as single, _
                                  byval f2 as single, v() as QVertB, _
                                  byval x as single, byval y as single ) as single
declare function qgl_diff_want ( v() as QVertB, byval kind as integer, _
                                 byval persp as integer, _
                                 byval px as integer, byval py as integer ) as integer
declare function qgl_diff_dev ( byval s as long, v() as QVertB, _
                                byval kind as integer, byval persp as integer ) as integer
declare sub qgl_diff_probe ( byval s as long, byval shape as integer, _
                             byval fh as integer )
declare sub qgl_diff_tri ( v() as QVertB, byval shape as integer )
declare function qgl_diff_drew ( byval s as long ) as integer
declare function qgl_diff_case ( byval mode as integer, byval qdst as long, _
                                 byval qtex as long, byval kind as integer, _
                                 byval shape as integer, nm as string, _
                                 byval want_n as integer, byval bound as integer, _
                                 byval fh as integer ) as integer
declare function qglDiffAll () as integer

''
'' The texture, and it is an INSTRUMENT rather than a pattern.
''
'' kind 0 is a ramp in u alone and kind 1 a ramp in v alone, so a pixel's
'' value IS the texel column or row that was sampled and its distance
'' from the exact answer reads directly as a sampling offset. kind 2 is
'' the usual no-two-alike pattern, which catches an error in either axis
'' but cannot say which axis or by how much.
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

sub qgl_diff_fill_tex ( byval qtex as long, byval kind as integer )
    dim x as integer
    dim y as integer
    dim c as integer

    '' `c` first: BC reads a parenthesised function call inside a call
    '' statement's argument list as that statement's own argument list
    '' and reports an argument-count mismatch.
    for y = 0 to DIFF_TW - 1
        for x = 0 to DIFF_TW - 1
            c = qgl_diff_texel( x, y, kind )
            qglSfPset qtex, x, y, c
        next x
    next y
end sub

''
'' One triangle. Not axis aligned, and 1/z differs at every vertex, so
'' u, v and 1/z all vary along both edges and across every span -- which
'' is what makes the perspective arm differ from the affine one at all.
''
sub qgl_diff_tri ( v() as QVertB, byval shape as integer )
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
end sub

function qgl_diff_drew ( byval s as long ) as integer
    dim x as integer
    dim y as integer
    dim n as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( qglSfPget( s, x, y ) <> 0 ) then n = n + 1
        next x
    next y
    qgl_diff_drew = n
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
'' THE EXACT ANSWER, in floating point. persp: interpolate u/z, v/z and
'' 1/z over the plane, divide, and that is the texel. Otherwise the
'' vertices carry plain u and v, which an affine caller passes, and the
'' plane of u itself is the answer; a reference that divided would be
'' answering a different question and read 32, the furthest two texels
'' can be apart.
''
'' The rasteriser approximates it -- it divides every 16 pixels -- so
'' the perspective bound is a distance and not an identity.
''
function qgl_diff_want ( v() as QVertB, byval kind as integer, _
                         byval persp as integer, _
                         byval px as integer, byval py as integer ) as integer
    dim zp as single
    dim f as single

    if ( kind = 0 ) then
        f = qgl_diff_plane( v(0).u, v(1).u, v(2).u, v(), px, py )
    else
        f = qgl_diff_plane( v(0).v, v(1).v, v(2).v, v(), px, py )
    end if
    if ( persp <> 0 ) then
        zp = qgl_diff_plane( v(0).z, v(1).z, v(2).z, v(), px, py )
        f = f / zp
    end if
    qgl_diff_want = ( int( f * DIFF_TW + 0.5 ) and (DIFF_TW - 1) )
end function

''
'' How far the rasteriser strays from that, at worst, over the pixels it
'' drew. The distance is taken the short way round the texture: an
'' overshoot of one texel past the last column reads as 63 otherwise,
'' and a wrap is not a large error.
''
function qgl_diff_dev ( byval s as long, v() as QVertB, _
                        byval kind as integer, byval persp as integer ) as integer
    dim x as integer
    dim y as integer
    dim e as integer
    dim worst as integer

    for y = 0 to DIFF_H - 1
        for x = 0 to DIFF_W - 1
            if ( qglSfPget( s, x, y ) <> 0 ) then
                e = ( qglSfPget( s, x, y ) - qgl_diff_want( v(), kind, persp, x, y ) ) _
                    and (DIFF_TW - 1)
                if ( e > DIFF_TW \ 2 ) then e = DIFF_TW - e
                if ( e > worst ) then worst = e
            end if
        next x
    next y
    qgl_diff_dev = worst
end function

''
'' What the rasteriser put at four points inside the triangle. A bound
'' says how far the sampling is out; only the values say in which
'' direction, which is the difference between a half-pixel convention
'' and a mapping that is turned around.
''
sub qgl_diff_probe ( byval s as long, byval shape as integer, _
                     byval fh as integer )
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
        print #fh, "        y="; y; " x="; x; " qgl"; qglSfPget( s, x, y )
    next x
    y = y + 20
    for x = 30 to 80 step 10
        print #fh, "        y="; y; " x="; x; " qgl"; qglSfPget( s, x, y )
    next x
end sub

''
'' One drawing mode. want_n is the coverage and bound the texel distance
'' the case may not exceed; bound applies to the ramp textures only.
'' Returns the failure count.
''
function qgl_diff_case ( byval mode as integer, byval qdst as long, _
                         byval qtex as long, byval kind as integer, _
                         byval shape as integer, nm as string, _
                         byval want_n as integer, byval bound as integer, _
                         byval fh as integer ) as integer
    dim v(2) as QVertB
    dim bad as integer
    dim qn as integer
    dim eq as integer
    dim persp as integer

    qgl_diff_tri v(), shape
    qgl_diff_fill_tex qtex, kind

    qglDrFill qdst, 0, 0, DIFF_W - 1, DIFF_H - 1, 0
    qglClRect 0, 0, DIFF_W - 1, DIFF_H - 1
    qglRsPoly qdst, v(0), 3, mode, qtex

    qn = qgl_diff_drew( qdst )
    if ( qn = 0 ) then bad = bad + 1
    if ( qn <> want_n ) then bad = bad + 1

    if ( kind < 2 ) then
        if ( mode = QGL_M_PTEX ) then persp = 1
        eq = qgl_diff_dev( qdst, v(), kind, persp )
        if ( eq > bound ) then bad = bad + 1
        print #fh, "   "; nm; " drew"; qn; " want"; want_n; _
                   "   off-exact"; eq; " bound"; bound
        qgl_diff_probe qdst, shape, fh
    else
        print #fh, "   "; nm; " drew"; qn; " want"; want_n
    end if
    qgl_diff_case = bad
end function

''
'' Every case, and the total. Printing is here rather than in the caller
'' so the flag's handler stays one line.
''
function qglDiffAll () as integer
    dim fh as integer
    dim bad as integer
    dim qdst as long
    dim qtex as long
    '' A FILE, not PRINT and a redirect: BASIC's PRINT goes to the
    '' display, and by here the display is a graphics mode.
    fh = freefile
    open "qgldiff.log" for output as #fh

    if ( qglSfInit() = 0 ) then
        print #fh, "   note EMS unavailable; the surfaces here are conventional"
    end if
    qdst = qglSfNew( DIFF_W, DIFF_H, QGL_SURF_CMEM )
    qtex = qglSfNew( DIFF_TW, DIFF_TW, QGL_SURF_CMEM )

    if ( qdst = 0 or qtex = 0 ) then
        print #fh, "   FAIL a store is missing: qdst"; qdst; " qtex"; qtex
        print #fh, "RESULT FAIL"
        close #fh
        qglDiffAll = 1
        exit function
    end if

    '' Shape 0 holds 1/z flat at 1, so an affine renderer is exact on it
    '' and THE ORACLE IS CALIBRATED HERE: a reference with the sample
    '' point, the rounding or the wrap wrong shows up as a deviation on
    '' these two, and the perspective verdict below would be worth
    '' nothing without them.
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 0, 0, _
                               "flat-z  u  ", 2079, 1, fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 1, 0, _
                               "flat-z  v  ", 2079, 1, fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 2, 0, _
                               "flat-z     ", 2076, 0, fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 0, 1, _
                               "affine  u  ", 2528, 1, fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 1, 1, _
                               "affine  v  ", 2526, 1, fh )
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 2, 1, _
                               "affine     ", 2560, 0, fh )

    '' The same vertices through the affine path FIRST. If that holds
    '' and the perspective one does not, the data reaches the rasteriser
    '' identically and only the correction differs -- which is what
    '' stops a perspective failure being read as a bad fixture.
    bad = bad + qgl_diff_case( QGL_M_TEX,  qdst, qtex, 2, 2, _
                               "persp-in af", 2565, 0, fh )
    bad = bad + qgl_diff_case( QGL_M_PTEX, qdst, qtex, 0, 2, _
                               "persp   u  ", 2462, 8, fh )
    bad = bad + qgl_diff_case( QGL_M_PTEX, qdst, qtex, 1, 2, _
                               "persp   v  ", 2507, 4, fh )

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
