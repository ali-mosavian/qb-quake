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
'' 256 entries and only a handful were being spent, so the ramps are as
'' long as they can usefully be: 100 background steps over 200 rows is two
'' rows per step, which stops the vignette banding without any dithering,
'' and 32 amber steps shade a twelve-pixel bar smoothly.
''
'' Quake's palette is browns: desaturated stone and warm bronze, lit by
'' fire. None of it is saturated and none of it is clean, so the ramps here
'' are a warm dark grey for the walls, a bronze for the plates, and an
'' ember for anything that glows. Nothing is a pure grey -- every step
'' carries some red, which is what stops it reading as a generic dark UI.
''
const LP_STN0   = 1              '' 48-step stone, near black -> mid brown
const LP_STNN   = 48
const LP_BRZ0   = 49             '' 32-step bronze, for the plates
const LP_BRZN   = 32
const LP_ACC0   = 81             '' 32-step ember, for the bars
const LP_ACCN   = 32
const LP_NEU0   = 113            '' 16-step warm neutral, for rules
const LP_NEUN   = 16
const LP_TEXT   = 254            '' where draw_load_font bakes the glyphs

'' Bevels are what make a Quake plate look pressed out of metal: a light
'' edge on the top and left, a dark one on the bottom and right, and the
'' opposite pair when something is meant to look sunken instead.
const C_PLATE   = LP_BRZ0 + 9    '' the raised bronze plate
const C_PLATEHI = LP_BRZ0 + 22
const C_PLATELO = LP_BRZ0 + 2
const C_PANEL   = LP_STN0 + 6    '' the sunken well the bar sits in
const C_EDGE    = LP_STN0 + 2
const C_EDGEHI  = LP_STN0 + 26
const C_TROUGH  = LP_STN0 + 1
const C_ACC     = LP_ACC0 + 16
const C_ACCHI   = LP_ACC0 + 29
const C_ACCLO   = LP_ACC0 + 4
const C_SPIN    = LP_BRZ0 + 12   '' the wireframe, bronze
const C_SPINHI  = LP_ACC0 + 26   '' its lit edges
const C_GRIME   = LP_STN0 + 12   '' the speckle over the walls
const C_GRIMELO = LP_STN0 + 1
const C_METAL   = LP_NEU0 + 4    '' the title slab: grey so the orange reads
const C_METALHI = LP_NEU0 + 9
const C_METALLO = LP_NEU0 + 1

'' Where the wireframe lives, so the tick can repaint just that box
'' the cube keeps to the left column, where Quake hangs its own sigil --
'' centred it would sit inside the painted title
const SPIN_CX   = 36
const SPIN_CY   = 40
const SPIN_R    = 20

''
'' The overlay runs under QUAKE's palette, not the loading ramps above --
'' videoOpen installs it. Its first sixteen entries are a grey ramp, black
'' through white, which is all the furniture needs.
''
''
'' The overlay's colours are LOOKED UP, not hardcoded: scr_hud_colors runs
'' once after videoOpen installs Quake's palette and best-fits each of
'' these against it. That is what lets the HUD share the game's material
'' language -- brown slabs, ember accents, fire-ramp warnings -- without
'' assuming anything about where Quake's ramps sit.
''
dim shared hc_bg as integer      '' near-black brown
dim shared hc_slab as integer    '' the panel slab
dim shared hc_slabhi as integer  '' its bevel, lit side
dim shared hc_slablo as integer  '' its bevel, shadow side
dim shared hc_hist as integer    '' graph columns
dim shared hc_peak as integer    '' the tallest column, so a spike reads
dim shared hc_meter as integer   '' bar fills
dim shared hc_good as integer    '' fps thresholds
dim shared hc_warn as integer
dim shared hc_bad as integer

'' peak-hold ticks on the VU meters, and the cache panel's warning flash
dim shared vu_pk(1) as integer
dim shared hud_flash as integer
dim shared hud_pevict as long
dim shared hud_pflush as long

'' How many frames of history the overlay graphs keep. One pixel column
'' each, so this is also their width.
const GRAPH_N   = 64

'' Panel geometry. The bars live inside it, so moving the panel moves
'' everything -- the old constants had the arithmetic spread over the file.
const PAN_X     = 62
const PAN_Y     = 124
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
dim shared ldr as LoadState
dim shared ldr_stage as string * 28
'$dynamic
'' 768 bytes, and DGROUP has nowhere near that spare -- see the note on
'' sc_lhead in d_surf.bas for what happens when something this size lands
'' there. REDIM'd, used, and erased inside scr_load_palette.
dim shared ldr_pal() as tRGB
dim shared spx() as integer      '' projected wireframe vertices
dim shared spy() as integer
'' Ring buffers behind the overlay graphs. Builds-per-frame is the one that
'' matters -- a hitch is several builds landing in one frame, and a number
'' that has already scrolled past cannot show you that shape.
dim shared g_bld() as integer
dim shared g_fps() as integer
'$static
dim shared g_head as integer     '' next slot, shared by both rings
dim shared g_fsec as integer     '' last fps value pushed
dim shared ldr_ang as single     '' how far the wireframe has turned

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
'' One loading step done: advance the bar and redraw it. The loaders used
'' to do this arithmetic themselves, which is how ldr reached all fourteen.
'' Part of one step, for a loader that reports progress within it.
sub scr_load_part ( _
    byval frac as single, _
    byval redraw as integer _
)
    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)*frac
    if ( redraw ) then scr_load_tick
end sub

sub scr_load_step
    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub

sub scr_load_tick
    draw_spinner
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

    '' Stone, and it has to go MUCH darker than feels right on a monitor:
    '' Quake's menu is nearly black except where a light falls. Red leads
    '' green leads blue at every step, which is what keeps it grimy brown
    '' rather than a cold grey.
    for i = 0 to LP_STNN-1
        f = i / (LP_STNN - 1.0)
        ldr_pal(LP_STN0+i).red   = chr$( cint(  6 + f * 62) )
        ldr_pal(LP_STN0+i).green = chr$( cint(  5 + f * 46) )
        ldr_pal(LP_STN0+i).blue  = chr$( cint(  4 + f * 34) )
    next i

    '' bronze, for the plates
    for i = 0 to LP_BRZN-1
        f = i / (LP_BRZN - 1.0)
        ldr_pal(LP_BRZ0+i).red   = chr$( cint( 34 + f * 148) )
        ldr_pal(LP_BRZ0+i).green = chr$( cint( 23 + f * 104) )
        ldr_pal(LP_BRZ0+i).blue  = chr$( cint( 12 + f * 50) )
    next i

    '' ember, for anything that glows
    for i = 0 to LP_ACCN-1
        f = i / (LP_ACCN - 1.0)
        ldr_pal(LP_ACC0+i).red   = chr$( cint( 62 + f * 193) )
        ldr_pal(LP_ACC0+i).green = chr$( cint( 20 + f * 188) )
        ldr_pal(LP_ACC0+i).blue  = chr$( cint(  6 + f * 118) )
    next i

    '' warm neutral: the title slab and the rules. Kept dim -- the metal
    '' in the reference is barely lighter than the wall behind it.
    for i = 0 to LP_NEUN-1
        f = i / (LP_NEUN - 1.0)
        ldr_pal(LP_NEU0+i).red   = chr$( cint( 30 + f * 132) )
        ldr_pal(LP_NEU0+i).green = chr$( cint( 28 + f * 124) )
        ldr_pal(LP_NEU0+i).blue  = chr$( cint( 25 + f * 112) )
    next i

    '' Every character on screen is this one index, and in Quake's menu
    '' every character is burnt orange -- so that is what it becomes. It
    '' does more for the resemblance than any amount of furniture.
    ldr_pal(LP_TEXT).red   = chr$(222)
    ldr_pal(LP_TEXT).green = chr$(138)
    ldr_pal(LP_TEXT).blue  = chr$( 66)

    uglPalSetBuff 0, 256, ldr_pal(0)
    erase ldr_pal

    redim spx(7) as integer
    redim spy(7) as integer
    ldr_ang = 0.0

    '' the overlay's history rings, allocated here because this is the one
    '' place in the module that runs exactly once at startup
    redim g_bld(GRAPH_N-1) as integer
    redim g_fps(GRAPH_N-1) as integer
    g_head = 0
    g_fsec = 0
end sub


''::::::::::
'' name: bg_band
'' desc: Repaints rows of the vignette. The spinner needs its box cleared
''       every turn, and the gradient is the only thing behind it, so the
''       backdrop had to become something that can be drawn in pieces.
''::::::::::
sub bg_band ( _
    x0 as integer, _
    x1 as integer, _
    y0 as integer, _
    y1 as integer _
)
    dim y as integer, x as integer, k as integer, d as integer, h as integer
    dim crs as integer, ofs as integer
    dim dy as integer, dx as integer, att as integer
    dim sg as integer, sx0 as integer, sx1 as integer

    for y = y0 to y1
        if ( y >= 0 and y <= 199 ) then
            ''
            '' A pool of light rather than a flat wash: Quake's menu is
            '' black at the edges and warm only where something is lit.
            '' Done in sixteen 20px columns instead of per pixel -- a true
            '' radial needs a distance per pixel and there are 64,000.
            ''
            dy = y - 88
            for sg = 0 to 15
                sx0 = sg * 20
                sx1 = sx0 + 19
                if ( sx1 >= x0 and sx0 <= x1 ) then
                    dx = (sx0 + 10) - 160
                    att = (dx * dx) \ 900 + (dy * dy) \ 300
                    k = LP_STN0 + 40 - att
                    if ( k < LP_STN0 ) then k = LP_STN0
                    if ( k > LP_STN0 + LP_STNN - 1 ) then k = LP_STN0 + LP_STNN - 1
                    if ( sx0 < x0 ) then sx0 = x0
                    if ( sx1 > x1 ) then sx1 = x1
                    uglHLine ldr.dc, sx0, y, sx1, k
                end if
            next sg

            ''
            '' Grain. Flat fills are the one thing Quake never has -- every
            '' surface is noisy -- so speckle each row from a hash of the
            '' coordinates rather than a random source, so a repaint of any
            '' box reproduces exactly what was there before.
            ''
            ''
            '' The hash needs a nonlinear term. A plain (x*a + y*b) lines
            '' the specks up on diagonals and the wall reads as tiled --
            '' the x*y folds that away, and the prime modulus keeps it from
            '' settling into a lattice.
            ''
            ''
            '' Block courses. Grain alone reads as noise; what makes it
            '' read as MASONRY is the seams -- a dark line every course,
            '' and vertical joints staggered half a block on alternate
            '' ones, the way stone is actually laid.
            ''
            crs = y \ 22
            if ( (y mod 22) = 0 ) then
                uglHLine ldr.dc, x0, y, x1, C_GRIMELO
            end if
            ofs = (crs and 1) * 27

            for x = x0 to x1
                h = cint( (clng(x) * 1619& + clng(y) * 7919& + _
                          ((clng(x) * clng(y)) mod 251&)) mod 997& )
                if ( ((x + ofs) mod 54) = 0 and (y mod 22) <> 0 ) then
                    uglPset ldr.dc, x, y, C_GRIMELO
                elseif ( h < 26 ) then
                    '' the speck sits a step above ITS column's light, not
                    '' the last column's -- k is stale here, so rederive
                    dx = x - 160
                    att = (dx * dx) \ 900 + (dy * dy) \ 300
                    k = LP_STN0 + 44 - att
                    if ( k < LP_STN0 + 2 ) then k = LP_STN0 + 2
                    if ( k > LP_STN0 + LP_STNN - 1 ) then k = LP_STN0 + LP_STNN - 1
                    uglPset ldr.dc, x, y, k
                elseif ( h < 52 ) then
                    uglPset ldr.dc, x, y, C_GRIMELO
                end if
            next x
        end if
    next y
end sub


''::::::::::
'' name: bevel
'' desc: A Quake plate: light along the top and left, dark along the bottom
''       and right, which reads as pressed out of metal. Pass raised = 0 to
''       swap them and have it read as sunken instead.
''::::::::::
''::::::::::
'' name: draw_logo
'' desc: The title, drawn the way Quake paints its menu lettering rather
''       than the way a system font sets it: each glyph pixel becomes a
''       chunky block with an ember gradient down the glyph (lit from
''       above), a hard drop shadow, and edges nibbled by the coordinate
''       hash so the outline reads as hand-cut rather than geometric.
''
''       The glyphs are read back out of the font DCs with uglPGet -- set
''       pixels carry LP_TEXT, clear ones the transparency key -- which is
''       what frees the lettering from the one-colour rule everything else
''       on screen lives under.
''::::::::::
sub draw_logo ( _
    text as string, _
    x as integer, _
    y as integer, _
    sc as integer _
)
    dim i as integer, ch as integer, gx as integer, gy as integer
    dim px as integer, bx as integer, by as integer, col as integer
    dim pass as integer, h as integer

    '' shadow first, then body, so the body always sits on top
    for pass = 0 to 1
        px = x
        for i = 1 to len( text )
            ch = asc( mid$( text, i, 1 ) )
            for gy = 0 to 7
                for gx = 0 to 7
                    if ( uglPGet( h_font_char(ch), gx, gy ) = LP_TEXT ) then
                        bx = px + gx*sc
                        by = y + gy*sc
                        if ( pass = 0 ) then
                            uglRectF ldr.dc, bx+2, by+3, bx+sc+1, by+sc+2, C_GRIMELO
                        else
                            '' lit from above: bright ember at the top of
                            '' the glyph falling to a dark red base
                            '' compressed: a full-steepness fade lost
                            '' the bottom third of every letter into the
                            '' wall. The base stays a readable ember.
                            col = LP_ACC0 + 29 - gy*3
                            if ( col < LP_ACC0 + 12 ) then col = LP_ACC0 + 12
                            uglRectF ldr.dc, bx, by, bx+sc-1, by+sc-1, col
                            '' nibble the block's corner from the hash, so
                            '' the outline stops being ruler-straight
                            h = cint( (clng(bx) * 1619& + clng(by) * 7919&) mod 11& )
                            if ( h < 3 ) then
                                uglPset ldr.dc, bx, by, col - 2
                                uglPset ldr.dc, bx+sc-1, by+sc-1, col - 3
                            end if
                        end if
                    end if
                next gx
            next gy
            px = px + 4*sc + sc\2
        next i
    next pass
end sub


''::::::::::
'' name: rivet
'' desc: Four pixels and a shadow. Corner hardware is half of what makes a
''       Quake plate read as bolted to the wall.
''::::::::::
sub rivet ( _
    x as integer, _
    y as integer _
)
    uglPset ldr.dc, x,   y,   C_METALHI
    uglPset ldr.dc, x+1, y,   C_METAL
    uglPset ldr.dc, x,   y+1, C_METAL
    uglPset ldr.dc, x+1, y+1, C_METALLO
end sub


sub bevel ( _
    x0 as integer, _
    y0 as integer, _
    x1 as integer, _
    y1 as integer, _
    hi as integer, _
    lo as integer, _
    raised as integer _
)
    dim a as integer, b as integer

    if ( raised ) then
        a = hi : b = lo
    else
        a = lo : b = hi
    end if
    uglHLine ldr.dc, x0, y0, x1, a
    uglVLine ldr.dc, x0, y0, y1, a
    uglHLine ldr.dc, x0, y1, x1, b
    uglVLine ldr.dc, x1, y0, y1, b
end sub


''::::::::::
'' name: draw_spinner
'' desc: A wireframe cube, turned a little further every tick. This is a
''       renderer, so the loading screen may as well render something --
''       and it doubles as proof of life during the long silent stretches
''       where a bar creeps a pixel every few seconds.
''
''       Twelve edges from eight vertices with no edge table: number the
''       corners so each bit is an axis, and two corners share an edge
''       exactly when they differ in one bit. Drawing only j > i visits
''       each edge once.
''::::::::::
sub draw_spinner
    dim i as integer, b as integer, j as integer
    dim ca as single, sa as single, cb as single, sb as single
    dim x as single, y as single, z as single
    dim x2 as single, y2 as single, z2 as single
    dim sc as single, col as integer

    '' only the spinner's own box -- clearing the full width here wiped the
    '' top corner brackets on every tick
    bg_band SPIN_CX - SPIN_R - 3, SPIN_CX + SPIN_R + 3, _
            SPIN_CY - SPIN_R - 3, SPIN_CY + SPIN_R + 3

    ca = cos( ldr_ang )
    sa = sin( ldr_ang )
    cb = cos( ldr_ang * 0.6 )
    sb = sin( ldr_ang * 0.6 )

    for i = 0 to 7
        '' bit per axis, so -1 or +1 on each
        if ( (i and 1) = 0 ) then x = -1.0 else x = 1.0
        if ( (i and 2) = 0 ) then y = -1.0 else y = 1.0
        if ( (i and 4) = 0 ) then z = -1.0 else z = 1.0

        x2 = x * ca - z * sa            '' yaw
        z2 = x * sa + z * ca
        y2 = y * cb - z2 * sb           '' then pitch
        z   = y * sb + z2 * cb

        sc = SPIN_R * 2.2 / (z + 4.0)   '' a little perspective
        spx(i) = SPIN_CX + cint( x2 * sc )
        spy(i) = SPIN_CY + cint( y2 * sc )
    next i

    for i = 0 to 7
        for b = 0 to 2
            j = i xor (2 ^ b)
            if ( j > i ) then
                '' the two corners nearest the front get the amber
                if ( (i and 4) <> 0 and (j and 4) <> 0 ) then
                    col = C_SPINHI
                else
                    col = C_SPIN
                end if
                uglLine ldr.dc, spx(i), spy(i), spx(j), spy(j), col
            end if
        next b
    next i

    ldr_ang = ldr_ang + 0.19
    if ( ldr_ang > 6.2831853 ) then ldr_ang = ldr_ang - 6.2831853
end sub


''::::::::::
'' name: draw_string_scl / draw_string_r
'' desc: Scaled and right-aligned text. Every glyph is its own 8x8 DC, so
''       scaling one is a masked blit; the advance is 4 because that is
''       what draw_string uses, the font being 4x6 inside an 8x8 cell.
''::::::::::
sub draw_string_scl ( _
    dc as long, _
    x as integer, _
    y as integer, _
    scale as single, _
    text as string _
)
    dim i as integer, char as integer, posx as integer

    posx = x
    for i = 0 to len( text )-1
        char = asc( mid$( text, i+1 ) )
        uglBlitMskScl dc, posx, y, scale, scale, h_font_char(char), 0, 0, 8, 8
        posx = posx + cint( 4 * scale )
    next i
end sub

sub draw_string_r ( _
    dc as long, _
    xright as integer, _
    y as integer, _
    text as string _
)
    draw_string dc, xright - 4*len( text ), y, text
end sub


''::::::::::
'' name: draw_pct
'' desc: The percentage, right-aligned and blanked first so a shorter
''       number cannot leave the tail of a longer one behind.
''::::::::::
sub draw_pct ( _
    dc as long, _
    xright as integer, _
    y as integer, _
    percent as single _
)
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
sub draw_bar ( _
    h_dc as long, _
    x as integer, _
    y as integer, _
    wdt as integer, _
    hgt as integer, _
    percent as single _
)
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
sub scr_load_chrome ( env as Env )
    dim ttl as string, sub1 as string, ftr as string
    dim plate_x as integer, plate_w as integer

    ''
    '' A soft vertical vignette: brightest across the middle where the panel
    '' sits, falling to near-black top and bottom. 32 ramp steps over 200
    '' rows is fine here because the range is narrow -- it reads as a
    '' backdrop rather than as banding.
    ''
    bg_band 0, 319, 0, 199

    ''
    '' A heavy frame around the whole screen, sunken, so the wall reads as
    '' a recess rather than as a picture.
    ''
    bevel 3, 3, 316, 196, C_EDGEHI, C_EDGE, 0
    bevel 5, 5, 314, 194, C_EDGEHI, C_EDGE, -1

    ''
    '' The title floats straight on the wall the way SINGLE PLAYER does in
    '' Quake's menu -- big painted letters, no box around them. The plate
    '' treatment goes to the small MAIN-style banner below instead.
    ''
    ttl = "QRENDER"
    draw_logo ttl, (320 - (len(ttl)*18 + 9)) \ 2, 48, 4

    sub1 = "a quake bsp renderer in quickbasic"
    draw_string ldr.dc, (320 - len(sub1)*4) \ 2, 92, sub1

    ''
    '' The map on a MAIN-style banner: grey riveted metal, so the orange
    '' name carries against it.
    ''
    sub1 = rtrim$( env.map_name )
    plate_w = len(sub1)*4 + 26
    plate_x = (320 - plate_w) \ 2
    uglRectF ldr.dc, plate_x, PAN_Y-19, plate_x+plate_w, PAN_Y-4, C_METAL
    bevel plate_x, PAN_Y-19, plate_x+plate_w, PAN_Y-4, C_METALHI, C_METALLO, -1
    bevel plate_x+2, PAN_Y-17, plate_x+plate_w-2, PAN_Y-6, C_METALHI, C_METALLO, 0
    rivet plate_x+4, PAN_Y-16
    rivet plate_x+plate_w-5, PAN_Y-16
    rivet plate_x+4, PAN_Y-9
    rivet plate_x+plate_w-5, PAN_Y-9
    draw_string ldr.dc, (320 - len(sub1)*4) \ 2, PAN_Y-14, sub1

    '' the well the bar sits in, sunken into the wall
    uglRectF ldr.dc, PAN_X, PAN_Y, PAN_X+PAN_W, PAN_Y+PAN_H, C_PANEL
    bevel PAN_X, PAN_Y, PAN_X+PAN_W, PAN_Y+PAN_H, C_EDGEHI, C_EDGE, 0

    ftr = "powered by uGL"
    draw_string ldr.dc, 320 - len(ftr)*4 - 12, 186, ftr
end sub






'':::::::::
function draw_load_font ( _
    flname as string, _
    colb as long, _
    env as Env, _
    bit_array() as integer _
) as integer
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
                if ( char(bit\16) and bit_array(15-bit and 15) ) then
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
sub draw_string ( _
    dc as long, _
    x as integer, _
    y as integer, _
    text as string _
)
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
''::::::::::
'' name: scr_hud_colors
'' desc: Best-fits the overlay's colours against whatever palette videoOpen
''       just installed. Called once, after the Quake palette is live.
''::::::::::
sub scr_hud_colors
    redim hpal(255) as tRGB

    uglPalGetBuff 0, 256, hpal(0)
    hc_bg     = uglPalBestFitBuff( hpal(0),  12,  10,   8 )
    hc_slab   = uglPalBestFitBuff( hpal(0),  52,  40,  28 )
    hc_slabhi = uglPalBestFitBuff( hpal(0), 104,  84,  60 )
    hc_slablo = uglPalBestFitBuff( hpal(0),  18,  14,  10 )
    hc_hist   = uglPalBestFitBuff( hpal(0), 150, 104,  56 )
    hc_peak   = uglPalBestFitBuff( hpal(0), 252, 216, 128 )
    hc_meter  = uglPalBestFitBuff( hpal(0), 200, 128,  56 )
    '' gold, not green: Quake has no bright green -- a green target
    '' best-fits onto a BLUE ramp entry -- and its own status bar numbers
    '' are gold anyway, so this is the more Quake convention regardless
    hc_good   = uglPalBestFitBuff( hpal(0), 244, 196,  92 )
    hc_warn   = uglPalBestFitBuff( hpal(0), 224, 164,  48 )
    hc_bad    = uglPalBestFitBuff( hpal(0), 216,  52,  36 )
    erase hpal

    vu_pk(0) = 0
    vu_pk(1) = 0
    hud_flash = 0
    hud_pevict = 0
    hud_pflush = 0
end sub


''::::::::::
'' name: hud_shade
'' desc: Tinted glass: darkens the scene under a rect by pushing every
''       pixel through a dark row of Quake's own colormap -- uglShadeRect
''       does the walk. Falls back to the opaque slab when no colormap is
''       loaded, so the overlay never depends on -lm's data being there.
''::::::::::
sub hud_shade ( _
    dc as long, _
    x0 as integer, _
    y0 as integer, _
    x1 as integer, _
    y1 as integer, _
    rw as integer _
)

    if ( mod_cm_ready = 0 ) then
        uglRectF dc, x0, y0, x1, y1, hc_slab
        exit sub
    end if
    ''
    '' Normalise the colormap pointer the way sb_build does: fold the
    '' offset into the segment so row*256 + offset stays inside 16 bits.
    ''
    '' Hoisted into a variable because BASIC will not take a Function
    '' call in a Sub's argument list here.
    dim cmp as long
    cmp = mod_cm_map
    uglShadeRect dc, x0, y0, x1, y1, cmp, rw
end sub


sub hud_panel ( _
    dc as long, _
    x as integer, _
    y as integer, _
    w as integer, _
    h as integer, _
    title as string _
)
    ''
    '' Tinted glass, then the slab's furniture: the scene stays visible
    '' under the panel, darkened three-quarters of the way down Quake's
    '' colormap, with the bevel and rivets on top saying where it ends.
    ''
    hud_shade dc, x, y, x+w, y+h, 46
    uglHLine dc, x, y, x+w, hc_slabhi
    uglVLine dc, x, y, y+h, hc_slabhi
    uglHLine dc, x, y+h, x+w, hc_slablo
    uglVLine dc, x+w, y, y+h, hc_slablo

    uglPset dc, x+2,   y+2,   hc_slabhi
    uglPset dc, x+3,   y+3,   hc_slablo
    uglPset dc, x+w-3, y+2,   hc_slabhi
    uglPset dc, x+w-2, y+3,   hc_slablo
    uglPset dc, x+2,   y+h-3, hc_slabhi
    uglPset dc, x+3,   y+h-2, hc_slablo
    uglPset dc, x+w-3, y+h-3, hc_slabhi
    uglPset dc, x+w-2, y+h-2, hc_slablo

    '' the title sits in the top rule, so blank the run it occupies
    uglHLine dc, x+5, y, x+8 + len( title )*4, hc_slab
    draw_string dc, x+7, y-3, title
end sub


''::::::::::
'' name: hud_num
'' desc: A number painted in a CHOSEN colour, which the baked one-colour
''       font cannot do: the glyph mask is read back out of the font DC
''       (set pixels carry LP_TEXT) and re-plotted block by block, with a
''       one-pixel shadow so it sits on the slab instead of floating.
''::::::::::
sub hud_num ( _
    dc as long, _
    x as integer, _
    y as integer, _
    sc as integer, _
    txt as string, _
    col as integer _
)
    dim i as integer, ch as integer, gx as integer, gy as integer
    dim px as integer, bx as integer, by as integer, pass as integer

    for pass = 0 to 1
        px = x
        for i = 1 to len( txt )
            ch = asc( mid$( txt, i, 1 ) )
            for gy = 0 to 7
                for gx = 0 to 7
                    if ( uglPGet( h_font_char(ch), gx, gy ) = LP_TEXT ) then
                        bx = px + gx*sc
                        by = y + gy*sc
                        if ( pass = 0 ) then
                            uglRectF dc, bx+1, by+1, bx+sc, by+sc, hc_slablo
                        else
                            uglRectF dc, bx, by, bx+sc-1, by+sc-1, col
                        end if
                    end if
                next gx
            next gy
            px = px + 4*sc + 1
        next i
    next pass
end sub


''::::::::::
'' name: hud_vu
'' desc: A VU meter with a peak-hold tick: the tick jumps to any new peak
''       and falls back slowly, which is what makes a meter read as an
''       instrument rather than a flickering bar. ch picks which channel's
''       peak this meter remembers.
''::::::::::
sub hud_vu ( _
    dc as long, _
    x as integer, _
    y as integer, _
    w as integer, _
    h as integer, _
    percent as single, _
    ch as integer _
)
    dim f as integer

    if ( percent < 0 ) then percent = 0
    if ( percent > 100 ) then percent = 100
    f = (w * percent) / 100.0

    if ( f > vu_pk(ch) ) then
        vu_pk(ch) = f
    elseif ( vu_pk(ch) > 0 ) then
        vu_pk(ch) = vu_pk(ch) - 1
    end if

    uglRectF dc, x, y, x+w, y+h, hc_bg
    uglRect  dc, x, y, x+w, y+h, hc_slablo
    if ( f > 1 ) then uglRectF dc, x+1, y+1, x+f-1, y+h-1, hc_meter
    if ( vu_pk(ch) > 1 ) then uglVLine dc, x+vu_pk(ch), y+1, y+h-1, hc_peak
end sub

sub hud_row ( _
    dc as long, _
    x as integer, _
    w as integer, _
    y as integer, _
    label as string, _
    value as string _
)
    draw_string dc, x+5, y, label
    draw_string_r dc, x+w-5, y, value
end sub

''::::::::::
'' name: hud_graph
'' desc: One pixel column per remembered frame, oldest at the left. The
''       scale is passed in rather than derived from the window, so the
''       bars keep their meaning as the view changes -- and the tallest
''       column is picked out, because the spike is the whole point.
''::::::::::
sub hud_graph ( _
    dc as long, _
    x as integer, _
    y as integer, _
    h as integer, _
    buf() as integer, _
    mx as integer _
)
    dim i as integer, k as integer, v as integer, c as integer, top as integer

    if ( mx < 1 ) then mx = 1

    uglRectF dc, x, y, x+GRAPH_N, y+h, hc_bg

    ''
    '' Reference lines at half and full scale, dashed. Without them a flat
    '' trace is an anonymous block and an idle one is an empty box -- both
    '' read as broken rather than as steady and quiet respectively.
    ''
    for i = 0 to GRAPH_N-1 step 3
        uglPset dc, x+i, y+1, hc_slablo
        uglPset dc, x+i, y+h\2, hc_slablo
    next i

    for i = 0 to GRAPH_N-1
        k = (g_head + i) mod GRAPH_N        '' oldest first, so it scrolls left
        v = buf(k)
        if ( v > 0 ) then
            top = (v * h) \ mx
            if ( top > h ) then top = h
            if ( v >= mx ) then c = hc_peak else c = hc_hist
            uglVLine dc, x+i, y+h-top, y+h, c
        end if
    next i
    uglRect dc, x, y, x+GRAPH_N, y+h, hc_slablo
end sub


sub hud_bar ( _
    dc as long, _
    x as integer, _
    y as integer, _
    w as integer, _
    h as integer, _
    percent as single _
)
    dim f as integer

    if ( percent < 0 ) then percent = 0
    if ( percent > 100 ) then percent = 100
    f = (w * percent) / 100.0

    uglRectF dc, x, y, x+w, y+h, hc_bg
    uglRect  dc, x, y, x+w, y+h, hc_slablo
    if ( f > 1 ) then uglRectF dc, x+1, y+1, x+f-1, y+h-1, hc_meter
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
sub scr_draw_hud ( _
    h_dst_dc as long, _
    env as Env, _
    scr as ScreenState, _
    rdr as RenderState, _
    vis as VisState, _
    wld as World _
)
    dim scs as CacheStats
    dim l as integer, r as integer
    dim lx as integer, rx as integer, cw as integer
    dim yy as integer, ftr as string
    dim fcol as integer

    cw = 146
    lx = 3
    rx = env.x_res - cw - 3

    if ( scr.stats ) then
        ''
        '' left, top: this frame
        ''
        hud_panel h_dst_dc, lx, 6, cw, 76, "RENDER"

        ''
        '' The frame rate is the number a player actually watches, so it
        '' gets the commercial treatment: twice the size and coloured by
        '' threshold -- readable from across the room in a way a fourth
        '' right-aligned row never was.
        ''
        if ( scr.fps >= 30 ) then
            fcol = hc_good
        elseif ( scr.fps >= 15 ) then
            fcol = hc_warn
        else
            fcol = hc_bad
        end if
        hud_num h_dst_dc, lx+6, 13, 2, ltrim$(str$( scr.fps )), fcol
        draw_string h_dst_dc, lx+34, 18, "fps"

        hud_row h_dst_dc, lx, cw, 30, "Polygons", ltrim$(str$( rdr.polys ))
        hud_row h_dst_dc, lx, cw, 38, "Triangles", ltrim$(str$( rdr.tris ))
        hud_row h_dst_dc, lx, cw, 46, "Leaves drawn/culled", _
                ltrim$(str$( vis.drw_leafs )) + "/" + ltrim$(str$( vis.cul_leafs ))
        draw_string h_dst_dc, lx+5, 60, "fps 60"
        hud_graph h_dst_dc, lx+cw-GRAPH_N-5, 59, 17, g_fps(), 60

        ''
        '' left, below: the surface cache. Builds-in-one-frame is what a
        '' hitch is made of, so it leads, and the worst frame is kept
        '' because an average over a run hides exactly that spike.
        ''
        '' one crossing into d_surf for the whole panel
        sc_stats scs

        hud_panel h_dst_dc, lx, 90, cw, 78, "SURFACE CACHE"

        ''
        '' Warning flash: evictions and flushes are the events being
        '' hunted, so the panel calls attention to itself when one lands
        '' rather than waiting to be read. Commercial HUDs surface alerts;
        '' logs wait to be read.
        ''
        if ( scs.evict > hud_pevict or scs.flushes > hud_pflush ) then
            hud_flash = 12
        end if
        hud_pevict = scs.evict
        hud_pflush = scs.flushes
        if ( hud_flash > 0 ) then
            if ( (hud_flash and 2) <> 0 ) then
                uglRect h_dst_dc, lx, 90, lx+cw, 90+78, hc_bad
            end if
            hud_flash = hud_flash - 1
        end if

        hud_row h_dst_dc, lx, cw, 96, "Hit / built", _
                ltrim$(str$( scs.hits )) + "/" + ltrim$(str$( scs.builds ))
        hud_row h_dst_dc, lx, cw, 104, "Worst frame", ltrim$(str$( scs.bpeak ))
        hud_row h_dst_dc, lx, cw, 112, "Resident", ltrim$(str$( scs.live ))
        hud_row h_dst_dc, lx, cw, 120, "Evicted", ltrim$(str$( scs.evict ))
        hud_row h_dst_dc, lx, cw, 128, "Flushes", ltrim$(str$( scs.flushes ))
        '' the store as a proportion of what it can hold, which a bare
        '' kilobyte count never conveys
        draw_string h_dst_dc, lx+5, 136, "Store"
        hud_bar h_dst_dc, lx+cw-GRAPH_N-5, 136, GRAPH_N, 6, _
                scs.peak * 100.0 / 4194304.0
        draw_string h_dst_dc, lx+5, 146, "builds " + ltrim$(str$( scs.bpeak ))
        hud_graph h_dst_dc, lx+cw-GRAPH_N-5, 145, 17, g_bld(), scs.bpeak

        ''
        '' right: the map, which never changes while it is loaded
        ''
        hud_panel h_dst_dc, rx, 6, cw, 56, "WORLD"
        hud_row h_dst_dc, rx, cw, 12, "Resolution", _
                ltrim$(str$( env.x_res )) + "x" + ltrim$(str$( env.y_res ))
        hud_row h_dst_dc, rx, cw, 20, "Vertices", ltrim$(str$( wld.count.verts ))
        hud_row h_dst_dc, rx, cw, 28, "Edges", ltrim$(str$( wld.count.edges ))
        hud_row h_dst_dc, rx, cw, 36, "Faces", ltrim$(str$( wld.count.faces ))
        hud_row h_dst_dc, rx, cw, 44, "Nodes", ltrim$(str$( wld.count.nodes ))
        hud_row h_dst_dc, rx, cw, 52, "Leaves", ltrim$(str$( wld.count.leaves ))

        ''
        '' one footer line for every toggle, in the order of the keys
        ''
        ftr = "F1 mip "
        if ( rdr.use_mips ) then ftr = ftr + "ON " else ftr = ftr + "off"
        if ( rdr.rend_mode = 0 ) then
            ftr = ftr + "   F2 perspective"
        elseif ( rdr.rend_mode = 1 ) then
            ftr = ftr + "   F2 affine     "
        else
            ftr = ftr + "   F2 wireframe  "
        end if
        ftr = ftr + "   B cull "
        if ( rdr.backface ) then ftr = ftr + "ON " else ftr = ftr + "off"
        ftr = ftr + "   L lm "
        if ( rdr.lightmap ) then ftr = ftr + "ON " else ftr = ftr + "off"
        ftr = ftr + "   F12 hide"

        yy = env.y_res - 9
        uglRectF h_dst_dc, 0, yy-2, env.x_res, env.y_res, hc_bg
        uglHLine h_dst_dc, 0, yy-2, env.x_res, hc_slabhi
        draw_string h_dst_dc, 4, yy, ftr
    else
        yy = env.y_res - 9
        draw_string h_dst_dc, 4, yy, "F12 stats"
    end if

    ''
    '' VU meters, bottom right, above the footer rule
    ''
    sndMasterGetVU l, r
    hud_vu h_dst_dc, env.x_res-76, env.y_res-24, 70, 4, l*100/255, 0
    hud_vu h_dst_dc, env.x_res-76, env.y_res-18, 70, 4, r*100/255, 1

    draw_string_r h_dst_dc, env.x_res-4, env.y_res-9, "powered by uGL"
end sub


''::::::::::
sub scr_screenshot ( _
    flname as string, _
    byval dc as long, _
    env as Env _
)
    dim f as integer
    dim x as integer
    dim y as integer
    dim w as integer
    dim h as integer
    dim pad as integer
    dim rowlen as integer
    dim imgsz as long
    dim off_bits as long
    dim palbuf(255) as tRGB
    dim row as string
    dim buf as string

    w   = env.x_res
    h   = env.y_res
    pad = (4 - (w mod 4)) mod 4

    rowlen  = w + pad
    imgsz   = clng(rowlen) * clng(h)
    off_bits = 14 + 40 + 1024

    uglPalGetBuff 0, 256, palbuf(0)

    f = freefile
    open flname for binary as #f

    ''
    '' BITMAPFILEHEADER
    ''
    buf = "BM" + mkl$( off_bits + imgsz ) + mki$(0) + mki$(0) + mkl$( off_bits )
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
sub draw_init_font ( _
    env as Env, _
    bit_array() as integer _
)
    if ( not draw_load_font( "base.dat::font/4x6.fnt", 254, env, bit_array() ) ) then
        sys_error "0x0000, Could not load font..."
    end if    

end sub

''::::::::::
'' name: scr_begin_loading
'' desc: Mode 13h for the duration of loading only.
''::::::::::
sub scr_begin_loading ( env as Env )
    ldr.dc = uglSetVideoDC( UGL.8BIT, 320, 200, 1 )
    if ( ldr.dc = false ) then
        sys_error "0x3001, Could not set loading video mode"
    end if

    '' palette before chrome: everything below indexes into its ramps
    scr_load_palette
    scr_load_chrome env
    scr_load_stage "starting up"
    scr_load_tick

end sub






''::::::::::
'' name: scr_count_frame
'' desc: One frame has been drawn. Rolls fps once a second, and clears the
''       counters the next frame will accumulate into.
''::::::::::
sub scr_count_frame ( _
    env as Env, _
    scr as ScreenState, _
    rdr as RenderState _
)

    fps1 = fps1 + 1

    if env.sec_timer.counter > 0 then
        scr.fps = fps1
        if ( fps1 > scr.fps_peak ) then scr.fps_peak = fps1
        '' low ignores the first completed second: it contains the tail of
        '' loading and the first surface builds, so it is not a frame rate
        '' the renderer ever sustains
        if ( scr.bench_secs > 0 ) then
            if ( ft.fps_low = 0 or fps1 < ft.fps_low ) then ft.fps_low = fps1
        end if
        g_fsec = fps1
        fps1 = 0
        env.sec_timer.counter = 0
        scr.bench_secs = scr.bench_secs + 1
    end if

    rdr.tris = 0
    rdr.polys = 0

    '' The cache closes its own frame now and reports what it built; the
    '' HUD only keeps the history graph, which is the HUD's business.
    g_bld(g_head) = sc_frame_end
    g_fps(g_head) = g_fsec
    g_head = (g_head + 1) mod GRAPH_N

end sub
