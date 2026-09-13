option explicit
''
'' mod_tex.bas -- reading texture headers and handing the preprocessed bitmaps to uGL,
''              in the game palette. The resampling and colour matching this
''              used to do at load now happen offline in tools/mkassets.py.
''
'' The region split below is load-bearing, not style. A module-level DIM
'' under '$DYNAMIC is an executable statement and module-level code only
'' runs in the MAIN module, so here it would never execute and the array
'' would never be allocated. texoffs carries a real bound and nothing
'' REDIMs it, so it must be '$STATIC. The rest are REDIMmed at load, and a
'' REDIM does allocate -- but REDIM requires a dynamic array, so those have
'' to stay '$DYNAMIC. Getting this backwards is what killed the first
'' attempt at this cut.
''
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'
'$include: 'qgl.bi'

''
'' qgl's own, for the atlas: it is a qgl surface now, not an mgl dc. The
'' narrowest place that can see them is here -- this is the only module
'' that makes or aims one.
''
declare function qglSfFromFileBas& ( _
    path as string, _
    byval wide as integer, _
    byval kind as integer _
)
declare function qglSfViewNew& ( _
    byval parent as long, _
    byval wide as integer, _
    byval high as integer, _
    byval bps as integer _
)
declare function qglSfViewShape% ( _
    byval v as long, _
    byval wid as integer, _
    byval ofs as long _
)
declare function qglSfPget% ( _
    byval s as long, _
    byval x as integer, _
    byval y as integer _
)

''
'' This module's own procedures.
''
declare sub mod_load_flat ( _
    flname as string, _
    byval dst as long _
)
declare sub mod_link_anims ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)
declare function mod_anim_class ( nm as string ) as integer
declare function mod_anim_slot ( nm as string ) as integer
declare function qglSfSize ( byval s as long, byval sel as integer ) as integer

''
'' This module's own procedures.
''
declare sub mod_load_texinfo ( _
    g as Game, _
    tex_info() as TexInfo, _
    mip_buff_inf() as MipTex _
)
declare sub mod_load_textures ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)
declare function mod_tex_ofs ( byval ent as long ) as long
declare function mod_tex_lg ( byval ent as long, byval axis as integer ) as integer
declare function mod_tex_dim ( byval ent as long, byval axis as integer ) as integer
declare function mod_tex_view ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer, _
    byval shaded as integer _
) as long

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub scr_load_part ( _
    byval frac as single, _
    byval redraw as integer _
)
declare sub scr_mip_tick ( percent as single )

'$static
dim shared tex_offs( 256 ) as long

'$dynamic
dim shared t_mip_inf( 1 ) as DiskMipTex




''::::::::::
'' name: mod_load_texinfo
'' desc: Reads the miptex directory and sizes the texture tables.
''::::::::::
sub mod_load_texinfo ( _
    g as Game, _
    tex_info() as TexInfo, _
    mip_buff_inf() as MipTex _
)
    scr_load_stage "texture info"
    dim i as integer

    mod_load_flat "assets.zip::texinf.bld", _
        clng( varseg( tex_info(0) ) ) * 65536& + (clng( varptr( tex_info(0) ) ) and 65535&)

    scr_load_step
    
    seek #g.wld.file.handle, g.wld.file.head.mip_tex.offs+1
    get #g.wld.file.handle,, g.wld.count.textures
    
    redim t_mip_inf( g.wld.count.textures-1 ) as DiskMipTex
    redim mip_buff_inf( g.wld.count.textures-1 ) as MipTex
    
    for  i = 0 to g.wld.count.textures-1
        get #g.wld.file.handle,, tex_offs(i)
    next i    
    

end sub








''::::::::::
'' name: mod_load_textures
'' desc: Reads every texture, builds its four mip levels and colour
''       matches each one back into the Quake palette. One loop over
''       numtex, so it is one routine.
''::::::::::
sub mod_load_textures ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)
    dim i as integer, j as integer
    dim bmp_file as string
    dim ofs as long

    scr_load_stage "textures"

    for  i = 0 to g.wld.count.textures-1
        ''
        '' Per-texture header only: the renderer scales texture axes by the
        '' reciprocal of the ORIGINAL texture size, so those dimensions are
        '' still needed even though the pixels come from the bmps.
        ''
        seek #g.wld.file.handle, g.wld.file.head.mip_tex.offs+tex_offs(i)+1
        get #g.wld.file.handle,, t_mip_inf(i)

        mip_buff_inf(i).hght = 1.0 / t_mip_inf(i).hght
        mip_buff_inf(i).wdth = 1.0 / t_mip_inf(i).wdth

        ''
        '' Quake encodes what a texture does in its name. A leading * is a
        '' liquid, which flows; a leading +N is one frame of an animation,
        '' the rest of whose frames share the name after the digit.
        ''
        mip_buff_inf(i).liquid     = false
        mip_buff_inf(i).anim_next  = i
        mip_buff_inf(i).anim_pos   = 0
        mip_buff_inf(i).anim_count = 1

        if ( left$( t_mip_inf(i).name, 1 ) = "*" ) then
            mip_buff_inf(i).liquid = true
        end if

    next i

    ''
    '' The pixels: two atlases, four views each. A cell is a FLAT run of
    '' cell*cell bytes, not a window on the 8192-wide image -- the fillers
    '' map one page and then walk the cell by the VIEW's bps, which is the
    '' cell width. Sizes are 4096/1024/256/64 and each cell is placed at a
    '' multiple of its own size, so none straddles a 16K page.
    ''
    '' The placement is READ, not re-derived: mkassets.py owns the layout
    '' and is free to pack in whatever order is tightest. Deriving it twice
    '' is the bug the luxel atlas avoids by shipping its own table.
    ''
    '' THE ATLAS IS QGL'S, NOT MGL'S. It used to be two uglNewBMPEx dcs out
    '' of assets.zip, read through mgl's own dispatch table -- which is a
    '' NEAR call, and mgl's table holds near offsets into ugl_text, so
    '' calling it from qgl_text (sb.asm) jumped into whatever qgl routine
    '' sat at that offset. That is why the surface builder hung.
    ''
    '' The pixels are the same bytes either way: mkassets.py writes them
    '' flat beside the exe as well, because file.asm is plain INT 21h and
    '' cannot see inside the zip -- the delivery FONT.FNT already uses.
    '' No BMP container, so no BMPOPT.NO332 to get wrong and no bottom-up
    '' row order to undo; the indices are already exactly what the filler
    '' wants.
    ''
    '' The HEIGHT is the file's, not a number here: qglSfFromFileBas sizes
    '' the surface from the length. This module must not re-derive the
    '' packer's layout -- same rule as the offset table below.
    ''
    g.wld.tex.raw    = qglSfFromFileBas&( "TEXR.RAW", TEX_ATLAS_W, QGL_SURF_EMS )
    g.wld.tex.shaded = qglSfFromFileBas&( "TEXS.RAW", TEX_ATLAS_W, QGL_SURF_EMS )
    if ( g.wld.tex.raw = 0 or g.wld.tex.shaded = 0 ) then
        sys_error "0x0016, texture atlas would not load"
    end if

    mod_load_flat "assets.zip::texofs.bld", _
        clng( varseg( g.wld.tex.ofs(0) ) ) * 65536& + (clng( varptr( g.wld.tex.ofs(0) ) ) and 65535&)

    '' The flat atlas is staged beside the exe apart from the zip, so it
    '' can be another map's: dm3ish's 14 rows under e1m1's table drew
    '' every texture as some other one, and nothing said so.
    dim last as integer, ent as long, cw as integer, ch as integer
    dim atlas_rows as integer
    last = g.wld.count.textures * 4 - 1
    ent  = g.wld.tex.ofs(last)
    cw   = mod_tex_dim( ent, 0 )
    ch   = mod_tex_dim( ent, 1 )
    atlas_rows = qglSfSize( g.wld.tex.raw, 1 )
    if ( mod_tex_ofs( ent ) + clng(cw) * ch > clng( atlas_rows ) * TEX_ATLAS_W ) then
        sys_error "0x0018, texture atlas shorter than its offset table"
    end if

    '' Made on first use, one per cell HEIGHT: a map wants a handful of
    '' the fifteen, and nothing here knows which until a face asks.
    for  j = 0 to TEX_HEIGHTS - 1
        g.wld.tex.v_raw(j)    = 0
        g.wld.tex.v_shaded(j) = 0
        g.wld.tex.aim_raw(j)  = -1
        g.wld.tex.aim_shd(j)  = -1
    next j
    scr_load_part 1.0, true

    mod_link_anims g, mip_buff_inf()

end sub



''::::::::::
'' name: mod_link_anims
'' desc: Groups +0name, +1name ... into chains.
''
''       A frame's name is + then a digit then the shared suffix, and the
''       digits give the order. This records, for every frame, where its
''       chain starts and how long it is -- which is all d_draw_faces needs
''       to pick a frame, given the chain is stored contiguously.
''
''       Only correct when a map lists an animation's frames in order, which
''       is how qbsp writes them. dm3ish has no animated textures at all, so
''       this is exercised only by maps that do.
''::::::::::
sub mod_link_anims ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)
    dim i as integer, j as integer, k as integer, n as integer
    dim seq as integer, slot as integer
    dim suffix as string
    dim ring( 9 ) as integer     '' Quake's own cap: ten frames a chain

    '' Mod_LoadTextures: +0..+9 are one sequence, +a..+j the alternate,
    '' both keyed by the name after the digit. The frames sit anywhere in
    '' the lump -- e1m1 has +0planet at 55 and +1planet at 70 -- so they
    '' are found by digit and linked in a ring, never assumed adjacent.
    for  i = 0 to g.wld.count.textures-1
        if ( left$( t_mip_inf(i).name, 1 ) = "+" ) then
            if ( mip_buff_inf(i).anim_count = 1 ) then
                seq = mod_anim_class( t_mip_inf(i).name )
                suffix = mid$( rtrim$( t_mip_inf(i).name ), 3 )
                for  k = 0 to 9
                    ring(k) = -1
                next k
                n = 0
                for  j = i to g.wld.count.textures-1
                    if ( left$( t_mip_inf(j).name, 1 ) = "+" ) then
                        if ( mod_anim_class( t_mip_inf(j).name ) = seq ) then
                            if ( mid$( rtrim$( t_mip_inf(j).name ), 3 ) = suffix ) then
                                slot = mod_anim_slot( t_mip_inf(j).name )
                                if ( ring(slot) < 0 ) then n = n + 1
                                ring(slot) = j
                            end if
                        end if
                    end if
                next j
                '' a gap in 0..n-1 is a broken chain: leave its frames single
                for  k = 0 to n-1
                    if ( ring(k) < 0 ) then n = 0
                next k
                if ( n > 1 ) then
                    for  k = 0 to n-1
                        mip_buff_inf( ring(k) ).anim_pos   = k
                        mip_buff_inf( ring(k) ).anim_next  = ring( (k+1) mod n )
                        mip_buff_inf( ring(k) ).anim_count = n
                    next k
                end if
            end if
        end if
    next i
    erase t_mip_inf     '' 40 bytes a texture, read by nothing from here on
end sub

'' 0 for +0..+9, 1 for +a..+j, -1 for anything else after the +
function mod_anim_class ( nm as string ) as integer
    dim c as integer
    c = asc( mid$( nm, 2, 1 ) )
    mod_anim_class = -1
    if ( c >= 48 and c <= 57 ) then mod_anim_class = 0
    if ( c >= 97 and c <= 106 ) then mod_anim_class = 1
    if ( c >= 65 and c <= 74 ) then mod_anim_class = 1
end function

'' the frame's place in its sequence: the digit, or the letter from a
function mod_anim_slot ( nm as string ) as integer
    dim c as integer
    c = asc( mid$( nm, 2, 1 ) )
    if ( c >= 48 and c <= 57 ) then mod_anim_slot = c - 48
    if ( c >= 97 and c <= 106 ) then mod_anim_slot = c - 97
    if ( c >= 65 and c <= 74 ) then mod_anim_slot = c - 65
end function


'' Cell k of mip j, as a dc. Re-aims a view rather than owning 648 of them.
''
'' mkassets.py packs the cell into the offset table entry: the byte
'' offset in bits 0..22, log2 of the cell width in 23..26 and log2 of its
'' height in 27..30. That is what lets a texture keep its own size and
'' aspect instead of being squeezed into a square.
''
function mod_tex_ofs ( byval ent as long ) as long
    mod_tex_ofs = ent and 8388607&
end function

function mod_tex_lg ( byval ent as long, byval axis as integer ) as integer
    if ( axis = 0 ) then
        mod_tex_lg = cint( (ent \ 8388608&) and 15& )
    else
        mod_tex_lg = cint( (ent \ 134217728&) and 15& )
    end if
end function

function mod_tex_dim ( byval ent as long, byval axis as integer ) as integer
    mod_tex_dim = cint( 2 ^ mod_tex_lg( ent, axis ) )
end function

''::::::::::
'' name: mod_tex_view
'' desc: The view of the right HEIGHT, shaped to cell (k, mip) and aimed
''       at it. A view's address table is its height's and qglSfViewShape
''       changes only the width, so the views are one per height and made
''       on first use -- a map wants a handful of the fifteen.
''::::::::::
function mod_tex_view ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer, _
    byval shaded as integer _
) as long
    dim ent as long, ofs as long, v as long
    dim cw as integer, ch as integer, hi as integer, want as integer
    dim ok as integer

    '' Every helper's result goes to a local first: BC reads a user
    '' FUNCTION inside another call's argument list as an array and
    '' reports Argument-count mismatch. `want` is not `key` for the same
    '' family of reason -- KEY is a statement.
    ent  = g.wld.tex.ofs( k*4 + mip )
    ofs  = mod_tex_ofs( ent )
    cw   = mod_tex_dim( ent, 0 )
    ch   = mod_tex_dim( ent, 1 )
    hi   = mod_tex_lg( ent, 1 )
    want = k*4 + mip

    if ( hi >= TEX_HEIGHTS ) then exit function

    if ( shaded ) then v = g.wld.tex.v_shaded(hi) else v = g.wld.tex.v_raw(hi)

    if ( v = 0 ) then
        '' bps IS the cell width: a cell is a flat run of cw*ch bytes, not
        '' a window on the 8192-wide image, so the view walks it by its own
        '' width and not the parent's.
        if ( shaded ) then
            v = qglSfViewNew&( g.wld.tex.shaded, cw, ch, cw )
            g.wld.tex.v_shaded(hi) = v
            g.wld.tex.aim_shd(hi)  = -1
        else
            v = qglSfViewNew&( g.wld.tex.raw, cw, ch, cw )
            g.wld.tex.v_raw(hi)   = v
            g.wld.tex.aim_raw(hi) = -1
        end if
        if ( v = 0 ) then sys_error "0x0017, no room for a texture view"
    end if

    if ( shaded ) then
        if ( g.wld.tex.aim_shd(hi) <> want ) then
            ok = qglSfViewShape%( v, cw, ofs )
            if ( ok = 0 ) then exit function
            g.wld.tex.aim_shd(hi) = want
        end if
    else
        if ( g.wld.tex.aim_raw(hi) <> want ) then
            ok = qglSfViewShape%( v, cw, ofs )
            if ( ok = 0 ) then exit function
            g.wld.tex.aim_raw(hi) = want
        end if
    end if

    mod_tex_view = v
end function

function mod_tex_raw ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
    mod_tex_raw = mod_tex_view( g, k, mip, 0 )
end function

function mod_tex_shaded ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
    mod_tex_shaded = mod_tex_view( g, k, mip, -1 )
end function


''::::::::::
'' name: mod_tex_dump
'' desc: Reads every cell back THROUGH ITS VIEW, with uglPGet, into a
''       contact sheet. Comparing that against the atlas says whether
''       uglNewView/uglSetView deliver the right pixels, with the renderer
''       out of the way.
''::::::::::
sub mod_tex_dump ( g as Game )
    dim k as integer, mip as integer, y as integer, ty as integer
    dim x as integer, cx as integer
    dim dc as long
    dim f as integer
    dim sw as integer, sh as integer
    dim colw as integer
    dim band(3) as integer, top(3) as integer
    dim rowlen as integer
    dim imgsz as long, off_bits as long
    dim palbuf(255) as PalRgb
    dim row as string, buf as string

    '' Cells are the textures' own sizes now, so the sheet is measured
    '' rather than assumed: one column per texture as wide as the widest
    '' mip-0 cell, and a band per mip as tall as its tallest cell.
    colw = 1
    for  mip = 0 to 3
        band(mip) = 1
        for  k = 0 to g.wld.count.textures-1
            x = mod_tex_dim( g.wld.tex.ofs( k*4 + mip ), 1 )
            if ( x > band(mip) ) then band(mip) = x
            if ( mip = 0 ) then
                x = mod_tex_dim( g.wld.tex.ofs( k*4 ), 0 )
                if ( x > colw ) then colw = x
            end if
        next k
    next mip

    top(0) = 0
    for  mip = 1 to 3
        top(mip) = top(mip-1) + band(mip-1)
    next mip

    sw       = g.wld.count.textures * colw
    sh       = top(3) + band(3)
    rowlen   = (sw + 3) and -4
    imgsz    = clng(rowlen) * clng(sh)
    off_bits = 14 + 40 + 1024

    '' the palette the screenshot carries too: pal.raw, r g b per entry
    f = freefile
    open "pal.raw" for binary as #f
    for x = 0 to 255
        get #f, , palbuf(x)
    next x
    close #f

    f = freefile
    open "texdump.bmp" for binary as #f

    buf = "BM" + mkl$( off_bits + imgsz ) + mki$(0) + mki$(0) + mkl$( off_bits )
    put #f, , buf

    buf = mkl$(40) + mkl$(clng(sw)) + mkl$(clng(sh)) + mki$(1) + mki$(8) + _
          mkl$(0) + mkl$(imgsz) + mkl$(2835) + mkl$(2835) + _
          mkl$(256) + mkl$(0)
    put #f, , buf

    buf = ""
    for  x = 0 to 255
        buf = buf + palbuf(x).blue + palbuf(x).green + palbuf(x).red + chr$(0)
    next x
    put #f, , buf

    ''
    '' One column per texture, the four mips stacked largest first. y runs
    '' down the sheet; BMP stores the bottom row first, so it counts down.
    ''
    for  y = sh-1 to 0 step -1
        mip = 0
        for  x = 1 to 3
            if ( y >= top(x) ) then mip = x
        next x
        ty = y - top(mip)

        row = string$( rowlen, 0 )
        for  k = 0 to g.wld.count.textures-1
            if ( ty < mod_tex_dim( g.wld.tex.ofs( k*4 + mip ), 1 ) ) then
                dc = mod_tex_raw( g, k, mip )
                if ( dc <> 0 ) then
                    for  cx = 0 to mod_tex_dim( g.wld.tex.ofs( k*4 + mip ), 0 ) - 1
                        mid$( row, k*colw + cx + 1, 1 ) = chr$( qglSfPget( dc, cx, ty ) and 255 )
                    next cx
                end if
            end if
        next k
        put #f, , row
    next y

    close #f
end sub
