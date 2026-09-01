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
declare sub mod_load_flat ( _
    flname as string, _
    byval dst as long _
)
declare sub mod_link_anims ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)

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

    ''
    '' The palette is still read here because videoOpen installs it and frees
    '' it. Nothing in this routine looks at its contents any more.
    ''
    g.pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )

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
        mip_buff_inf(i).anim_base  = i
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
    '' BMPOPT.NO332 matters: without it uGL remaps the image to its own
    '' 3-3-2 palette and the indices, already correct, would be destroyed.
    ''
    g.wld.tex.raw    = uglNewBMPEx( UGL.EMS, UGL.8BIT, "assets.zip::texr.bmp", BMPOPT.NO332 )
    g.wld.tex.shaded = uglNewBMPEx( UGL.EMS, UGL.8BIT, "assets.zip::texs.bmp", BMPOPT.NO332 )
    if ( g.wld.tex.raw = 0 or g.wld.tex.shaded = 0 ) then
        sys_error "0x0016, texture atlas would not load"
    end if

    mod_load_flat "assets.zip::texofs.bld", _
        clng( varseg( g.wld.tex.ofs(0) ) ) * 65536& + (clng( varptr( g.wld.tex.ofs(0) ) ) and 65535&)

    for  j = 0 to 3
        g.wld.tex.cell(j) = 64 \ (2 ^ j)
        g.wld.tex.aim_raw(j) = -1
        g.wld.tex.aim_shd(j) = -1

        g.wld.tex.v_raw(j)    = uglNewView&( g.wld.tex.raw, 0, _
                                             g.wld.tex.cell(j), g.wld.tex.cell(j) )
        g.wld.tex.v_shaded(j) = uglNewView&( g.wld.tex.shaded, 0, _
                                             g.wld.tex.cell(j), g.wld.tex.cell(j) )
        if ( g.wld.tex.v_raw(j) = 0 or g.wld.tex.v_shaded(j) = 0 ) then
            sys_error "0x0017, no room for a texture view"
        end if
        scr_load_part 0.25, true
    next j

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
    dim i as integer, j as integer
    dim chain0 as integer, n as integer
    dim suffix as string

    for  i = 0 to g.wld.count.textures-1
        if ( left$( t_mip_inf(i).name, 1 ) = "+" ) then

            '' already claimed by an earlier frame's chain
            if ( mip_buff_inf(i).anim_count > 1 ) then goto next_tex

            suffix$ = mid$( rtrim$(t_mip_inf(i).name), 3 )
            chain0 = i
            n    = 0

            for  j = i to g.wld.count.textures-1
                if ( left$( t_mip_inf(j).name, 1 ) = "+" ) then
                    if ( mid$( rtrim$(t_mip_inf(j).name), 3 ) = suffix$ ) then
                        n = n + 1
                    end if
                end if
            next j

            if ( n > 1 ) then
                for  j = chain0 to chain0+n-1
                    mip_buff_inf(j).anim_base  = chain0
                    mip_buff_inf(j).anim_count = n
                next j
            end if
        end if
next_tex:
    next i

end sub


'' Cell k of mip j, as a dc. Re-aims a view rather than owning 648 of them.
function mod_tex_raw ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
    if ( g.wld.tex.aim_raw(mip) <> k ) then
        if ( uglSetView%( g.wld.tex.v_raw(mip), _
                          g.wld.tex.ofs( k*4 + mip ) ) = 0 ) then exit function
        g.wld.tex.aim_raw(mip) = k
    end if
    mod_tex_raw = g.wld.tex.v_raw(mip)
end function

function mod_tex_shaded ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
    if ( g.wld.tex.aim_shd(mip) <> k ) then
        if ( uglSetView%( g.wld.tex.v_shaded(mip), _
                          g.wld.tex.ofs( k*4 + mip ) ) = 0 ) then exit function
        g.wld.tex.aim_shd(mip) = k
    end if
    mod_tex_shaded = g.wld.tex.v_shaded(mip)
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
    dim x as integer, cx as integer, cell as integer
    dim dc as long
    dim f as integer
    dim sw as integer, sh as integer
    dim rowlen as integer
    dim imgsz as long, off_bits as long
    dim palbuf(255) as tRGB
    dim row as string, buf as string

    sw       = 20 * 64
    sh       = 64 + 32 + 16 + 8
    rowlen   = sw
    imgsz    = clng(rowlen) * clng(sh)
    off_bits = 14 + 40 + 1024

    uglPalGetBuff 0, 256, palbuf(0)

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
        if ( y < 64 ) then
            mip = 0 : ty = y
        elseif ( y < 96 ) then
            mip = 1 : ty = y - 64
        elseif ( y < 112 ) then
            mip = 2 : ty = y - 96
        else
            mip = 3 : ty = y - 112
        end if
        cell = g.wld.tex.cell(mip)

        row = string$( rowlen, 0 )
        for  k = 0 to g.wld.count.textures-1
            dc = mod_tex_raw( g, k, mip )
            if ( dc <> 0 ) then
                for  cx = 0 to cell-1
                    mid$( row, k*64 + cx + 1, 1 ) = chr$( uglPGet( dc, cx, ty ) and 255 )
                next cx
            end if
        next k
        put #f, , row
    next y

    close #f
end sub
