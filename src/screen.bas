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

'' Module-level DIMs under '$DYNAMIC are executable statements, and
'' module-level code only runs in the MAIN module -- in any other module
'' they never execute and the array is never allocated. '$STATIC arrays
'' are allocated at load with no code to run, so non-main modules must
'' declare their arrays here.
'$static
dim shared hFontChar(255) as long



'' ==========================================================================
''  SUPPORT
'' ==========================================================================
'' :::::::::::::
'' name: drwLoadingBar
'' desc: Draws a loading bar
''
'' :::::::::::::
defint a-z
sub drwLoadingBar ( hDC as long, x as integer, y as integer, wdt as integer, _
                    hgt as integer, percent as single, col as long )
    dim drwWidth as integer
    
    if ( percent < 0   ) then percent = 0
    if ( percent > 100 ) then percent = 100
    
    drwWidth = (wdt * percent) / 100.0    
    uglRect  hDC, x-2, y-2, x+wdt+2, y+hgt+2, col
    uglRectF hDC, x, y, x+drwWidth, y+hgt, col  
    
end sub




'':::::::::
defint a-z
function initFont% ( flname as string, colb as long )
    dim col as long
    dim trn as long
    dim fHndl as integer
    dim char(3) as integer
    
    dim file as UAR
    dim idstr as string * 4
    dim i as integer, x as integer, y as integer, bit as integer
    
    trn = uglColor8( 7, 0, 3 )    
    
    if ( not uglNewMult( hFontChar(), 256, UGL.EMS, env.cfmt, 8, 8 ) ) then
        initFont% = 0
        exit function
    end if        

    
    if ( uarOpen( file, flname, F4READ ) = false ) then
        initFont% = 0
        exit function
    end if

    
    ''
    '' Check id
    ''
    if ( uarReadEx( file, idstr, 4 ) <> 4 ) then
        initFont% = 0
        exit function
    end if    
    
    
    'if ( idstr <> "font" ) then
    '    initFont% = 0
    '    exit function        
    'end if
    
        
    
    for  i = 0 to 255
        if ( uarReadEx( file, char(0), 4*2 ) <> 4*2 ) then
            initFont% = 0
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
                
                uglPset hFontChar(i), x, y, col
                
                bit = bit + 1
            next x
        next y
    next i
    
    uarClose file
    initFont% = -1
end function



'':::::::::
defint a-z
sub fontPrintText ( dc as long, x as integer, y as integer, _
                    text as string )
    dim posx as integer
    dim i as integer, char as integer
    
    posx = x
    
    for  i = 0 to len( text )-1
    
        char = asc( mid$( text, i+1 ) )
        
        if ( (char >= 0) or (char <= 255) ) then
            uglPutMsk dc, posx, y, hFontChar(char)        
        end if
    
        posx = posx + 4
    next i
    
end sub



''::::::::::
'' name: drawHud
'' desc: Sound VU bars, the statistics overlay and the watermark.
''::::::::::
defint a-z
sub drawHud ( hDstDC as long )
    dim l as integer, r as integer

    ''
    '' Draw VUs
    ''
    sndMasterGetVU l, r
    drwLoadingBar hDstDC, env.xres-80, env.yres-29, 70, 3, l*100/255, 254
    drwLoadingBar hDstDC, env.xres-80, env.yres-20, 70, 3, r*100/255, 254
    

    ''
    '' Print stuff
    ''
    if ( stats ) then                    
        fontPrintText hDstDC, 0, 8*0, "Fps: " + str$( fps )
        fontPrintText hDstDC, 0, 8*1, "Renderd polys: " + str$( polys )
        fontPrintText hDstDC, 0, 8*2, "Renderd triangles: " + str$( tris )
        
        if ( usemips ) then 
            fontPrintText hDstDC, 0, 8*3, "Mipmapping: enabled, press f1 to disable"
        else
            fontPrintText hDstDC, 0, 8*3, "Mipmapping: disabled, press f1 to enable"
        end if
        
        if ( rendmode = 0 ) then 
            fontPrintText hDstDC, 0, 8*4, "Render mode: perspective correct, press f2 to change"
        elseif ( rendmode = 1 ) then 
            fontPrintText hDstDC, 0, 8*4, "Render mode: affine, press f2 to change"
        else
            fontPrintText hDstDC, 0, 8*4, "Render mode: wireframe, press f2 to change"
        end if       
        
        if ( backface ) then 
            fontPrintText hDstDC, 0, 8*5, "Backface culling: enabled, press 'b' to disable"
        else
            fontPrintText hDstDC, 0, 8*5, "Backface culling: disabled, press 'b' to enable"
        end if
        
        fontPrintText hDstDC, 0, env.yres-8*7-6, "Resolution: " + str$( env.xres ) + "x" + ltrim$(str$( env.yres ))
        fontPrintText hDstDC, 0, env.yres-8*6-6, "Vertices:" + str$( vtxCount )
        fontPrintText hDstDC, 0, env.yres-8*5-6, "Edges:" + str$( edgCount )
        fontPrintText hDstDC, 0, env.yres-8*4-6, "Polygons:" + str$( triCount )
        fontPrintText hDstDC, 0, env.yres-8*3-6, "Nodes:" + str$( ndsCount )
        fontPrintText hDstDC, 0, env.yres-8*2-6, "Leaves:" + str$( lefCount )
        fontPrintText hDstDC, 0, env.yres-8*1-6, "PVS entries:" + str$( lefCount^2 )
        fontPrintText hDstDC, 0, env.yres-8*0-6, "Stats: enabled, press f12 to disable"             
    else 
        fontPrintText hDstDC, 0, env.yres-8*0-6, "Stats: disabled, press f12 to enable"
    end if
    
    fontPrintText hDstDC, env.xres-56, env.yres-6, "Powered by UGL"
end sub




''::::::::::
'' name: ugluBMPSave
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
defint a-z
sub ugluBMPSave ( flname as string, byval dc as long )
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

    w   = env.xRes
    h   = env.yRes
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
