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
    ''
    '' hTextrDC is COMMON now, and COMMON can only declare it as hTextrDC()
    '' with no elements. It carried a real bound, so size it here.
    ''
    redim h_textr_dc( 256*4 ) as long
    if ( env.use_lm ) then
        redim h_rawtx_dc( 256*4 ) as long
    end if
    redim tx_view( 3 ) as long
    redim tx_rview( 3 ) as long

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
    dim i as integer, j as integer, cell as integer

    ''
    '' The palette is still read here because videoOpen installs it and frees
    '' it. Nothing in this routine looks at its contents any more.
    ''
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )

    draw_string ldr.dc, 0, 199-8, "Loading textures..."

    ''
    '' ONE store for every texel of every texture and mip, built by ONE
    '' uglNewBMPEx, with a view per mip size aimed into it.
    ''
    '' This used to be a DC per texture per mip -- 160 of them, each built by
    '' its own uglNewBMPEx from its own file. A DC costs conventional memory
    '' for its scanline table, and every one of those calls also allocated and
    '' freed uGL's 10K BMP scratch buffer, so the loading churn fragmented the
    '' heap even though the DCs were all freed again. tools/mkassets.py now
    '' packs the whole set into one image, each texture already at the byte
    '' offset a view will be aimed at, so none of that happens at all.
    ''
    '' uglNewBMPEx builds the DC from the file, so the image's own
    '' dimensions define the store and nothing beside the data can go
    '' stale. BMPOPT.NO332 matters: without it uGL remaps the image to
    '' its own 3-3-2 palette and the indices, already correct, would be
    '' destroyed.
    ''
    tx_store = uglNewBMPEx( UGL.EMS, UGL.8BIT, "tex.bmp", BMPOPT.NO332 )
    if ( tx_store = 0 ) then
        sys_error "0x0004, missing tex.bmp -- run tools/mkassets.py"
    end if

    def seg = varseg( h_textr_dc(0) )
    bload "texofs.bld", varptr( h_textr_dc(0) )
    def seg

    for  j = 0 to 3
        cell = 64 \ (2 ^ j)
        tx_view(j) = uglNewView&( tx_store, 0, cell, cell )
        if ( tx_view(j) = 0 ) then sys_error "0x0007, uglNewView failed"
    next j

    ''
    '' The raw-index twin, for the surface builder only. It shades through the
    '' whole colormap itself, and tex.bmp already had row 0 applied on the way
    '' in -- feeding it those would treat a brightened index as a raw one. See
    '' mkassets.py's shaded/raw note. Same layout, so the same offset table.
    ''
    if ( env.use_lm ) then
        tx_rstore = uglNewBMPEx( UGL.EMS, UGL.8BIT, "texr.bmp", BMPOPT.NO332 )
        if ( tx_rstore = 0 ) then
            sys_error "0x0005, missing texr.bmp -- run tools/mkassets.py"
        end if

        def seg = varseg( h_rawtx_dc(0) )
        bload "texofs.bld", varptr( h_rawtx_dc(0) )
        def seg

        for  j = 0 to 3
            cell = 64 \ (2 ^ j)
            tx_rview(j) = uglNewView&( tx_rstore, 0, cell, cell )
            if ( tx_rview(j) = 0 ) then sys_error "0x0007, uglNewView failed"
        next j
    end if

    scr_mip_tick 100

    for  i = 0 to wld.numtex-1
        ''
        '' Per-texture header only: the renderer scales texture axes by the
        '' reciprocal of the ORIGINAL texture size, so those dimensions are
        '' still needed even though the texels come from the store.
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
