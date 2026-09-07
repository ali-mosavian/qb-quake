option explicit
''
'' qglpres.bas -- the production present, differentially.
''
'' Drives vid_present, the shipped seam, over one frozen backbuffer and
'' checks four things: the bytes match a direct uglPutScl reference, they
'' match an oracle computed here, the 1,536 bytes of A000 past the
'' visible screen survive, and vid_present REPORTED the qgl route.
''
'' The route assertion is the one that is easy to leave out and the one
'' that matters: identical pixels prove nothing about which path drew
'' them, and a pixel-only differential passes just as well when the new
'' path never ran.
''
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

declare function qglPresAll ( _
    g as Game _
) as integer

''
'' Declared here: this module is the only caller.
''
declare function vid_present ( _
    g as Game _
) as integer

const PRES_W    = 160
const PRES_H    = 100
const PRES_SW   = 320
const PRES_SH   = 200
const VGA_SEG   = &HA000
const SCREEN_N  = 64000&
const CANARY_N  = 1536&          '' 65536 - 64000: A000 holds more than
                                 '' the mode shows, and a present that
                                 '' runs long lands here and nowhere a
                                 '' picture comparison would look
const CANARY_V  = 213
const SCRUB_V   = 87             '' see pres_scrub

'$static


''::::::::::
'' name: pres_seed
'' desc: The frozen source. Non-uniform in BOTH axes and with an x*y
''       term, so a duplicated, dropped or transposed row cannot come
''       out looking right.
''
''       This uses uglPset, which is mgl. That dependency is deliberate
''       and stated rather than claimed away: the routine under test is
''       the PRESENT, not pset, and the oracle below is computed from
''       the rule independently -- so a mis-seeded source shows up as
''       both arms failing the oracle, not as a false pass.
''::::::::::
sub pres_seed ( _
    dc as long _
)
    dim x as integer, y as integer

    for y = 0 to PRES_H-1
        for x = 0 to PRES_W-1
            uglPset dc, x, y, (7*x + 3*y + x*y) and 255
        next x
    next y

end sub


''::::::::::
'' name: pres_expect -- the oracle, from the same rule and its own
''       indexing, never read back from either arm.
''::::::::::
function pres_expect ( _
    x as integer, _
    y as integer _
) as integer
    dim sx as integer, sy as integer

    sx = x \ 2
    sy = y \ 2
    pres_expect = (7*sx + 3*sy + sx*sy) and 255

end function


''::::::::::
'' name: pres_scrub
'' desc: Fill the 64,000 VISIBLE bytes with a constant before the
''       candidate runs.
''
''       Without this the test cannot tell a correct present from one
''       that writes nothing: the reference has already put the right
''       bytes in A000, so every pixel the candidate skips still
''       compares equal. Dropping the last row went undetected until
''       this existed.
''
''       SCRUB_V collides with the expected value at about one pixel in
''       256, so a skipped 320-pixel row still shows ~319 mismatches.
''::::::::::
sub pres_scrub ( )
    dim i as long

    def seg = VGA_SEG
    for i = 0 to SCREEN_N - 1
        poke i, SCRUB_V
    next i
    def seg

end sub


sub pres_canary_set ( )
    dim i as long

    def seg = VGA_SEG
    for i = SCREEN_N to SCREEN_N + CANARY_N - 1
        poke i, CANARY_V
    next i
    def seg

end sub


function pres_canary_bad ( ) as long
    dim i as long
    dim bad as long

    bad = 0
    def seg = VGA_SEG
    for i = SCREEN_N to SCREEN_N + CANARY_N - 1
        if ( peek(i) <> CANARY_V ) then bad = bad + 1
    next i
    def seg

    pres_canary_bad = bad

end function


''::::::::::
'' name: pres_save -- A000's 64,000 shown bytes into an offscreen DC.
''
''       A DC and not a BASIC array: 64,000 bytes will not fit in
''       DGROUP beside everything else this program already has there.
''::::::::::
sub pres_save ( _
    dc as long _
)
    dim x as integer, y as integer
    dim rowo as long

    def seg = VGA_SEG
    for y = 0 to PRES_SH-1
        rowo = clng(y) * PRES_SW
        for x = 0 to PRES_SW-1
            uglPset dc, x, y, peek( rowo + x )
        next x
    next y
    def seg

end sub


''::::::::::
'' name: pres_cmp_ref -- A000 against the saved reference.
''::::::::::
function pres_cmp_ref ( _
    dc as long _
) as long
    dim x as integer, y as integer
    dim bad as long
    dim rowo as long

    bad = 0
    for y = 0 to PRES_SH-1
        rowo = clng(y) * PRES_SW
        for x = 0 to PRES_SW-1
            def seg = VGA_SEG
            if ( peek( rowo + x ) <> uglPGet( dc, x, y ) ) then
                bad = bad + 1
            end if
            def seg
        next x
    next y

    pres_cmp_ref = bad

end function


''::::::::::
'' name: pres_cmp_oracle -- A000 against the rule.
''::::::::::
function pres_cmp_oracle ( ) as long
    dim x as integer, y as integer
    dim bad as long
    dim rowo as long

    bad = 0
    def seg = VGA_SEG
    for y = 0 to PRES_SH-1
        rowo = clng(y) * PRES_SW
        for x = 0 to PRES_SW-1
            if ( peek( rowo + x ) <> pres_expect( x, y ) ) then
                bad = bad + 1
            end if
        next x
    next y
    def seg

    pres_cmp_oracle = bad

end function


''::::::::::
'' name: qglPresAll
'' desc: Returns the number of failures. Runs after vid_init: it drives
''       the real mode, the real video DC and the real backbuffer.
''::::::::::
function qglPresAll ( _
    g as Game _
) as integer
    dim bad as integer
    dim refdc as long
    dim routed as integer
    dim r_oracle as long, r_canary as long
    dim c_ref as long, c_oracle as long, c_canary as long

    ''
    '' EVERY observation is taken before ANY output. BASIC's PRINT in
    '' mode 13h renders into A000, so a result printed between two
    '' measurements corrupts the second -- the screen is the thing under
    '' test, not a place to report about it. The log is a file for the
    '' same reason, and because main.bas discards the return value.
    ''
    open "QGLPRES.LOG" for output as #1
    print #1, "qglpres: the production present, differentially"
    print #1, "  back"; g.env.x_res; "x"; g.env.y_res; _
              "  mode"; g.env.scr_x_res; "x"; g.env.scr_y_res; _
              "  view"; g.env.view_w; "x"; g.env.view_h; _
              " at"; g.env.view_x; ","; g.env.view_y; _
              "  scale"; g.env.view_scale

    bad = 0

    if ( g.env.use_paging <> false or _
         g.env.c_fmt <> UGL.8BIT or _
         g.env.x_res <> PRES_W or g.env.y_res <> PRES_H or _
         g.env.scr_x_res <> PRES_SW or g.env.scr_y_res <> PRES_SH or _
         g.env.view_w <> PRES_SW or g.env.view_h <> PRES_SH or _
         g.env.view_scale <> 2 or _
         g.env.view_x <> 0 or g.env.view_y <> 0 or _
         g.env.h_video_dc = false or g.env.h_back_bdc = false ) then
        print #1, "  FAIL fixture: not the non-paged 8-bit exact-2x shape"
        print #1, "RESULT FAIL"
        close #1
        qglPresAll = 1
        exit function
    end if

    '' EMS: 64,000 bytes of conventional MEM DC does not exist by this
    '' point -- the video dc and the backbuffer have taken it, the same
    '' shortage e1m1 dies on. The reference is scratch; where it lives
    '' does not change what it holds.
    refdc = uglNew( ugl.ems, g.env.c_fmt, PRES_SW, PRES_SH )
    if ( refdc = false ) then
        print #1, "  FAIL could not allocate the reference dc"
        print #1, "RESULT FAIL"
        close #1
        qglPresAll = 1
        exit function
    end if

    pres_seed g.env.h_back_bdc

    '' 1. the reference: mgl's own present, preserved offscreen. Its
    ''    canary is read before the candidate's set overwrites it.
    pres_canary_set
    uglPutScl g.env.h_video_dc, g.env.view_x, g.env.view_y, _
              g.env.view_scale, g.env.view_scale, g.env.h_back_bdc
    pres_save refdc
    r_oracle = pres_cmp_oracle
    r_canary = pres_canary_bad

    '' 2. the candidate: the production seam. Scrubbed first, or a
    ''    pixel the candidate never writes would still hold the
    ''    reference's already-correct value and compare as a pass.
    pres_scrub
    pres_canary_set
    routed = vid_present( g )
    c_ref = pres_cmp_ref( refdc )
    c_oracle = pres_cmp_oracle
    c_canary = pres_canary_bad

    uglDel refdc

    ''
    '' Only now, with every byte already read.
    ''
    print #1, "  ok   fixture is the non-paged 8-bit exact-2x shape"

    if ( r_oracle = 0 ) then
        print #1, "  ok   mgl reference matches the oracle"
    else
        print #1, "  FAIL mgl reference differs from the oracle,"; r_oracle
        bad = bad + 1
    end if

    if ( r_canary = 0 ) then
        print #1, "  ok   mgl reference left the canary intact"
    else
        print #1, "  FAIL mgl reference overwrote the canary,"; r_canary
        bad = bad + 1
    end if

    if ( c_ref = 0 ) then
        print #1, "  ok   candidate matches the mgl reference"
    else
        print #1, "  FAIL candidate differs from the reference,"; c_ref
        bad = bad + 1
    end if

    if ( c_oracle = 0 ) then
        print #1, "  ok   candidate matches the oracle"
    else
        print #1, "  FAIL candidate differs from the oracle,"; c_oracle
        bad = bad + 1
    end if

    if ( c_canary = 0 ) then
        print #1, "  ok   candidate left the canary intact"
    else
        print #1, "  FAIL candidate overwrote the canary,"; c_canary
        bad = bad + 1
    end if

    if ( routed ) then
        print #1, "  ok   vid_present reported the qgl route"
    else
        print #1, "  FAIL vid_present did not take the qgl route"
        bad = bad + 1
    end if

    print #1, "qglpres: failures"; bad
    if ( bad = 0 ) then
        print #1, "RESULT PASS"
    else
        print #1, "RESULT FAIL"
    end if
    close #1

    qglPresAll = bad

end function
