''
'' main -- a Quake 1 BSP walker and renderer for uGL.
''
'' Reads a .bsp, walks the tree back to front with PVS and frustum culling,
'' and rasterises it perspective correct, affine or wireframe with mipmaps.
'' Real mode DOS, QuickBASIC.
''
'' ---------------------------------------------------------------------------
'' How this file is organised, and why
'' ---------------------------------------------------------------------------
''
'' There is no optimiser here. A SUB call costs a stack frame and a descriptor
'' per argument, and nothing inlines it back out. So routines are split on ONE
'' criterion: how often they are entered.
''
''   once at startup   split as far as it stays readable. doInit is a list of
''                     28 named steps; each does one thing and the calls are
''                     free. Same for parseIni's per-key validation.
''
''   once per frame    still free. camUpdate, inputToggles, bspDrawFaces,
''                     drawHud, presentFrame.
''
''   per node, face,   NOT split. bspDrawFaces is one 250 line routine on
''   vertex, triangle  purpose, and bspWalkNodeB is STATIC to skip its frame
''                     setup. Repetition inside them is deliberate; the way to
''                     remove it is to hoist the work into the setup above it,
''                     never to wrap it in a call.
''
'' Memory follows the same split. Level data is '$DYNAMIC -- sized at load,
'' far too large for DGROUP. Renderer scratch is '$STATIC, because QuickBASIC
'' reaches a dynamic array through a descriptor and these are indexed per
'' vertex and per triangle.
''
'' Copyleft Blitz, july/2003.
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
'$include: 'quakedef.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'


declare sub getSBSettings  ( port as integer, irq as integer, _
                             ldma as integer, hdma as integer )

dim shared mymod as UGMMOD


dim shared hTextrDC( 256*4 ) as long
'' Startup-only state. These were locals of the 700 line doInit; splitting it
'' into one routine per step is what promoted them, and they stay out of the
'' frame path entirely.
dim shared loadmod as UGMMOD
'' texiCount was the one lump count never declared shared. Inside the old
'' monolithic doInit that did not matter; once bspOpen and bspAlloc were
'' separate routines, bspAlloc read 0 and did redim texInfBuff(-1).
dim shared camUp as u3dVector3f    
dim shared camLookAt as u3dVector3f
dim shared hFontChar(255) as long

'$dynamic
dim shared mipBuffInf( 1 ) as miptexb
dim shared colmap( 1 ) as integer
dim shared tmipinf( 1 ) as miptex
dim shared texoffs( 256 ) as long
dim shared miplevel0( 1 ) as long
dim shared miplevel1( 1 ) as long
dim shared miplevel2( 1 ) as long
dim shared miplevel3( 1 ) as long
dim shared lightmap as long

''
'' polyFlag holds the frame a face was last marked visible in, not a flag:
'' see bspShowModel. pvsLeaf is the leaf the visible set was last unpacked
'' for -- leaf ids carry bit 15, so 0 doubles as "nothing cached yet".
''

''
'' Renderer scratch and app state, shared rather than passed.
''
'' The split between what is a SUB here and what is written inline follows
'' one rule: a SUB call in QuickBASIC costs a stack frame and a descriptor
'' per argument, and nothing inlines it back out, so a routine may only be
'' extracted if it is entered at most once per frame. camUpdate,
'' inputToggles, bspDrawFaces and drawHud all qualify. Everything reached
'' per face, per vertex or per triangle stays written out where it runs --
'' the repetition there is deliberate, and the way to remove it is to hoist
'' the work into the per-face or per-polygon setup above it, never to wrap
'' it in a call.
''
'' These buffers were locals of doMain; they are shared so bspDrawFaces can
'' reach them without passing ten array descriptors every frame. One frame
'' is in flight at a time, so there is nothing to make re-entrant.
''





'$static

'' These are declared AFTER '$static on purpose. In the '$dynamic region
'' above, QuickBASIC gives an array a descriptor and reaches its elements
'' indirectly; the per-vertex and per-triangle loops below index these on
'' every element, so they want the fixed, directly addressed form. The map
'' data above stays dynamic because it is sized at load time and is far too
'' large to live in DGROUP.

dim shared vtx(31) as tritype
dim shared poly(64) as u3dVector4f
dim shared polyb(32) as u3dVector4f
dim shared uvbuff(64) as uv
dim shared uvbuffb(32) as uv
dim shared prjW(32) as single
dim shared prjX(32) as single
dim shared prjY(32) as single
dim shared prjU(32) as single
dim shared prjV(32) as single
dim shared su0 as single, su1 as single, su2 as single, su3 as single
dim shared sv0 as single, sv1 as single, sv2 as single, sv3 as single
dim shared vx as single, vy as single, vz as single
dim shared tw as single, th as single
dim shared vcnt as integer, mipidx as integer

'' Toggles and per-frame counters, formerly locals of doMain.
dim shared usemips as integer
dim shared rendmode as integer
dim shared backface as integer
dim shared stats as integer
dim shared fpsview as integer
dim shared polys as integer
dim shared tris as integer
dim shared fps as integer
'' fps1 counts frames within the current second. It used to live in
'' doMain's frame loop, where one invocation kept it across frames;
'' presentFrame is entered per frame, so as a local it reset to 0 every
'' time and the counter read 1 forever.
dim shared fps1 as integer
'' screenie was undeclared, so it was a fresh integer 0 on every entry to
'' presentFrame and every screenshot overwrote scrn0.bmp.
dim shared screenie as integer

'' pal is loaded by texLoadAll (which needs its segment and offset to
'' colour match) and consumed by videoOpen, which sets it as the hardware
'' palette and frees it. Those were one scope inside the old monolithic
'' doInit; splitting doInit apart left videoOpen reading an undeclared 0.
dim shared pal as long

    ''
    '' Grr, qb suxs
    '' 
    on errror goto HandleErr
    
        
    '':::::
    
    doInit 
    doMain   
    doEnd
    
    
HandleErr:    
    ExitError "0x1000, Unknown runtime error..."


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



''::::
defint a-z
'' ==========================================================================
''  STARTUP
'' ==========================================================================
''::::::::::
'' name: doInit
'' desc: Startup, in order. Every step below runs exactly once, so each is
''       its own routine -- the call costs nothing here and the sequence
''       reads as the list of things that have to be true before the first
''       frame. Contrast bspDrawFaces, which is one routine on purpose.
''::::::::::
defint a-z
sub doInit

    '' arguments and subsystems
    checkCommandLine
    initTables
    initUgl
    soundOpen
    musicStart
    fontOpen

    '' map file and the loading screen
    bspOpen
    loadScreenOpen
    bspFindSpawn
    bspAlloc

    '' level lumps
    bspLoadVertices
    bspLoadFaces
    bspLoadEdges
    bspLoadEdgeIndex
    bspLoadLeaves
    bspLoadFaceIndex
    bspLoadNodes
    bspLoadPlanes
    bspLoadModels
    bspLoadPvs

    '' textures and palette
    texLoadOffsets
    palLoadColormap
    texLoadAll

    '' hand over to the real video mode
    videoOpen
    inputOpen
    musicStopLoading

end sub





''::::
defint a-z
sub doMain
    dim a as single
    dim b as single
    static zm as single    
    dim mtxMdl as u3dMtrx
    dim mtxPrj as u3dMtrx
    dim mtxFin as u3dMtrx
    dim mtxScl as u3dMtrx
    
    dim ppos(env.caminterp) as PNT3D
    dim plok(env.caminterp) as PNT3D
    dim cbzp(10) as PNT3D
    dim cbzl(10) as PNT3D
    
    dim hDstDC as long
    dim pa as integer
    dim crrPnt as integer
    dim cntPnts as integer
    dim xres as single, yres as single
    dim xresh as single, yresh as single
    
    dim viewvec as vertex
    dim polyc(3) as u3dVector4f
    dim vtxb as quadtype    
    
    ''
    '' min/max/bmin/bmax/extn went with the lightmap extent computation in
    '' the draw loop, which produced values nothing read.
    ''
    dim polyvert as integer
    ''
    '' Per-face texture axes with the texture size folded in, and the
    '' per-vertex projection the triangle fan shares. See the draw loop.
    ''
    dim camPosB as u3dVector3f
    
    
    xres  = env.xRes
    yres  = env.yRes
    xresh = env.xRes/2.0
    yresh = env.yRes/2.0

    mousePos 0, 0


    camUp.x = 0.0
    camUp.y = 1.0
    camUp.z = 0.0   
    
    mousePos (env.xres-1) * startAngle/360.0, 110
    
    

    
    if ( env.cammode = 1 ) then
        open env.camscrpt for input as #1    
        do 
            input #1, cbzp(i).x, cbzp(i).y, cbzp(i).z
            input #1, cbzl(i).x, cbzl(i).y, cbzl(i).z
            i = i + 1
        loop until ( eof( 1 ) )    
        close #1    
        cntPnts = i-1
                
        ugluCubicBez3D ppos(0), cbzp(crrPnt), env.caminterp
        ugluCubicBez3D plok(0), cbzl(crrPnt), env.caminterp
        crrPnt = crrPnt + 3
    end if        
    
    if ( env.cammode = 2 ) then
        open env.camscrpt for output as #1
    end if
    
    
    
    hz& = tmrMs2Freq&( 1000 )
    tmrNew env.secTimer, TMR.AUTOINIT, hz&    
    
    if ( env.usepag = false ) then
        hDstDC = env.hBackBDC
    else        
        hDstDC = env.hVideoDC
    end if        
    
    u3dMtrxScale mtxScl, 1.0, 1.0, 1.0
    u3dMtrxPersp mtxPrj, env.camfov, 320.0/240.0, env.zNear, env.zFar
    
    usemips = -1
    rendmode = 0
    fpsview = -1
    
    if ( env.sound = true ) then
        modPlay mymod
    end if
    
    
    ''
    ''
    ''
    do  
    	''
    	'' Clear DC
    	''      
        if ( env.disclear = true ) then
            uglClear hDstDC, 0
        end if 
        
        camUpdate pa, crrPnt, cntPnts, ppos(), plok(), cbzp(), cbzl(), last_point

        inputToggles

        ''
        '' Combine all transforms 
        ''
        u3dMtrxLookAt mtxMdl, camPos, camLookAt, camUp        
        u3dMtrxConc mtxFin, mtxMdl, mtxPrj
        ExtractFrustum frustum(), mtxFin
        

        ''
        '' Birdseye stuff
        ''
        '' Deliberate, and it looks like a bug: the frustum above was taken
        '' from the PLAYER camera, and the view matrix is now rebuilt from a
        '' fixed overhead one. Flying above the level while the culling still
        '' answers to the player's view is the point of the mode -- you get to
        '' watch what the PVS and the frustum actually throw away. Do not
        '' "fix" it by moving ExtractFrustum below this block.
        ''
        if ( fpsview = false ) then 
            camPosB.x = 351.0
            camPosB.y = 2119.0
            camPosB.z = -552.0            
                        
            camLookAt.x = camPosB.x + 1.991367e-8
            camLookAt.y = camPosB.y + -1.0
            camLookAt.z = camPosB.z + 1.570986e-2
        else
            camPosB.x = camPos.x
            camPosB.y = camPos.y
            camPosB.z = camPos.z
        end if
        
        '        
        u3dMtrxLookAt mtxMdl, camPosB, camLookAt, camUp        
        u3dMtrxConc mtxFin, mtxMdl, mtxPrj
        
        
        ''
        '' Walk BSP tree
        ''
        bspShowModel 0
        
        
        bspDrawFaces hDstDC, mtxFin, xresh, yresh


        
        drawHud hDstDC
            
        
        presentFrame hDstDC, page
        
        
    loop while ( env.keyboard.esc = FALSE )
    
    tmrDel env.secTimer
    close #1

end sub


''::::
defint a-z
sub doEnd
    
    ''
    '' Restore video mode and end UGL
    ''
    uglRestore
    uglEnd
    
    screen 0
    width 80, 25
    end

end sub


''::::
defint a-z
sub ExitError ( msg as string )
    ''
    '' Record the message before touching the video mode.
    ''
    '' Everything below draws to the screen, and if uglRestore leaves a
    '' graphics mode the message is rendered as pixels: not in the text
    '' buffer, not on redirected stdout, and gone the moment the program
    '' ends. A failed run then looks exactly like a slow one from outside.
    ''
    dim errf as integer
    errf = freefile
    open "error.log" for output as #errf
    print #errf, msg
    close #errf

    ''
    '' Restore video mode and end UGL
    ''
    uglRestore
    uglEnd
    
    ''
    '' Print msg and quit program
    ''
    screen 0
    width 80, 25
    print "Error: " + msg
    sleep
    end
end sub



'':::::::
defint a-z
sub SHClipzNearFar ( otVtx() as u3dVector4f, otUV() as uv, otCnt as integer, _
                     inVtx() as u3dVector4f, inUV() as uv, inCnt as integer )

    dim n as integer
    dim scl as single
    dim dsti as integer, tmCnt as integer
    dim src1 as integer, src2 as integer

    for  n = 0 to inCnt-1
        src1 = n
        src2 = (n + 1) mod inCnt
        
        if ( inVtx(src1).w >= env.zNear ) then
            otVtx(dsti).x = inVtx(src1).x
            otVtx(dsti).y = inVtx(src1).y
            otVtx(dsti).z = inVtx(src1).z
            otVtx(dsti).w = inVtx(src1).w
            otUV(dsti).u = inUV(src1).u
            otUV(dsti).v = inUV(src1).v
            
            dsti = dsti + 1 
            
            if ( inVtx(src2).w >= env.zNear ) then
                goto continuenfa
            end if
        else
            if ( inVtx(src2).w < env.zNear ) then
                goto continuenfa
            end if
        end if

        scl = ((env.zNear - inVtx(src1).w) / (inVtx(src2).w - inVtx(src1).w))
     
        otVtx(dsti).x = inVtx(src1).x + (inVtx(src2).x-inVtx(src1).x)*scl
        otVtx(dsti).y = inVtx(src1).y + (inVtx(src2).y-inVtx(src1).y)*scl
        otVtx(dsti).z = inVtx(src1).z
        otVtx(dsti).w = env.zNear        
        otUV(dsti).u = inUV(src1).u + (inUV(src2).u-inUV(src1).u)*scl
        otUV(dsti).v = inUV(src1).v + (inUV(src2).v-inUV(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfa:        
    next n
    
    otCnt = dsti
    if ( otCnt < 3 ) then exit sub
    dsti = 0
    
    for  n = 0 to otCnt-1
        src1 = n
        src2 = (n + 1) mod otCnt
        
        if ( otVtx(src1).w <= env.zFar ) then
            inVtx(dsti).x = otVtx(src1).x
            inVtx(dsti).y = otVtx(src1).y
            inVtx(dsti).z = otVtx(src1).z
            inVtx(dsti).w = otVtx(src1).w
            inUV(dsti).u = otUV(src1).u
            inUV(dsti).v = otUV(src1).v
            
            dsti = dsti + 1 
            
            if ( otVtx(src2).w <= env.zFar ) then
                goto continuenfb
            end if
        else
            if ( otVtx(src2).w > env.zFar ) then
                goto continuenfb
            end if
        end if

        scl = ((env.zFar - otVtx(src1).w) / (otVtx(src2).w - otVtx(src1).w))
     
        inVtx(dsti).x = otVtx(src1).x + (otVtx(src2).x-otVtx(src1).x)*scl
        inVtx(dsti).y = otVtx(src1).y + (otVtx(src2).y-otVtx(src1).y)*scl
        inVtx(dsti).z = otVtx(src1).z
        inVtx(dsti).w = env.zFar        
        inUV(dsti).u = otUV(src1).u + (otUV(src2).u-otUV(src1).u)*scl
        inUV(dsti).v = otUV(src1).v + (otUV(src2).v-otUV(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfb:
    next n
    
    otCnt = dsti    
    
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
    
    posx = x
    
    for  i = 0 to len( text )-1
    
        char = asc( mid$( text, i+1 ) )
        
        if ( (char >= 0) or (char <= 255) ) then
            uglPutMsk dc, posx, y, hFontChar(char)        
        end if
    
        posx = posx + 4
    next i
    
end sub


'':::::::::
defint a-z
function NodesToLeaf% ( p as u3dVector3f, nodenr as integer )

    count = 0

    '' Find the node that the camera is in
    ''
    while not ( nodenr and &h8000 )
        dp! = p.x*plnBuffer(ndsBuffer(nodenr).planeid).norm.x + _
              p.y*plnBuffer(ndsBuffer(nodenr).planeid).norm.z + _
              p.z*plnBuffer(ndsBuffer(nodenr).planeid).norm.y - _
              plnBuffer(ndsBuffer(nodenr).planeid).dist             
    
        if ( dp! > 0.0 ) then
            nodenr = ndsBuffer(nodenr).child0
        else
            nodenr = ndsBuffer(nodenr).child1
        end if
        
        count = count + 1        
    wend
    
    NodesToLeaf% = count
    
end function


'' :::::::::::
'' name: getSBSettings
'' desc: Parse the BLASTER enviroment variable
''
'' :::::::::::
defint a-z
sub getSBSettings  ( port as integer, irq as integer, ldma as integer, _    
                     hdma as integer )
    
    dim tmpstr as string
    dim sbvstr as string
    dim strpos as integer
    dim currChar as string
                         
    port = false
    irq  = false
    ldma = false
    hdma = false
    strpos = 1
    
    ''
    '' Get BLASTER variable
    ''
    sbvstr = environ$( "BLASTER" )
    if ( sbvstr = "" ) then exit sub
    
    
    ''
    '' Parse it
    ''
    while ( strpos <= len( sbvstr ) )
    
        currChar = mid$( sbvstr, strpos, 1 )              
        
        select case ( currChar )            
            case "A", "a"
                tmpstr = "&h" + mid$( sbvstr, strpos+1, 3 )
                port = val( tmpstr )
                strpos = strpos + 4
                
            case "I", "i"
                tmpstr = mid$( sbvstr, strpos+1, 2 )
                irq = val( tmpstr )
                strpos = strpos + 2
                
            case "D", "d"
                tmpstr = mid$( sbvstr, strpos+1, 1 )
                ldma = val( tmpstr )
                strpos = strpos + 2
                
            case "H", "h"
                tmpstr = mid$( sbvstr, strpos+1, 1 )
                hdma = val( tmpstr )
                strpos = strpos + 2                
            
            case else
                strpos = strpos + 1
        end select        
    wend   
    
end sub


'' ==========================================================================
''  FRAME
'' ==========================================================================
''::::::::::
'' name: camUpdate
'' desc: Advances the camera for one frame -- scripted bezier playback
''       in mode 1, mouse freelook in modes 0 and 2.
''
'' Once per frame, so the call is free. See the note by the shared
'' renderer state for why the draw loop is not carved up the same way.
''::::::::::
defint a-z
sub camUpdate ( pa as integer, crrPnt as integer, cntPnts as integer, _
                ppos() as PNT3D, plok() as PNT3D, _
                cbzp() as PNT3D, cbzl() as PNT3D, last_point as integer )
    dim camPosC as u3dVector3f

	''
	'' mode script_play run through the bezier curves
	''                
    if ( env.cammode = 1 ) then
        pa = pa + 1
        if ( crrPnt+3 <= cntPnts and last_point=false ) then
            if ( pa > env.caminterp ) then
                
                        
                ugluCubicBez3D ppos(0), cbzp(crrPnt), env.caminterp
                ugluCubicBez3D plok(0), cbzl(crrPnt), env.caminterp
                
                pa = 0
                crrPnt = crrPnt+3
            end if                
        else
            if ( crrPnt <> cntPnts and (not last_point) ) then
                pa = 0
                last_point = true
                ugluCubicBez3D ppos(0), cbzp(cntPnts-4), env.caminterp
                ugluCubicBez3D plok(0), cbzl(cntPnts-4), env.caminterp
                
            elseif ( pa > env.caminterp ) then
                crrPnt = 0
                last_point = false
                env.keyboard.esc = true
            end if                    
        end if                
        
        camPos.x = ppos(pa).x
        camPos.y = ppos(pa).y
        camPos.z = ppos(pa).z        
        camLookAt.x = camPos.x+plok(pa).x
        camLookAt.y = camPos.y+plok(pa).y
        camLookAt.z = camPos.z+plok(pa).z
    end if
    
    
    ''
    '' Mode: freelook or script_edit
    ''
    if ( env.cammode = 0 or env.cammode = 2 ) then            
        if env.mouse.x < 1 then  mousepos env.xres-4, env.mouse.y
        if env.mouse.x > env.xres-3 then  mousepos 1, env.mouse.y
        
        if env.mouse.y < 0        then  mousepos env.mouse.x, 0
        if env.mouse.y > env.yres then  mousepos env.mouse.x, env.yres-1
        
        tmx = env.mouse.x + 1
        tmy = env.mouse.y + 2

        theta! = 2 * 3.14159 * ((env.xRes-1)-tmx) / env.xRes
        phi! = 3.14159 * tmy / env.yRes
        
        camLookAt.x = cos( theta! ) * sin( phi! )
        camLookAt.y = cos( phi! )
        camLookAt.z = sin( theta! ) * sin( phi! )
        

        if ( env.mouse.left  ) then 
            camPosC.x = camPos.x + CamLookAt.x*3
            camPosC.y = camPos.y + CamLookAt.y*3
            camPosC.z = camPos.z + CamLookAt.z*3

    		camPos.x = camPosC.x
    		camPos.y = camPosC.y
    		camPos.z = camPosC.z
        end if
                    
        if ( env.mouse.right ) then
            camPosC.x = camPos.x - CamLookAt.x*3
            camPosC.y = camPos.y - CamLookAt.y*3
            camPosC.z = camPos.z - CamLookAt.z*3                
            
    		camPos.x = camPosC.x
    		camPos.y = camPosC.y
    		camPos.z = camPosC.z
        end if            
        
        if ( env.keyboard.n and env.cammode = 2 ) then
            print #1, camPos.x, camPos.y, camPos.z
            print #1, camLookAt.x, camLookAt.y, camLookAt.z
            
            while ( env.keyboard.n )
            wend
        end if
        
        camLookAt.x = camLookAt.x + camPos.x 
        camLookAt.y = camLookAt.y + camPos.y 
        camLookAt.z = camLookAt.z + camPos.z
    end if
end sub


''::::::::::
'' name: inputToggles
'' desc: The function-key toggles. Each waits for the key to come back
''       up so one press is one toggle.
''::::::::::
defint a-z
sub inputToggles

	''
	'' Toggle mipmaps
	''
    if ( env.keyboard.f1 ) then
        usemips = not usemips
        do 
        loop while ( env.keyboard.f1 )
    end if            

	''
	'' Toggle perspective/affine/wireframe
	''        
    if ( env.keyboard.f2 ) then
        rendmode = (rendmode + 1) mod 3
        do 
        loop while ( env.keyboard.f2 )
    end if                    

	''
	'' Toggle cam/birdseye
	''        
    if ( env.keyboard.f3 ) then
        fpsview = not fpsview
        do 
        loop while ( env.keyboard.f3 )
    end if            
    
	''
	'' Toggle stats
	''        
    if ( env.keyboard.f12 ) then
        stats = not stats
        do 
        loop while ( env.keyboard.f12 )
    end if                    
    
	''
	'' Toggle backface culling
	''        
    if ( env.keyboard.b ) then
        backface = not backface
        do 
        loop while ( env.keyboard.b )
    end if
    
end sub


''::::::::::
'' name: bspDrawFaces
'' desc: Draws the faces the BSP walk marked, in the walk's back to
''       front order.
''
'' One call per frame. Everything inside it runs per node, per face,
'' per vertex or per triangle and is therefore written out in place.
''::::::::::
'' ==========================================================================
''  RASTER
'' ==========================================================================
defint a-z
sub bspDrawFaces ( hDstDC as long, mtxFin as u3dMtrx, _
                   xresh as single, yresh as single )
    dim dp as single
    dim polycnt as integer

   ''
   '' Draw nodes
   ''       
    for mi = 0 to ordCount-1
        m = orderList(mi)
            
        leafIndx = ndsBuffer(m).lfaceid
        leafEnd = leafIndx + ndsBuffer(m).lfacenum-1
        
        for  ti = leafIndx to leafEnd            
            i = ti
                   
            if ( polyFlag(i) = frameStamp ) then
                
                ''
                '' Backface cull.
                ''
                '' Signed distance from the camera to the face's plane,
                '' with the face's side folded into the sign: side 0 is a
                '' face pointing along the plane normal, side 1 one
                '' pointing against it, and a face is only ever visible
                '' from its own front. One sign test then decides it.
                ''
                '' Three separate faults used to make this inert. It read
                '' triBuffer(nodenr), and nodenr does not exist in this
                '' scope -- under defint a-z QuickBASIC created it as an
                '' integer 0, so every face in the map was tested against
                '' face 0's plane. It added the plane distance where the
                '' rest of the file (bspClasifypoint, bspWalkNodeB)
                '' subtracts it. And all three branches assigned
                '' drawply = 1, so nothing was ever rejected and the HUD's
                '' "backface culling: enabled" was reporting a switch that
                '' did nothing.
                ''
                pid = triBuffer(i).planeid
                dp  = camPos.x*plnBuffer(pid).norm.x + _
                      camPos.y*plnBuffer(pid).norm.z + _
                      camPos.z*plnBuffer(pid).norm.y - _
                      plnBuffer(pid).dist
                      
                if ( triBuffer(i).side ) then dp = -dp
                
                if ( backface = 0 or dp > 0.01 ) then
                	
        		''
        		'' Build polygon
        		''
                    lid = triBuffer(i).ledgeid
                    tex = triBuffer(i).texinfoid
                    mipidx = texInfBuff(tex).miptex
                    vcnt = triBuffer(i).ledgenum
                    
                    ''
                    '' Texture axes, scaled by the texture size once per
                    '' face rather than per vertex.
                    ''
                    '' Each of these was an array index plus a UDT member
                    '' fetch inside the vertex loop, and the size was a
                    '' further two fetches and two multiplies per vertex.
                    '' Folding the size into the axes is exact -- it is
                    '' the same product in a different order -- and
                    '' nothing downstream wants the unscaled value.
                    ''
                    tw = mipBuffInf(mipidx).wdth
                    th = mipBuffInf(mipidx).hght
                    su0 = texInfBuff(tex).vecs(0) * tw
                    su1 = texInfBuff(tex).vecs(1) * tw
                    su2 = texInfBuff(tex).vecs(2) * tw
                    su3 = texInfBuff(tex).vecs(3) * tw
                    sv0 = texInfBuff(tex).vect(0) * th
                    sv1 = texInfBuff(tex).vect(1) * th
                    sv2 = texInfBuff(tex).vect(2) * th
                    sv3 = texInfBuff(tex).vect(3) * th
                    
                    for  j = 0 to vcnt-1
                        EdgeIdx = ledgBuffer(lid+j)
                        
                        if ( EdgeIdx >= 0 ) then
                            v0 = edgBuffer(EdgeIdx).v0
                        else                        
                            v0 = edgBuffer(-EdgeIdx).v1
                        end if

                        ''
                        '' One fetch per component. The vertex was read
                        '' nine times before: three for the position and
                        '' three for each texture axis.
                        ''
                        vx = vtxBuffer(v0).x
                        vy = vtxBuffer(v0).y
                        vz = vtxBuffer(v0).z

                        polyb(j).x = vx
                        polyb(j).y = vz
                        polyb(j).z = vy
                        polyb(j).w = 1.0
                        
                        uvbuffb(j).u = su0*vx + su1*vy + su2*vz + su3
                        uvbuffb(j).v = sv0*vx + sv1*vy + sv2*vz + sv3
                    next j
                    
                    ''
                    '' The lightmap extent that used to be computed here
                    '' -- the min/max of u and v over the face, the 16
                    '' unit block round-down, smax, tmax, size and the
                    '' lightmap offset -- was never read by anything. It
                    '' cost four compares per vertex and a divide per
                    '' axis per face to produce values that were
                    '' overwritten on the next face. Removed; the lump is
                    '' still loaded, so it can come back with a consumer.
                    ''

                    
                    ''
                    '' Transform and clip to near and far
                    ''
                    u3dMtrxByVec4 polyb(0), len( polyb(0) ), mtxFin, _
                                  polyb(0), len( polyb(0) ), vcnt
                    SHClipzNearFar poly(), uvbuff(), polycnt, polyb(), uvbuffb(), vcnt

        			''
        			'' If more then 2 vertices, rasterize
        			''
                    if polycnt > 2 then
                    	
                    ''
                    '' Project every vertex of the polygon once, then let
                    '' the fan reference the results.
                    ''
                    '' The fan divided and projected all three corners of
                    '' every triangle it emitted. Vertex 0 is in every
                    '' triangle of a fan and was re-divided for each one,
                    '' and each interior vertex appears in two triangles
                    '' and was divided twice: a 7-gon paid 15 reciprocals
                    '' where 7 do. On a 486 without a fast divide that is
                    '' the most expensive line in the loop.
                    ''
                    ''
                    '' Project every vertex of the polygon once, then let
                    '' the fan reference the results.
                    ''
                    '' The fan divided and projected all three corners of
                    '' every triangle it emitted. Vertex 0 is in every
                    '' triangle of a fan and was re-divided for each one,
                    '' and each interior vertex appears in two triangles
                    '' and was divided twice: a 7-gon paid 15 reciprocals
                    '' where 7 do. On a 486 without a fast divide that is
                    '' the most expensive line in the loop.
                    ''
                    for  j = 0 to polycnt-1
                        prjW(j) = 1.0 / polyb(j).w
                        prjX(j) = xresh + polyb(j).x*prjW(j)*xresh
                        prjY(j) = yresh - polyb(j).y*prjW(j)*yresh
                    next j

                    ''
                    '' The same argument for the texture coordinates: the
                    '' perspective divide belongs to the vertex, not to
                    '' each triangle that happens to share it. Choosing
                    '' the mode out here also leaves ONE copy of the
                    '' vertex assignment below instead of the three
                    '' near-identical copies the mode branches used to
                    '' carry.
                    ''
                    if ( rendmode = 0 ) then
                        for  j = 0 to polycnt-1
                            prjU(j) = uvbuffb(j).u * prjW(j)
                            prjV(j) = uvbuffb(j).v * prjW(j)
                        next j
                    elseif ( rendmode = 1 ) then
                        for  j = 0 to polycnt-1
                            prjU(j) = uvbuffb(j).u
                            prjV(j) = uvbuffb(j).v
                        next j
                    end if

                    ''
                    '' Mip level, once per face.
                    ''
                    '' This used to run per triangle, on the mean of that
                    '' triangle's three vertices -- and every fan triangle
                    '' includes the pivot, so the two halves of a quad could
                    '' straddle a threshold and land on different mips. The
                    '' mips are box filtered resamples at different sizes, so
                    '' a one texel mortar line falls on a different texel row
                    '' in each: the seam shows as the texture stepping a
                    '' couple of pixels along the fan diagonal. Quake picks a
                    '' mip per surface, and so does this now.
                    ''
                    zl! = 0.0
                    for  j = 0 to polycnt-1
                        zl! = zl! + polyb(j).w
                    next j
                    zl! = zl! / polycnt

                    if  ( zl! >= 1400.0 ) then
                        miplevel = 3
                    elseif  ( zl! >= 560.0 ) then
                        miplevel = 2
                    elseif  ( zl! >= 280.0 ) then
                        miplevel = 1
                    else
                        miplevel = 0
                    end if

                    if ( usemips ) then
                        texIndx = mipidx*4+miplevel
                    else
                        texIndx = mipidx*4
                    end if
                        for j = 0 to polycnt-3
                            p2 = j+1
                            p3 = j+2


                            ''
                            '' Rasterize. Vertex 0 is the fan pivot.
                            ''
                            vtx(j).v1.z = prjW(0)
                            vtx(j).v2.z = prjW(p2)
                            vtx(j).v3.z = prjW(p3)
                            vtx(j).v1.x = prjX(0)
                            vtx(j).v1.y = prjY(0)
                            vtx(j).v2.x = prjX(p2)
                            vtx(j).v2.y = prjY(p2)
                            vtx(j).v3.x = prjX(p3)
                            vtx(j).v3.y = prjY(p3)

                            if ( rendmode = 2 ) then
                                uglTriF hDstDC, vtx(j), 200
                                uglLine hDstDC, vtx(j).v1.x, vtx(j).v1.y, vtx(j).v2.x, vtx(j).v2.y, 0
                                uglLine hDstDC, vtx(j).v2.x, vtx(j).v2.y, vtx(j).v3.x, vtx(j).v3.y, 0
                                uglLine hDstDC, vtx(j).v3.x, vtx(j).v3.y, vtx(j).v1.x, vtx(j).v1.y, 0
                            else
                                vtx(j).v1.u = prjU(0)
                                vtx(j).v1.v = prjV(0)
                                vtx(j).v2.u = prjU(p2)
                                vtx(j).v2.v = prjV(p2)
                                vtx(j).v3.u = prjU(p3)
                                vtx(j).v3.v = prjV(p3)

                                if ( rendmode = 0 ) then
                                    uglTriTP hDstDC, vtx(j), 0, hTextrDC(texIndx)
                                else
                                    uglTriT hDstDC, vtx(j), 0, hTextrDC(texIndx)
                                end if
                            end if

                            tris = tris + 1                                
                        next j
                        
                    end if
                end if
                
                polys = polys + 1
            end if
            
        next ti
    next mi        
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
'' name: checkCommandLine
'' desc: A map on the command line, and the ini beside it.
''::::::::::
defint a-z
sub checkCommandLine
    if ( rtrim$(ltrim$( command$ )) = "" ) then
        print "Usage: qrender mapname.bsp"
        print "Copyleft Blitz, july/2003"
        doEnd
    end if
    
    if ( (dir$( command$ ) = "") ) then
        print "File " + lcase$(command$) + " could not be found"
        doEnd
    end if
    
    if ( (dir$( "stuff.ini" ) = "") ) then
        print "Ini file could not be found"
        doEnd
    end if    

end sub



''::::::::::
'' name: initTables
'' desc: Reads stuff.ini and builds the bit mask table the PVS decoder indexes.
''::::::::::
defint a-z
sub initTables
    ''
    '' bitarray and frustum are COMMON now, and COMMON can only declare an
    '' array as name() -- with no elements. Both carried a real bound in their
    '' DIM, so they must be sized here or the first write is out of range.
    ''
    redim bitarray( 15 ) as integer
    redim frustum( 5 ) as plane

    dim i as integer

    parseIni "stuff.ini"    
    
    for  i = 0 to 15
        bitarray(i) = clng(2^i)
    next i    

end sub



''::::::::::
'' name: initUgl
''::::::::::
defint a-z
sub initUgl
    if ( uglInit() = FALSE ) then 
        ExitError "0x0000, Could not init UGL..."
    end if

end sub



''::::::::::
'' name: soundOpen
'' desc: Autodetects an SB16, falls back to the BLASTER variable.
''::::::::::
defint a-z
sub soundOpen
    dim port as integer
    dim irq as integer
    dim ldma as integer
    dim hdma as integer

    if ( env.sound = true ) then
        if ( sndInit( false, false, false, false ) = false ) then
            
            getSBSettings port, irq, ldma, hdma
            if ( (port = false) or (irq = false) or (ldma = false ) ) then
                ExitError "0x0001, No sound blaster or compatible detected..."
            end if
          
            if ( sndInit( port, irq, ldma, hdma ) = false ) then
                ExitError "0x0002, Could not init sound module..."
            end if
            
        end if
        
        ''
        '' Try to open sound output with a update rate of
        '' 50 times per second.
        ''
        '' SB 1.0 - 2.0:    8 bit, mono, 4000Hz-23000Hz
        '' SB 2.01:         8 bit, mono, 4000Hz-44100Hz
        '' SB Pro:          8 bit, mono, 4000Hz-44100Hz
        ''                  8 bit, stereo, 11025Hz-22050Hz
        '' SB 16:           8/16 bit, mono/stereo, 5000Hz-44100Hz
        ''        
        if ( sndOpenOutput( snd.s16.stereo, 44100, 50 ) = false ) then
            if ( sndOpenOutput( snd.s8.stereo, 22050, 50 ) = false ) then
                if ( sndOpenOutput( snd.s8.mono, 22050, 50 ) = false ) then
                    ExitError "0x1003, Could not open sound output..."
                end if
            end if        
        end if

    end if
end sub



''::::::::::
'' name: musicStart
'' desc: Starts the module that plays over the loading screen.
''::::::::::
defint a-z
sub musicStart
    if ( env.sound = true ) then
        if ( modInit = false ) then
            ExitError "0x1004, Could not init mod module..."
        end if
        
        ''
        '' Load mod
        ''    
        if ( modNew( loadmod, mod.ems, "base.dat::mods/flim.mod" ) = false ) then
            ExitError "0x1005, Could not load mod..."
        end if
            
        if ( modNew( mymod, mod.ems, "base.dat::mods/mainfrm.mod" ) = false ) then
            ExitError "0x1005, Could not load mod..."
        end if
        
       
        ''
        '' Loading music
        ''
        modPlay loadmod
    end if

end sub



''::::::::::
'' name: fontOpen
''::::::::::
defint a-z
sub fontOpen
    if ( not initFont( "base.dat::font/4x6.fnt", 254 ) ) then
        ExitError "0x0000, Could not load font..."
    end if    

end sub



''::::::::::
'' name: loadScreenOpen
'' desc: Mode 13h for the duration of loading only.
''::::::::::
defint a-z
sub loadScreenOpen
    loadDC = uglSetVideoDC( UGL.8BIT, 320, 200, 1 )
    if ( loadDC = false ) then
        ExitError "0x3001, Could not set loading video mode"
    end if
    
    drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1    

end sub



''::::::::::
'' name: texLoadOffsets
'' desc: Reads the miptex directory and sizes the texture tables.
''::::::::::
defint a-z
sub texLoadOffsets
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



''::::::::::
'' name: videoOpen
'' desc: Final video mode, backbuffer and the Quake palette.
''::::::::::
defint a-z
sub videoOpen
    dim pages as integer

    if ( env.usepag = true ) then
        pages = env.pages
    else
        pages = 1
    end if
            
    env.hVideoDC = uglSetVideoDC( env.cFmt, env.xRes, env.yRes, pages )
    if ( env.hVideoDC = FALSE ) then 
        ExitError "0x0001, Could not set video mode..."
    end if
    
    
    ''
    '' Create a backbuffer
    '' 
    if ( env.usepag = false ) then
        env.hBackBDC = uglNew( ugl.mem, env.cFmt, env.xRes, env.yRes )
        if ( env.hBackBDC = FALSE ) then 
            ExitError "0x0002, Could not create a backbuffer..."
        end if
    end if     
    

    ''
    '' Load quake palette
    ''    
    uglPalSet 0, 256, pal
    memFree pal

end sub



''::::::::::
'' name: inputOpen
'' desc: Mouse, keyboard and the one second timer.
''::::::::::
defint a-z
sub inputOpen
    if ( mouseInit( env.hVideoDC, env.mouse ) = FALSE ) then
        ExitError "0x0006, Could not init mouse..."
    end if  
    
    ''
    '' Init keyboard
    ''
    kbdInit env.keyboard
    
    ''
    '' Init timer
    ''
    tmrInit

end sub



''::::::::::
'' name: musicStopLoading
''::::::::::
defint a-z
sub musicStopLoading
    if ( env.sound = true ) then
        modStop
        modDel loadmod
    end if

end sub


''::::::::::
'' name: presentFrame
'' desc: Screenshot key, page flip or backbuffer blit, and the frame counter.
''
'' Once per frame, at the end of it.
''::::::::::
defint a-z
sub presentFrame ( hDstDC as long, page as integer )

    ''
    '' Take screenshoot ?
    '' 
    if ( env.keyboard.s ) then            
        ugluBMPSave "scrn" + ltrim$(rtrim$(str$( screenie ))) + ".bmp", hDstDC
        screenie = screenie + 1
    end if
    
    ''
    '' Paging/backbuffer
    ''
    if ( env.usepag = false ) then
        uglPut env.hVideoDC, 0, 0, env.hBackBDC
    else        
        uglSetVisPage page
        uglSetWrkPage (page+1) mod env.pages
        page = (page+1) mod env.pages
    end if
    
    fps1 = fps1 + 1
    env.frames = env.frames + 1.0
    
    if env.secTimer.counter > 0 then
        fps = fps1
        fps1 = 0
        env.secTimer.counter = 0
    end if        
    
    tris = 0
    polys = 0

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
