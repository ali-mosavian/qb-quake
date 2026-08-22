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


'' Startup-only state. These were locals of the 700 line doInit; splitting it
'' into one routine per step is what promoted them, and they stay out of the
'' frame path entirely.
dim shared loadmod as UGMMOD
'' texiCount was the one lump count never declared shared. Inside the old
'' monolithic doInit that did not matter; once bspOpen and bspAlloc were
'' separate routines, bspAlloc read 0 and did redim texInfBuff(-1).
dim shared camUp as u3dVector3f    
dim shared camLookAt as u3dVector3f

'$dynamic
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


'' Toggles and per-frame counters, formerly locals of doMain.
dim shared fpsview as integer
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
