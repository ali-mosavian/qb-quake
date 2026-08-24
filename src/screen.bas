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
''
'' The loading screen sets its OWN palette. uGL's default is RGB332, which
'' gives blue only four levels and bands anything subtle; videoOpen replaces
'' the whole thing with Quake's later, so nothing downstream cares what we
'' do here. Note that uglColor8 and friends are meaningless once this is
'' installed -- mgl says so in uglpal.asm -- which is why every colour below
'' is an explicit index into a ramp we laid out ourselves.
''
'' The font is baked at index 254 by draw_load_font, with 227 as its
'' transparency key, so ALL text is one colour: 254 is set to the brightest
'' neutral and the hierarchy comes from size and placement instead.
''
const LP_BG0    = 1              '' 32-step background ramp
const LP_BGN    = 32
const LP_NEU0   = 33             '' 16-step neutral, for chrome
const LP_NEUN   = 16
const LP_ACC0   = 49             '' 16-step amber, for the bars
const LP_ACCN   = 16
const LP_TEXT   = 254            '' where draw_load_font bakes the glyphs

const C_PANEL   = LP_BG0  + 4
const C_EDGE    = LP_NEU0 + 2
const C_EDGEHI  = LP_NEU0 + 6
const C_TROUGH  = LP_BG0  + 1
const C_ACC     = LP_ACC0 + 8
const C_ACCHI   = LP_ACC0 + 14
const C_ACCLO   = LP_ACC0 + 2

''
'' The overlay runs under QUAKE's palette, not the loading ramps above --
'' videoOpen installs it. Its first sixteen entries are a grey ramp, black
'' through white, which is all the furniture needs.
''
const HUD_BG    = 0
const HUD_EDGE  = 5
const HUD_METER = 11

'' Panel geometry. The bars live inside it, so moving the panel moves
'' everything -- the old constants had the arithmetic spread over the file.
const PAN_X     = 62
const PAN_Y     = 100
const PAN_W     = 196
const PAN_H     = 48
const LOADBAR_X = PAN_X + 10
const LOADBAR_W = PAN_W - 20
const LOADBAR_Y = PAN_Y + 20
const LOADBAR_H = 12
const MIPBAR_Y  = LOADBAR_Y + LOADBAR_H + 6
const MIPBAR_H  = 4

'' Module-level DIMs under '$DYNAMIC are executable statements, and
'' module-level code only runs in the MAIN module -- in any other module
'' they never execute and the array is never allocated. '$STATIC arrays
'' are allocated at load with no code to run, so non-main modules must
'' declare their arrays here.
'$static
dim shared h_font_char(255) as long

'' The loading stage line, redrawn in place rather than appended down the
'' screen the way the old bare draw_string did it.
dim shared ldr_stage as string * 28
'$dynamic
'' 768 bytes, and DGROUP has nowhere near that spare -- see the note on
'' sc_lhead in d_surf.bas for what happens when something this size lands
'' there. REDIM'd, used, and erased inside scr_load_palette.
dim shared ldr_pal() as tRGB
'$static

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
    draw_bar ldr.dc, LOADBAR_X, LOADBAR_Y, LOADBAR_W, LOADBAR_H, ldr.pct
    draw_pct ldr.dc, PAN_X + PAN_W - 10, PAN_Y + 8, ldr.pct
end sub


''::::::::::
'' name: scr_load_palette
'' desc: Installs the loading screen's own ramps -- see the note by LP_BG0.
''       Three of them: a cool slate for the background, a neutral for the
''       chrome, and an amber for the bars.
''::::::::::
sub scr_load_palette
    dim i as integer
    dim f as single

    redim ldr_pal(255) as tRGB

    for i = 0 to 255
        ldr_pal(i).red = chr$(0)
        ldr_pal(i).green = chr$(0)
        ldr_pal(i).blue = chr$(0)
    next i

    '' background: near-black to a dark slate, cool rather than neutral so
    '' the amber has something to sit against
    for i = 0 to LP_BGN-1
        f = i / (LP_BGN - 1.0)
        ldr_pal(LP_BG0+i).red   = chr$( cint(  4 + f * 22) )
        ldr_pal(LP_BG0+i).green = chr$( cint(  6 + f * 26) )
        ldr_pal(LP_BG0+i).blue  = chr$( cint( 10 + f * 34) )
    next i

    '' chrome
    for i = 0 to LP_NEUN-1
        f = i / (LP_NEUN - 1.0)
        ldr_pal(LP_NEU0+i).red   = chr$( cint( 40 + f * 190) )
        ldr_pal(LP_NEU0+i).green = chr$( cint( 46 + f * 188) )
        ldr_pal(LP_NEU0+i).blue  = chr$( cint( 56 + f * 184) )
    next i

    '' amber
    for i = 0 to LP_ACCN-1
        f = i / (LP_ACCN - 1.0)
        ldr_pal(LP_ACC0+i).red   = chr$( cint( 70 + f * 185) )
        ldr_pal(LP_ACC0+i).green = chr$( cint( 34 + f * 168) )
        ldr_pal(LP_ACC0+i).blue  = chr$( cint(  8 + f * 96) )
    next i

    '' the glyphs are baked at this index, so this is every character on
    '' screen -- brightest neutral, slightly warm
    ldr_pal(LP_TEXT).red   = chr$(238)
    ldr_pal(LP_TEXT).green = chr$(240)
    ldr_pal(LP_TEXT).blue  = chr$(246)

    uglPalSetBuff 0, 256, ldr_pal(0)
    erase ldr_pal
end sub


''::::::::::
'' name: draw_string_scl / draw_string_r
'' desc: Scaled and right-aligned text. Every glyph is its own 8x8 DC, so
''       scaling one is a masked blit; the advance is 4 because that is
''       what draw_string uses, the font being 4x6 inside an 8x8 cell.
''::::::::::
sub draw_string_scl ( dc as long, x as integer, y as integer, _
                      scale as single, text as string )
    dim i as integer, char as integer, posx as integer

    posx = x
    for i = 0 to len( text )-1
        char = asc( mid$( text, i+1 ) )
        uglBlitMskScl dc, posx, y, scale, scale, h_font_char(char), 0, 0, 8, 8
        posx = posx + cint( 4 * scale )
    next i
end sub

sub draw_string_r ( dc as long, xright as integer, y as integer, _
                    text as string )
    draw_string dc, xright - 4*len( text ), y, text
end sub


''::::::::::
'' name: draw_pct
'' desc: The percentage, right-aligned and blanked first so a shorter
''       number cannot leave the tail of a longer one behind.
''::::::::::
sub draw_pct ( dc as long, xright as integer, y as integer, percent as single )
    dim p as integer

    p = cint( percent )
    if ( p < 0 ) then p = 0
    if ( p > 100 ) then p = 100

    uglRectF dc, xright-20, y, xright, y+6, C_PANEL
    draw_string_r dc, xright, y, ltrim$(str$( p )) + "%"
end sub


''::::::::::
'' name: scr_load_stage
'' desc: What loading is currently doing. Drawn in a fixed slot inside the
''       panel and blanked first, so the phases replace one another rather
''       than marching down the screen.
''::::::::::
sub scr_load_stage ( msg as string )
    ldr_stage = msg
    if ( ldr.dc = 0 ) then exit sub
    uglRectF ldr.dc, PAN_X+9, PAN_Y+8, PAN_X+PAN_W-32, PAN_Y+14, C_PANEL
    draw_string ldr.dc, PAN_X+10, PAN_Y+8, rtrim$( ldr_stage )
end sub


'' :::::::::::::
'' name: scr_mip_tick
'' desc: The thinner sub-bar above the main one, showing progress through
''       the current texture's four mip levels.
'' :::::::::::::
sub scr_mip_tick ( percent as single )
    draw_bar ldr.dc, LOADBAR_X, MIPBAR_Y, LOADBAR_W, MIPBAR_H, percent
end sub


'' :::::::::::::
'' name: draw_bar
'' desc: Draws a loading bar
''
'' :::::::::::::
sub draw_bar ( h_dc as long, x as integer, y as integer, wdt as integer, _
                    hgt as integer, percent as single )
    dim w as integer, i as integer, k as integer

    if ( percent < 0   ) then percent = 0
    if ( percent > 100 ) then percent = 100
    w = (wdt * percent) / 100.0

    ''
    '' Sunken trough, then the fill. The trough is drawn every tick rather
    '' than once because the fill only ever grows here -- but a flush during
    '' a map change rewinds it, and a stale tail is worse than the redraw.
    ''
    uglRectF h_dc, x, y, x+wdt, y+hgt, C_TROUGH
    uglHLine h_dc, x, y, x+wdt, C_EDGE
    uglVLine h_dc, x, y, y+hgt, C_EDGE
    uglHLine h_dc, x, y+hgt, x+wdt, C_EDGEHI
    uglVLine h_dc, x+wdt, y, y+hgt, C_EDGEHI

    if ( w < 1 ) then exit sub

    ''
    '' The fill is shaded across its height off the amber ramp: brightest
    '' just under the top edge, falling away below. One HLine per row, so a
    '' twelve-pixel bar is twelve calls.
    ''
    for i = 1 to hgt-1
        k = LP_ACC0 + LP_ACCN - 1 - ((i * (LP_ACCN-4)) \ hgt)
        uglHLine h_dc, x+1, y+i, x+w, k
    next i
    uglHLine h_dc, x+1, y+1, x+w, C_ACCHI
end sub


''::::::::::
'' name: scr_load_chrome
'' desc: Everything on the loading screen that does not move, drawn once.
''       scr_load_tick repaints only the bars and the percentage, which is
''       what keeps ~200 ticks cheap.
''::::::::::
sub scr_load_chrome
    dim y as integer, k as integer, d as integer
    dim ttl as string, sub1 as string, ftr as string

    ''
    '' A soft vertical vignette: brightest across the middle where the panel
    '' sits, falling to near-black top and bottom. 32 ramp steps over 200
    '' rows is fine here because the range is narrow -- it reads as a
    '' backdrop rather than as banding.
    ''
    for y = 0 to 199
        d = y - 100
        if ( d < 0 ) then d = -d
        k = LP_BG0 + LP_BGN - 1 - (d * (LP_BGN-1)) \ 100
        if ( k < LP_BG0 ) then k = LP_BG0
        uglHLine ldr.dc, 0, y, 319, k
    next y

    '' title, three times size, centred on its own advance
    ttl = "QRENDER"
    draw_string_scl ldr.dc, (320 - len(ttl)*12) \ 2, 38, 3.0, ttl

    sub1 = "a quake bsp renderer in quickbasic"
    draw_string ldr.dc, (320 - len(sub1)*4) \ 2, 72, sub1

    '' the map, since loading one is the whole reason this screen exists
    sub1 = rtrim$( env.map_name )
    draw_string ldr.dc, (320 - len(sub1)*4) \ 2, PAN_Y - 12, sub1

    '' a rule, bevelled: the dark line above the light one reads as incised
    uglHLine ldr.dc, 70, 86, 250, C_EDGE
    uglHLine ldr.dc, 70, 87, 250, C_EDGEHI

    '' the panel the bars sit in
    uglRectF ldr.dc, PAN_X, PAN_Y, PAN_X+PAN_W, PAN_Y+PAN_H, C_PANEL
    uglHLine ldr.dc, PAN_X, PAN_Y, PAN_X+PAN_W, C_EDGEHI
    uglVLine ldr.dc, PAN_X, PAN_Y, PAN_Y+PAN_H, C_EDGEHI
    uglHLine ldr.dc, PAN_X, PAN_Y+PAN_H, PAN_X+PAN_W, C_EDGE
    uglVLine ldr.dc, PAN_X+PAN_W, PAN_Y, PAN_Y+PAN_H, C_EDGE

    ftr = "powered by uGL"
    draw_string ldr.dc, 320 - len(ftr)*4 - 8, 188, ftr
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
'' name: hud_panel / hud_row / hud_bar
'' desc: The overlay's furniture. Quake's palette is installed by the time
''       any of this runs, so the indices here are its grey ramp (0 black
''       through 15 white) and NOT the loading screen's ramps.
''
''       Values are right-aligned against the panel's inner edge. That is
''       the whole difference between a readable column of numbers and the
''       ragged "label: value  label: value" this replaced -- the eye can
''       compare digits that line up.
''::::::::::
sub hud_panel ( dc as long, x as integer, y as integer, _
                w as integer, h as integer, title as string )
    uglRectF dc, x, y, x+w, y+h, HUD_BG
    uglRect  dc, x, y, x+w, y+h, HUD_EDGE
    '' the title sits in the top rule, so blank the run it occupies
    uglHLine dc, x+5, y, x+8 + len( title )*4, HUD_BG
    draw_string dc, x+7, y-3, title
end sub

sub hud_row ( dc as long, x as integer, w as integer, y as integer, _
              label as string, value as string )
    draw_string dc, x+5, y, label
    draw_string_r dc, x+w-5, y, value
end sub

sub hud_bar ( dc as long, x as integer, y as integer, w as integer, _
              h as integer, percent as single )
    dim f as integer

    if ( percent < 0 ) then percent = 0
    if ( percent > 100 ) then percent = 100
    f = (w * percent) / 100.0

    uglRectF dc, x, y, x+w, y+h, HUD_BG
    uglRect  dc, x, y, x+w, y+h, HUD_EDGE
    if ( f > 1 ) then uglRectF dc, x+1, y+1, x+f-1, y+h-1, HUD_METER
end sub


''::::::::::
'' name: scr_draw_hud
'' desc: Sound VU bars, the statistics overlay and the watermark.
''
''       Three panels rather than seventeen loose lines: what the renderer
''       is doing right now, what the map is, and how the surface cache is
''       behaving. The key hints moved to one footer line -- repeating
''       "press f1 to disable" on every row cost more space than the rows.
''::::::::::
sub scr_draw_hud ( h_dst_dc as long )
    dim l as integer, r as integer
    dim lx as integer, rx as integer, cw as integer
    dim yy as integer, ftr as string

    cw = 146
    lx = 3
    rx = env.x_res - cw - 3

    if ( scr.stats ) then
        ''
        '' left, top: this frame
        ''
        hud_panel h_dst_dc, lx, 6, cw, 40, "RENDER"
        hud_row h_dst_dc, lx, cw, 12, "Frames/sec", ltrim$(str$( scr.fps ))
        hud_row h_dst_dc, lx, cw, 20, "Polygons", ltrim$(str$( rdr.polys ))
        hud_row h_dst_dc, lx, cw, 28, "Triangles", ltrim$(str$( rdr.tris ))
        hud_row h_dst_dc, lx, cw, 36, "Leaves drawn/culled", _
                ltrim$(str$( vis.drw_leafs )) + "/" + ltrim$(str$( vis.cul_leafs ))

        ''
        '' left, below: the surface cache. Builds-in-one-frame is what a
        '' hitch is made of, so it leads, and the worst frame is kept
        '' because an average over a run hides exactly that spike.
        ''
        hud_panel h_dst_dc, lx, 54, cw, 56, "SURFACE CACHE"
        hud_row h_dst_dc, lx, cw, 60, "Hit / built", _
                ltrim$(str$( sc_hits )) + "/" + ltrim$(str$( sc_builds ))
        hud_row h_dst_dc, lx, cw, 68, "Worst frame", ltrim$(str$( sc_bpeak ))
        hud_row h_dst_dc, lx, cw, 76, "Resident", ltrim$(str$( sc_live ))
        hud_row h_dst_dc, lx, cw, 84, "Evicted", ltrim$(str$( sc_evict ))
        hud_row h_dst_dc, lx, cw, 92, "Flushes", ltrim$(str$( sc_flushes ))
        hud_row h_dst_dc, lx, cw, 100, "Peak store", _
                ltrim$(str$( sc_peak \ 1024& )) + "K"

        ''
        '' right: the map, which never changes while it is loaded
        ''
        hud_panel h_dst_dc, rx, 6, cw, 56, "WORLD"
        hud_row h_dst_dc, rx, cw, 12, "Resolution", _
                ltrim$(str$( env.x_res )) + "x" + ltrim$(str$( env.y_res ))
        hud_row h_dst_dc, rx, cw, 20, "Vertices", ltrim$(str$( wld.vtx_count ))
        hud_row h_dst_dc, rx, cw, 28, "Edges", ltrim$(str$( wld.edg_count ))
        hud_row h_dst_dc, rx, cw, 36, "Faces", ltrim$(str$( wld.tri_count ))
        hud_row h_dst_dc, rx, cw, 44, "Nodes", ltrim$(str$( wld.nds_count ))
        hud_row h_dst_dc, rx, cw, 52, "Leaves", ltrim$(str$( wld.lef_count ))

        ''
        '' one footer line for every toggle, in the order of the keys
        ''
        ftr = "F1 mip "
        if ( rdr.usemips ) then ftr = ftr + "ON " else ftr = ftr + "off"
        if ( rdr.rendmode = 0 ) then
            ftr = ftr + "   F2 perspective"
        elseif ( rdr.rendmode = 1 ) then
            ftr = ftr + "   F2 affine     "
        else
            ftr = ftr + "   F2 wireframe  "
        end if
        ftr = ftr + "   B cull "
        if ( rdr.backface ) then ftr = ftr + "ON " else ftr = ftr + "off"
        ftr = ftr + "   F12 hide"

        yy = env.y_res - 9
        uglRectF h_dst_dc, 0, yy-2, env.x_res, env.y_res, HUD_BG
        uglHLine h_dst_dc, 0, yy-2, env.x_res, HUD_EDGE
        draw_string h_dst_dc, 4, yy, ftr
    else
        yy = env.y_res - 9
        draw_string h_dst_dc, 4, yy, "F12 stats"
    end if

    ''
    '' VU meters, bottom right, above the footer rule
    ''
    sndMasterGetVU l, r
    hud_bar h_dst_dc, env.x_res-76, env.y_res-24, 70, 4, l*100/255
    hud_bar h_dst_dc, env.x_res-76, env.y_res-18, 70, 4, r*100/255

    draw_string_r h_dst_dc, env.x_res-4, env.y_res-9, "powered by uGL"
end sub


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

    '' palette before chrome: everything below indexes into its ramps
    scr_load_palette
    scr_load_chrome
    scr_load_stage "starting up"
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

    '' Per-frame cache counters. The peak is kept before the reset because a
    '' hitch is one bad frame, and an average over the run hides it.
    if ( sc_builds > sc_bpeak ) then sc_bpeak = sc_builds
    sc_hits = 0
    sc_builds = 0

end sub
