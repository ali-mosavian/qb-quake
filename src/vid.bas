option explicit
''
'' vid.bas -- video mode, back buffer and page flip.
''
'' Brings uGL up, opens the mode named in stuff.ini, and presents each
'' finished frame. Quake keeps this in its own vid_*.c for the same
'' reason: it is the only part that knows how pixels reach the screen.
''
'' fps1 and screenie are scalars, so no '$STATIC/'$DYNAMIC concern.
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
'$include: 'quakedef.bi'

'$static
dim shared fps1 as integer
dim shared screenie as integer




''::::::::::
'' name: initUgl
''::::::::::
defint a-z
sub vid_init_ugl
    if ( uglInit() = FALSE ) then 
        sys_error "0x0000, Could not init UGL..."
    end if

end sub




''::::::::::
'' name: videoOpen
'' desc: Final video mode, backbuffer and the Quake palette.
''::::::::::
defint a-z
sub vid_init
    dim pages as integer

    if ( env.usepag = true ) then
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
    if ( env.usepag = false ) then
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

end sub



''::::::::::
'' name: presentFrame
'' desc: Screenshot key, page flip or backbuffer blit, and the frame counter.
''
'' Once per frame, at the end of it.
''::::::::::
defint a-z
sub vid_update ( hDstDC as long, page as integer )

    ''
    '' Take screenshoot ?
    '' 
    if ( env.keyboard.s ) then            
        scr_screenshot "scrn" + ltrim$(rtrim$(str$( screenie ))) + ".bmp", hDstDC
        screenie = screenie + 1
    end if
    
    ''
    '' Paging/backbuffer
    ''
    if ( env.usepag = false ) then
        uglPut env.h_video_dc, 0, 0, env.h_back_bdc
    else        
        uglSetVisPage page
        uglSetWrkPage (page+1) mod env.pages
        page = (page+1) mod env.pages
    end if
    
    fps1 = fps1 + 1
    
    if env.sec_timer.counter > 0 then
        scr.fps = fps1
        fps1 = 0
        env.sec_timer.counter = 0
        scr.bench_secs = scr.bench_secs + 1
    end if        
    
    rdr.tris = 0
    rdr.polys = 0

end sub
