option explicit
''
'' in_main.bas -- keyboard and mouse. in_init came from sys_init.bas, the
''                toggles from r_main.bas where they sat beside the camera,
''                and the screenshot key from vid.bas, where it was being
''                polled from inside the present path.
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
'$include: 'q_game.bi'

''
'' This module's own procedures.
''
declare function in_keystroke ( key_down as integer ) as integer

''
'' This module's own procedures.
''
declare sub in_handle_toggles ( _
    g as Game _
)
declare sub in_screenshot_key ( _
    g as Game, _
    byval h_dst_dc as long _
)
declare sub in_init ( _
    g as Game _
)


'' Screenshot counter: without it every shot overwrote scrn0.bmp.
dim shared screenie as integer






''::::::::::
'' name: in_init
'' desc: Mouse, keyboard and the one second timer.
''::::::::::
sub in_init ( _
    g as Game _
)
    if ( mouseInit( g.env.h_video_dc, g.env.mouse ) = FALSE ) then
        sys_error "0x0006, Could not init mouse..."
    end if  
    
    ''
    '' Init keyboard
    ''
    kbdInit g.env.keyboard
    
    ''
    '' Init timer
    ''
    tmrInit

end sub





''::::::::::
'' name: in_keystroke
'' desc: The function-key toggles. Each waits for the key to come back
''       up so one press is one toggle.
''::::::::::
function in_keystroke ( key_down as integer ) as integer
    ''
    '' True once per press, not once per frame. The key is passed by
    '' reference, so the loop below re-reads the live flag the keyboard
    '' handler writes -- which is what makes waiting for the release work.
    ''
    '' Five toggles each carried their own copy of this test-and-spin.
    ''
    if ( key_down = false ) then
        in_keystroke = false
        exit function
    end if

    do
    loop while ( key_down )

    in_keystroke = true

end function






''::::::::::
'' name: in_handle_toggles
'' desc: The render-mode keys. One line each now.
''::::::::::
sub in_handle_toggles ( _
    g as Game _
)

    if ( in_keystroke( g.env.keyboard.f1  ) ) then g.rdr.use_mips  = not g.rdr.use_mips
    if ( in_keystroke( g.env.keyboard.f2  ) ) then g.rdr.rend_mode = (g.rdr.rend_mode + 1) mod 3
    if ( in_keystroke( g.env.keyboard.f3  ) ) then g.cam.fps_view  = not g.cam.fps_view
    if ( in_keystroke( g.env.keyboard.f12 ) ) then g.scr.stats    = not g.scr.stats
    if ( in_keystroke( g.env.keyboard.b   ) ) then g.rdr.backface = not g.rdr.backface
    if ( in_keystroke( g.env.keyboard.l   ) ) then g.rdr.lightmap = not g.rdr.lightmap
    if ( in_keystroke( g.env.keyboard.f4  ) ) then g.pl.no_clip    = not g.pl.no_clip

end sub






''::::::::::
'' name: in_screenshot_key
'' desc: Writes scrnNN.bmp while the key is held. Lives with the other input
''       handling rather than in the present path.
''::::::::::
sub in_screenshot_key ( _
    g as Game, _
    byval h_dst_dc as long _
)

    ''
    '' F5, not S: S walks backwards now.
    ''
    if ( g.env.keyboard.f5 ) then
        scr_screenshot g, "scrn" + ltrim$(rtrim$(str$( screenie ))) + ".bmp", h_dst_dc
        screenie = screenie + 1
    end if

end sub
