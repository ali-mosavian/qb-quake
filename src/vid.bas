option explicit
''
'' vid.bas -- video mode, back buffer and page flip.
''
'' Brings uGL up, opens the mode named in stuff.ini, and presents each
'' finished frame. Quake keeps this in its own vid_*.c for the same
'' reason: it is the only part that knows how pixels reach the screen.
''
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
'$include: 'q_draw.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_scr.bi'
'$include: 'q_snd.bi'

'$static




''::::::::::
'' name: vid_init_ugl
''::::::::::
sub vid_init_ugl
    if ( uglInit() = FALSE ) then 
        sys_error "0x0000, Could not init UGL..."
    end if

end sub




''::::::::::
'' name: vid_init
'' desc: Final video mode, backbuffer and the Quake palette.
''::::::::::
sub vid_init
    dim pages as integer

    if ( env.use_paging = true ) then
        pages = env.pages
    else
        pages = 1
    end if
            
    env.h_video_dc = uglSetVideoDC( env.c_fmt, env.x_res, env.y_res, pages )
    if ( env.h_video_dc = FALSE ) then 
        sys_error "0x0001, Could not set video mode..."
    end if
    
    
    ''
    '' Create a backbuffer
    '' 
    if ( env.use_paging = false ) then
        env.h_back_bdc = uglNew( ugl.mem, env.c_fmt, env.x_res, env.y_res )
        if ( env.h_back_bdc = FALSE ) then 
            sys_error "0x0002, Could not create a backbuffer..."
        end if
    end if     
    

    ''
    '' Load quake palette
    ''    
    uglPalSet 0, 256, pal
    memFree pal

    '' the overlay best-fits its colours against the palette that is now
    '' live -- it has to run after the set, and exactly once
    scr_hud_colors

end sub



''::::::::::
'' name: vid_update
'' desc: Screenshot key, page flip or backbuffer blit, and the frame counter.
''
'' Once per frame, at the end of it.
''::::::::::
sub vid_update ( _
    h_dst_dc as long, _
    page as integer _
)
    ''
    '' Present only. This used to also poll the screenshot key, tally frames
    '' per second, and zero the per-frame counters -- four unrelated jobs, and
    '' three of them nothing to do with video. Input polling in the present
    '' path is the odd one: pressing a key had to wait for a blit.
    ''
    if ( env.use_paging = false ) then
        uglPut env.h_video_dc, 0, 0, env.h_back_bdc
    else
        uglSetVisPage page
        uglSetWrkPage (page+1) mod env.pages
        page = (page+1) mod env.pages
    end if

end sub
