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
'' reads and updates them every call. cam_up is likewise main.bas's,
'' passed byref into host_render -- never written here, but a UDT, and
'' this project passes those byref throughout rather than by value.
''
'' The depth buffer used to travel the same way and no longer does: it
'' is attached to the backbuffer, so the surface this file already holds
'' is the whole of it.
''
'$include: 'qgl.bi'
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'

declare sub qglM4LookAt ( _
    seg m as Mat4, _
    seg eye as Vec3, _
    seg at as Vec3, _
    seg up as Vec3 _
)
declare sub qglM4Conc ( _
    seg m as Mat4, _
    seg a as Mat4, _
    seg b as Mat4 _
)

dim shared qgl_faces_dbg as integer
dim shared qgl_drop_dbg as integer

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
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
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
declare sub ent_move_doors ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt _
)
declare sub ent_reset ( _
    g as Game, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    plat() as PlatEnt _
)
declare sub ent_move_trigs ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
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
declare sub mdl_think ( _
    g as Game, _
    ent as MdlEnt, _
    m as MdlState, _
    byval can_chase as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane, _
    nail() as Spike _
)
declare sub pl_fire ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    nail() as Spike, _
    plat() as PlatEnt _
)
declare sub pl_nails_tick ( _
    g as Game, _
    byval dt as single, _
    nail() as Spike, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane, _
    nodes() as Node, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    plat() as PlatEnt _
)
declare sub pl_traps_tick ( _
    g as Game, _
    trig() as TrigEnt, _
    nail() as Spike _
)
declare sub pl_items_touch ( _
    g as Game, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    plat() as PlatEnt _
)
declare sub pl_env_damage ( g as Game )
declare sub pl_select_weapon ( g as Game )
declare sub pl_respawn ( g as Game )
declare sub pl_carry_save ( g as Game )
declare sub host_next_level ( g as Game )
declare sub pl_game_reset ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare function mdl_draw_box ( _
    org as Vec3, _
    byval half as single, _
    byval top as single, _
    byval cyaw as single, _
    byval syaw as single, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long, _
    byval side_col as integer, _
    byval top_col as integer _
) as integer
declare function mdl_draw_crate ( _
    g as Game, _
    org as Vec3, _
    c as CrateModel, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long, _
    byval mip as integer, _
    byval anim_time as single _
) as integer
declare sub ent_crate ( _
    byval k as integer, _
    c as CrateModel _
)
declare sub ls_animate ( byval anim_time as single )
declare sub r_set_frustum ( _
    frustum() as DiskPlane, _
    mtx as Mat4 _
)
declare sub r_draw_world ( _
    g as Game, _
    byval model as integer, _
    campos as Vec3, _
    mtx_fin as Mat4, _
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
declare function dbg_qgl_faces ( ) as integer
declare function dbg_qgl_drop ( ) as integer
'' The whole face loop, in C, once per frame -- see d_faces.c.
'' `z`, not `val`: VAL is a BASIC intrinsic and BC rejects it as a
'' formal parameter name.
declare sub qglSfZClear ( byval surf as long, byval z as integer )

declare sub d_draw_faces ( _
    g as Game, _
    dp as DrawParams, _
    mtx_fin as Mat4, _
    campos as Vec3, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    brush() as BrushModel, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mip_buff_inf() as MipTex, _
    order_list() as integer, _
    poly_flag() as integer _
)
declare sub scr_draw_hud ( _
    g as Game, _
    h_dst_dc as long, _
    byval w as integer, _
    byval h as integer _
)
declare function r_mdl_visible ( _
    org as Vec3, _
    byval radius as single, _
    byval zlo as single, _
    byval zhi as single, _
    nodes() as Node, _
    planes() as Plane, _
    frustum() as DiskPlane _
) as integer
declare sub r_portal_outline ( _
    g as Game, _
    byval dc as long, _
    mtx_fin as Mat4 _
)
declare function sys_now ( ) as single
declare function sys_rdtsc ( ) as long
declare function host_lap ( t0 as long ) as single
declare sub host_tk ( _
    byval timing as integer, _
    t0 as long, _
    tt as TickTimer _
)


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
    door() as DoorEnt, _
    trig() as TrigEnt, _
    host_accum as single, _
    host_ticks as long, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
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
                   cp_z(), tele(), plat(), door(), trig(), mdl_ent(), item(), nail(), mon()
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
'' changelevel: the kit to CARRY.BIN, the next map's run to NEXT.BAT --
'' GOMAP.BAT stages its files, then qrender with -carry and the flags
'' that describe the run rather than where it started -- and the host
'' loop ends. dosbox.sh's run.bat runs NEXT.BAT while one is written.
sub host_next_level ( g as Game )
    dim f as integer
    dim cmd as string

    pl_carry_save g
    cmd = "qrender.exe " + rtrim$( g.fight.next_map ) + ".bsp -carry"
    if ( g.env.use_lm ) then cmd = cmd + " -lm"
    if ( g.snd.off ) then cmd = cmd + " -nosound"
    if ( g.env.no_stats ) then cmd = cmd + " -nostats"
    if ( g.env.no_ai ) then cmd = cmd + " -noai"
    if ( g.env.no_mdl ) then cmd = cmd + " -nomdl"
    if ( g.env.no_view ) then cmd = cmd + " -noview"
    if ( g.env.comp ) then cmd = cmd + " -comp"
    if ( g.env.hold_fire ) then cmd = cmd + " -fire"
    if ( g.env.bench_frames > 0 ) then cmd = cmd + " -bench " + ltrim$( str$( g.env.bench_frames ) )
    if ( g.env.bench_ticks > 0 ) then cmd = cmd + " -ticks " + ltrim$( str$( g.env.bench_ticks ) )
    f = freefile
    open "NEXT.BAT" for output as #f
    print #f, "call GOMAP.BAT " + rtrim$( g.fight.next_map )
    print #f, cmd + " >> run.out"
    close #f
    g.fight.state = GS_NEXT%
end sub

''::::::::::
'' the view model of the weapon in hand, loaded the first time it is
'' held -- a pickup, a key, the carry -- and never before: each costs
'' the far heap 600 bytes, and e1m4 ran out of string space at the
'' bench write with all six loaded at host_init
sub host_view_load ( g as Game )
    select case g.fight.weapon
    case PL_IT_SSG%
        if ( g.smdl.loaded = 0 ) then mdl_load g, g.smdl, "v_shot2"
    case PL_IT_NAILGUN%
        if ( g.nmdl.loaded = 0 ) then mdl_load g, g.nmdl, "v_nail"
    case PL_IT_GL%
        if ( g.gmdl.loaded = 0 ) then mdl_load g, g.gmdl, "v_rock"
    case PL_IT_SNG%
        if ( g.n2mdl.loaded = 0 ) then mdl_load g, g.n2mdl, "v_nail2"
    case PL_IT_RL%
        if ( g.rmdl.loaded = 0 ) then mdl_load g, g.rmdl, "v_rock2"
    end select
end sub

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
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)
    dim mdl_i as integer
    dim fire as integer, ndead as integer
    dim t0 as long

    '' what the player asked for
    in_handle_toggles g

    '' and what the world does about it: camera, and the physics under it
    t0 = sys_rdtsc()
    v_update_camera g, dt, cp_x(), cp_y(), cp_z(), brush(), models(), planes(), nodes()
    host_tk g.ft.n > 0, t0, g.pt.tk_cam

    '' the fight. Fire is mouse 1 or ctrl; outside GS_PLAY a fresh press
    '' is the only input that matters, and the world stands still.
    fire = ( g.env.mouse.left or g.env.keyboard.ctrl or g.env.hold_fire )
    select case g.fight.state
    case GS_PLAY%
        pl_select_weapon g
        if ( fire ) then pl_fire g, mdl_ent(), models(), brush(), planes(), item(), door(), trig(), nail(), plat()
        host_tk g.ft.n > 0, t0, g.pt.tk_fire
        pl_nails_tick g, dt, nail(), mdl_ent(), models(), brush(), planes(), nodes(), item(), door(), trig(), plat()
        host_tk g.ft.n > 0, t0, g.pt.tk_nails
        pl_items_touch g, item(), door(), trig(), plat()
        host_tk g.ft.n > 0, t0, g.pt.tk_items
        host_view_load g
        pl_env_damage g
        '' every soldier's own think -- Quake's 10 Hz, gated inside
        '' mdl_think against g.rdr.anim_time
        ndead = 0
        for mdl_i = 0 to g.mdl_count - 1
            if ( g.env.no_ai ) then
                '' held at the spawn: the model gate's away arm
            else
                mdl_think g, mdl_ent( mdl_i ), mon( mdl_ent( mdl_i ).kind ), -1, models(), brush(), planes(), nail()
            end if
            if ( mdl_ent( mdl_i ).state = MDL_ST_DEAD% ) then ndead = ndead + 1
        next mdl_i
        host_tk g.ft.n > 0, t0, g.pt.tk_think
        if ( g.fight.health <= 0 ) then
            g.fight.state = GS_DEAD%
            snd_play g, SND_DEATH%, g.pl.pos
            g.fight.state_until = g.rdr.anim_time + PL_DEATH_PAUSE#
        elseif ( g.mdl_count > 0 and ndead = g.mdl_count ) then
            g.fight.state = GS_WON%
        end if
    case GS_DEAD%
        if ( g.rdr.anim_time >= g.fight.state_until ) then
            pl_respawn g
            g.fight.state = GS_PLAY%
        end if
    case GS_EXIT%
        '' IntermissionThink: a button held past exittime goes on to the
        '' next map; with none, the level again
        if ( fire and g.rdr.anim_time >= g.fight.exit_time + PL_INTER_HOLD# ) then
            if ( len( rtrim$( g.fight.next_map ) ) > 0 ) then
                host_next_level g
            else
                pl_game_reset g, mdl_ent(), item(), models(), brush(), planes()
                ent_reset g, brush(), door(), trig(), plat()
                g.fight.state = GS_PLAY%
            end if
        end if
    case else
        if ( fire and g.fight.fire_prev = 0 ) then
            if ( g.fight.state = GS_WON% ) then
                pl_game_reset g, mdl_ent(), item(), models(), brush(), planes()
                ent_reset g, brush(), door(), trig(), plat()
            end if
            g.fight.state = GS_PLAY%
        end if
    end select
    g.fight.fire_prev = fire

    '' and anything the world does to the player as a result of moving
    t0 = sys_rdtsc()
    ent_check_teleport g, tele()
    host_tk g.ft.n > 0, t0, g.pt.tk_tele

    '' movers, after the player has moved and before anything is drawn
    ent_move_plats g, dt, brush(), plat()
    host_tk g.ft.n > 0, t0, g.pt.tk_plats
    ent_move_doors g, dt, brush(), door()
    host_tk g.ft.n > 0, t0, g.pt.tk_doors
    ent_move_trigs g, dt, brush(), door(), trig(), plat()
    host_tk g.ft.n > 0, t0, g.pt.tk_trigs
    pl_traps_tick g, trig(), nail()
    host_tk g.ft.n > 0, t0, g.pt.tk_traps

    '' where each mover ended up, so the draw order can place it
    ent_place_models g.wld.count.models, models(), nodes(), planes(), brush()
    host_tk g.ft.n > 0, t0, g.pt.tk_place

    '' map time, which drives every texture animation
    g.rdr.anim_time = g.rdr.anim_time + dt

    '' light styles: fixed 10 Hz off the same clock, not framerate
    ls_animate g.rdr.anim_time
    host_tk g.ft.n > 0, t0, g.pt.tk_ls

    '' the test dynamic light, following the player -- field by field,
    '' not a whole-UDT assignment, matching how every other Vec3 copy in
    '' this codebase is written
    g.rdr.dlight.pos.x = g.pl.pos.x
    g.rdr.dlight.pos.y = g.pl.pos.y
    g.rdr.dlight.pos.z = g.pl.pos.z
    g.rdr.dlight.radius = DL_RADIUS#
    '' and the muzzle flash, which is the same light, wider
    if ( g.rdr.anim_time < g.fight.flash_until ) then g.rdr.dlight.radius = DL_RADIUS# * 2.0

end sub


'' Microseconds since t0, and t0 moved on. sys_rdtsc wraps every minute
'' or so as a negative jump; that sample is dropped, as its docstring says.
function host_lap ( t0 as long ) as single
    dim t1 as long
    t1 = sys_rdtsc()
    host_lap = t1 - t0
    if ( t1 < t0 ) then host_lap = -1.0   '' sys_rdtsc wrapped: no sample
    t0 = t1
end function

'' One call's lap into its timer, once the frame clock counts.
sub host_tk ( _
    byval timing as integer, _
    t0 as long, _
    tt as TickTimer _
)
    dim d as single
    d = host_lap( t0 )
    if ( timing = 0 or d < 0.0 ) then exit sub
    tt.sum = tt.sum + d
    tt.n = tt.n + 1
    if ( d < tt.lo ) then tt.lo = d
    if ( d > tt.hi ) then tt.hi = d
end sub




''::::::::::
'' name: host_render
'' desc: One frame's drawing. Reads the world, changes none of it -- the
''       counterpart to host_tick, which changes it and draws none of it.
''::::::::::
sub host_render ( _
    g as Game, _
    byval h_dst_dc as long, _
    mtx_prj as Mat4, _
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
    cam_up as Vec3, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)
    dim mtx_mdl as Mat4
    dim bob as Vec3
    dim nbox as integer
    dim crate as CrateModel, corg as Vec3, cdist as single, cmip as integer
    dim vlen as single, vframe as integer
    dim vdx as single, vdy as single, vdz as single
    dim mdl_i as integer, k as integer
    dim mtx_fin as Mat4
    dim cam_pos_b as Vec3
    dim bm as integer
    dim pt0 as single, ptd as single
    dim dparm as DrawParams

    pt0 = sys_now()
    qglM4LookAt mtx_mdl, g.cam.pos, g.cam.look_at, cam_up
    qglM4Conc mtx_fin, mtx_mdl, mtx_prj
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
    qglM4LookAt mtx_mdl, cam_pos_b, g.cam.look_at, cam_up
    qglM4Conc mtx_fin, mtx_mdl, mtx_prj
    
    
    ''
    '' Walk BSP tree
    ''
    r_draw_world g, 0, g.cam.pos, mtx_fin, mdl_buffer(), brush(), nds_buffer(), pln_buffer(), _
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
        if ( ptd < g.pt.cull_min ) then g.pt.cull_min = ptd
    end if

    ''
    '' Clear to the far plane before the frame. Depth is 1/z and larger is
    '' nearer, so zero is infinitely distant and the first surface to
    '' cover a pixel always wins.
    ''
    qglSfZClear h_dst_dc, 0

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
    dparm.ord_count   = g.vis.ord_count
    dparm.use_lm      = g.env.use_lm
    dparm.lightmap    = g.rdr.lightmap
    dparm.backface    = g.rdr.backface
    dparm.rend_mode   = g.rdr.rend_mode
    dparm.use_mips    = g.rdr.use_mips
    dparm.x_res       = g.env.x_res
    dparm.y_res       = g.env.y_res
    dparm.prof        = (g.ft.n > 0)

    pt0 = sys_now()
    d_draw_faces g, dparm, mtx_fin, g.cam.pos, _
                  tri_buffer(), tex_inf_buff(), gv_buf(), _
                  brush(), pln_buffer(), nds_buffer(), mip_buff_inf(), _
                  order_list(), poly_flag()

    g.rdr.polys = g.rdr.polys + dparm.polys
    g.rdr.tris  = g.rdr.tris + dparm.tris
    qgl_faces_dbg = dparm.qgl_faces
    qgl_drop_dbg = dparm.qgl_drop

    '' Only the surface BUILD is still timed inside the loop -- a build
    '' is a cache miss, so its bracket is rare. The per-face raster/aim
    '' brackets are gone: 4-6 sys_rdtsc far calls per face, each a far
    '' call plus a 32-bit divide, to measure a loop that no longer needs
    '' measuring at that grain. pt_raster/pt_aim/pt_emit read 0 now.
    if ( g.ft.n > 0 ) then
        g.pt.build_sum = g.pt.build_sum + dparm.build_us / 1000000.0
        if ( dparm.build_us / 1000000.0 > g.pt.build_max ) then g.pt.build_max = dparm.build_us / 1000000.0
        if ( dparm.build_us / 1000000.0 < g.pt.build_min ) then g.pt.build_min = dparm.build_us / 1000000.0
    end if
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.draw_sum = g.pt.draw_sum + ptd
        if ( ptd > g.pt.draw_max ) then g.pt.draw_max = ptd
        if ( ptd < g.pt.draw_min ) then g.pt.draw_min = ptd
    end if

    '' Every spawned model, real geometry, while depth is still on -- it
    '' goes in WITH the world, not after it. Depth-tested like a brush
    '' entity: the world only WRITES (arrives front to back by BSP order
    '' already), this has no such guarantee. mdl_ent()'s pos/yaw are
    '' mdl_think's own state (pl_move.bas), updated once per tick --
    '' drawing reads them, same split host_tick/host_render already keep
    '' for the player.
    pt0 = sys_now()
    g.mdl_drawn = 0
    if ( g.env.no_mdl = 0 ) then
        for mdl_i = 0 to g.mdl_count - 1
            k = mdl_ent( mdl_i ).kind
            if ( mon( k ).loaded = 0 ) then
            elseif ( mdl_ent( mdl_i ).state = MDL_ST_DEAD% and mon( k ).ndeath = 0 ) then
                '' gibbed: a zombie has no death frames to lie in
            elseif ( r_mdl_visible( mdl_ent( mdl_i ).pos, mon( k ).radius, mon( k ).zlo, mon( k ).zhi, _
                                    nds_buffer(), pln_buffer(), frustum() ) ) then
                    mdl_draw g, mon( k ), mdl_ent( mdl_i ), _
                             mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
                    g.mdl_drawn = g.mdl_drawn + 1
                    '' the volley has no frames, so it has a flash: a small
                    '' box at the muzzle, the frame it fires
                    if ( g.rdr.anim_time < mdl_ent( mdl_i ).flash_until ) then
                        bob = mdl_ent( mdl_i ).pos
                        bob.x = bob.x + cos( mdl_ent( mdl_i ).yaw * 0.017453293 ) * MDL_GUN_FWD#
                        bob.y = bob.y + sin( mdl_ent( mdl_i ).yaw * 0.017453293 ) * MDL_GUN_FWD#
                        bob.z = bob.z + MDL_GUN_UP#
                        nbox = mdl_draw_box( bob, 3.0, 6.0, 1.0, 0.0, mtx_fin, xresh, yresh, g.env.z_near, _
                                             h_dst_dc, ENT_COL_YELLOW%, ENT_COL_WHITE% )
                    end if
            end if
        next mdl_i
    end if
    '' the pickups: a box each, spinning and bobbing on the same clock
    '' as the liquids, flat colours the world's palette already has
    for mdl_i = 0 to g.item_count - 1
        if ( item( mdl_i ).gone = 0 ) then
            if ( r_mdl_visible( item( mdl_i ).pos, ENT_BOX_HALF# * 1.5, 0.0, ENT_BOX_TOP# + 8.0, _
                                nds_buffer(), pln_buffer(), frustum() ) ) then
                bob = item( mdl_i ).pos
                bob.z = bob.z + 4.0 + 4.0 * sin( g.rdr.anim_time * 3.0 )
                if ( item( mdl_i ).crate >= 0 ) then
                    '' the map's b_*.bsp, still, centred on the origin as
                    '' the touch and the explosive box's trace already are;
                    '' the mip by distance, d_faces.c's thresholds
                    ent_crate item( mdl_i ).crate, crate
                    corg = item( mdl_i ).pos
                    corg.x = corg.x - crate.size.x * 0.5
                    corg.y = corg.y - crate.size.y * 0.5
                    cdist = sqr( ( corg.x - g.pl.pos.x ) ^ 2 + ( corg.y - g.pl.pos.y ) ^ 2 + ( corg.z - g.pl.pos.z ) ^ 2 )
                    cmip = 0
                    if ( g.rdr.use_mips ) then
                        if ( cdist >= 1400.0 ) then
                            cmip = 3
                        elseif ( cdist >= 560.0 ) then
                            cmip = 2
                        elseif ( cdist >= 280.0 ) then
                            cmip = 1
                        end if
                    end if
                    nbox = mdl_draw_crate( g, corg, crate, mtx_fin, xresh, yresh, g.env.z_near, _
                                           h_dst_dc, cmip, g.rdr.anim_time )
                elseif ( item( mdl_i ).kind = ENT_ITEM_EXPLOBOX ) then
                    '' the box stands still, b_explob's size
                    nbox = mdl_draw_box( item( mdl_i ).pos, ENT_BOX_HALF#, ENT_BOX_TOP#, 1.0, 0.0, _
                                         mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_YELLOW%, ENT_COL_BROWN% )
                elseif ( item( mdl_i ).kind = ENT_ITEM_QUAD ) then
                    nbox = mdl_draw_box( bob, ENT_ITEM_HALF#, ENT_ITEM_TOP#, cos( g.rdr.anim_time * 2.0 ), _
                                         sin( g.rdr.anim_time * 2.0 ), mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_BLUE%, ENT_COL_WHITE% )
                elseif ( item( mdl_i ).kind = ENT_ITEM_SUIT ) then
                    nbox = mdl_draw_box( bob, ENT_ITEM_HALF#, ENT_ITEM_TOP#, cos( g.rdr.anim_time * 2.0 ), _
                                         sin( g.rdr.anim_time * 2.0 ), mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_GREEN%, ENT_COL_WHITE% )
                elseif ( item( mdl_i ).kind = ENT_ITEM_PENT ) then
                    nbox = mdl_draw_box( bob, ENT_ITEM_HALF#, ENT_ITEM_TOP#, cos( g.rdr.anim_time * 2.0 ), _
                                         sin( g.rdr.anim_time * 2.0 ), mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_RED%, ENT_COL_YELLOW% )
                elseif ( item( mdl_i ).kind = ENT_ITEM_HEALTH ) then
                    nbox = mdl_draw_box( bob, ENT_ITEM_HALF#, ENT_ITEM_TOP#, cos( g.rdr.anim_time * 2.0 ), _
                                         sin( g.rdr.anim_time * 2.0 ), mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_RED%, ENT_COL_WHITE% )
                else
                    nbox = mdl_draw_box( bob, ENT_ITEM_HALF#, ENT_ITEM_TOP#, cos( g.rdr.anim_time * 2.0 ), _
                                         sin( g.rdr.anim_time * 2.0 ), mtx_fin, xresh, yresh, g.env.z_near, _
                                         h_dst_dc, ENT_COL_BROWN%, ENT_COL_YELLOW% )
                end if
            end if
        end if
    next mdl_i
    '' the nails in flight, a sliver each, dark with a bright end; a
    '' grenade a box
    for mdl_i = 0 to ubound( nail )
        if ( nail( mdl_i ).alive ) then
            bob = nail( mdl_i ).pos
            bob.z = bob.z - 1.0
            if ( nail( mdl_i ).toss ) then
                nbox = mdl_draw_box( bob, 4.0, 8.0, 1.0, 0.0, mtx_fin, xresh, yresh, g.env.z_near, _
                                     h_dst_dc, ENT_COL_RED%, ENT_COL_YELLOW% )
            elseif ( nail( mdl_i ).grenade ) then
                nbox = mdl_draw_box( bob, 2.0, 4.0, 1.0, 0.0, mtx_fin, xresh, yresh, g.env.z_near, _
                                     h_dst_dc, ENT_COL_BROWN%, ENT_COL_BROWN% )
            else
                nbox = mdl_draw_box( bob, 1.0, 2.0, 1.0, 0.0, mtx_fin, xresh, yresh, g.env.z_near, _
                                     h_dst_dc, ENT_COL_BROWN%, ENT_COL_WHITE% )
            end if
        end if
    next mdl_i
    '' the view weapon: v_shot, v_shot2, v_nail, v_rock, v_nail2 or v_rock2 by the weapon in hand,
    '' at the eye, turned with the view, last and with depth off, as Quake
    '' draws it. The fire animation is shot2.. at 10 Hz from the shot,
    '' the model's last frame held until it is ready again; the nailgun
    '' cycles its eight while fire is held (player_nail1/2).
    if ( g.env.no_mdl = 0 and g.env.no_view = 0 ) then
        bob.x = g.pl.pos.x : bob.y = g.pl.pos.y : bob.z = g.pl.pos.z + PL_EYE#
        vdx = g.cam.look_at.x - g.cam.pos.x
        vdy = g.cam.look_at.y - g.cam.pos.y
        vdz = g.cam.look_at.z - g.cam.pos.z
        vlen = sqr( vdx * vdx + vdz * vdz )
        if ( vlen < 0.001 ) then vlen = 0.001
        vframe = 0
        if ( g.rdr.anim_time < g.fight.next_fire ) then
            vframe = 1 + int( ( g.rdr.anim_time - g.fight.fire_at ) * 10.0 )
            if ( g.fight.weapon = PL_IT_NAILGUN% or g.fight.weapon = PL_IT_SNG% ) then vframe = 1 + ( clng( g.rdr.anim_time * 10.0 ) mod 8 )
        end if
        '' look_at is the point one unit from cam.pos the eye looks at,
        '' renderer Y up: the yaw's cos and sin are the difference's x and z
        '' over their length, the pitch's are that length and -y, positive
        '' looking down
        if ( g.fight.state = GS_EXIT% ) then
            '' no gun in the intermission's view
        elseif ( g.fight.weapon = PL_IT_RL% and g.rmdl.loaded ) then
            mdl_draw_view g, g.rmdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        elseif ( g.fight.weapon = PL_IT_SNG% and g.n2mdl.loaded ) then
            mdl_draw_view g, g.n2mdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        elseif ( g.fight.weapon = PL_IT_GL% and g.gmdl.loaded ) then
            mdl_draw_view g, g.gmdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        elseif ( g.fight.weapon = PL_IT_NAILGUN% and g.nmdl.loaded ) then
            mdl_draw_view g, g.nmdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        elseif ( g.fight.weapon = PL_IT_SSG% and g.smdl.loaded ) then
            mdl_draw_view g, g.smdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        elseif ( g.vmdl.loaded ) then
            mdl_draw_view g, g.vmdl, vframe, bob, _
                          vdx / vlen, vdz / vlen, vlen, -vdy, _
                          mtx_fin, xresh, yresh, g.env.z_near, h_dst_dc
        end if
    end if
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.mdl_sum = g.pt.mdl_sum + ptd
        if ( ptd > g.pt.mdl_max ) then g.pt.mdl_max = ptd
        if ( ptd < g.pt.mdl_min ) then g.pt.mdl_min = ptd
    end if

    if ( g.scr.portal_wire ) then
        r_portal_outline g, h_dst_dc, mtx_fin
    end if

    '' Nothing turns depth off for the overlay: the overlay draws
    '' through the 2D calls, which never touch depth, and every 3D draw
    '' names its own depth mode. There is no installed mode to restore.

    '' Under -comp the host loop draws this onto the composite after the
    '' scale, at the mode's own size.
    pt0 = sys_now()
    if ( g.env.comp = 0 ) then scr_draw_hud g, h_dst_dc, g.env.x_res, g.env.y_res
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.hud_sum = g.pt.hud_sum + ptd
        if ( ptd > g.pt.hud_max ) then g.pt.hud_max = ptd
        if ( ptd < g.pt.hud_min ) then g.pt.hud_min = ptd
    end if

end sub

''
'' Faces the -qgl slice actually drew. Without it a slice that fell
'' back to mgl for every face produces a perfect picture and proves
'' nothing, which is the one way this comparison can pass for the
'' wrong reason.
''
function dbg_qgl_faces ( ) as integer
    dbg_qgl_faces = qgl_faces_dbg
end function

function dbg_qgl_drop ( ) as integer
    dbg_qgl_drop = qgl_drop_dbg
end function
