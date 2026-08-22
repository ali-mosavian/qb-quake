option explicit
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
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_snd.bi'



'' Startup-only state. These were locals of the 700 line doInit; splitting it
'' into one routine per step is what promoted them, and they stay out of the
'' frame path entirely.
'' texiCount was the one lump count never declared shared. Inside the old
'' monolithic doInit that did not matter; once bspOpen and bspAlloc were
'' separate routines, bspAlloc read 0 and did redim texInfBuff(-1).
dim shared cam_up as u3dVector3f    

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
'' fps1 counts frames within the current second. It used to live in
'' doMain's frame loop, where one invocation kept it across frames;
'' presentFrame is entered per frame, so as a local it reset to 0 every
'' time and the counter read 1 forever.
'' screenie was undeclared, so it was a fresh integer 0 on every entry to
'' presentFrame and every screenshot overwrote scrn0.bmp.

'' pal is loaded by texLoadAll (which needs its segment and offset to
'' colour match) and consumed by videoOpen, which sets it as the hardware
'' palette and frees it. Those were one scope inside the old monolithic
'' doInit; splitting doInit apart left videoOpen reading an undeclared 0.

    ''
    '' This was `on errror goto HandleErr` for years -- three r's. BASIC
    '' also has a computed ON n GOTO, so the typo parsed as "branch to the
    '' zeroth label" and silently fell through: runtime error trapping had
    '' never worked. OPTION EXPLICIT turns that same typo into a hard compile
    '' error instead of a silent no-op, which is what actually surfaced it.
    ''
    on error goto HandleErr
    
        
    '':::::
    
    host_init 
    host_main   
    host_shutdown
    
    
HandleErr:    
    sys_error "0x1000, Unknown runtime error..."



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
sub host_init
    ''
    '' Load profiling. A 1 kHz AUTOINIT timer counts milliseconds, and the
    '' phase boundaries below are recorded so load time can be attributed
    '' rather than guessed -- twice now a bottleneck has been asserted from
    '' the shape of the code and been wrong.
    ''
    dim t_start as single, t_sub as single, t_map as single
    dim t_lump as single, t_tex as single, t_vid as single
    dim pf as integer

    '' TIMER, not a TMR: tmrInit does not run until inputOpen, the
    '' second-to-last step below, so a TMR counter reads zero for almost
    '' the whole load. TIMER is ~55ms granular, which is fine for phases
    '' measured in seconds.
    t_start = timer

    '' arguments and subsystems
    sys_parse_args
    sys_init_tables
    vid_init_ugl
    s_init
    s_start_music
    draw_init_font

    '' map file and the loading screen
    t_sub = timer

    mod_open
    scr_begin_loading
    mod_find_spawn
    mod_alloc

    t_map = timer

    '' level lumps
    mod_load_vertexes
    mod_load_faces
    mod_load_edges
    mod_load_surfedges
    mod_load_leafs
    mod_load_marksurfaces
    mod_load_nodes
    mod_load_planes
    mod_load_submodels
    mod_load_visibility

    t_lump = timer

    '' textures and palette
    mod_load_texinfo
    mod_load_textures
    mod_close

    t_tex = timer

    '' hand over to the real video mode
    vid_init
    in_init
    s_stop_music

    t_vid = timer

    if ( env.bench_frames > 0 ) then
    pf = freefile
    open "load.txt" for output as #pf
    print #pf, "subsystems " + ltrim$(str$( t_sub  - t_start ))
    print #pf, "mapopen    " + ltrim$(str$( t_map  - t_sub   ))
    print #pf, "lumps      " + ltrim$(str$( t_lump - t_map   ))
    print #pf, "textures   " + ltrim$(str$( t_tex  - t_lump  ))
    print #pf, "video      " + ltrim$(str$( t_vid  - t_tex   ))
    print #pf, "total      " + ltrim$(str$( t_vid  - t_start ))
    close #pf
    end if

end sub





''::::
defint a-z
sub host_main
    dim mtx_mdl as u3dMtrx
    dim mtx_prj as u3dMtrx
    dim mtx_fin as u3dMtrx
    
    dim ppos(env.caminterp) as PNT3D
    dim plok(env.caminterp) as PNT3D
    dim cbzp(10) as PNT3D
    dim cbzl(10) as PNT3D
    
    dim h_dst_dc as long
    dim pa as integer
    dim crr_pnt as integer
    dim cnt_pnts as integer
    dim xresh as single, yresh as single
    
    dim i as integer
    dim hz as long
    dim last_point as integer
    dim page as integer
    dim frame_no as long
    dim benchf as integer
    
    ''
    '' min/max/bmin/bmax/extn went with the lightmap extent computation in
    '' the draw loop, which produced values nothing read.
    ''
    dim polyvert as integer
    ''
    '' Per-face texture axes with the texture size folded in, and the
    '' per-vertex projection the triangle fan shares. See the draw loop.
    ''
    dim cam_pos_b as u3dVector3f
    
    
    xresh = env.x_res/2.0
    yresh = env.y_res/2.0

    mousePos 0, 0


    cam_up.x = 0.0
    cam_up.y = 1.0
    cam_up.z = 0.0   
    
    mousePos (env.x_res-1) * cam.start_angle/360.0, 110
    
    

    
    if ( env.cammode = 1 ) then
        cam.script_file = freefile
        open env.camscrpt for input as #cam.script_file    
        do 
            input #cam.script_file, cbzp(i).x, cbzp(i).y, cbzp(i).z
            input #cam.script_file, cbzl(i).x, cbzl(i).y, cbzl(i).z
            i = i + 1
        loop until ( eof( 1 ) )    
        close #cam.script_file
        cam.script_file = 0
        cnt_pnts = i-1
                
        ugluCubicBez3D ppos(0), cbzp(crr_pnt), env.caminterp
        ugluCubicBez3D plok(0), cbzl(crr_pnt), env.caminterp
        crr_pnt = crr_pnt + 3
    end if        
    
    if ( env.cammode = 2 ) then
        cam.script_file = freefile
        open env.camscrpt for output as #cam.script_file
    end if
    
    
    
    hz& = tmrMs2Freq&( 1000 )
    tmrNew env.sec_timer, TMR.AUTOINIT, hz&    
    
    if ( env.usepag = false ) then
        h_dst_dc = env.h_back_bdc
    else        
        h_dst_dc = env.h_video_dc
    end if        
    
    u3dMtrxPersp mtx_prj, env.camfov, 320.0/240.0, env.z_near, env.z_far
    
    rdr.usemips = -1
    rdr.rendmode = 0
    cam.fpsview = -1
    scr.stats    = -1
    
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
            uglClear h_dst_dc, 0
        end if 
        
        v_update_camera pa, crr_pnt, cnt_pnts, ppos(), plok(), cbzp(), cbzl(), last_point

        in_handle_toggles

        ''
        '' Combine all transforms 
        ''
        u3dMtrxLookAt mtx_mdl, cam.pos, cam.look_at, cam_up        
        u3dMtrxConc mtx_fin, mtx_mdl, mtx_prj
        r_set_frustum frustum(), mtx_fin
        

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
        if ( cam.fpsview = false ) then 
            cam_pos_b.x = 351.0
            cam_pos_b.y = 2119.0
            cam_pos_b.z = -552.0            
                        
            cam.look_at.x = cam_pos_b.x + 1.991367e-8
            cam.look_at.y = cam_pos_b.y + -1.0
            cam.look_at.z = cam_pos_b.z + 1.570986e-2
        else
            cam_pos_b.x = cam.pos.x
            cam_pos_b.y = cam.pos.y
            cam_pos_b.z = cam.pos.z
        end if
        
        '        
        u3dMtrxLookAt mtx_mdl, cam_pos_b, cam.look_at, cam_up        
        u3dMtrxConc mtx_fin, mtx_mdl, mtx_prj
        
        
        ''
        '' Walk BSP tree
        ''
        r_draw_world 0
        
        
        d_draw_faces h_dst_dc, mtx_fin, xresh, yresh


        
        scr_draw_hud h_dst_dc
            
        
        ''
        '' Benchmark mode: a fixed frame budget makes a run repeatable and
        '' headless. Without it verification needs a live debugger socket to
        '' drive a screenshot, and an identical picture cannot tell a working
        '' build from one that never rebuilt -- the frame count and fps here
        '' can.
        ''
        frame_no = frame_no + 1
        if ( env.bench_frames > 0 and frame_no >= env.bench_frames ) then
            scr_screenshot "bench.bmp", h_dst_dc
            benchf = freefile
            open "bench.txt" for output as #benchf
            print #benchf, "frames " + ltrim$(str$( frame_no ))
            print #benchf, "seconds " + ltrim$(str$( scr.bench_secs ))
            print #benchf, "lastfps " + ltrim$(str$( scr.fps ))
            print #benchf, "polys " + ltrim$(str$( rdr.polys ))
            print #benchf, "tris " + ltrim$(str$( rdr.tris ))
            close #benchf
            exit do
        end if

        in_screenshot_key h_dst_dc
        vid_update h_dst_dc, page
        scr_count_frame

    loop while ( env.keyboard.esc = FALSE )
    
    tmrDel env.sec_timer
    if ( cam.script_file <> 0 ) then close #cam.script_file

end sub


''::::
defint a-z
sub host_shutdown
    
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
sub sys_error ( msg as string )
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
