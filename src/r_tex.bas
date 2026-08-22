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
dim shared colmap( 1 ) as integer
dim shared miplevel0( 1 ) as long
dim shared miplevel1( 1 ) as long
dim shared miplevel2( 1 ) as long
dim shared miplevel3( 1 ) as long
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
    dim tex as miptex

    seek #1, bsphead.texinfo.offs+1
    for  i = 0 to texiCount-1
        get #1 ,, texInfBuff(i)
        
        loading = loading + (100.0/14.0)/texiCount
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i
    
    seek #1, bsphead.miptex.offs+1
    get #1,, numtex
    
    redim tmipinf( numtex-1 ) as miptex
    redim mipBuffInf( numtex-1 ) as miptexb
    
    for  i = 0 to numtex-1
        get #1,, texoffs(i)
    next i    
    
    for  i = 0 to numtex-1
        seek #1, bsphead.miptex.offs+texoffs(0)+1
        get #1,, tex
    next i

    
    redim colmap(8192*2-1) as integer

end sub




''::::::::::
'' name: palLoadColormap
''::::::::::
defint a-z
sub palLoadColormap
    dim file as UAR

    if ( uarOpen( file, "base.dat::color/colormap.lmp", F4READ ) = false ) then
        ExitError "Could not open ( 1 ) base.dat::color/colormap.lmp..."
    end if

    if ( uarReadEx( file, colmap(0), 16384 ) <> 16384 ) then
        ExitError "Could not open ( 2 ) base.dat::color/colormap.lmp..."
    end if
    
    loading = loading + (100.0/14.0)
    drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1    
    
    
    uarClose file

end sub




''::::::::::
'' name: texLoadAll
'' desc: Reads every texture, builds its four mip levels and colour
''       matches each one back into the Quake palette. One loop over
''       numtex, so it is one routine.
''::::::::::
defint a-z
sub texLoadAll
    dim i as integer

    dim byte as string * 1 
    
    dim tmpdc as long
    dim ix as integer
    dim iy as integer
    dim dx as single, dy as single
    dim cx as single, cy as single
    
    redim miplevel0( numtex-1 ) as long
    redim miplevel1( numtex-1 ) as long
    redim miplevel2( numtex-1 ) as long
    redim miplevel3( numtex-1 ) as long
    
    if ( (uglNewMult( miplevel0(), numtex, ugl.ems, ugl.8bit, 64, 64 ) = false) or _
         (uglNewMult( miplevel1(), numtex, ugl.ems, ugl.8bit, 32, 32 ) = false) or _
         (uglNewMult( miplevel2(), numtex, ugl.ems, ugl.8bit, 16, 16 ) = false) or _
         (uglNewMult( miplevel3(), numtex, ugl.ems, ugl.8bit, 08, 08 ) = false) ) then
            ExitError "0x0004, Could not create textures..."
    end if
    
    tmpdc = uglNew( UGL.EMS, env.cFmt, 256, 256 )
    if ( tmpdc = false ) then
        ExitError "0x0004, Could not create texture temp..."
    end if
    
    dim palseg as integer
    dim palofs as integer
    dim cmpseg as integer
    dim cmpofs as integer
    dim dist as single
    dim dista as single    
    dim r as single
    dim g as single
    dim b as single
    dim s as single
    dim t as single
    dim j as integer, k as integer, x as integer, y as integer, mipl as integer
    dim col as integer, col1 as integer, col2 as integer, col3 as integer, col4 as integer
    dim cofs1 as integer, cofs2 as integer, cofs3 as integer, cofs4 as integer
    dim kofs as integer
    dim r2 as single, g2 as single, b2 as single
    
    
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )
    palseg = pal \ 65536&
    palofs = pal and &h0000ffff&
    
    cmpseg = varseg( colmap(0) ) 
    cmpofs = varptr( colmap(0) ) + 256*0
            
    fontPrintText loadDC, 0, 199-8, "Loading and converting textures, this might take a while..."
    
    
    for  i = 0 to numtex-1
        seek #1, bsphead.miptex.offs+texoffs(i)+1
        get #1,, tmipinf(i)
        
        
        mipBuffInf(i).hght = 1.0 / tmipinf(i).hght
        mipBuffInf(i).wdth = 1.0 / tmipinf(i).wdth        
        
        dx = tmipinf(i).wdth / 64.0
        dy = tmipinf(i).hght / 64.0

        for  j = 0 to 3
        
            mipl = 2^j            
            
            seek #1, bsphead.miptex.offs+texoffs(i)+ tmipinf(i).offset(j)+1
            
            def seg = cmpseg
            for  y = 0 to tmipinf(i).hght\mipl-1
                for  x = 0 to tmipinf(i).wdth\mipl-1
                    get #1,, byte
                    uglPset tmpdc&, x, y, peek( cmpofs+asc(byte) )
                next x
            next y
        

            select case ( j )
                case 0: hTextrDC(i*4+j) = miplevel0(i)
                case 1: hTextrDC(i*4+j) = miplevel1(i)
                case 2: hTextrDC(i*4+j) = miplevel2(i)
                case 3: hTextrDC(i*4+j) = miplevel3(i)
            end select
            
            def seg = palseg
            cy = 0.0

            for  y = 0 to ((64\(2^j))-1)
                cx = 0.0            
                
                for  x = 0 to ((64\(2^j))-1)
                    ''
                    '' Take the sample indices with int(), not by letting MOD
                    '' do the conversion. QB's MOD ROUNDS its operands to
                    '' integers while int() TRUNCATES, so with a non-integer
                    '' step the four samples came from one texel while s and t
                    '' weighted them as if they came from another -- up to half
                    '' a texel of skew. dx and dy are only non-integer when the
                    '' texture is smaller than 64 on that axis, so this hit the
                    '' 32x32 signs and the 64x16 trim and left them looking
                    '' shifted, with the wrap column repeated.
                    ''
                    ix = int( cx )
                    iy = int( cy )

                    col1 = uglPGet( tmpdc&, _
                                    (ix+0) mod (tmipinf(i).wdth\mipl), _
                                    (iy+0) mod (tmipinf(i).hght\mipl) )
                    col2 = uglPGet( tmpdc&, _
                                    (ix+0) mod (tmipinf(i).wdth\mipl), _
                                    (iy+1) mod (tmipinf(i).hght\mipl) )
                    col3 = uglPGet( tmpdc&, _
                                    (ix+1) mod (tmipinf(i).wdth\mipl), _
                                    (iy+0) mod (tmipinf(i).hght\mipl) )
                    col4 = uglPGet( tmpdc&, _
                                    (ix+1) mod (tmipinf(i).wdth\mipl), _
                                    (iy+1) mod (tmipinf(i).hght\mipl) )

                    s = cx - ix
                    t = cy - iy

                    cofs1 = palofs+col1*3
                    cofs2 = palofs+col2*3
                    cofs3 = palofs+col3*3
                    cofs4 = palofs+col4*3

                    r = peek( cofs1+0 )*(1-s)*(1-t)
                    g = peek( cofs1+1 )*(1-s)*(1-t)
                    b = peek( cofs1+2 )*(1-s)*(1-t)
                    r = r + peek( cofs2+0 )*(1-s)*t
                    g = g + peek( cofs2+1 )*(1-s)*t
                    b = b + peek( cofs2+2 )*(1-s)*t
                    r = r + peek( cofs3+0 )*(1-t)*s
                    g = g + peek( cofs3+1 )*(1-t)*s
                    b = b + peek( cofs3+2 )*(1-t)*s
                    r = r + peek( cofs4+0 )*s*t
                    g = g + peek( cofs4+1 )*s*t
                    b = b + peek( cofs4+2 )*s*t
                    
                    if ( r > 255.0 ) then r = 255.0
                    if ( g > 255.0 ) then g = 255.0
                    if ( b > 255.0 ) then b = 255.0

                    
                    dist  = 167777217
                    
                    for  k = 0 to 255
                        kofs = palofs+k*3
                        r2! = r-peek( kofs+0 )
                        g2! = g-peek( kofs+1 )
                        b2! = b-peek( kofs+2 )
                                                
                        dista = r2!*r2! + g2!*g2! +b2!*b2!
                        
                        if ( dist > dista ) then
                            col = k
                            
                            if ( dista = 0.0 ) then
                                exit for
                            end if
                            
                            dist = dista                            
                        end if
                    next k
                    
                    uglPset hTextrDC(i*4+j), x, y, col
                    cx = cx + dx
                next x
                
                cy = cy + dy
            next y
            
            if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2-15, 150, 7, (i*4+j)*25\numtex, 51
        next j
        
        loading = loading + (100.0/14.0)/numtex
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2-15, 150, 7, (i*4+j)*25\numtex, 51
    next i
    
    uglDel tmpdc&
    erase colmap
        
    
    close #1    
    
    uglRestore
    screen 0
    width 80, 25
    
    dim hFile as FILE

end sub
