option explicit
''
'' screen.bas -- everything drawn on top of the world.
''
'' The loading bar, the bitmap font, the statistics overlay and the
'' screenshot writer. Quake keeps the same unit unprefixed: screen.c and
'' sbar.c draw over the finished frame rather than being part of it.
''
'' hFontChar carries a real bound and stays module-local, so it keeps its
'' allocation -- only COMMON arrays lose theirs.
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

''
'' Loading screen geometry. Private to this module on purpose: the bar is
'' drawn through drwLoadTick/drwMipTick below, so no caller needs to know
'' where it sits. Sixteen call sites used to carry the arithmetic inline.
'' The 320x200 here is the loading DC's own mode, not the render mode --
'' loadScreenOpen sets it explicitly and videoOpen replaces it later.
''
const LOADBAR_W = 150
const LOADBAR_H = 20
const LOADBAR_X = (320-LOADBAR_W)\2
const LOADBAR_Y = (200-LOADBAR_H)\2
const MIPBAR_H  = 7
const MIPBAR_Y  = LOADBAR_Y-15

'' Module-level DIMs under '$DYNAMIC are executable statements, and
'' module-level code only runs in the MAIN module -- in any other module
'' they never execute and the array is never allocated. '$STATIC arrays
'' are allocated at load with no code to run, so non-main modules must
'' declare their arrays here.
'$static
dim shared h_font_char(255) as long

'' Frames within the current second; scr.fps is the last completed
'' second's total, which is what the overlay shows.
dim shared fps1 as integer



'' ==========================================================================
''  SUPPORT
'' ==========================================================================
'' :::::::::::::
'' name: scr_load_tick
'' desc: Redraws the main loading bar at the current 'loading' percent.
''       Takes no arguments -- loadDC and loading are both /qmapS/ --
''       which is why the fourteen callers reduce to a bare call.
'' :::::::::::::
sub scr_load_tick
    draw_bar ldr.dc, LOADBAR_X, LOADBAR_Y, LOADBAR_W, LOADBAR_H, ldr.pct, -1
end sub


'' :::::::::::::
'' name: scr_mip_tick
'' desc: The thinner sub-bar above the main one, showing progress through
''       the current texture's four mip levels.
'' :::::::::::::
sub scr_mip_tick ( percent as single )
    draw_bar ldr.dc, LOADBAR_X, MIPBAR_Y, LOADBAR_W, MIPBAR_H, percent, 51
end sub


'' :::::::::::::
'' name: draw_bar
'' desc: Draws a loading bar
''
'' :::::::::::::
sub draw_bar ( h_dc as long, x as integer, y as integer, wdt as integer, _
                    hgt as integer, percent as single, col as long )
    dim drw_width as integer
    
    if ( percent < 0   ) then percent = 0
    if ( percent > 100 ) then percent = 100
    
    drw_width = (wdt * percent) / 100.0    
    uglRect  h_dc, x-2, y-2, x+wdt+2, y+hgt+2, col
    uglRectF h_dc, x, y, x+drw_width, y+hgt, col  
    
end sub




'':::::::::
function draw_load_font ( flname as string, colb as long ) as integer
    dim col as long
    dim trn as long
    dim f_hndl as integer
    dim char(3) as integer
    
    dim file as UAR
    dim idstr as string * 4
    dim i as integer, x as integer, y as integer, bit as integer
    
    trn = uglColor8( 7, 0, 3 )    
    
    if ( not uglNewMult( h_font_char(), 256, UGL.EMS, env.c_fmt, 8, 8 ) ) then
        draw_load_font = 0
        exit function
    end if        

    
    if ( uarOpen( file, flname, F4READ ) = false ) then
        draw_load_font = 0
        exit function
    end if

    
    ''
    '' Check id
    ''
    if ( uarReadEx( file, idstr, 4 ) <> 4 ) then
        draw_load_font = 0
        exit function
    end if    
    
    
    'if ( idstr <> "font" ) then
    '    draw_load_font% = 0
    '    exit function        
    'end if
    
        
    
    for  i = 0 to 255
        if ( uarReadEx( file, char(0), 4*2 ) <> 4*2 ) then
            draw_load_font = 0
            exit function
        end if
        
        bit = 0
        
        for y = 0 to 7
            for  x = 0 to 7
                if ( char(bit\16) and bitarray(15-bit and 15) ) then
                    col = colb
                else
                    col = trn                         
                end if
                
                uglPset h_font_char(i), x, y, col
                
                bit = bit + 1
            next x
        next y
    next i
    
    uarClose file
    draw_load_font = -1
end function



'':::::::::
sub draw_string ( dc as long, x as integer, y as integer, _
                    text as string )
    dim posx as integer
    dim i as integer, char as integer
    
    posx = x
    
    for  i = 0 to len( text )-1
    
        char = asc( mid$( text, i+1 ) )
        
        if ( (char >= 0) or (char <= 255) ) then
            uglPutMsk dc, posx, y, h_font_char(char)        
        end if
    
        posx = posx + 4
    next i
    
end sub



''::::::::::
'' name: scr_draw_hud
'' desc: Sound VU bars, the statistics overlay and the watermark.
''::::::::::
sub scr_draw_hud ( h_dst_dc as long )
    dim l as integer, r as integer

    ''
    '' Draw VUs
    ''
    sndMasterGetVU l, r
    draw_bar h_dst_dc, env.x_res-80, env.y_res-29, 70, 3, l*100/255, 254
    draw_bar h_dst_dc, env.x_res-80, env.y_res-20, 70, 3, r*100/255, 254
    

    ''
    '' Print stuff
    ''
    if ( scr.stats ) then                    
        draw_string h_dst_dc, 0, 8*0, "Fps: " + str$( scr.fps )
        draw_string h_dst_dc, 0, 8*1, "Renderd polys: " + str$( rdr.polys )
        draw_string h_dst_dc, 0, 8*2, "Renderd triangles: " + str$( rdr.tris )
        
        if ( rdr.usemips ) then 
            draw_string h_dst_dc, 0, 8*3, "Mipmapping: enabled, press f1 to disable"
        else
            draw_string h_dst_dc, 0, 8*3, "Mipmapping: disabled, press f1 to enable"
        end if
        
        if ( rdr.rendmode = 0 ) then 
            draw_string h_dst_dc, 0, 8*4, "Render mode: perspective correct, press f2 to change"
        elseif ( rdr.rendmode = 1 ) then 
            draw_string h_dst_dc, 0, 8*4, "Render mode: affine, press f2 to change"
        else
            draw_string h_dst_dc, 0, 8*4, "Render mode: wireframe, press f2 to change"
        end if       
        
        if ( rdr.backface ) then 
            draw_string h_dst_dc, 0, 8*5, "Backface culling: enabled, press 'b' to disable"
        else
            draw_string h_dst_dc, 0, 8*5, "Backface culling: disabled, press 'b' to enable"
        end if

        ''
        '' Cull efficiency. Both counters were already being incremented
        '' once per leaf in the innermost traversal loop, and nothing read
        '' them -- the cost was being paid for no output.
        ''
        draw_string h_dst_dc, 0, 8*6, "Leaves drawn:" + str$( vis.drw_leafs ) + _
                                     "  culled:" + str$( vis.cul_leafs )
        
        draw_string h_dst_dc, 0, env.y_res-8*7-6, "Resolution: " + str$( env.x_res ) + "x" + ltrim$(str$( env.y_res ))
        draw_string h_dst_dc, 0, env.y_res-8*6-6, "Vertices:" + str$( wld.vtx_count )
        draw_string h_dst_dc, 0, env.y_res-8*5-6, "Edges:" + str$( wld.edg_count )
        draw_string h_dst_dc, 0, env.y_res-8*4-6, "Polygons:" + str$( wld.tri_count )
        draw_string h_dst_dc, 0, env.y_res-8*3-6, "Nodes:" + str$( wld.nds_count )
        draw_string h_dst_dc, 0, env.y_res-8*2-6, "Leaves:" + str$( wld.lef_count )
        draw_string h_dst_dc, 0, env.y_res-8*1-6, "PVS entries:" + str$( wld.lef_count^2 )
        draw_string h_dst_dc, 0, env.y_res-8*0-6, "Stats: enabled, press f12 to disable"             
    else 
        draw_string h_dst_dc, 0, env.y_res-8*0-6, "Stats: disabled, press f12 to enable"
    end if
    
    draw_string h_dst_dc, env.x_res-56, env.y_res-6, "Powered by UGL"
end sub




''::::::::::
'' name: scr_screenshot
'' desc: Writes a DC out as an 8 bit Windows BMP.
''
''       uGL declares a screenshot routine in uglu.bi (ugluSaveTGA) but never
''       shipped an implementation, and bspfile.bi declares a ugluBMPSave that
''       exists in no library either. The screenshot key has been calling an
''       unresolved symbol, so the program has never linked. This is that
''       routine, in BASIC.
''
''       Entered once per keypress, so it is written for clarity: rows are
''       built as strings and PUT whole rather than a byte at a time.
''::::::::::
sub scr_screenshot ( flname as string, byval dc as long )
    dim f as integer
    dim x as integer
    dim y as integer
    dim w as integer
    dim h as integer
    dim pad as integer
    dim rowlen as integer
    dim imgsz as long
    dim offbits as long
    dim palbuf(255) as tRGB
    dim row as string
    dim buf as string

    w   = env.x_res
    h   = env.y_res
    pad = (4 - (w mod 4)) mod 4

    rowlen  = w + pad
    imgsz   = clng(rowlen) * clng(h)
    offbits = 14 + 40 + 1024

    uglPalGetBuff 0, 256, palbuf(0)

    f = freefile
    open flname for binary as #f

    ''
    '' BITMAPFILEHEADER
    ''
    buf = "BM" + mkl$( offbits + imgsz ) + mki$(0) + mki$(0) + mkl$( offbits )
    put #f, , buf

    ''
    '' BITMAPINFOHEADER
    ''
    buf = mkl$(40) + mkl$(clng(w)) + mkl$(clng(h)) + mki$(1) + mki$(8) + _
          mkl$(0) + mkl$(imgsz) + mkl$(2835) + mkl$(2835) + _
          mkl$(256) + mkl$(0)
    put #f, , buf

    ''
    '' Palette, written BGRA
    ''
    buf = ""
    for x = 0 to 255
        buf = buf + palbuf(x).blue + palbuf(x).green + palbuf(x).red + chr$(0)
    next x
    put #f, , buf

    ''
    '' Pixels, bottom row first. Pad bytes stay zero.
    ''
    for y = h-1 to 0 step -1
        row = string$( rowlen, 0 )
        for x = 0 to w-1
            mid$( row, x+1, 1 ) = chr$( uglPGet( dc, x, y ) and 255 )
        next x
        put #f, , row
    next y

    close #f

end sub






''::::::::::
'' name: draw_init_font
''::::::::::
sub draw_init_font
    if ( not draw_load_font( "base.dat::font/4x6.fnt", 254 ) ) then
        sys_error "0x0000, Could not load font..."
    end if    

end sub






''::::::::::
'' name: scr_begin_loading
'' desc: Mode 13h for the duration of loading only.
''::::::::::
sub scr_begin_loading
    ldr.dc = uglSetVideoDC( UGL.8BIT, 320, 200, 1 )
    if ( ldr.dc = false ) then
        sys_error "0x3001, Could not set loading video mode"
    end if
    
    scr_load_tick    

end sub






''::::::::::
'' name: scr_count_frame
'' desc: One frame has been drawn. Rolls fps once a second, and clears the
''       counters the next frame will accumulate into.
''::::::::::
sub scr_count_frame

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
