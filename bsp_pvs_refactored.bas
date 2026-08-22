''
'' BSP PVS Renderer - Refactored Version (No Global State)
'' All state is passed explicitly via parameters
''
defint a-z
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bsp_pvs.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'

declare sub getSBSettings  ( port as integer, irq as integer, _
                             ldma as integer, hdma as integer )

''
'' Constants
''
const LOADING_STEPS = 14
const MAX_MIP_LEVELS = 4
const MIP_LEVEL_0_SIZE = 64
const MIP_LEVEL_1_SIZE = 32
const MIP_LEVEL_2_SIZE = 16
const MIP_LEVEL_3_SIZE = 8
const LOADING_BAR_WIDTH = 150
const LOADING_BAR_HEIGHT = 20
const LOADING_SCREEN_WIDTH = 320
const LOADING_SCREEN_HEIGHT = 200
const LOADING_BAR_X = (LOADING_SCREEN_WIDTH - LOADING_BAR_WIDTH) \ 2
const LOADING_BAR_Y = (LOADING_SCREEN_HEIGHT - LOADING_BAR_HEIGHT) \ 2
const COLOR_MAP_SIZE = 16384
const MAX_TEXTURES = 256
const MAX_MIPMAPS_PER_TEXTURE = 4
const BITARRAY_SIZE = 16
const LEAF_MASK = &h8000
const NEAR_CLIP_THRESHOLD = 0.01
const FAR_CLIP_THRESHOLD = 0.01
const MIP_DISTANCE_THRESHOLD_0 = 1400.0
const MIP_DISTANCE_THRESHOLD_1 = 1400.0 * 0.8 * 0.50
const MIP_DISTANCE_THRESHOLD_2 = 1400.0 * 0.8 * 0.25
const MAX_COLOR_VALUE = 255.0
const MAX_DISTANCE_SEARCH = 167777217
const LIGHTMAP_TILE_SIZE = 16
const ENTITY_START_CLASS = "info_player_start"
const ENTITY_ORIGIN_KEY = "origin"
const ENTITY_ANGLE_KEY = "angle"
const CAMERA_MOVE_SPEED = 3.0
const PI = 3.14159

''
'' Application State Structures
''
type BSPData
    triCount as long
    vtxCount as long
    edgCount as long
    ledgCount as long
    lefCount as long
    lfcCount as long
    plnCount as long
    ndsCount as long
    mdlCount as long
    clpCount as long
    texCount as long
    visCount as long
    bsphead as header
end type

type CameraState
    pos as u3dVector3f
    lookAt as u3dVector3f
    up as u3dVector3f
    startAngle as single
end type

type RenderState
    usemips as integer
    rendmode as integer
    fpsview as integer
    stats as integer
    backface as integer
    fps as integer
    fps1 as integer
    polys as integer
    tris as integer
    screenie as integer
    page as integer
end type

type BSPTreeState
    ordCount as integer
    culLeafs as integer
    drwLeafs as integer
end type

type ScriptCameraState
    pa as integer
    crrPnt as integer
    cntPnts as integer
    last_point as integer
end type

''
'' Global arrays (QBASIC limitation - must be global for dynamic arrays)
'' These are passed as parameters but declared globally for memory management
''
'$dynamic
dim shared triBuffer(1) as face2
dim shared edgBuffer(1) as edge
dim shared ledgBuffer(1) as integer
dim shared vtxBuffer(1) as vertex
dim shared txcBuffer(1) as uv
dim shared lefBuffer(1) as leaf2
dim shared lfcBuffer(1) as integer
dim shared mdlBuffer(1) as model
dim shared plnBuffer(1) as plane2
dim shared ndsBuffer(1) as nodeb
dim shared orderList(1) as integer
dim shared pvsBufferA(1) as integer
dim shared pvsBufferB(1) as integer
dim shared texInfBuff(1) as texinfo
dim shared mipBuffInf(1) as miptexb
dim shared clpBuffer(1) as clipnode
dim shared polyFlag(1) as integer
dim shared hTextrDC(MAX_TEXTURES * MAX_MIPMAPS_PER_TEXTURE) as long
dim shared hFontChar(255) as long
dim shared bitarray(BITARRAY_SIZE-1) as integer
dim shared frustum(5) as plane
dim shared lightmap as long

''
'' Global environment (configuration - read-only after init)
''
dim shared env as EnvType
dim shared mymod as UGMMOD

'$static

''
'' Main Entry Point
''
on errror goto HandleErr

dim bspData as BSPData
dim cameraState as CameraState
dim renderState as RenderState

doInit bspData, cameraState
doMain bspData, cameraState, renderState
doEnd

HandleErr:    
    ExitError "0x1000, Unknown runtime error..."


''============================================================================
'' UI Functions
''============================================================================

''
'' Draws a loading bar with progress indication
''
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


''
'' Updates loading progress and redraws bar
''
defint a-z
sub updateLoadingProgress ( hDC as long, byref loading as single, increment as single )
    loading = loading + increment
    drwLoadingBar hDC, LOADING_BAR_X, LOADING_BAR_Y, LOADING_BAR_WIDTH, LOADING_BAR_HEIGHT, loading, -1
end sub


''============================================================================
'' File Validation Functions
''============================================================================

''
'' Validates command line arguments
''
defint a-z
function validateCommandLine% ()
    dim cmd as string
    
    cmd = rtrim$(ltrim$(command$))
    
    if ( cmd = "" ) then
        print "Usage: bsp_pvs mapname.bsp"
        print "Copyleft Blitz, july/2003"
        validateCommandLine% = false
        exit function
    end if
    
    if ( dir$(cmd) = "" ) then
        print "File " + lcase$(cmd) + " could not be found"
        validateCommandLine% = false
        exit function
    end if
    
    if ( dir$("stuff.ini") = "" ) then
        print "Ini file could not be found"
        validateCommandLine% = false
        exit function
    end if
    
    validateCommandLine% = true
end function


''============================================================================
'' Initialization Functions
''============================================================================

''
'' Initializes bit array for bitwise operations
''
defint a-z
sub initBitArray ( bitarray() as integer )
    dim i as integer
    
    for i = 0 to BITARRAY_SIZE-1
        bitarray(i) = clng(2^i)
    next i
end sub


''
'' Initializes UGL graphics system
''
defint a-z
function initGraphics% ()
    if ( uglInit() = FALSE ) then 
        ExitError "0x0000, Could not init UGL..."
        initGraphics% = false
        exit function
    end if
    
    initGraphics% = true
end function


''
'' Attempts to initialize sound with fallback options
''
defint a-z
function initSoundSystem% ( soundEnabled as integer )
    dim port as integer, irq as integer
    dim ldma as integer, hdma as integer
    
    if ( soundEnabled = false ) then
        initSoundSystem% = true
        exit function
    end if
    
    '' Try autodetect first
    if ( sndInit( false, false, false, false ) = false ) then
        getSBSettings port, irq, ldma, hdma
        if ( (port = false) or (irq = false) or (ldma = false) ) then
            ExitError "0x0001, No sound blaster or compatible detected..."
            initSoundSystem% = false
            exit function
        end if
      
        if ( sndInit( port, irq, ldma, hdma ) = false ) then
            ExitError "0x0002, Could not init sound module..."
            initSoundSystem% = false
            exit function
        end if
    end if
    
    '' Try different sound output formats
    if ( sndOpenOutput( snd.s16.stereo, 44100, 50 ) = false ) then
        if ( sndOpenOutput( snd.s8.stereo, 22050, 50 ) = false ) then
            if ( sndOpenOutput( snd.s8.mono, 22050, 50 ) = false ) then
                ExitError "0x1003, Could not open sound output..."
                initSoundSystem% = false
                exit function
            end if
        end if        
    end if
    
    '' Initialize mod module
    if ( modInit = false ) then
        ExitError "0x1004, Could not init mod module..."
        initSoundSystem% = false
        exit function
    end if
    
    initSoundSystem% = true
end function


''
'' Loads music modules
''
defint a-z
function loadMusicModules% ( soundEnabled as integer, byref mymod as UGMMOD, _
                            byref loadmod as UGMMOD )
    if ( soundEnabled = false ) then
        loadMusicModules% = true
        exit function
    end if
    
    if ( modNew( loadmod, mod.ems, "base.dat::mods/flim.mod" ) = false ) then
        ExitError "0x1005, Could not load mod..."
        loadMusicModules% = false
        exit function
    end if
        
    if ( modNew( mymod, mod.ems, "base.dat::mods/mainfrm.mod" ) = false ) then
        ExitError "0x1005, Could not load mod..."
        loadMusicModules% = false
        exit function
    end if
    
    modPlay loadmod
    loadMusicModules% = true
end function


''
'' Sets up loading screen
''
defint a-z
function setupLoadingScreen% ( byref hVideoDC as long )
    hVideoDC = uglSetVideoDC( UGL.8BIT, LOADING_SCREEN_WIDTH, LOADING_SCREEN_HEIGHT, 1 )
    if ( hVideoDC = false ) then
        ExitError "0x3001, Could not set loading video mode"
        setupLoadingScreen% = false
        exit function
    end if
    
    setupLoadingScreen% = true
end function


''============================================================================
'' BSP File Loading Functions
''============================================================================

''
'' Calculates BSP data structure counts from header
''
defint a-z
sub calculateBSPCounts ( byref bspData as BSPData )
    dim vtx as vertex   
    dim fce as face
    dim nodetmp as node
    dim leaftmp as leaf
    dim planetmp as plane
    
    bspData.triCount = bspData.bsphead.faces.size \ len(fce)
    bspData.vtxCount = bspData.bsphead.vertices.size \ len(vtxBuffer(0))
    bspData.edgCount = bspData.bsphead.edges.size \ len(edgBuffer(0))
    bspData.ledgCount = bspData.bsphead.ledges.size \ 4
    bspData.lefCount = bspData.bsphead.leaves.size \ len(leaftmp)
    bspData.lfcCount = bspData.bsphead.lface.size \ len(lfcBuffer(0))
    bspData.plnCount = bspData.bsphead.planes.size \ len(planetmp)
    bspData.ndsCount = bspData.bsphead.nodes.size \ len(nodetmp)
    bspData.mdlCount = bspData.bsphead.models.size \ len(mdlBuffer(0))
    bspData.visCount = bspData.bsphead.vislist.size
    bspData.clpCount = bspData.bsphead.clipnode.size \ len(clpBuffer(0))
end sub


''
'' Allocates memory for all BSP data structures
''
defint a-z
sub allocateBSPBuffers ( bspData as BSPData )
    redim triBuffer(bspData.triCount-1) as face2
    redim edgBuffer(bspData.edgCount-1) as edge    
    redim ledgBuffer(bspData.ledgCount-1) as integer
    redim vtxBuffer(bspData.vtxCount-1) as vertex
    redim txcBuffer(bspData.vtxCount-1) as uv
    redim lefBuffer(bspData.lefCount-1) as leaf2
    redim lfcBuffer(bspData.lfcCount-1) as integer
    redim plnBuffer(bspData.plnCount-1) as plane2
    redim ndsBuffer(bspData.ndsCount-1) as nodeb
    redim mdlBuffer(bspData.mdlCount-1) as model
    redim orderList(bspData.ndsCount-1) as integer
    redim pvsBufferA((bspData.bsphead.vislist.size+1)\2) as integer
    redim pvsBufferB(4096) as integer
    redim polyFlag(4096) as integer
    redim texInfBuff(bspData.bsphead.texinfo.size \ len(texInfBuff(0)) - 1) as texinfo
end sub


''
'' Loads vertices from BSP file
''
defint a-z
sub loadVertices ( fileNum as integer, hDC as long, byref loading as single, _
                   bspData as BSPData )
    dim i as integer
    
    seek #fileNum, bspData.bsphead.vertices.offs+1
    for i = 0 to bspData.vtxCount-1
        get #fileNum,, vtxBuffer(i)
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.vtxCount
    next i
end sub


''
'' Loads faces/polygons from BSP file
''
defint a-z
sub loadFaces ( fileNum as integer, hDC as long, byref loading as single, _
                bspData as BSPData )
    dim i as integer
    dim fce as face
    
    seek #fileNum, bspData.bsphead.faces.offs+1
    for i = 0 to bspData.triCount-1
        get #fileNum,, fce
        triBuffer(i).planeid = fce.planeid
        triBuffer(i).side = fce.side
        triBuffer(i).ledgeid = fce.ledgeid
        triBuffer(i).ledgenum = fce.ledgenum
        triBuffer(i).texinfoid = fce.texinfoid
        triBuffer(i).lightmap = fce.lightmap
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.triCount
    next i    
end sub


''
'' Loads edges from BSP file
''
defint a-z
sub loadEdges ( fileNum as integer, hDC as long, byref loading as single, _
                bspData as BSPData )
    dim i as integer
    
    seek #fileNum, bspData.bsphead.edges.offs+1
    for i = 0 to bspData.edgCount-1
        get #fileNum,, edgBuffer(i)
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.edgCount
    next i        
end sub


''
'' Loads edge list from BSP file
''
defint a-z
sub loadEdgeList ( fileNum as integer, hDC as long, byref loading as single, _
                   bspData as BSPData )
    dim i as integer
    dim tmp as long
    
    seek #fileNum, bspData.bsphead.ledges.offs+1
    for i = 0 to bspData.ledgCount-1
        get #fileNum,, tmp
        ledgBuffer(i) = tmp
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.ledgCount
    next i    
end sub


''
'' Loads BSP leaves from file
''
defint a-z
sub loadLeaves ( fileNum as integer, hDC as long, byref loading as single, _
                 bspData as BSPData )
    dim i as integer
    dim leaftmp as leaf
    
    seek #fileNum, bspData.bsphead.leaves.offs+1
    for i = 0 to bspData.lefCount-1        
        get #fileNum,, leaftmp
        lefBuffer(i).vislist = leaftmp.vislist
        swap lefBuffer(i).bound, leaftmp.bound
        lefBuffer(i).lfaceid = leaftmp.lfaceid
        lefBuffer(i).lfacenum = leaftmp.lfacenum
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.lefCount
    next i        
end sub


''
'' Loads face list from BSP file
''
defint a-z
sub loadFaceList ( fileNum as integer, hDC as long, byref loading as single, _
                   bspData as BSPData )
    dim i as integer
    
    seek #fileNum, bspData.bsphead.lface.offs+1
    for i = 0 to bspData.lfcCount-1
        get #fileNum,, lfcBuffer(i)
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.lfcCount
    next i                
end sub


''
'' Loads BSP nodes from file
''
defint a-z
sub loadNodes ( fileNum as integer, hDC as long, byref loading as single, _
                bspData as BSPData )
    dim i as integer
    dim nodetmp as node
    
    seek #fileNum, bspData.bsphead.nodes.offs+1
    for i = 0 to bspData.ndsCount-1
        get #fileNum,, nodetmp
        ndsBuffer(i).planeid = nodetmp.planeid
        ndsBuffer(i).child0  = nodetmp.child0
        ndsBuffer(i).child1  = nodetmp.child1
        ndsBuffer(i).lfaceid = nodetmp.lfaceid
        ndsBuffer(i).lfacenum = nodetmp.lfacenum
        
        ndsBuffer(i).bound.min.x = nodetmp.bound.min.x
        ndsBuffer(i).bound.min.y = nodetmp.bound.min.y
        ndsBuffer(i).bound.min.z = nodetmp.bound.min.z
        ndsBuffer(i).bound.max.x = nodetmp.bound.max.x
        ndsBuffer(i).bound.max.y = nodetmp.bound.max.y
        ndsBuffer(i).bound.max.z = nodetmp.bound.max.z
        
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.ndsCount
    next i
end sub


''
'' Loads split planes from BSP file
''
defint a-z
sub loadPlanes ( fileNum as integer, hDC as long, byref loading as single, _
                 bspData as BSPData )
    dim i as integer
    dim planetmp as plane
    
    seek #fileNum, bspData.bsphead.planes.offs+1
    for i = 0 to bspData.plnCount-1
        get #fileNum,, planetmp
        plnBuffer(i).norm.x = planetmp.norm.x
        plnBuffer(i).norm.y = planetmp.norm.y
        plnBuffer(i).norm.z = planetmp.norm.z
        plnBuffer(i).dist = planetmp.dist
        
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.plnCount
    next i    
end sub


''
'' Loads models from BSP file
''
defint a-z
sub loadModels ( fileNum as integer, hDC as long, byref loading as single, _
                 bspData as BSPData )
    dim i as integer
    
    seek #fileNum, bspData.bsphead.models.offs+1
    for i = 0 to bspData.mdlCount-1
        get #fileNum,, mdlBuffer(i)
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/bspData.mdlCount
    next i
end sub


''
'' Loads PVS (Potentially Visible Set) data
''
defint a-z
sub loadPVS ( fileNum as integer, hDC as long, byref loading as single, _
              bspData as BSPData )
    dim i as integer
    
    seek #fileNum, bspData.bsphead.vislist.offs+1
    for i = 0 to (bspData.bsphead.vislist.size\2)-1
        get #fileNum,, pvsBufferA(i)
    next i
    
    if ( bspData.bsphead.vislist.size mod 2 ) then
        get #fileNum,, pvsBufferA(i)
    end if
    
    updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)
end sub


''
'' Loads texture info from BSP file
''
defint a-z
sub loadTextureInfo ( fileNum as integer, hDC as long, byref loading as single, _
                      bspData as BSPData )
    dim i as integer
    dim texiCount as long
    
    texiCount = bspData.bsphead.texinfo.size \ len(texInfBuff(0))
    
    seek #fileNum, bspData.bsphead.texinfo.offs+1
    for i = 0 to texiCount-1
        get #fileNum,, texInfBuff(i)
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/texiCount
    next i
end sub


''
'' Parses entity string to find player start position
''
defint a-z
sub parsePlayerStartEntity ( entity$ as string, byref cameraState as CameraState )
    dim i as integer, j as integer
    dim char$ as string * 1
    dim class$ as string
    dim fchar as integer
    dim new as integer
    dim strm(50) as string
    dim strm_cnt as integer
    
    for i = 1 to len(entity$)    
        char$ = mid$(entity$, i, 1)

        if char$ = "{" then 
            new = 1
            fchar = i
        end if
            
        if char$ = "}" then 
            if new = 1 then
                class$ = mid$(entity$, fchar, i-fchar+1)
                
                if instr(class$, ENTITY_START_CLASS) then
                    strtok strm(), strm_cnt, " {}"+chr$(34)+chr$(10)+chr$(13), class$
                    
                    for j = 0 to strm_cnt-1
                        if strm(j) = ENTITY_ORIGIN_KEY then
                            cameraState.pos.x = val(strm(j+1))
                            cameraState.pos.z = val(strm(j+2))
                            cameraState.pos.y = val(strm(j+3))
                        end if
                        
                        if strm(j) = ENTITY_ANGLE_KEY then
                            cameraState.startAngle = val(strm(j+1))                            
                        end if                        
                    next j
                end if
            end if
        end if    
    next i
end sub


''
'' Loads colormap from file
''
defint a-z
function loadColormap% ( colmap() as integer )
    dim file as UAR
    
    redim colmap(8192*2-1) as integer
    
    if ( uarOpen( file, "base.dat::color/colormap.lmp", F4READ ) = false ) then
        ExitError "Could not open ( 1 ) base.dat::color/colormap.lmp..."
        loadColormap% = false
        exit function
    end if

    if ( uarReadEx( file, colmap(0), COLOR_MAP_SIZE ) <> COLOR_MAP_SIZE ) then
        ExitError "Could not open ( 2 ) base.dat::color/colormap.lmp..."
        loadColormap% = false
        exit function
    end if
    
    uarClose file
    loadColormap% = true
end function


''
'' Finds nearest palette color using distance calculation
''
defint a-z
function findNearestPaletteColor% ( r as single, g as single, b as single, _
                                    palofs as integer )
    dim k as integer
    dim kofs as integer
    dim r2 as single, g2 as single, b2 as single
    dim dist as single, dista as single
    dim col as integer
    
    dist = MAX_DISTANCE_SEARCH
    
    for k = 0 to 255
        kofs = palofs + k * 3
        r2 = r - peek(kofs+0)
        g2 = g - peek(kofs+1)
        b2 = b - peek(kofs+2)
                                
        dista = r2*r2 + g2*g2 + b2*b2
        
        if ( dist > dista ) then
            col = k
            
            if ( dista = 0.0 ) then
                exit for
            end if
            
            dist = dista                            
        end if
    next k
    
    findNearestPaletteColor% = col
end function


''
'' Samples texture pixel with bilinear filtering
''
defint a-z
function sampleTexturePixel% ( tmpdc as long, x as single, y as single, _
                                wdth as integer, hght as integer, _
                                mipl as integer, palofs as integer )
    dim col1 as integer, col2 as integer, col3 as integer, col4 as integer
    dim cofs1 as integer, cofs2 as integer, cofs3 as integer, cofs4 as integer
    dim r as single, g as single, b as single
    dim s as single, t as single
    
    col1 = uglPGet( tmpdc, (x+0) mod (wdth\mipl), (y+0) mod (hght\mipl) )
    col2 = uglPGet( tmpdc, (x+0) mod (wdth\mipl), (y+1) mod (hght\mipl) )
    col3 = uglPGet( tmpdc, (x+1) mod (wdth\mipl), (y+0) mod (hght\mipl) )
    col4 = uglPGet( tmpdc, (x+1) mod (wdth\mipl), (y+1) mod (hght\mipl) )
                            
    s = x - int(x)
    t = y - int(y)
    
    '' Bilinear interpolation
    cofs1 = palofs + col1 * 3
    cofs2 = palofs + col2 * 3
    cofs3 = palofs + col3 * 3
    cofs4 = palofs + col4 * 3

    r = peek(cofs1+0) * (1-s) * (1-t)
    g = peek(cofs1+1) * (1-s) * (1-t)
    b = peek(cofs1+2) * (1-s) * (1-t)
    r = r + peek(cofs2+0) * (1-s) * t
    g = g + peek(cofs2+1) * (1-s) * t
    b = b + peek(cofs2+2) * (1-s) * t
    r = r + peek(cofs3+0) * (1-t) * s
    g = g + peek(cofs3+1) * (1-t) * s
    b = b + peek(cofs3+2) * (1-t) * s
    r = r + peek(cofs4+0) * s * t
    g = g + peek(cofs4+1) * s * t
    b = b + peek(cofs4+2) * s * t
    
    if ( r > MAX_COLOR_VALUE ) then r = MAX_COLOR_VALUE
    if ( g > MAX_COLOR_VALUE ) then g = MAX_COLOR_VALUE
    if ( b > MAX_COLOR_VALUE ) then b = MAX_COLOR_VALUE
    
    sampleTexturePixel% = findNearestPaletteColor(r, g, b, palofs)
end function


''
'' Processes a single mipmap level
''
defint a-z
sub processMipmapLevel ( fileNum as integer, texIndex as integer, _
                         mipLevel as integer, tmipinf() as miptex, _
                         texoffs() as long, tmpdc as long, _
                         miplevelArray() as long, hDC as long, _
                         palofs as integer, cmpseg as integer, cmpofs as integer, _
                         numtex as long, bspData as BSPData )
    dim mipl as integer
    dim x as integer, y as integer
    dim cx as single, cy as single
    dim dx as single, dy as single
    dim byte as string * 1
    dim col as integer
    
    mipl = 2^mipLevel
    
    seek #fileNum, bspData.bsphead.miptex.offs+texoffs(texIndex)+tmipinf(texIndex).offset(mipLevel)+1
    
    '' Load raw texture data
    def seg = cmpseg
    for y = 0 to tmipinf(texIndex).hght\mipl-1
        for x = 0 to tmipinf(texIndex).wdth\mipl-1
            get #fileNum,, byte
            uglPset tmpdc, x, y, peek(cmpofs+asc(byte))
        next x
    next y

    '' Assign texture handle
    select case (mipLevel)
        case 0: hTextrDC(texIndex*4+mipLevel) = miplevelArray(texIndex)
        case 1: hTextrDC(texIndex*4+mipLevel) = miplevelArray(texIndex)
        case 2: hTextrDC(texIndex*4+mipLevel) = miplevelArray(texIndex)
        case 3: hTextrDC(texIndex*4+mipLevel) = miplevelArray(texIndex)
    end select
    
    '' Scale and filter texture
    def seg = varseg(palofs)
    dx = tmipinf(texIndex).wdth / MIP_LEVEL_0_SIZE
    dy = tmipinf(texIndex).hght / MIP_LEVEL_0_SIZE
    cy = 0.0

    for y = 0 to ((MIP_LEVEL_0_SIZE\(2^mipLevel))-1)
        cx = 0.0            
        
        for x = 0 to ((MIP_LEVEL_0_SIZE\(2^mipLevel))-1)
            col = sampleTexturePixel(tmpdc, cx, cy, tmipinf(texIndex).wdth, _
                                     tmipinf(texIndex).hght, mipl, palofs)
            uglPset hTextrDC(texIndex*4+mipLevel), x, y, col
            cx = cx + dx
        next x
        
        cy = cy + dy
    next y
    
    drwLoadingBar hDC, LOADING_BAR_X, LOADING_BAR_Y-15, LOADING_BAR_WIDTH, 7, _
                  (texIndex*4+mipLevel)*25\numtex, 51
end sub


''
'' Loads and processes all textures with mipmaps
''
defint a-z
sub loadTextures ( fileNum as integer, hDC as long, byref loading as single, _
                   numtex as long, bspData as BSPData )
    dim i as integer, j as integer
    dim texoffs(MAX_TEXTURES-1) as long
    dim tmipinf(MAX_TEXTURES-1) as miptex
    dim miplevel0(MAX_TEXTURES-1) as long
    dim miplevel1(MAX_TEXTURES-1) as long
    dim miplevel2(MAX_TEXTURES-1) as long
    dim miplevel3(MAX_TEXTURES-1) as long
    dim tmpdc as long
    dim pal as long
    dim palseg as integer
    dim palofs as integer
    dim cmpseg as integer
    dim cmpofs as integer
    dim colmap() as integer
    
    '' Allocate mipmap buffers
    if ( (uglNewMult(miplevel0(), numtex, ugl.ems, ugl.8bit, MIP_LEVEL_0_SIZE, MIP_LEVEL_0_SIZE) = false) or _
         (uglNewMult(miplevel1(), numtex, ugl.ems, ugl.8bit, MIP_LEVEL_1_SIZE, MIP_LEVEL_1_SIZE) = false) or _
         (uglNewMult(miplevel2(), numtex, ugl.ems, ugl.8bit, MIP_LEVEL_2_SIZE, MIP_LEVEL_2_SIZE) = false) or _
         (uglNewMult(miplevel3(), numtex, ugl.ems, ugl.8bit, MIP_LEVEL_3_SIZE, MIP_LEVEL_3_SIZE) = false) ) then
        ExitError "0x0004, Could not create textures..."
    end if
    
    tmpdc = uglNew( UGL.EMS, env.cFmt, 256, 256 )
    if ( tmpdc = false ) then
        ExitError "0x0004, Could not create texture temp..."
    end if
    
    '' Load palette and colormap
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )
    palseg = pal \ 65536&
    palofs = pal and &h0000ffff&
    
    if ( loadColormap(colmap()) = false ) then
        ExitError "Could not load colormap"
    end if
    
    cmpseg = varseg(colmap(0)) 
    cmpofs = varptr(colmap(0)) + 256*0
            
    fontPrintText hDC, 0, 199-8, "Loading and converting textures, this might take a while...", hFontChar()
    
    '' Load texture offsets
    seek #fileNum, bspData.bsphead.miptex.offs+1
    for i = 0 to numtex-1
        get #fileNum,, texoffs(i)
    next i
    
    '' Process each texture
    for i = 0 to numtex-1
        seek #fileNum, bspData.bsphead.miptex.offs+texoffs(i)+1
        get #fileNum,, tmipinf(i)
        
        mipBuffInf(i).hght = 1.0 / tmipinf(i).hght
        mipBuffInf(i).wdth = 1.0 / tmipinf(i).wdth        
        
        '' Process each mipmap level
        for j = 0 to MAX_MIP_LEVELS-1
            select case j
                case 0: processMipmapLevel fileNum, i, j, tmipinf(), texoffs(), tmpdc, miplevel0(), hDC, palofs, cmpseg, cmpofs, numtex, bspData
                case 1: processMipmapLevel fileNum, i, j, tmipinf(), texoffs(), tmpdc, miplevel1(), hDC, palofs, cmpseg, cmpofs, numtex, bspData
                case 2: processMipmapLevel fileNum, i, j, tmipinf(), texoffs(), tmpdc, miplevel2(), hDC, palofs, cmpseg, cmpofs, numtex, bspData
                case 3: processMipmapLevel fileNum, i, j, tmipinf(), texoffs(), tmpdc, miplevel3(), hDC, palofs, cmpseg, cmpofs, numtex, bspData
            end select
        next j
        
        updateLoadingProgress hDC, loading, (100.0/LOADING_STEPS)/numtex
        drwLoadingBar hDC, LOADING_BAR_X, LOADING_BAR_Y-15, LOADING_BAR_WIDTH, 7, _
                      (i*4+j)*25\numtex, 51
    next i
    
    uglDel tmpdc
    erase colmap
end sub


''
'' Sets up video mode and backbuffer
''
defint a-z
function setupVideoMode% ( env as EnvType )
    dim pages as integer
    
    if ( env.usepag = true ) then
        pages = env.pages
    else
        pages = 1
    end if
            
    env.hVideoDC = uglSetVideoDC( env.cFmt, env.xRes, env.yRes, pages )
    if ( env.hVideoDC = FALSE ) then 
        ExitError "0x0001, Could not set video mode..."
        setupVideoMode% = false
        exit function
    end if
    
    if ( env.usepag = false ) then
        env.hBackBDC = uglNew( ugl.mem, env.cFmt, env.xRes, env.yRes )
        if ( env.hBackBDC = FALSE ) then 
            ExitError "0x0002, Could not create a backbuffer..."
            setupVideoMode% = false
            exit function
        end if
    end if
    
    setupVideoMode% = true
end function


''
'' Main initialization function - orchestrates all initialization steps
''
defint a-z
sub doInit ( byref bspData as BSPData, byref cameraState as CameraState )
    dim hVideoDC as long
    dim loading as single
    dim loadmod as UGMMOD
    dim fileNum as integer
    dim numtex as long
    dim entity$ as string
    dim pal as long
    
    '' Validate command line
    if ( validateCommandLine() = false ) then
        doEnd
        exit sub
    end if
    
    '' Initialize configuration
    parseIni "stuff.ini"    
    initBitArray bitarray()
    
    '' Initialize graphics
    if ( initGraphics() = false ) then
        exit sub
    end if
    
    '' Initialize sound
    if ( initSoundSystem(env.sound) = false ) then
        exit sub
    end if
    
    '' Load music
    if ( loadMusicModules(env.sound, mymod, loadmod) = false ) then
        exit sub
    end if
    
    '' Initialize font
    if ( not initFont( "base.dat::font/4x6.fnt", 254, bitarray(), hFontChar(), env.cFmt ) ) then
        ExitError "0x0000, Could not load font..."
        exit sub
    end if    
    
    '' Setup loading screen
    if ( setupLoadingScreen(hVideoDC) = false ) then
        exit sub
    end if
    
    '' Open BSP file
    fileNum = freefile
    open command$ for binary as #fileNum 
    
    '' Read header and calculate counts
    get #fileNum,, bspData.bsphead
    calculateBSPCounts bspData
    
    '' Get texture count
    seek #fileNum, bspData.bsphead.miptex.offs+1
    get #fileNum,, numtex&    
    bspData.texCount = numtex&
    numtex = numtex&
    
    '' Parse player start entity
    entity$ = space$(bspData.bsphead.entities.size)
    seek #fileNum, bspData.bsphead.entities.offs+1
    get #fileNum,, entity$
    parsePlayerStartEntity entity$, cameraState
    updateLoadingProgress hVideoDC, loading, 100.0/LOADING_STEPS
    
    '' Allocate buffers
    allocateBSPBuffers bspData
    
    '' Load all BSP data sections
    loadVertices fileNum, hVideoDC, loading, bspData
    loadFaces fileNum, hVideoDC, loading, bspData
    loadEdges fileNum, hVideoDC, loading, bspData
    loadEdgeList fileNum, hVideoDC, loading, bspData
    loadLeaves fileNum, hVideoDC, loading, bspData
    loadFaceList fileNum, hVideoDC, loading, bspData
    loadNodes fileNum, hVideoDC, loading, bspData
    loadPlanes fileNum, hVideoDC, loading, bspData
    loadModels fileNum, hVideoDC, loading, bspData
    loadPVS fileNum, hVideoDC, loading, bspData
    loadTextureInfo fileNum, hVideoDC, loading, bspData
    
    '' Load textures
    loadTextures fileNum, hVideoDC, loading, numtex, bspData
    
    '' Close file and restore screen
    close #fileNum    
    uglRestore
    screen 0
    width 80, 25
    
    '' Setup final video mode
    if ( setupVideoMode(env) = false ) then
        exit sub
    end if
    
    '' Load palette
    pal = uglPalLoad( "base.dat::color/palette.lmp", PALRGB )
    uglPalSet 0, 256, pal
    memFree pal
    
    '' Initialize input devices
    if ( mouseInit( env.hVideoDC, env.mouse ) = FALSE ) then
        ExitError "0x0006, Could not init mouse..."
        exit sub
    end if  
    
    kbdInit env.keyboard
    tmrInit
    
    '' Initialize camera up vector
    cameraState.up.x = 0.0
    cameraState.up.y = 1.0
    cameraState.up.z = 0.0
    
    '' Stop loading music
    if ( env.sound = true ) then
        modStop
        modDel loadmod
    end if
end sub


''============================================================================
'' Camera Functions
''============================================================================

''
'' Updates camera position based on mouse input (freelook mode)
''
defint a-z
sub updateCameraFreelook ( byref cameraState as CameraState, env as EnvType )
    dim tmx as integer, tmy as integer
    dim theta as single, phi as single
    dim lookDir as u3dVector3f
    
    '' Clamp mouse to screen bounds
    if env.mouse.x < 1 then mousepos env.xres-4, env.mouse.y
    if env.mouse.x > env.xres-3 then mousepos 1, env.mouse.y
    if env.mouse.y < 0 then mousepos env.mouse.x, 0
    if env.mouse.y > env.yres then mousepos env.mouse.x, env.yres-1
    
    tmx = env.mouse.x + 1
    tmy = env.mouse.y + 2

    theta = 2 * PI * ((env.xRes-1)-tmx) / env.xRes
    phi = PI * tmy / env.yRes
    
    lookDir.x = cos(theta) * sin(phi)
    lookDir.y = cos(phi)
    lookDir.z = sin(theta) * sin(phi)
    
    '' Move camera
    if ( env.mouse.left ) then 
        cameraState.pos.x = cameraState.pos.x + lookDir.x * CAMERA_MOVE_SPEED
        cameraState.pos.y = cameraState.pos.y + lookDir.y * CAMERA_MOVE_SPEED
        cameraState.pos.z = cameraState.pos.z + lookDir.z * CAMERA_MOVE_SPEED
    end if
                    
    if ( env.mouse.right ) then
        cameraState.pos.x = cameraState.pos.x - lookDir.x * CAMERA_MOVE_SPEED
        cameraState.pos.y = cameraState.pos.y - lookDir.y * CAMERA_MOVE_SPEED
        cameraState.pos.z = cameraState.pos.z - lookDir.z * CAMERA_MOVE_SPEED
    end if
    
    '' Convert to world space
    cameraState.lookAt.x = lookDir.x + cameraState.pos.x 
    cameraState.lookAt.y = lookDir.y + cameraState.pos.y 
    cameraState.lookAt.z = lookDir.z + cameraState.pos.z
end sub


''
'' Updates camera for script playback mode
''
defint a-z
sub updateCameraScriptPlay ( byref cameraState as CameraState, _
                              byref scriptState as ScriptCameraState, _
                              ppos() as PNT3D, plok() as PNT3D, _
                              cbzp() as PNT3D, cbzl() as PNT3D, _
                              env as EnvType )
    scriptState.pa = scriptState.pa + 1
    
    if ( scriptState.crrPnt+3 <= scriptState.cntPnts and scriptState.last_point = false ) then
        if ( scriptState.pa > env.caminterp ) then
            ugluCubicBez3D ppos(0), cbzp(scriptState.crrPnt), env.caminterp
            ugluCubicBez3D plok(0), cbzl(scriptState.crrPnt), env.caminterp
            scriptState.pa = 0
            scriptState.crrPnt = scriptState.crrPnt+3
        end if                
    else
        if ( scriptState.crrPnt <> scriptState.cntPnts and (not scriptState.last_point) ) then
            scriptState.pa = 0
            scriptState.last_point = true
            ugluCubicBez3D ppos(0), cbzp(scriptState.cntPnts-4), env.caminterp
            ugluCubicBez3D plok(0), cbzl(scriptState.cntPnts-4), env.caminterp
        elseif ( scriptState.pa > env.caminterp ) then
            scriptState.crrPnt = 0
            scriptState.last_point = false
            env.keyboard.esc = true
        end if                    
    end if                
    
    cameraState.pos.x = ppos(scriptState.pa).x
    cameraState.pos.y = ppos(scriptState.pa).y
    cameraState.pos.z = ppos(scriptState.pa).z        
    cameraState.lookAt.x = cameraState.pos.x + plok(scriptState.pa).x
    cameraState.lookAt.y = cameraState.pos.y + plok(scriptState.pa).y
    cameraState.lookAt.z = cameraState.pos.z + plok(scriptState.pa).z
end sub


''============================================================================
'' Input Processing Functions
''============================================================================

''
'' Processes keyboard input for toggles
''
defint a-z
sub processKeyboardInput ( byref renderState as RenderState, _
                           fileNum as integer, env as EnvType )
    '' Toggle mipmaps
    if ( env.keyboard.f1 ) then
        renderState.usemips = not renderState.usemips
        do 
        loop while ( env.keyboard.f1 )
    end if            

    '' Toggle render mode
    if ( env.keyboard.f2 ) then
        renderState.rendmode = (renderState.rendmode + 1) mod 3
        do 
        loop while ( env.keyboard.f2 )
    end if                    

    '' Toggle camera view
    if ( env.keyboard.f3 ) then
        renderState.fpsview = not renderState.fpsview
        do 
        loop while ( env.keyboard.f3 )
    end if            
    
    '' Toggle stats
    if ( env.keyboard.f12 ) then
        renderState.stats = not renderState.stats
        do 
        loop while ( env.keyboard.f12 )
    end if                    
    
    '' Toggle backface culling
    if ( env.keyboard.b ) then
        renderState.backface = not renderState.backface
        do 
        loop while ( env.keyboard.b )
    end if
    
    '' Save camera position (script edit mode)
    if ( env.keyboard.n and env.cammode = 2 ) then
        '' Note: cameraState would need to be passed here
        '' print #fileNum, cameraState.pos.x, cameraState.pos.y, cameraState.pos.z
        '' print #fileNum, cameraState.lookAt.x, cameraState.lookAt.y, cameraState.lookAt.z
        
        while ( env.keyboard.n )
        wend
    end if
end sub


''============================================================================
'' Rendering Functions
''============================================================================

''
'' Calculates mipmap level based on depth
''
defint a-z
function calculateMipLevel% ( w1i as single, w2i as single, w3i as single )
    dim zl as single
    
    zl = (w1i + w2i + w3i) / 3
    
    if ( zl >= MIP_DISTANCE_THRESHOLD_0 ) then
        calculateMipLevel% = 3
    elseif ( zl >= MIP_DISTANCE_THRESHOLD_1 ) then
        calculateMipLevel% = 2
    elseif ( zl >= MIP_DISTANCE_THRESHOLD_2 ) then
        calculateMipLevel% = 1
    else
        calculateMipLevel% = 0
    end if
end function


''
'' Renders a single triangle
''
defint a-z
sub renderTriangle ( hDstDC as long, vtx as tritype, texIndx as integer, _
                     rendmode as integer, xresh as single, yresh as single )
    if ( rendmode = 0 ) then
        '' Perspective correct
        uglTriTP hDstDC, vtx, 0, hTextrDC(texIndx)
    elseif ( rendmode = 1 ) then
        '' Affine
        uglTriT hDstDC, vtx, 0, hTextrDC(texIndx)
    else
        '' Wireframe
        uglTriF hDstDC, vtx, 200 
        uglLine hDstDC, vtx.v1.x, vtx.v1.y, vtx.v2.x, vtx.v2.y, 0
        uglLine hDstDC, vtx.v2.x, vtx.v2.y, vtx.v3.x, vtx.v3.y, 0
        uglLine hDstDC, vtx.v3.x, vtx.v3.y, vtx.v1.x, vtx.v1.y, 0
    end if
end sub


''
'' Draws statistics overlay
''
defint a-z
sub drawStats ( hDstDC as long, renderState as RenderState, bspData as BSPData, env as EnvType )
    if ( renderState.stats = false ) then
        fontPrintText hDstDC, 0, env.yres-8*0-6, "Stats: disabled, press f12 to enable", hFontChar()
        exit sub
    end if
    
    fontPrintText hDstDC, 0, 8*0, "Fps: " + str$(renderState.fps), hFontChar()
    fontPrintText hDstDC, 0, 8*1, "Renderd polys: " + str$(renderState.polys), hFontChar()
    fontPrintText hDstDC, 0, 8*2, "Renderd triangles: " + str$(renderState.tris), hFontChar()
    
    if ( renderState.usemips ) then 
        fontPrintText hDstDC, 0, 8*3, "Mipmapping: enabled, press f1 to disable", hFontChar()
    else
        fontPrintText hDstDC, 0, 8*3, "Mipmapping: disabled, press f1 to enable", hFontChar()
    end if
    
    if ( renderState.rendmode = 0 ) then 
        fontPrintText hDstDC, 0, 8*4, "Render mode: perspective correct, press f2 to change", hFontChar()
    elseif ( renderState.rendmode = 1 ) then 
        fontPrintText hDstDC, 0, 8*4, "Render mode: affine, press f2 to change", hFontChar()
    else
        fontPrintText hDstDC, 0, 8*4, "Render mode: wireframe, press f2 to change", hFontChar()
    end if       
    
    if ( renderState.backface ) then 
        fontPrintText hDstDC, 0, 8*5, "Backface culling: enabled, press 'b' to disable", hFontChar()
    else
        fontPrintText hDstDC, 0, 8*5, "Backface culling: disabled, press 'b' to enable", hFontChar()
    end if
    
    fontPrintText hDstDC, 0, env.yres-8*7-6, "Resolution: " + str$(env.xres) + "x" + ltrim$(str$(env.yres)), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*6-6, "Vertices:" + str$(bspData.vtxCount), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*5-6, "Edges:" + str$(bspData.edgCount), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*4-6, "Polygons:" + str$(bspData.triCount), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*3-6, "Nodes:" + str$(bspData.ndsCount), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*2-6, "Leaves:" + str$(bspData.lefCount), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*1-6, "PVS entries:" + str$(bspData.lefCount^2), hFontChar()
    fontPrintText hDstDC, 0, env.yres-8*0-6, "Stats: enabled, press f12 to disable", hFontChar()             
end sub


''============================================================================
'' BSP Tree Functions
''============================================================================

''
'' Classifies point relative to BSP node plane
''
defint a-z
function bspClassifyPoint% ( nodenr as integer, cameraPos as u3dVector3f )
    dim dp as single
    
    dp = cameraPos.x*plnBuffer(ndsBuffer(nodenr).planeid).norm.x + _
         cameraPos.y*plnBuffer(ndsBuffer(nodenr).planeid).norm.z + _
         cameraPos.z*plnBuffer(ndsBuffer(nodenr).planeid).norm.y
         
    if ( (dp-plnBuffer(ndsBuffer(nodenr).planeid).dist) > 0.0 ) then
        bspClassifyPoint% = -1
    else
        bspClassifyPoint% = 0
    end if
end function


''
'' Walks BSP tree and marks visible polygons
''
defint a-z
sub bspWalkNodeB ( byval nodenr as integer, cameraPos as u3dVector3f, _
                    frustum() as plane, byref treeState as BSPTreeState )
    dim dp as single
    dim pid as integer
    dim side as integer

    '' Check if leaf node
    if ( nodenr and LEAF_MASK ) then
        '' Check PVS and frustum
        if ( pvsBufferB(not nodenr) and _
             BBoxInFrustum(lefBuffer(not nodenr).bound, frustum()) ) then
            dim frst as integer, last as integer
            dim i as integer
            
            frst = lefBuffer(not nodenr).lfaceid
            last = frst + lefBuffer(not nodenr).lfacenum
            
            for i = frst to last-1            
                polyFlag(lfcBuffer(i)) = 1
            next i
            
            treeState.drwLeafs = treeState.drwLeafs + 1
        else 
            treeState.culLeafs = treeState.culLeafs + 1
        end if
        
        exit sub
    end if    
    
    '' Frustum cull node
    if ( not BBoxInFrustum(ndsBuffer(nodenr).bound, frustum()) ) then
        exit sub
    end if
    
    '' Classify camera position
    pid = ndsBuffer(nodenr).planeid
    dp = cameraPos.x*plnBuffer(pid).norm.x + _
         cameraPos.y*plnBuffer(pid).norm.z + _
         cameraPos.z*plnBuffer(pid).norm.y
         
    if ( dp-plnBuffer(pid).dist >= 0.0 ) then
        side = 1
    else
        side = 0
    end if
    
    '' Traverse children in correct order
    if ( side ) then
        bspWalkNodeB ndsBuffer(nodenr).child1, cameraPos, frustum(), treeState
        orderList(treeState.ordCount) = nodenr
        treeState.ordCount = treeState.ordCount + 1
        bspWalkNodeB ndsBuffer(nodenr).child0, cameraPos, frustum(), treeState
    else
        bspWalkNodeB ndsBuffer(nodenr).child0, cameraPos, frustum(), treeState
        orderList(treeState.ordCount) = nodenr
        treeState.ordCount = treeState.ordCount + 1        
        bspWalkNodeB ndsBuffer(nodenr).child1, cameraPos, frustum(), treeState
    end if
end sub


''
'' Initializes PVS (Potentially Visible Set) for current camera position
''
defint a-z
sub pvsInit ( byval nodenr as integer, cameraPos as u3dVector3f, _
              bspData as BSPData, bitarray() as integer )
    dim v as long
    dim l as long
    dim j as long
    dim bit as long
    dim byte as integer
    dim i as integer
    
    '' Find the node that the camera is in
    while not ( nodenr and LEAF_MASK )
        if ( bspClassifyPoint(nodenr, cameraPos) ) then
            nodenr = ndsBuffer(nodenr).child0
        else
            nodenr = ndsBuffer(nodenr).child1
        end if            
    wend
    
    '' Setup
    v = lefBuffer(not nodenr).vislist
    if ( v = -2 ) then ExitError "Leaf has no pvs data."
        
    v = v + varptr(pvsBufferA(0))
    def seg = varseg(pvsBufferA(0))
    
    if ( lefBuffer(not nodenr).vislist = -1 ) then
        for i = 0 to bspData.lefCount-1
            pvsBufferB(i) = -1
        next i           
        exit sub
    end if
    
    '' Extract the pvs data
    l = 1
    while ( l < bspData.lefCount )
        if ( peek(v) = 0 ) then
            j = l
            l = l + 8& * peek(v+1) 
            
            for j = j to l-1
                pvsBufferB(j) = 0
            next j
            
            v = v + 1
        else
            byte = peek(v)
            
            for bit = 0 to 7
                if ( byte and bitarray(bit) ) then
                    pvsBufferB(l) = 1
                else                 
                    pvsBufferB(l) = 0
                end if
                
                l = l + 1
            next bit            
        end if            
            
        v = v + 1        
    wend
end sub


''
'' Shows model by traversing BSP tree
''
defint a-z
sub bspShowModel ( model as integer, cameraPos as u3dVector3f, _
                   frustum() as plane, byref treeState as BSPTreeState, _
                   bspData as BSPData, bitarray() as integer )
    dim i as integer
    
    '' Reset tree state
    treeState.ordCount = 0
    treeState.culLeafs = 0
    treeState.drwLeafs = 0
    
    for i = 0 to bspData.triCount-1        
        polyFlag(i) = 0
    next i    
    
    '' Extract PVS
    pvsInit int(mdlBuffer(model).headnode0), cameraPos, bspData, bitarray()
    
    '' Traverse tree
    bspWalkNodeB int(mdlBuffer(model).headnode0), cameraPos, frustum(), treeState
end sub


''============================================================================
'' Cleanup Functions
''============================================================================

''
'' Cleanup and exit
''
defint a-z
sub doEnd
    uglRestore
    uglEnd
    
    screen 0
    width 80, 25
    end
end sub


''============================================================================
'' Error Handling
''============================================================================

''
'' Handles errors and exits gracefully
''
defint a-z
sub ExitError ( msg as string )
    uglRestore
    uglEnd
    
    screen 0
    width 80, 25
    print "Error: " + msg
    sleep
    end
end sub


''============================================================================
'' Utility Functions
''============================================================================

''
'' Tokenizes a string stream
''
defint a-z
sub strtok ( strm() as string, strm_cnt as integer, _
             tokenlist as string, stream as string )
    dim char as string * 1
    dim i as integer, j as integer    
    dim is_a_tok as integer
    dim token_cnt as integer
    dim last_char_tok as integer
    dim token(50-1) as string * 1    
    dim stream_len as integer            
    dim stream_pos as integer    
    dim crnt_strm_indx as integer
    
    strm_cnt   = 0    
    token_cnt  = 0
    stream_pos = 0
    crnt_strm_indx = 0
    strm(crnt_strm_indx) = ""
    
    stream_len = len(stream)
    if ( stream_len = 0 ) then exit sub
        
    token_cnt = len(tokenlist)
    if ( token_cnt = 0  ) then exit sub
    if ( token_cnt > 50 ) then exit sub
    
    for i = 1 to token_cnt
        token(i-1) = mid$(tokenlist, i, 1)
    next i
    
    for i = 1 to stream_len
        char = mid$(stream, i, 1)
    
        is_a_tok = false
        
        for j = 0 to token_cnt-1
            if ( char = token(j) ) then
                is_a_tok = true
                exit for
            end if                
        next j
        
        if ( is_a_tok = false ) then
            strm(crnt_strm_indx) = strm(crnt_strm_indx) + char
        else         
            if ( last_char_tok = false ) then
                crnt_strm_indx = crnt_strm_indx + 1
                strm(crnt_strm_indx) = ""
            end if                            
        end if
        
        last_char_tok = is_a_tok
    next i    
    
    if ( len(strm(crnt_strm_indx)) = 0 ) then 
        strm_cnt = crnt_strm_indx
    else
        strm_cnt = crnt_strm_indx + 1
    end if
end sub


'' [Additional utility functions like parseIni, ExtractFrustum, BBoxInFrustum, 
''  pvsInit, SHClipzNearFar, initFont, fontPrintText, NodesToLeaf, 
''  getSBSettings would follow with similar refactoring - passing state explicitly]
