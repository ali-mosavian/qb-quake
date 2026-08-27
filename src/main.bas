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
'$include: 'q_pl.bi'
'$include: 'q_map.bi'
'$include: 'q_ent.bi'
Declare Sub cp_load ( )
Declare Sub cp_advance ( )

''
'' Simulation time owed but not yet run. Frames deliver time in whatever
'' irregular amounts the renderer manages; the simulation spends it in equal
'' HOST_DT pieces, and whatever is left over waits here for the next frame.
''
dim shared host_accum as single
dim shared host_ticks as long          '' steps run, for the benchmark
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
'' THE DEPTH BUFFER. Created here, alongside the destination dc it belongs
'' to. d_poly is the only other module that cares, and only to ask whether
'' depth exists at all -- host_z_on answers that.
''
dim shared z_dc as long

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
    dim ef as integer, mi as integer

    on error goto HandleErr
    
        
    '':::::
    
    host_init 
    if ( env.dump_set ) then
        sb_dump env.dump_face, env.dump_mip
    else
        host_main
    end if
    host_shutdown
    
    
HandleErr:
    ''
    '' ERR and ERL, not just "something went wrong". ERR names the fault --
    '' 7 is out of memory, 9 subscript out of range, 5 illegal call -- and
    '' with the memory trace beside it that is usually enough to say which
    '' buffer would not fit, without a debugger and without another build.
    ''
    ef = freefile
    open "errmem.txt" for output as #ef
    print #ef, "err " + ltrim$(str$( err )) + " erl " + ltrim$(str$( erl ))
    for mi = 0 to sys_mem_count-1
        print #ef, "mem " + sys_mem_tag(mi) + " " + ltrim$(str$( sys_mem_fre(mi) ))
    next mi
    close #ef

    sys_error "0x1000, runtime error" + str$( err ) + " at line" + str$( erl )



''::::
'' ==========================================================================
''  STARTUP
'' ==========================================================================
''::::::::::
'' name: host_init
'' desc: Startup, in order. Every step below runs exactly once, so each is
''       its own routine -- the call costs nothing here and the sequence
''       reads as the list of things that have to be true before the first
''       frame. Contrast bspDrawFaces, which is one routine on purpose.
''::::::::::
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
    sys_mem_mark "start"
    d_init_turb
    vid_init_ugl
    sys_mem_mark "ugl"
    s_init
    s_start_music
    draw_init_font
    sys_mem_mark "font"

    '' map file and the loading screen
    t_sub = timer

    mod_open
    sys_mem_mark "mapopen"
    scr_begin_loading
    mod_find_spawn
    pl_init pl, cam, env
    mod_alloc
    sys_mem_mark "bsparrays"

    t_map = timer


    '' level lumps
    mod_load_faces
    mod_load_lightmaps
    sys_mem_mark "lmtable"
    mod_load_facevtx
    mod_load_leafs
    mod_load_marksurfaces
    mod_load_nodes
    mod_load_planes
    mod_load_submodels
    mod_load_visibility
    mod_load_clipnodes
    sys_mem_mark "clipnodes"
    ent_load_teleports wld, mdl_buffer()

    t_lump = timer

    '' textures and palette
    mod_load_texinfo
    mod_load_textures
    sys_mem_mark "textures"
    mod_close
    sys_mem_mark "mapclose"

    sc_init
    sys_mem_mark "surfcache"

    t_tex = timer

    '' hand over to the real video mode
    vid_init
    sys_mem_mark "backbuf"
    in_init
    s_stop_music

    '' After the mode switch, deliberately. vid_init needs a sizeable
    '' block for the video DC, and holding the colormap's 16K across it
    '' left it short -- the program wedged inside vid_init with no error,
    '' having got all the way through loading. Nothing needs the table
    '' until the first surface is built.
    if ( env.use_lm ) then mod_load_colormap
    sys_mem_mark "colormap"

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
sub host_main
    dim mtx_prj as u3dMtrx
    
    
    dim h_dst_dc as long
    dim xresh as single, yresh as single
    
    dim i as integer
    dim hz as long
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
    
    
    xresh = env.x_res/2.0
    yresh = env.y_res/2.0

    mousePos 0, 0


    cam_up.x = 0.0
    cam_up.y = 1.0
    cam_up.z = 0.0   
    
    if ( env.yaw_set ) then cam.start_angle = env.start_yaw
    mousePos (env.x_res-1) * cam.start_angle/360.0, 110
    
    

    
    v_open_script
    
    
    
    
    dim zz as long                  '' soaks up uglZScale/uglZMode's
                                    '' return; the call is the point
    hz = tmrMs2Freq&( 1000 )
    tmrNew env.sec_timer, TMR.AUTOINIT, hz    
    
    if ( env.usepag = false ) then
        h_dst_dc = env.h_back_bdc
    else        
        h_dst_dc = env.h_video_dc
    end if        
    
    u3dMtrxPersp mtx_prj, env.camfov, 320.0/240.0, env.z_near, env.z_far

    ''
    '' Depth buffer, matching the destination. EMS: 320x200 of depth is
    '' 128,000 bytes and conventional memory has nothing like that spare.
    ''
    '' The scale maps 1/z into 16 bits. 1/z is largest at the near plane,
    '' so 65535 * z_near puts the nearest thing drawn at the top of the
    '' range; anything closer would saturate, and nothing is, because the
    '' clipper drops it first.
    ''
    z_dc = 0
    if ( env.no_z = 0 ) then z_dc = uglNewZ&( h_dst_dc, UGL.EMS% )
    if ( z_dc <> 0 ) then
        uglSetZ z_dc
        zz = uglZScale&( 65535.0 * env.z_near )
    end if
    
    rdr.usemips = -1
    '' follows -lm: with no lightmap data loaded there is nothing to toggle
    rdr.lightmap = env.use_lm
    rdr.rendmode = 0
    cam.fpsview = -1
    ''
    '' On by default. The cull is a single sign test against the face's own
    '' plane, and a sealed level cannot show a back face, so enabling it must
    '' leave the image untouched while the polygon count falls.
    ''
    rdr.backface = -1
    scr.stats    = -1
    if ( env.no_stats ) then scr.stats = 0

    redim cp_x(CP_MAX) as integer
    redim cp_y(CP_MAX) as integer
    redim cp_z(CP_MAX) as integer
    if ( env.campath ) then cp_load
    vis.bad_order = env.bad_order
    vis.no_ents   = env.no_ents
    
    if ( env.sound = true ) then
        modPlay mymod
    end if
    
    
    ''
    ''
    ''
    sys_time_init

    do
    	''
    	'' Clear DC
    	''
        if ( env.disclear = true ) then
            uglClear h_dst_dc, 0
        end if

        ''
        '' Measured once, at the top of the frame, and used by everything that
        '' moves. Every such update multiplies by it, so the game plays the
        '' same whether it runs at 15 fps or 60.
        ''
        scr.frame_time = sys_frame_time

        '' Skip the first few frames: they carry the tail of loading and
        '' the first surface builds, which no later frame repeats.
        if ( frame_no > 3 and sys_raw_dt > 0.0 ) then
            if ( ft_n = 0 ) then
                ft_min = sys_raw_dt
                ft_max = sys_raw_dt
            else
                if ( sys_raw_dt < ft_min ) then ft_min = sys_raw_dt
                if ( sys_raw_dt > ft_max ) then ft_max = sys_raw_dt
            end if
            ft_sum = ft_sum + sys_raw_dt
            ft_n   = ft_n + 1
        end if

        host_advance scr.frame_time

        '' cp_advance is called from view.bas now, where the movement
        '' input is assembled -- it steers the player rather than placing
        '' the camera.

        ''
        '' Combine all transforms
        ''
        host_render h_dst_dc, mtx_prj, xresh, yresh


        ''
        '' Benchmark mode: a fixed frame budget makes a run repeatable and
        '' headless. Without it verification needs a live debugger socket to
        '' drive a screenshot, and an identical picture cannot tell a working
        '' build from one that never rebuilt -- the frame count and fps here
        '' can.
        ''
        frame_no = frame_no + 1
        '' -campath ends when the route does, whatever -bench says
        if ( env.campath and cp_done ) then
            host_bench_report frame_no, h_dst_dc
            exit do
        end if
        if ( env.bench_ticks > 0 and host_ticks >= env.bench_ticks ) then
            host_bench_report frame_no, h_dst_dc
            exit do
        end if
        if ( env.bench_frames > 0 and frame_no >= env.bench_frames ) then
            host_bench_report frame_no, h_dst_dc
            exit do
        end if

        in_screenshot_key h_dst_dc
        vid_update h_dst_dc, page
        scr_count_frame

        ''
        '' -benchsecs: a wall-clock budget instead of a frame/tick count, for
        '' fast iteration. scr.bench_secs is ticked once per real second by
        '' scr_count_frame just above, so this must run after it.
        ''
        if ( env.bench_secs > 0 and scr.bench_secs >= env.bench_secs ) then
            host_bench_report frame_no, h_dst_dc
            exit do
        end if

    loop while ( env.keyboard.esc = FALSE )
    
    tmrDel env.sec_timer
    if ( cam.script_file <> 0 ) then close #cam.script_file

end sub


''::::
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


''::::::::::
'' name: cp_load
'' desc: Reads campath.bin, the A* flight path tools/campath.py builds over
''       the map's EMPTY leaves. Water, slime and lava are excluded there,
''       not here -- a path through lava would time the warp and the
''       palette flash rather than the renderer.
''::::::::::
sub cp_load
    dim f as integer
    dim i as integer, n as integer
    dim x as integer, y as integer, z as integer

    cp_n = 0
    cp_i = 0
    cp_t = 0.0

    f = freefile
    open "campath.bin" for binary as #f
    if ( lof(f) < 8 ) then
        close #f
        exit sub
    end if
    get #f, , n
    if ( n > CP_MAX ) then n = CP_MAX
    for i = 0 to n-1
        get #f, , x
        get #f, , y
        get #f, , z
        cp_x(i) = x
        cp_y(i) = y
        cp_z(i) = z
    next i
    close #f
    cp_n = n
end sub

''::::::::::
'' name: cp_advance
'' desc: Steps the camera along the path by a FIXED amount per frame.
''
''       Per frame, not per second, deliberately. Both builds then render
''       the identical sequence of viewpoints, so frames, peak and low
''       compare the renderer instead of how far a quicker build managed
''       to travel in the same wall time.
''::::::::::
sub cp_advance
    dim dx as single, dy as single, dl as single
    dim k as integer, best as integer
    dim bestd as single

    ''
    '' STEERING, not positioning. The camera used to be placed on the path
    '' directly, which flew it through walls -- an exact BSP point test put
    '' 36% of the route inside solid -- and ignored gravity and the player
    '' hull entirely.
    ''
    '' Now the path only says WHERE TO WALK. pl_move does the moving, so
    '' collision, gravity, step-up and the 32x32x56 hull are the game's own
    '' code rather than something approximated here. A route the player
    '' cannot walk simply does not get walked.
    ''
    if ( cp_n < 1 or cp_done ) then exit sub

    ''
    '' Start ON the route. The spawn is wherever the map puts it, and
    '' waypoint 0 is at one extreme of the level -- so from the spawn the
    '' steering aimed at a target most of a map away and walked straight
    '' into the first wall between. Every waypoint is a verified standing
    '' position, so dropping the player on one is safe; gravity settles it.
    ''
    if ( cp_init = 0 ) then
        pl.pos.x = cp_x(0)
        pl.pos.y = cp_y(0)
        pl.pos.z = cp_z(0)
        pl.vel.x = 0.0
        pl.vel.y = 0.0
        pl.vel.z = 0.0
        cp_i     = 1
        cp_lastx = pl.pos.x
        cp_lasty = pl.pos.y
        cp_init  = -1
        exit sub
    end if

    ''
    '' Advance by PROGRESS, not proximity. Steering 64 units ahead means
    '' the player walks past a waypoint without ever coming within the
    '' reach radius of it -- so a proximity test never fires, the index
    '' never moves, and the walk circles that point forever. That is the
    '' spinning.
    ''
    '' Instead: slide the index forward to the nearest waypoint in a short
    '' window ahead. Monotonic, so it can never run backwards and oscillate.
    ''
    best  = cp_i
    bestd = 1e30
    k = cp_i
    do while ( k <= cp_i + 12 and k <= cp_n-1 )
        dx = cp_x(k) - pl.pos.x
        dy = cp_y(k) - pl.pos.y
        dl = dx*dx + dy*dy
        if ( dl < bestd ) then
            bestd = dl
            best  = k
        end if
        k = k + 1
    loop
    cp_i = best

    '' done when the last waypoint is the nearest and we are on it
    if ( cp_i >= cp_n-1 ) then
        dx = cp_x(cp_n-1) - pl.pos.x
        dy = cp_y(cp_n-1) - pl.pos.y
        if ( sqr( dx*dx + dy*dy ) < CP_REACH * 2.0 ) then
            cp_done = -1
            exit sub
        end if
    end if

    ''
    '' Pure pursuit: aim at the first waypoint at least CP_AHEAD away,
    '' not at the one we are about to reach. A near target's bearing
    '' swings wildly as it is approached; a far one's barely moves.
    ''
    k = cp_i
    do while ( k < cp_n-1 )
        dx = cp_x(k) - pl.pos.x
        dy = cp_y(k) - pl.pos.y
        if ( sqr( dx*dx + dy*dy ) >= CP_AHEAD ) then exit do
        k = k + 1
    loop
    dx = cp_x(k) - pl.pos.x
    dy = cp_y(k) - pl.pos.y
    dl = sqr( dx*dx + dy*dy )

    if ( dl > 0.001 ) then
        cp_dirx = dx / dl
        cp_diry = dy / dl
    end if

    '' Stuck? The hull is against something the path did not know about.
    '' Give up on this waypoint rather than grinding into a wall forever.
    if ( abs(pl.pos.x - cp_lastx) + abs(pl.pos.y - cp_lasty) < 0.5 ) then
        cp_stuck = cp_stuck + 1
        if ( cp_stuck > 60 ) then
            cp_stuck = 0
            cp_i = cp_i + 1
            if ( cp_i > cp_n-1 ) then cp_done = -1
        end if
    else
        cp_stuck = 0
    end if
    cp_lastx = pl.pos.x
    cp_lasty = pl.pos.y
end sub

''::::::::::
'' name: host_advance
'' desc: Spends a frame's worth of real time on whole simulation steps.
''
''       The renderer's frame time varies with what is on screen. Feeding
''       it straight to the physics made every result depend on the
''       framerate: the same walk integrated in a few long steps at 12 fps
''       and many short ones at 45, and the two drifted apart because a
''       long step overshoots a wall that a short one stops against.
''
''       Now every step is HOST_DT regardless, and the remainder is
''       carried. Physics sees a constant rate; only how many steps a
''       frame runs varies.
''::::::::::
sub host_advance ( byval real_dt as single )
    dim steps as integer

    host_accum = host_accum + real_dt

    steps = 0
    do while ( host_accum >= HOST_DT# and steps < HOST_MAXSTEPS )
        host_tick HOST_DT#
        host_accum = host_accum - HOST_DT#
        host_ticks = host_ticks + 1
        steps = steps + 1
    loop

    ''
    '' Still behind after the cap: give up on the backlog rather than
    '' carry it into the next frame, where it would only grow.
    ''
    if ( host_accum > HOST_DT# ) then host_accum = 0.0

end sub




''::::::::::
'' name: host_tick
'' desc: One simulation step. Everything that changes the world in response
''       to time or input happens here, and nothing here draws.
''
''       dt is a parameter rather than a global read so that the step is
''       explicit at the call site: this is the one number that decides how
''       far the world moves, and a caller can pass a different one -- a
''       fixed step, a halved step for a sub-tick -- without the routine
''       knowing or caring.
''::::::::::
sub host_tick ( byval dt as single )

    '' what the player asked for
    in_handle_toggles

    '' and what the world does about it: camera, and the physics under it
    v_update_camera dt

    '' and anything the world does to the player as a result of moving
    ent_check_teleport pl, env

    '' movers, after the player has moved and before anything is drawn
    ent_move_plats dt, pl

    '' where each mover ended up, so the draw order can place it
    ent_place_models wld.mdl_count, mdl_buffer(), nds_buffer(), pln_buffer()

    '' map time, which drives every texture animation
    rdr.anim_time = rdr.anim_time + dt

end sub




''::::::::::
'' name: host_render
'' desc: One frame's drawing. Reads the world, changes none of it -- the
''       counterpart to host_tick, which changes it and draws none of it.
''::::::::::
sub host_render ( _
    byval h_dst_dc as long, _
    mtx_prj as u3dMtrx, _
    byval xresh as single, _
    byval yresh as single _
)
    dim mtx_mdl as u3dMtrx
    dim zz as long                  '' soaks up uglZMode's return;
                                    '' the call is the point
    dim mtx_fin as u3dMtrx
    dim cam_pos_b as u3dVector3f
    dim bm as integer

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

    
    
    ''
    '' Clear to the far plane before the frame. Depth is 1/z and larger is
    '' nearer, so zero is infinitely distant and the first surface to
    '' cover a pixel always wins.
    ''
    if ( z_dc <> 0 ) then uglClearZ z_dc, 0

    '' -nodraw stops HERE: the walk above has run and filled order_list,
    '' so everything the node paging touches has happened. What is skipped
    '' is fill, which paging does not affect.
    if ( env.no_draw ) then exit sub

    d_draw_faces h_dst_dc, mtx_fin, xresh, yresh

    '' leave depth off for the overlay, which is 2D and would otherwise
    '' test itself against the scene it is drawn on top of
    if ( z_dc <> 0 ) then zz = uglZMode%( UGL.Z.OFF% )


    
    scr_draw_hud h_dst_dc

end sub




''::::::::::
'' name: host_bench_report
'' desc: Writes bench.bmp and bench.txt at the end of a -bench run.
''
''       Called before vid_update, so the counters are still the frame's
''       own -- scr_count_frame clears them -- and h_dst_dc still holds
''       the finished image.
''::::::::::
sub host_bench_report ( _
    frame_no as long, _
    h_dst_dc as long _
)
    dim scs as CacheStats
    dim dv as long
    dim df as long
    dim ddv as long
    dim ddf as long
    dim mi as integer
    dim benchf as integer

    scr_screenshot "bench.bmp", h_dst_dc

    benchf = freefile
    open "bench.txt" for output as #benchf
    print #benchf, "frames " + ltrim$(str$( frame_no ))
    print #benchf, "seconds " + ltrim$(str$( scr.bench_secs ))
    print #benchf, "lastfps " + ltrim$(str$( scr.fps ))
    print #benchf, "peakfps " + ltrim$(str$( scr.fps_peak ))
    print #benchf, "lowfps " + ltrim$(str$( fps_low ))
    print #benchf, "cppts " + ltrim$(str$( cp_n ))
    ''
    '' Frame times in milliseconds, and the rates they imply. These are the
    '' numbers to compare: fastest frame, slowest frame, mean over the run.
    ''
    if ( ft_n > 0 ) then
        print #benchf, "ftmin " + ltrim$(str$( ft_min * 1000.0 ))
        print #benchf, "ftmax " + ltrim$(str$( ft_max * 1000.0 ))
        print #benchf, "ftmean " + ltrim$(str$( (ft_sum / ft_n) * 1000.0 ))
        print #benchf, "ftn " + ltrim$(str$( ft_n ))
        if ( ft_min > 0.0 ) then _
            print #benchf, "fpsbest " + ltrim$(str$( 1.0 / ft_min ))
        if ( ft_max > 0.0 ) then _
            print #benchf, "fpsworst " + ltrim$(str$( 1.0 / ft_max ))
        if ( ft_sum > 0.0 ) then _
            print #benchf, "fpsmean " + ltrim$(str$( ft_n / ft_sum ))
    end if
    print #benchf, "polys " + ltrim$(str$( rdr.polys ))
    print #benchf, "tris " + ltrim$(str$( rdr.tris ))
    print #benchf, "px " + ltrim$(str$( pl.pos.x ))
    print #benchf, "py " + ltrim$(str$( pl.pos.y ))
    print #benchf, "pz " + ltrim$(str$( pl.pos.z ))
    print #benchf, "onground " + ltrim$(str$( pl.on_ground ))
    print #benchf, "vz " + ltrim$(str$( pl.vel.z ))
    print #benchf, "dt " + ltrim$(str$( scr.frame_time ))
    print #benchf, "tickhz " + ltrim$(str$( sys_tick_hz ))
    print #benchf, "memavail " + ltrim$(str$( memAvail& ))
    print #benchf, "lmsize " + ltrim$(str$( mod_lm_bytes ))
    print #benchf, "lmread " + ltrim$(str$( mod_lm_got ))
    print #benchf, "geomrows " + ltrim$(str$( mod_geom_rows ))
    print #benchf, "cmsize " + ltrim$(str$( mod_cm_bytes ))
        sc_stats scs
    print #benchf, "scmade " + ltrim$(str$( scs.made ))
    print #benchf, "scems " + ltrim$(str$( scs.peak ))
    ''
    '' Cache behaviour. scworst is the most surfaces built in any ONE
    '' frame, which is what a hitch is made of -- a run-wide total says
    '' nothing about whether they arrived together or spread out.
    ''
    print #benchf, "scbuilt " + ltrim$(str$( scs.tbuilds ))
    print #benchf, "scworst " + ltrim$(str$( scs.bpeak ))
    print #benchf, "sclive " + ltrim$(str$( scs.live ))
    print #benchf, "scevict " + ltrim$(str$( scs.evict ))
    print #benchf, "scflush " + ltrim$(str$( scs.flushes ))
    print #benchf, "sctest " + ltrim$(str$( sc_selftest ))
    print #benchf, "peakz " + ltrim$(str$( pl.peak_z ))
    print #benchf, "ticks " + ltrim$(str$( host_ticks ))
    ''
    '' Where conventional memory went. Deltas, not absolutes: what matters
    '' is which stage took the bite, and a running total drifts with DOS's
    '' own overhead between the marks.
    ''
    for mi = 0 to sys_mem_count-1
        dv = sys_mem_val(mi)
        df = sys_mem_fre(mi)
        if ( mi = 0 ) then
            ddv = 0
            ddf = 0
        else
            ddv = sys_mem_val(mi-1) - dv
            ddf = sys_mem_fre(mi-1) - df
        end if
        print #benchf, "mem " + sys_mem_tag(mi) + _
                       " " + ltrim$(str$( dv )) + " " + ltrim$(str$( ddv )) + _
                       " " + ltrim$(str$( df )) + " " + ltrim$(str$( ddf ))
    next mi
    print #benchf, "clprec " + ltrim$(str$( pl_hull_rec ))
    print #benchf, "clpcnt " + ltrim$(str$( wld.clp_count ))
    print #benchf, "waterlevel " + ltrim$(str$( pl.water_level ))
    print #benchf, "watertype " + ltrim$(str$( pl.water_type ))
    print #benchf, "animtime " + ltrim$(str$( rdr.anim_time ))
    if ( plat_count > 0 ) then
        print #benchf, "platzofs " + ltrim$(str$( brush( plat(0).model ).zofs ))
        print #benchf, "platstate " + ltrim$(str$( plat(0).state ))
    end if
    close #benchf

end sub

''::::::::::
'' name: host_z_on
'' desc: Whether a depth buffer exists. main.bas creates it, so it answers
''       for it; d_poly hoists this once a frame rather than testing a
''       shared handle per face.
''::::::::::
function host_z_on ( ) as integer
    host_z_on = ( z_dc <> 0 )
end function
