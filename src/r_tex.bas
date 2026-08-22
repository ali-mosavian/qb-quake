option explicit
''
'' r_tex.bas -- reading textures, building mips and matching them back into
''              the Quake palette. One loop over numtex.
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
dim shared texoffs( 256 ) as long

'$dynamic
dim shared tmipinf( 1 ) as miptex




''::::::::::
'' name: texLoadOffsets
'' desc: Reads the miptex directory and sizes the texture tables.
''::::::::::
defint a-z
sub texLoadOffsets
    ''
    '' hTextrDC is COMMON now, and COMMON can only declare it as hTextrDC()
    '' with no elements. It carried a real bound, so size it here.
    ''
    redim hTextrDC( 256*4 ) as long

    dim i as integer

    def seg = varseg( texInfBuff(0) )
    bload "texinf.bld", varptr( texInfBuff(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    drwLoadTick
    
    seek #wld.file, wld.head.miptex.offs+1
    get #wld.file,, wld.numtex
    
    redim tmipinf( wld.numtex-1 ) as miptex
    redim mipBuffInf( wld.numtex-1 ) as miptexb
    
    for  i = 0 to wld.numtex-1
        get #wld.file,, texoffs(i)
    next i    
    

end sub








''::::::::::
'' name: texLoadAll
'' desc: Reads every texture, builds its four mip levels and colour
''       matches each one back into the Quake palette. One loop over
''       numtex, so it is one routine.
''::::::::::
defint a-z
sub texLoadAll
    dim i as integer, j as integer
    dim bmpfile as string
    dim dc as long

    ''
    '' The palette is still read here because videoOpen installs it and frees
    '' it. Nothing in this routine looks at its contents any more.
    ''
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )

    fontPrintText ldr.dc, 0, 199-8, "Loading textures..."

    for  i = 0 to wld.numtex-1
        ''
        '' Per-texture header only: the renderer scales texture axes by the
        '' reciprocal of the ORIGINAL texture size, so those dimensions are
        '' still needed even though the pixels come from the bmps.
        ''
        seek #wld.file, wld.head.miptex.offs+texoffs(i)+1
        get #wld.file,, tmipinf(i)

        mipBuffInf(i).hght = 1.0 / tmipinf(i).hght
        mipBuffInf(i).wdth = 1.0 / tmipinf(i).wdth

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
                ExitError "0x0004, missing " + bmpfile + " -- run tools/mkassets.py"
            end if

            hTextrDC(i*4+j) = dc

            if ( (i and 15) = 0 ) then drwMipTick (j+1)*25
        next j

        ldr.pct = ldr.pct + (100.0/LOAD_STEPS)/wld.numtex
        if ( (i and 15) = 0 ) then drwLoadTick
    next i

    uglRestore
    screen 0
    width 80, 25

end sub
