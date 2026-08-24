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
'$include: 'q_draw.bi'
'$include: 'q_snd.bi'

'$static
dim shared texoffs( 256 ) as long

'$dynamic
dim shared tmipinf( 1 ) as miptex




''::::::::::
'' name: mod_load_texinfo
'' desc: Reads the miptex directory and sizes the texture tables.
''::::::::::
sub mod_load_texinfo
    scr_load_stage "texture info"
    ''
    '' hTextrDC is COMMON now, and COMMON can only declare it as hTextrDC()
    '' with no elements. It carried a real bound, so size it here.
    ''
    redim h_textr_dc( 256*4 ) as long
    if ( env.use_lm ) then
        redim h_rawtx_dc( 256*4 ) as long
    end if

    dim i as integer

    def seg = varseg( tex_inf_buff(0) )
    bload "texinf.bld", varptr( tex_inf_buff(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
    
    seek #wld.file, wld.head.miptex.offs+1
    get #wld.file,, wld.numtex
    
    redim tmipinf( wld.numtex-1 ) as miptex
    redim mip_buff_inf( wld.numtex-1 ) as miptexb
    
    for  i = 0 to wld.numtex-1
        get #wld.file,, texoffs(i)
    next i    
    

end sub








''::::::::::
'' name: mod_load_textures
'' desc: Reads every texture, builds its four mip levels and colour
''       matches each one back into the Quake palette. One loop over
''       numtex, so it is one routine.
''::::::::::
sub mod_load_textures
    dim i as integer, j as integer
    dim bmpfile as string
    dim dc as long

    ''
    '' The palette is still read here because videoOpen installs it and frees
    '' it. Nothing in this routine looks at its contents any more.
    ''
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )

    scr_load_stage "textures"

    for  i = 0 to wld.numtex-1
        ''
        '' Per-texture header only: the renderer scales texture axes by the
        '' reciprocal of the ORIGINAL texture size, so those dimensions are
        '' still needed even though the pixels come from the bmps.
        ''
        seek #wld.file, wld.head.miptex.offs+texoffs(i)+1
        get #wld.file,, tmipinf(i)

        mip_buff_inf(i).hght = 1.0 / tmipinf(i).hght
        mip_buff_inf(i).wdth = 1.0 / tmipinf(i).wdth

        ''
        '' Quake encodes what a texture does in its name. A leading * is a
        '' liquid, which flows; a leading +N is one frame of an animation,
        '' the rest of whose frames share the name after the digit.
        ''
        mip_buff_inf(i).liquid     = false
        mip_buff_inf(i).anim_base  = i
        mip_buff_inf(i).anim_count = 1

        if ( left$( tmipinf(i).name, 1 ) = "*" ) then
            mip_buff_inf(i).liquid = true
        end if

        ''
        '' One DC per texture per mip, built straight from a preprocessed bmp
        '' by uGL's own loader.
        ''
        '' This replaced a per-texel loop that read the miptex data a byte at
        '' a time, expanded each index to RGB, filtered, and then searched all
        '' 256 palette entries to get back to an index -- for dm3ish, 150,960
        '' single-byte reads, 108,800 output texels and 27,852,800 palette
        '' searches, every launch, recomputing something that depends only on
        '' the map and the palette. tools/mkassets.py does it in ~1.5s.
        ''
        '' BMPOPT.NO332 matters: without it uGL remaps the image to its own
        '' 3-3-2 palette and the indices, already correct, would be destroyed.
        ''
        for  j = 0 to 3
            bmpfile = "t" + right$( "00" + ltrim$(str$( i )), 3 ) + _
                      "m" + ltrim$(str$( j )) + ".bmp"

            dc = uglNewBMPEx( UGL.EMS, UGL.8BIT, bmpfile, BMPOPT.NO332 )
            if ( dc = false ) then
                sys_error "0x0004, missing " + bmpfile + " -- run tools/mkassets.py"
            end if

            h_textr_dc(i*4+j) = dc

            ''
            '' The raw-index twin, for the surface builder only. It shades
            '' through the whole colormap itself, and t* already had row 0
            '' applied on the way in -- feeding it those would treat a
            '' brightened index as a raw one. See mkassets.py's r*/t* note.
            ''
            if ( env.use_lm ) then
                bmpfile = "r" + right$( "00" + ltrim$(str$( i )), 3 ) + _
                          "m" + ltrim$(str$( j )) + ".bmp"
                dc = uglNewBMPEx( UGL.EMS, UGL.8BIT, bmpfile, BMPOPT.NO332 )
                if ( dc = false ) then
                    sys_error "0x0005, missing " + bmpfile + " -- run tools/mkassets.py"
                end if
                h_rawtx_dc(i*4+j) = dc
            end if

            if ( (i and 15) = 0 ) then scr_mip_tick (j+1)*25
        next j

        ldr.pct = ldr.pct + (100.0/LOAD_STEPS)/wld.numtex
        if ( (i and 15) = 0 ) then scr_load_tick
    next i

    mod_link_anims


    uglRestore
    screen 0
    width 80, 25

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
sub mod_link_anims
    dim i as integer, j as integer
    dim chain0 as integer, n as integer
    dim suffix as string

    for  i = 0 to wld.numtex-1
        if ( left$( tmipinf(i).name, 1 ) = "+" ) then

            '' already claimed by an earlier frame's chain
            if ( mip_buff_inf(i).anim_count > 1 ) then goto next_tex

            suffix$ = mid$( rtrim$(tmipinf(i).name), 3 )
            chain0 = i
            n    = 0

            for  j = i to wld.numtex-1
                if ( left$( tmipinf(j).name, 1 ) = "+" ) then
                    if ( mid$( rtrim$(tmipinf(j).name), 3 ) = suffix$ ) then
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
