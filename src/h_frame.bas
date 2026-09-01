option explicit
''
'' h_frame.bas -- one frame's simulation step and one frame's drawing.
'' Split out of main.bas: host_advance/host_tick/host_render do not
'' need to live in the module that owns doInit/doMain/doEnd just
'' because host_main calls them, and main.bas was headed toward BC's
'' own compile-time memory ceiling regardless -- see h_bench.bas's own
'' header for that half of the story.
''
'' host_accum and host_ticks are main.bas's own state (dim shared
'' there), passed byref rather than reached for: host_advance both
'' reads and updates them every call. cam_up and z_dc are likewise
'' main.bas's, passed into host_render -- the first byref (never
'' written here, but a UDT, and this project passes those byref
'' throughout rather than by value), the second byval since a plain
'' long read-only is simplest passed that way.
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

dim shared lm_want_dbg as integer
dim shared lm_fall_dbg as integer
dim shared k_mip_dbg as long, k_sw_dbg as long
dim shared k_sh_dbg as long, k_stag_dbg as long
dim shared k_n_dbg as long
dim shared k_hdr_dbg as long, k_ext_dbg as long
dim shared k_v0_dbg as long, k_lm_dbg as long

const DL_RADIUS# = 200.0#   '' Quake's own rocket dlight radius

'' This module's own procedures -- host_advance calls host_tick before
'' its definition appears below, so it needs a forward declare same as
'' any cross-module call would.
declare sub host_tick ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    tele() as Teleporter, _
    plat() as PlatEnt _
)

'' Declared here, not in a header: this module is the only caller of
'' each, matching main.bas's own stated reason for doing the same.
declare sub ent_place_models ( _
    byval model_count as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
)
declare sub ent_check_teleport ( _
    g as Game, _
    tele() as Teleporter _
)
declare sub ent_move_plats ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    plat() as PlatEnt _
)
declare sub in_handle_toggles ( _
    g as Game _
)
declare sub v_update_camera ( _
    g as Game, _
    byval dt as single, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node _
)
declare sub ls_animate ( byval anim_time as single )
declare sub r_set_frustum ( _
    frustum() as DiskPlane, _
    mtx as u3dMtrx _
)
declare sub r_draw_world ( _
    g as Game, _
    byval model as integer, _
    campos as u3dVector3f, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane, _
    bit_array() as integer _
)
declare function d_turb_ptr ( ) as long
'' Temporary instrumentation: how many faces asked for a cached surface
'' and how many fell back to unlit. NOT in Game -- adding a field there
'' shifts the offsets sb_build.c and r_walk.c hard-code.
declare function dbg_lm_want ( ) as integer
declare function dbg_lm_fall ( ) as integer
declare function dbg_keys ( byval which as integer ) as long
'' The whole face loop, in C, once per frame -- see d_faces.c.
declare sub d_draw_faces ( _
    g as Game, _
    dp as DrawParams, _
    mtx_fin as u3dMtrx, _
    campos as u3dVector3f, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    face_mdl() as integer, _
    brush() as BrushModel, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mip_buff_inf() as MipTex, _
    order_list() as integer, _
    poly_flag() as integer _
)
declare sub scr_draw_hud ( _
    g as Game, _
    h_dst_dc as long _
)
declare function sys_now ( ) as single


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
sub host_advance ( _
    g as Game, _
    byval real_dt as single, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    tele() as Teleporter, _
    plat() as PlatEnt, _
    host_accum as single, _
    host_ticks as long _
)
    dim steps as integer

    host_accum = host_accum + real_dt

    steps = 0
    do while ( host_accum >= HOST_DT# and steps < HOST_MAXSTEPS )
        ''
        '' Stop ON the tick budget, not past it. -ticks is tested once a
        '' frame, after this whole loop, so a slow frame that runs two or
        '' three steps ends the run at 902 rather than 900 -- and the
        '' camera is wherever those extra steps carried it. Two runs of
        '' one binary then differ by most of a room, which reads exactly
        '' like a rendering bug and is not one.
        ''
        if ( g.env.bench_ticks > 0 and host_ticks >= g.env.bench_ticks ) then
            exit do
        end if
        host_tick g, HOST_DT#, brush(), models(), planes(), nodes(), cp_x(), cp_y(), _
                   cp_z(), tele(), plat()
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
sub host_tick ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    tele() as Teleporter, _
    plat() as PlatEnt _
)

    '' what the player asked for
    in_handle_toggles g

    '' and what the world does about it: camera, and the physics under it
    v_update_camera g, dt, cp_x(), cp_y(), cp_z(), brush(), models(), planes(), nodes()

    '' and anything the world does to the player as a result of moving
    ent_check_teleport g, tele()

    '' movers, after the player has moved and before anything is drawn
    ent_move_plats g, dt, brush(), plat()

    '' where each mover ended up, so the draw order can place it
    ent_place_models g.wld.count.models, models(), nodes(), planes(), brush()

    '' map time, which drives every texture animation
    g.rdr.anim_time = g.rdr.anim_time + dt

    '' light styles: fixed 10 Hz off the same clock, not framerate
    ls_animate g.rdr.anim_time

    '' the test dynamic light, following the player -- field by field,
    '' not a whole-UDT assignment, matching how every other Vec3 copy in
    '' this codebase is written
    g.rdr.dlight.pos.x = g.pl.pos.x
    g.rdr.dlight.pos.y = g.pl.pos.y
    g.rdr.dlight.pos.z = g.pl.pos.z
    g.rdr.dlight.radius = DL_RADIUS#

end sub




''::::::::::
'' name: host_render
'' desc: One frame's drawing. Reads the world, changes none of it -- the
''       counterpart to host_tick, which changes it and draws none of it.
''::::::::::
sub host_render ( _
    g as Game, _
    byval h_dst_dc as long, _
    mtx_prj as u3dMtrx, _
    byval xresh as single, _
    byval yresh as single, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mdl_buffer() as Submodel, _
    order_list() as integer, _
    poly_flag() as integer, _
    gv_buf() as integer, _
    brush() as BrushModel, _
    frustum() as DiskPlane, _
    bit_array() as integer, _
    mip_buff_inf() as MipTex, _
    face_mdl() as integer, _
    cam_up as u3dVector3f, _
    byval z_dc as long _
)
    dim mtx_mdl as u3dMtrx
    dim zz as long                  '' soaks up uglZMode's return;
                                    '' the call is the point
    dim mtx_fin as u3dMtrx
    dim cam_pos_b as u3dVector3f
    dim bm as integer
    dim pt0 as single, ptd as single
    dim dparm as DrawParams

    pt0 = sys_now()
    u3dMtrxLookAt mtx_mdl, g.cam.pos, g.cam.look_at, cam_up
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
    if ( g.cam.fps_view = false ) then 
        cam_pos_b.x = 351.0
        cam_pos_b.y = 2119.0
        cam_pos_b.z = -552.0            
                    
        g.cam.look_at.x = cam_pos_b.x + 1.991367e-8
        g.cam.look_at.y = cam_pos_b.y + -1.0
        g.cam.look_at.z = cam_pos_b.z + 1.570986e-2
    else
        cam_pos_b.x = g.cam.pos.x
        cam_pos_b.y = g.cam.pos.y
        cam_pos_b.z = g.cam.pos.z
    end if
    
    '        
    u3dMtrxLookAt mtx_mdl, cam_pos_b, g.cam.look_at, cam_up        
    u3dMtrxConc mtx_fin, mtx_mdl, mtx_prj
    
    
    ''
    '' Walk BSP tree
    ''
    r_draw_world g, 0, g.cam.pos, mdl_buffer(), brush(), nds_buffer(), pln_buffer(), _
                  poly_flag(), order_list(), frustum(), bit_array()

    ''
    '' Cull ends here -- both exits from this sub after this point
    '' (-nodraw, and the normal one at the bottom) have to pass through
    '' it, so timing it once here covers both.
    ''
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.cull_sum = g.pt.cull_sum + ptd
        if ( ptd > g.pt.cull_max ) then g.pt.cull_max = ptd
    end if

    ''
    '' Clear to the far plane before the frame. Depth is 1/z and larger is
    '' nearer, so zero is infinitely distant and the first surface to
    '' cover a pixel always wins.
    ''
    if ( z_dc <> 0 ) then uglClearZ z_dc, 0

    '' -nodraw stops HERE: the walk above has run and filled order_list,
    '' so everything the node paging touches has happened. What is skipped
    '' is fill, which paging does not affect.
    if ( g.env.no_draw ) then exit sub

    ''
    '' Gathered here, once, rather than read out of Game inside the loop:
    '' that keeps every offset in BASIC, where the compiler checks it,
    '' instead of hand-mirroring Game's layout in C.
    ''
    dparm.h_dst_dc    = h_dst_dc
    dparm.tex_ofs_ptr = clng( varseg( g.wld.tex.ofs(0) ) ) * 65536& + _
                        (clng( varptr( g.wld.tex.ofs(0) ) ) and 65535&)
    dparm.turb_ptr    = d_turb_ptr
    dparm.xresh       = xresh
    dparm.yresh       = yresh
    dparm.z_near      = g.env.z_near
    dparm.z_far       = g.env.z_far
    dparm.anim_time   = g.rdr.anim_time
    dparm.dl_x        = g.rdr.dlight.pos.x
    dparm.dl_y        = g.rdr.dlight.pos.y
    dparm.dl_z        = g.rdr.dlight.pos.z
    dparm.dl_radius   = g.rdr.dlight.radius
    dparm.frame_stamp = g.vis.frame_stamp
    dparm.ord_count   = g.vis.ord_count
    dparm.use_lm      = g.env.use_lm
    dparm.lightmap    = g.rdr.lightmap
    dparm.backface    = g.rdr.backface
    dparm.rend_mode   = g.rdr.rend_mode
    dparm.use_mips    = g.rdr.use_mips
    dparm.poly_tp     = g.env.poly_tp
    dparm.span_draw   = g.env.span_draw
    dparm.x_res       = g.env.x_res
    dparm.y_res       = g.env.y_res
    dparm.prof        = (g.ft.n > 0)

    pt0 = sys_now()
    d_draw_faces g, dparm, mtx_fin, g.cam.pos, _
                  tri_buffer(), tex_inf_buff(), gv_buf(), face_mdl(), _
                  brush(), pln_buffer(), nds_buffer(), mip_buff_inf(), _
                  order_list(), poly_flag()

    g.rdr.polys = g.rdr.polys + dparm.polys
    g.rdr.tris  = g.rdr.tris + dparm.tris
    lm_want_dbg = dparm.lm_want
    lm_fall_dbg = dparm.lm_fallback
    k_mip_dbg = k_mip_dbg + dparm.k_mip
    k_sw_dbg = k_sw_dbg + dparm.k_sw
    k_sh_dbg = k_sh_dbg + dparm.k_sh
    k_stag_dbg = k_stag_dbg + dparm.k_stag
    k_n_dbg = k_n_dbg + dparm.k_n
    k_hdr_dbg = k_hdr_dbg + dparm.k_hdr
    k_ext_dbg = k_ext_dbg + dparm.k_ext
    k_v0_dbg = k_v0_dbg + dparm.k_v0
    k_lm_dbg = k_lm_dbg + dparm.k_lm

    '' Only the surface BUILD is still timed inside the loop -- a build
    '' is a cache miss, so its bracket is rare. The per-face raster/aim
    '' brackets are gone: 4-6 sys_rdtsc far calls per face, each a far
    '' call plus a 32-bit divide, to measure a loop that no longer needs
    '' measuring at that grain. pt_raster/pt_aim/pt_emit read 0 now.
    if ( g.ft.n > 0 ) then
        g.pt.build_sum = g.pt.build_sum + dparm.build_us / 1000000.0
    end if
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.draw_sum = g.pt.draw_sum + ptd
        if ( ptd > g.pt.draw_max ) then g.pt.draw_max = ptd
    end if

    '' leave depth off for the overlay, which is 2D and would otherwise
    '' test itself against the scene it is drawn on top of
    if ( z_dc <> 0 ) then zz = uglZMode%( UGL.Z.OFF% )

    pt0 = sys_now()
    scr_draw_hud g, h_dst_dc
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.hud_sum = g.pt.hud_sum + ptd
        if ( ptd > g.pt.hud_max ) then g.pt.hud_max = ptd
    end if

end sub

function dbg_lm_want ( ) as integer
    dbg_lm_want = lm_want_dbg
end function

function dbg_lm_fall ( ) as integer
    dbg_lm_fall = lm_fall_dbg
end function

function dbg_keys ( byval which as integer ) as long
    select case which
        case 0
            dbg_keys = k_mip_dbg
        case 1
            dbg_keys = k_sw_dbg
        case 2
            dbg_keys = k_sh_dbg
        case 3
            dbg_keys = k_stag_dbg
        case 4
            dbg_keys = k_n_dbg
        case 5
            dbg_keys = k_hdr_dbg
        case 6
            dbg_keys = k_ext_dbg
        case 7
            dbg_keys = k_v0_dbg
        case else
            dbg_keys = k_lm_dbg
    end select
end function
