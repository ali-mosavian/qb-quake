option explicit
''
'' qgltex.bas -- the EMS texture bridge, checked against mgl's own reads.
''
'' -qgltex runs this and exits. It runs AFTER the textures load, because
'' what it checks is a view onto the real atlas: mod_tex.bas builds that
'' with uglNewBMPEx UGL.EMS and aims one view per mip size at a cell.
''
'' Two checks, and the second is the one that earns the design.
''
'' EXACT BYTES. A Surface whose fields look sensible proves nothing about
'' whether the bytes behind it are the cell's: the addrTB offset could be
'' wrong by four, the page split could be wrong, the map could have
'' landed on another page entirely, and every one of those yields a
'' perfectly well-formed Surface. So every texel is read back through qgl
'' and compared against uglPGet on the SAME view -- mgl reading its own
'' pixels its own way.
''
'' SLOT COHERENCE, and NOT by alternating slots. An earlier version of
'' this file read mgl's slot 0 and qgl's slot 2 in turn and called that
'' coherence; it proves only that two different slots do not collide,
'' which is true however the bridge maps, and a raw INT 67h bridge would
'' have passed it. What discriminates is the SAME slot, evicted:
''
''   1. mgl maps page A into slot 2, so ppgTB[2] records A
''   2. the bridge maps view B into slot 2
''   3. mgl is asked for A in slot 2 again
''
'' A bridge that went through emsMapEx left ppgTB[2] saying B, so mgl
'' does the remap and A's bytes come back. A bridge that mapped raw left
'' ppgTB[2] still saying A, so mgl SKIPS the remap it needed and hands
'' back B's bytes wearing A's name -- silently, which is the whole
'' hazard.
''
'' A and B are the raw and shaded atlases: different EMS handles, so they
'' cannot alias. ppgTB packs lpage:handle, so the handle alone separates
'' them even at the same logical page number.
''

defint a-z

'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bspfile.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_snd.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'
'$include: 'qgl.bi'

const QGLTEX_SLOT = 2           '' mgl reads through 0, writes 1, depth 3
const QGLTEX_SURF = 3           '' a scratch Surface index, not a slot

declare function qglSfScratch ( byval n as integer ) as long
declare function qglSfPget ( byval s as long, byval x as integer, _
                               byval y as integer ) as integer
declare function qglSfAdoptEms ( byval dc as long, byval slot as integer, _
                                    byval s as long ) as integer

declare function qgl_tex_peek ( byval p as long ) as integer
declare function qgl_tex_one ( g as Game, byval k as integer, _
                               byval mip as integer, byval fh as integer ) as integer
declare function qgl_tex_coh ( g as Game, byval fh as integer ) as integer
declare function qglTexAll ( g as Game ) as integer

'' one byte at a far pointer packed seg:ofs the way uglMapEx returns it
function qgl_tex_peek ( byval p as long ) as integer
    dim sg as long
    dim of as long

    sg = (p \ 65536) and 65535
    of = p and 65535
    def seg = sg
    qgl_tex_peek = peek( of )
    def seg
end function

''
'' One cell, every texel, against mgl's own read of the same view.
''
function qgl_tex_one ( g as Game, byval k as integer, _
                       byval mip as integer, byval fh as integer ) as integer
    dim dc as long
    dim sf as long
    dim x as integer
    dim y as integer
    dim side as integer
    dim bad as integer
    dim want as integer
    dim got as integer
    dim first as integer

    dc = mod_tex_shaded( g, k, mip )
    if ( dc = 0 ) then
        print #fh, "   FAIL no view for k"; k; " mip"; mip
        qgl_tex_one = 1
        exit function
    end if

    sf = qglSfScratch( QGLTEX_SURF )
    if ( qglSfAdoptEms( dc, QGLTEX_SLOT, sf ) = 0 ) then
        print #fh, "   FAIL adoption refused: k"; k; " mip"; mip
        qgl_tex_one = 1
        exit function
    end if

    side = 64 \ (2 ^ mip)
    first = -1
    for y = 0 to side - 1
        for x = 0 to side - 1
            want = uglPGet( dc, x, y )
            got = qglSfPget( sf, x, y )
            if ( got <> want ) then
                bad = bad + 1
                if ( first < 0 ) then first = y * side + x
            end if
        next x
    next y

    if ( bad = 0 ) then
        print #fh, "   ok   exact bytes k"; k; " mip"; mip; " side"; side
    else
        print #fh, "   FAIL exact bytes k"; k; " mip"; mip; " bad"; bad; _
                   " of"; side * side; " first at"; first
    end if
    qgl_tex_one = bad
end function

''
'' The same slot, evicted. See the header: this is the check that a raw
'' INT 67h bridge fails and an emsMapEx one passes.
''
function qgl_tex_coh ( g as Game, byval fh as integer ) as integer
    dim dcA as long
    dim dcB as long
    dim sf as long
    dim pA as long
    dim wantA as integer
    dim gotA as integer
    dim wantB as integer
    dim gotB as integer
    dim bad as integer
    dim x as integer
    dim y as integer
    dim px as integer
    dim py as integer

    dcA = mod_tex_raw( g, 0, 0 )
    dcB = mod_tex_shaded( g, 0, 0 )
    if ( dcA = 0 or dcB = 0 ) then
        print #fh, "   FAIL coherence: no views"
        qgl_tex_coh = 1
        exit function
    end if

    '' A COORDINATE WHERE A AND B ACTUALLY DIFFER, found rather than
    '' assumed. If the two atlases happen to agree at the probe, the
    '' whole check passes whichever page is mapped and the raw-INT
    '' mutation is unobservable -- the assertion would be measuring
    '' nothing. Shaded is raw with colormap row 0 applied and 221 of 256
    '' entries differ, so this finds one almost at once; if it cannot,
    '' that is a failure and not something to shrug at.
    px = -1
    for y = 0 to 63
        for x = 0 to 63
            if ( px < 0 ) then
                if ( uglPGet( dcA, x, y ) <> uglPGet( dcB, x, y ) ) then
                    px = x
                    py = y
                end if
            end if
        next x
    next y
    if ( px < 0 ) then
        print #fh, "   FAIL coherence: A and B agree everywhere; the probe"
        print #fh, "        could not tell them apart and would pass blind"
        qgl_tex_coh = 1
        exit function
    end if

    wantA = uglPGet( dcA, px, py )
    wantB = uglPGet( dcB, px, py )

    '' 1. mgl puts A in the slot
    pA = uglMapEx( dcA, 0, QGLTEX_SLOT )
    if ( pA = 0 ) then
        print #fh, "   FAIL coherence: uglMapEx refused A"
        qgl_tex_coh = 1
        exit function
    end if

    '' 2. the bridge puts B in the same slot
    sf = qglSfScratch( QGLTEX_SURF )
    if ( qglSfAdoptEms( dcB, QGLTEX_SLOT, sf ) = 0 ) then
        print #fh, "   FAIL coherence: adoption refused B"
        qgl_tex_coh = 1
        exit function
    end if

    '' 3. mgl asks for A again. If the bridge bypassed ppgTB, mgl skips
    ''    the remap and this reads B.
    pA = uglMapEx( dcA, 0, QGLTEX_SLOT )
    gotA = qgl_tex_peek( pA + py * 64 + px )
    if ( gotA = wantA ) then
        print #fh, "   ok   mgl gets A back after the bridge took the slot"; _
                   " at"; px; py
    else
        print #fh, "   FAIL mgl got"; gotA; " wanted A ="; wantA; _
                   " (B ="; wantB; ")"
        bad = bad + 1
    end if

    '' and B is still reachable afterwards
    if ( qglSfAdoptEms( dcB, QGLTEX_SLOT, sf ) = 0 ) then
        print #fh, "   FAIL coherence: re-adoption refused B"
        bad = bad + 1
    else
        gotB = qglSfPget( sf, px, py )
        if ( gotB = wantB ) then
            print #fh, "   ok   and the bridge gets B back after mgl did"
        else
            print #fh, "   FAIL bridge got"; gotB; " wanted B ="; wantB
            bad = bad + 1
        end if
    end if

    qgl_tex_coh = bad
end function

function qglTexAll ( g as Game ) as integer
    dim fh as integer
    dim bad as integer
    dim mip as integer

    '' A FILE, not PRINT: by here the display is a graphics mode.
    fh = freefile
    open "qgltex.log" for output as #fh

    '' every mip size, because each is a different cell size and the
    '' straddle check is the one that depends on it
    for mip = 0 to 3
        bad = bad + qgl_tex_one( g, 0, mip, fh )
    next mip

    '' a second texture, so a bridge that works only for cell 0 -- offset
    '' zero, first page -- does not pass on that alone
    bad = bad + qgl_tex_one( g, 1, 0, fh )

    bad = bad + qgl_tex_coh( g, fh )

    if ( bad = 0 ) then
        print #fh, "RESULT PASS"
    else
        print #fh, "RESULT FAIL"
    end if
    close #fh
    qglTexAll = bad
end function
