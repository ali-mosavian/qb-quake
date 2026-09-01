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
declare sub vid_update ( _
    g as Game, _
    h_dst_dc as long, _
    page as integer _
)
declare sub vid_init_ugl ( )
declare sub vid_init ( _
    g as Game _
)

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub scr_hud_colors ( )

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
sub vid_init ( _
    g as Game _
)
    dim pages as integer

    if ( g.env.use_paging = true ) then
        pages = g.env.pages
    else
        pages = 1
    end if
            
    g.env.h_video_dc = uglSetVideoDC( g.env.c_fmt, g.env.scr_x_res, g.env.scr_y_res, pages )
    if ( g.env.h_video_dc = FALSE ) then 
        sys_error "0x0001, Could not set video mode..."
    end if
    
    
    ''
    '' Create a backbuffer
    '' 
    if ( g.env.use_paging = false ) then
        ''
        '' The RENDER size, not the mode's. This is the single
        '' largest conventional allocation the program makes, and it
        '' scales with the view: 150x150 is 22,500 bytes where a full
        '' 320x200 is 64,000.
        ''
        g.env.h_back_bdc = uglNew( ugl.mem, g.env.c_fmt, g.env.x_res, g.env.y_res )
        if ( g.env.h_back_bdc = FALSE ) then 
            sys_error "0x0002, Could not create a backbuffer..."
        end if

        ''
        '' -comp: one more dc, the size of the MODE, that the view is
        '' scaled into and the overlay drawn onto at 1:1 -- then a single
        '' uglPut reaches the screen.
        ''
        '' The point is that video memory is written ONCE a frame. Scaling
        '' straight onto the screen and then drawing the overlay on top of
        '' it is two passes over the live framebuffer: the second one tears,
        '' and VRAM writes are slow enough to cost real frames.
        ''
        '' EMS, not conventional: 320x200 is 64,000 bytes, which is the
        '' allocation e1m1 already fails on. EMS maps a 16K page at a time,
        '' so a 320-wide row means one page covers ~51 rows and a sequential
        '' full-screen pass remaps about four times, not once a scanline.
        ''
        if ( g.env.comp ) then
            g.env.h_comp_dc = uglNew( ugl.ems, g.env.c_fmt, _
                                       g.env.scr_x_res, g.env.scr_y_res )
            if ( g.env.h_comp_dc = FALSE ) then
                sys_error "0x0003, Could not create the composite buffer..."
            end if
        end if

    end if     
    

    ''
    '' The border outside the view is written once and never again --
    '' nothing blits there -- so whatever the mode set left behind
    '' would sit there for the whole run.
    ''
    uglRectF g.env.h_video_dc, 0, 0, g.env.scr_x_res-1, g.env.scr_y_res-1, 0

    ''
    '' Load quake palette
    ''    
    uglPalSet 0, 256, g.pal
    memFree g.pal

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
    g as Game, _
    h_dst_dc as long, _
    page as integer _
)
    ''
    '' Present only. This used to also poll the screenshot key, tally frames
    '' per second, and zero the per-frame counters -- four unrelated jobs, and
    '' three of them nothing to do with video. Input polling in the present
    '' path is the odd one: pressing a key had to wait for a blit.
    ''
    if ( g.env.use_paging = false ) then
        '' -comp scales into the composite and leaves the screen alone; the
        '' host loop draws the overlay on top and blits the result once.
        if ( g.env.comp ) then
            uglPutScl g.env.h_comp_dc, g.env.view_x, g.env.view_y, _
                      g.env.view_scale, g.env.view_scale, g.env.h_back_bdc
        else
            uglPutScl g.env.h_video_dc, g.env.view_x, g.env.view_y, _
                      g.env.view_scale, g.env.view_scale, g.env.h_back_bdc
        end if

    else
        uglSetVisPage page
        uglSetWrkPage (page+1) mod g.env.pages
        page = (page+1) mod g.env.pages
    end if

end sub
