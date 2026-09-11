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

''
'' This module's own procedures.
''
declare sub cp_load ( _
    g as Game, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer _
)
declare sub pl_items_drop ( _
    g as Game, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub host_pt_init ( g as Game )
declare sub host_bench_report ( _
    g as Game, _
    frame_no as long, _
    h_dst_dc as long, _
    brush() as BrushModel, _
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    byval host_ticks as long, _
    mon() as MdlState, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane _
)
declare sub host_view_load ( g as Game )
declare sub host_render ( _
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
declare sub host_advance ( _
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
declare function qglCheckAll () as integer
declare function qglDiffAll () as integer
declare function qglFaceAll () as integer
declare function qglArrAll () as integer
declare function qglSfInit () as integer
'' The mode. qglVgaShutdown goes back to what was current before the
'' loading screen's own qglVgaInit -- mgl no longer sets a mode, so
'' uglRestore has nothing left to restore.
declare sub qglVgaShutdown ()
declare function qglVgaScreen () as long
declare sub qglTmrShutdown ()
declare sub qglDspShutdown ()
declare function qglTmrTicks () as long
declare sub qglKbdShutdown ()
declare sub qglMouseShutdown ()
declare sub qglMousePos ( byval x as integer, byval y as integer )
declare function qglSfZNew ( byval surf as long, byval kind as integer ) as long
declare sub qglDrFill ( byval d as long, _
                        byval x0 as integer, _
                        byval y0 as integer, _
                        byval x1 as integer, _
                        byval y1 as integer, _
                        byval col as integer )
'' `as single`, not `as long`: the fillers read this with `fmul D
'' qgl$zscale`, so what crosses is the float's bit pattern, not its
'' value. mgl's uglZScale took an integer and a `as long` here would
'' silently convert instead of reinterpreting.
declare function qglZScale ( byval f as single ) as long

declare sub sys_fp_native ()
declare function sys_fp_sites () as long
declare sub host_init ( _
    g as Game, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mdl_buffer() as Submodel, _
    order_list() as integer, _
    poly_flag() as integer, _
    gv_buf() as integer, _
    bit_array() as integer, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    mip_buff_inf() as MipTex, _
    frustum() as DiskPlane, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)
declare sub host_main ( _
    g as Game, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
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
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    tele() as Teleporter, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)

''
'' This module's own procedures.
''
declare sub host_shutdown ( )

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub draw_init_font ( )
declare sub in_screenshot_key ( _
    g as Game, _
    byval h_dst_dc as long _
)
declare sub vid_update ( _
    g as Game _
)
declare sub scr_pal_shift ( g as Game, byval dt as single )
declare function qglMemAvail ( byval what as integer ) as long
declare sub scr_draw_hud ( _
    g as Game, _
    h_dst_dc as long, _
    byval w as integer, _
    byval h as integer _
)
declare sub qglDrBlit ( _
    byval d as long, _
    byval x as integer, _
    byval y as integer, _
    byval s as long _
)
declare function sys_mem_count ( ) as integer
declare function sys_mem_fre ( byval i as integer ) as long
declare function sys_mem_tag ( byval i as integer ) as string
declare function sys_now ( ) as single
declare function sys_rdtsc ( ) as long
'' r_walk.c. Only caller is host_init's startup layout check.
declare function r_walk_layout_ok ( byval vis_off as long ) as integer
'' sb_build.c. Only caller is host_init's startup layout check.
declare function sb_layout_ok ( byval dlight_off as long ) as integer
'' d_faces.c, likewise: DrawParams is spelled out on both sides of the
'' BASIC/C boundary and only this says the two still agree.
declare function d_faces_layout_ok ( _
    byval sz as long, _
    byval drop_off as long _
) as integer
declare sub d_init_turb ( )
declare sub in_init ( _
    g as Game _
)
declare sub scr_begin_loading ( _
    g as Game _
)
declare sub sys_init_tables ( _
    g as Game, _
    bit_array() as integer, _
    frustum() as DiskPlane _
)
declare sub sys_parse_args ( _
    g as Game _
)
declare sub sys_time_init ( )
declare sub vid_init ( _
    g as Game _
)
declare sub qglMemInit ()
declare sub qglM4Persp ( _
    seg m as Mat4, _
    byval fov as single, _
    byval asp as single, _
    byval zn as single, _
    byval zf as single _
)
declare sub qglMemShutdown ()
declare sub mod_load_texinfo ( _
    g as Game, _
    tex_info() as TexInfo, _
    mip_buff_inf() as MipTex _
)
declare sub mod_load_world ( _
    g as Game, _
    faces() as Face, _
    tex_info() as TexInfo, _
    planes() as Plane, _
    nodes() as Node, _
    models() as Submodel, _
    ord() as integer, _
    pflag() as integer, _
    gv() as integer, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    plat() as PlatEnt, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
declare sub mod_open ( _
    g as Game, _
    models() as Submodel _
)
declare sub sb_dump ( _
    g as Game, _
    byval face as integer, _
    byval mip as integer, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    mip_buff_inf() as MipTex, _
    pln_buffer() as Plane _
)
declare sub ls_init ()
declare sub mod_close ( _
    g as Game _
)
declare sub mod_load_colormap ( _
    g as Game _
)
declare sub mod_load_textures ( _
    g as Game, _
    mip_buff_inf() as MipTex _
)
declare function sc_store_open ( ) as integer
declare sub sc_init ( _
    g as Game _
)
declare sub scr_count_frame ( _
    g as Game _
)
declare function sys_frame_time ( _
    g as Game _
) as single
declare sub ent_load_spawn ( _
    g as Game _
)
declare sub pl_init ( _
    g as Game _
)
declare sub pl_reset_player ( g as Game )
declare sub pl_carry_load ( g as Game )
declare function ent_monster_kinds ( _
    g as Game, _
    count as integer _
) as integer
declare function ent_load_monsters ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane, _
    mon() as MdlState _
) as integer
declare sub mdl_spawn ( _
    g as Game, _
    ent as MdlEnt, _
    org as Vec3, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)

'' Scattering the crowd across the map's own rooms rather than in one
'' ring: not from ents.bin, since mkassets never preprocesses deathmatch
'' spawns (ent_load_spawn's own note on why the entities text itself
'' never reaches the target) -- built instead from data already loaded
'' for rendering, a random non-solid LEAF and its own bounding box.
declare function r_leaf_contents ( byval leafnr as integer ) as integer
declare sub r_leaf_bound ( byval leafnr as integer, b as Bounds )
declare sub mdl_pick_section ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    byval done_count as integer, _
    fallback as Vec3, _
    picked as Vec3 _
)
const MDL_SECTION_TRIES%   = 30    '' random leaves tried before giving up
const MDL_SECTION_MINBOX%  = 96    '' a leaf smaller than this isn't a room
const MDL_SECTION_MIN_SEP# = 300.0 '' minimum floor distance between sections

''
'' Simulation time owed but not yet run. Frames deliver time in whatever
'' irregular amounts the renderer manages; the simulation spends it in equal
'' HOST_DT pieces, and whatever is left over waits here for the next frame.
''
dim shared host_accum as single
dim shared host_ticks as long          '' steps run, for the benchmark



'' Startup-only state. These were locals of the 700 line doInit; splitting it
'' into one routine per step is what promoted them, and they stay out of the
'' frame path entirely.
'' texiCount was the one lump count never declared shared. Inside the old
'' monolithic doInit that did not matter; once bspOpen and bspAlloc were
'' separate routines, bspAlloc read 0 and did redim texInfBuff(-1).
dim shared cam_up as Vec3    

'$dynamic
dim shared lightmap as long

''
'' THE DEPTH BUFFER. Created here and ATTACHED to the destination it was
'' made for, so nothing else has to be told about it: a draw reads the
'' depth of the surface it is drawing on. This handle only says whether
'' the allocation worked.
''
''
'' THE APPLICATION STATE. `dim`, not `dim shared`: module-level code can
'' see these and the procedures below cannot, so the compiler enforces
'' that everything receives what it needs rather than reaching for it.
''

dim g as Game

''
'' What is left of the shared arrays. REDIM forces them to module level,
'' so they live with the map arrays below and travel as parameters.
''
dim brush() as BrushModel
dim tele() as Teleporter
dim item() as ItemEnt
dim nail() as Spike
dim plat() as PlatEnt
dim door() as DoorEnt
dim trig() as TrigEnt
dim bit_array() as integer
dim frustum() as DiskPlane
dim mip_buff_inf() as MipTex
dim cp_x() as integer
dim cp_y() as integer
dim cp_z() as integer

''
'' THE MAP ARRAYS. Declared here because REDIM forces an array to module
'' level and something has to hold them -- this is the module that runs
'' the load and the frame, so nothing else needs to name them. World
'' describes them; the loaders bind them; everything below takes them as
'' parameters.
''
dim tri_buffer() as Face
dim tex_inf_buff() as TexInfo
dim pln_buffer() as Plane
dim nds_buffer() as Node
dim mdl_buffer() as Submodel
dim order_list() as integer
dim poly_flag() as integer
dim gv_buf() as integer

'' One alias (.mdl) model's geometry -- "mdl_buffer" above is already the
'' BSP submodel array (doors, platforms), a different "model" entirely;
'' these are named mdltri/mdlvert to not collide with it.

'' One spawned instance per element -- the asset (mdltri_buffer, above,
'' and mon()) is shared; only per-monster position/state lives here.
'' Sized in host_init to the map's monster count, MDL_CROWD% at least.
dim mdl_ent() as MdlEnt
'' the asset a kind's spawns share, indexed MDL_KIND_*
dim mon() as MdlState

''
'' view.bas. Declared here rather than in a header: main is the only
'' caller, and a header would hand them to modules that never call them.
''
declare sub v_open_script ( _
    g as Game _
)

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
    
    host_init g, tri_buffer(), tex_inf_buff(), pln_buffer(), nds_buffer(), _
              mdl_buffer(), order_list(), poly_flag(), gv_buf(), bit_array(), _
              cp_x(), cp_y(), cp_z(), mip_buff_inf(), _
              frustum(), brush(), tele(), plat(), door(), trig(), _
              mdl_ent(), item(), nail(), mon()
    if ( g.env.dump_tex ) then
        mod_tex_dump g
    elseif ( g.env.dump_set ) then
        sb_dump g, g.env.dump_face, g.env.dump_mip, tri_buffer(), tex_inf_buff(), _
                gv_buf(), mip_buff_inf(), pln_buffer()
    else
        host_main g, cp_x(), cp_y(), cp_z(), _
                  tri_buffer(), tex_inf_buff(), pln_buffer(), nds_buffer(), _
                  mdl_buffer(), order_list(), poly_flag(), gv_buf(), brush(), _
                  frustum(), bit_array(), _
                  mip_buff_inf(), plat(), door(), trig(), tele(), _
                  mdl_ent(), item(), nail(), mon()
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



''::::::::::::::
'' name: mdl_pick_section
'' desc: A candidate spawn point in a random room, not the ring around the
''       player host_init used before this. Rejects a leaf too small to
''       be a real room (MDL_SECTION_MINBOX%) and one too close to an
''       already-placed monster (MDL_SECTION_MIN_SEP#, checked against
''       mdl_ent()'s own SETTLED positions -- after mdl_spawn's
''       droptofloor, so "close" means close on the floor the entity
''       actually stands on, not close in an unrelated leaf's box).
''       Falls back to the caller's own point if nothing qualifies inside
''       the try budget: a spawn point beats no spawn point on a map this
''       heuristic fits badly.
''::::::::::::::
sub mdl_pick_section ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    byval done_count as integer, _
    fallback as Vec3, _
    picked as Vec3 _
)
    dim tries as integer, leafnr as integer, leaf_total as long
    dim b as Bounds
    dim cand as Vec3
    dim dx as single, dy as single
    dim k as integer, far_enough as integer

    leaf_total = g.wld.count.leaves

    for tries = 1 to MDL_SECTION_TRIES%
        leafnr = 1 + int( rnd * csng( leaf_total - 1 ) )
        if ( r_leaf_contents( leafnr ) = CONTENTS_EMPTY ) then
            r_leaf_bound leafnr, b
            if ( ( b.max.x - b.min.x ) >= MDL_SECTION_MINBOX% and _
                 ( b.max.y - b.min.y ) >= MDL_SECTION_MINBOX% ) then
                cand.x = ( b.min.x + b.max.x ) / 2.0
                cand.y = ( b.min.y + b.max.y ) / 2.0
                '' near the FLOOR end of the leaf's own bound, not its
                '' vertical centre -- a tall room's centre can sit well
                '' past mdl_spawn's own 256-unit droptofloor search depth,
                '' leaving the entity floating with nothing to correct it.
                cand.z = b.min.z + 16.0

                far_enough = -1
                for k = 0 to done_count - 1
                    dx = cand.x - mdl_ent(k).pos.x
                    dy = cand.y - mdl_ent(k).pos.y
                    if ( dx*dx + dy*dy < MDL_SECTION_MIN_SEP# * MDL_SECTION_MIN_SEP# ) then
                        far_enough = 0
                        exit for
                    end if
                next k

                if ( far_enough ) then
                    picked = cand
                    exit sub
                end if
            end if
        end if
    next tries

    picked = fallback
end sub

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
sub host_init ( _
    g as Game, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mdl_buffer() as Submodel, _
    order_list() as integer, _
    poly_flag() as integer, _
    gv_buf() as integer, _
    bit_array() as integer, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    mip_buff_inf() as MipTex, _
    frustum() as DiskPlane, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)
    ''
    '' Load profiling. A 1 kHz AUTOINIT timer counts milliseconds, and the
    '' phase boundaries below are recorded so load time can be attributed
    '' rather than guessed -- twice now a bottleneck has been asserted from
    '' the shape of the code and been wrong.
    ''
    dim dp_probe as DrawParams      '' the layout check below, nothing else
    dim t_start as single, t_sub as single, t_map as single
    dim t_lump as single, t_tex as single, t_vid as single
    dim pf as integer

    '' Before anything computes: every float below is an emulator
    '' interrupt until its site has run once. fp87.asm.
    sys_fp_native

    ''
    '' r_walk.c hardcodes vis's byte offset within Game (measured once,
    '' not derived from the five structs ahead of it) because r_bsp.bas's
    '' r_recursive_world_node now lives there. A field added ahead of vis
    '' in q_game.bi would silently shift that offset and corrupt whatever
    '' VisState field the wrong address lands on -- checked here instead,
    '' once, at startup, so that shows up as a loud, clear exit instead.
    ''
    if ( r_walk_layout_ok( varptr( g.vis ) - varptr( g ) ) = 0 ) then
        sys_error "0x0041, r_walk.c's Game.vis offset is stale, is now" + str$( varptr( g.vis ) - varptr( g ) )
    end if
    if ( sb_layout_ok( varptr( g.rdr.dlight ) - varptr( g ) ) = 0 ) then
        sys_error "0x0042, sb_build.c's Game.rdr.dlight offset is stale, is now" + str$( varptr( g.rdr.dlight ) - varptr( g ) )
    end if
    '' DrawParams crosses to d_faces.c by layout alone. Three fields
    '' dropped from q_draw.bi and left in qcshared.h shifted every field
    '' after them, and the frame came back empty with polys 0 -- the C
    '' side was reading ord_count and x_res out of the wrong words.
    if ( d_faces_layout_ok( len( dp_probe ), _
                            varptr( dp_probe.qgl_drop ) - varptr( dp_probe ) ) = 0 ) then
        sys_error "0x0043, d_faces.c's DrawParams layout is stale, len is" + str$( len( dp_probe ) ) + " drop at" + str$( varptr( dp_probe.qgl_drop ) - varptr( dp_probe ) )
    end if

    '' TIMER, not qglTmrTicks: the PIT is not hooked until sys_time_init,
    '' after the load. TIMER is ~55ms granular, which is fine for phases
    '' measured in seconds.
    t_start = timer

    '' arguments and subsystems
    sys_parse_args g

    '' -qglcheck: the qgl ABI and behaviour test, before anything else is
    '' set up. It is the only BASIC caller of qgl, and it exits.
    if ( g.qgl_check ) then
        dim qglbad as integer
        qglbad = qglCheckAll()
        system
    end if

    sys_init_tables g, bit_array(), frustum()
    sys_mem_mark "start"
    d_init_turb
    qglMemInit

    '' qgl probes INT 67h before the first qglGemAlloc, which refuses
    '' until it has. Here, not at the first qgl
    '' allocation: mod_load_textures loads the atlas long before the
    '' surface cache opens, and sc_store_open's own call was too late
    '' -- the atlas load failed with 0x0016 and nothing said why.
    if ( qglSfInit() = 0 ) then sys_error "0x0017, qgl has no EMS"
    sys_mem_mark "meminit"

    '' -qgldiff: qgl's rasteriser against mgl's, which it brings up and
    '' ends itself. Before the map, because nothing it draws comes from
    '' one.
    if ( g.qgl_diff ) then
        dim qgldbad as integer
        qgldbad = qglDiffAll()
        qglVgaShutdown
        system
    end if
    '' -qglarr: the paged-array store against a real .pag fixture.
    '' BEFORE mod_open, because that is the last point at which all four
    '' of uglArrNew's UA_MAX stores are still free -- afterwards leaves,
    '' faces, nodes and clip have taken every one and a fifth cannot be
    '' created to test with.
    if ( g.qgl_arr ) then
        dim qglabad as integer
        qglabad = qglArrAll()
        qglVgaShutdown
        system
    end if

    draw_init_font
    sys_mem_mark "font"

    '' map file and the loading screen
    t_sub = timer

    mod_open g, mdl_buffer()
    sys_mem_mark "mapopen"
    scr_begin_loading g
    ent_load_spawn g
    pl_init g
    g.fight.spawn.x = g.pl.pos.x : g.fight.spawn.y = g.pl.pos.y : g.fight.spawn.z = g.pl.pos.z
    pl_reset_player g
    if ( g.fight.carry ) then pl_carry_load g
    '' a headless run has no one to press fire, and its frame is a reference
    g.fight.state = GS_TITLE%
    if ( g.env.bench_frames > 0 or g.env.bench_ticks > 0 or g.env.cam_path ) then g.fight.state = GS_PLAY%

    t_map = timer

    '' level lumps
    mod_load_world g, tri_buffer(), tex_inf_buff(), pln_buffer(), nds_buffer(), _
                    mdl_buffer(), order_list(), poly_flag(), gv_buf(), brush(), tele(), _
                    plat(), item(), door(), trig()
    pl_items_drop g, item(), mdl_buffer(), brush(), pln_buffer()

    t_lump = timer

    '' textures and palette
    mod_load_texinfo g, tex_inf_buff(), mip_buff_inf()
    mod_load_textures g, mip_buff_inf()
    sys_mem_mark "textures"

    mod_close g
    sys_mem_mark "mapclose"

    sc_init g
    '' the store now, not at the first lit face: its 16K conventional
    '' scratch comes out of DOS's block here, where the shrink of BASIC's
    '' heap it took mid-frame raised Out of memory on e1m1
    if ( sc_store_open() = 0 ) then sys_error "0x0047, no surface cache store"
    ls_init
    sys_mem_mark "surfcache"

    t_tex = timer

    '' hand over to the real video mode
    vid_init g
    sys_mem_mark "backbuf"

    in_init g

    '' After the mode switch, deliberately. vid_init needs a sizeable
    '' block for the video DC, and holding the colormap's 16K across it
    '' left it short -- the program wedged inside vid_init with no error,
    '' having got all the way through loading. Nothing needs the table
    '' until the first surface is built.
    if ( g.env.use_lm ) then mod_load_colormap g
    sys_mem_mark "colormap"

    '' A crowd of one alias model, each wandering on its own (mdl_think,
    '' pl_move.bas) rather than loaded-and-static: the "basic version"
    '' milestone this started as. The game's own palette (set inside
    '' vid_init, above) already applies -- the skin's indices come from
    '' the same Quake palette mkmdl.py baked them from, so nothing extra
    '' to install here.
    '' Only the kinds this map's monsters are -- a kind loaded costs
    '' about a K of far heap -- or the crowd's soldiers and knights on
    '' a map with none
    dim mon_kinds as integer, mon_count as integer
    mon_kinds = ent_monster_kinds( g, mon_count )
    if ( mon_kinds = 0 ) then mon_kinds = 3
    if ( mon_count < MDL_CROWD% ) then mon_count = MDL_CROWD%
    redim mon( MDL_KINDS% - 1 ) as MdlState
    if ( mon_kinds and 1 ) then mdl_load g, mon( MDL_KIND_ARMY% ), "soldier"
    mdl_load g, g.vmdl, "v_shot"
    host_view_load g
    if ( mon_kinds and 2 ) then mdl_load g, mon( MDL_KIND_KNIGHT% ), "knight"
    if ( mon_kinds and 4 ) then mdl_load g, mon( MDL_KIND_DOG% ), "dog"
    if ( mon_kinds and 8 ) then mdl_load g, mon( MDL_KIND_OGRE% ), "ogre"
    if ( mon_kinds and 16 ) then mdl_load g, mon( MDL_KIND_DEMON% ), "demon"
    if ( mon_kinds and 32 ) then mdl_load g, mon( MDL_KIND_ZOMBIE% ), "zombie"
    if ( mon_kinds and 64 ) then mdl_load g, mon( MDL_KIND_WIZARD% ), "wizard"
    if ( mon_kinds and 128 ) then mdl_load g, mon( MDL_KIND_SHAMBLER% ), "shambler"
    snd_init g
    '' mdl_pick_section places every model from rnd, so a clock
    '' seed leaves the saved frame unrepeatable. Bench only.
    if ( g.env.bench_frames > 0 or g.env.bench_ticks > 0 ) then
        randomize 1
    else
        randomize timer
    end if
    dim mdl_i as integer
    dim mdl_spawn_rad as single, mdl_spawn_fallback as Vec3, mdl_spawn_org as Vec3
    '' sized whatever the map has: a map with no soldier still has the
    '' nails, and ubound of an array never made is error 9 (e1m3)
    redim mdl_ent( mon_count - 1 ) as MdlEnt
    redim nail( PL_NAILS_MAX% - 1 ) as Spike
    '' the map's own, where it put them; a deathmatch map has none
    g.mdl_count = ent_load_monsters( g, mdl_ent(), mdl_buffer(), brush(), pln_buffer(), mon() )
    if ( g.mdl_count = 0 and mon( MDL_KIND_ARMY% ).loaded ) then
        for mdl_i = 0 to MDL_CROWD% - 1
            '' the old ring around the player, kept as mdl_pick_section's
            '' own fallback when the map doesn't offer enough separated
            '' rooms (or on a mishap: a leaf whose box centre sits inside
            '' geometry the droptofloor trace below can't recover from).
            '' seeded from the map's own angle, as before the yaw mirror,
            '' so the crowd the fight and model gates stand beside stays put
            mdl_spawn_rad = ( 360.0 - g.cam.start_angle + mdl_i * ( 360.0 / MDL_CROWD% ) ) * 0.017453293
            mdl_spawn_fallback.x = g.pl.pos.x + 96.0 * cos( mdl_spawn_rad )
            mdl_spawn_fallback.y = g.pl.pos.y + 96.0 * sin( mdl_spawn_rad )
            mdl_spawn_fallback.z = g.pl.pos.z

            '' every other one a knight, when its model loaded
            mdl_ent( mdl_i ).kind = MDL_KIND_ARMY%
            mdl_ent( mdl_i ).patrol = -1
            if ( mon( MDL_KIND_KNIGHT% ).loaded and ( mdl_i and 1 ) ) then mdl_ent( mdl_i ).kind = MDL_KIND_KNIGHT%
            mdl_pick_section g, mdl_ent(), mdl_i, mdl_spawn_fallback, mdl_spawn_org
            mdl_spawn g, mdl_ent( mdl_i ), mdl_spawn_org, mdl_buffer(), brush(), pln_buffer()
        next mdl_i
        g.mdl_count = MDL_CROWD%
    end if
    '' where they stood: a bench run is aimed at one with -at
    if ( g.env.bench_frames > 0 or g.env.bench_ticks > 0 ) then
        dim mdl_sf as integer
        mdl_sf = freefile
        open "spawn.txt" for output as #mdl_sf
        for mdl_i = 0 to g.mdl_count - 1
            print #mdl_sf, mdl_ent( mdl_i ).kind; mdl_ent( mdl_i ).pos.x; mdl_ent( mdl_i ).pos.y; mdl_ent( mdl_i ).pos.z
        next mdl_i
        close #mdl_sf
    end if

    t_vid = timer

    if ( g.env.bench_frames > 0 ) then
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
sub host_main ( _
    g as Game, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
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
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    tele() as Teleporter, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    nail() as Spike, _
    mon() as MdlState _
)
    dim mtx_prj as Mat4
    dim aspect as single
    
    
    dim h_dst_dc as long
    dim xresh as single, yresh as single
    
    dim i as integer
    dim frame_no as long
    dim pt0 as single, ptd as single
    dim pr0 as long, prd as long
    dim ht0 as single, htd as single
    dim lp0 as single, lpd as single
    dim benchf as integer
    
    ''
    '' min/max/bmin/bmax/extn went with the lightmap extent computation in
    '' the draw loop, which produced values nothing read.
    ''
    dim poly_vert as integer
    ''
    '' Per-face texture axes with the texture size folded in, and the
    '' per-vertex projection the triangle fan shares. See the draw loop.
    ''

    xresh = g.env.x_res/2.0
    yresh = g.env.y_res/2.0

    ''
    '' Wipe the loading screen. It draws across the whole mode, and
    '' from here on only the view is blitted -- so anything it left
    '' outside the view would sit in the border for the whole run.
    ''
    qglDrFill qglVgaScreen(), 0, 0, g.env.scr_x_res-1, g.env.scr_y_res-1, 0

    qglMousePos 0, 0


    cam_up.x = 0.0
    cam_up.y = 1.0
    cam_up.z = 0.0   
    
    if ( g.env.yaw_set ) then g.cam.start_angle = g.env.start_yaw
    '' v_update_camera reads the pitch off mouse y: phi = pi * (y+2) / y_res,
    '' level at y_res/2 - 2. 110 is where it always started, 11 degrees down
    dim mouse_y as single
    mouse_y = 110
    if ( g.env.pitch_set ) then mouse_y = g.env.scr_y_res * ( 90.0 - g.env.start_pitch ) / 180.0 - 2.0
    qglMousePos (g.env.scr_x_res-1) * g.cam.start_angle/360.0, mouse_y
    
    

    
    v_open_script g
    
    
    
    
    dim zz as long                  '' soaks up uglZScale/uglZMode's
                                    '' return; the call is the point
    
    h_dst_dc = g.env.h_back_bdc
    
    ''
    '' The view's PHYSICAL shape, not its pixel count. A 320x200 mode
    '' is displayed 4:3, so its pixels are taller than they are wide,
    '' and a view covers only the fraction of that shape its pixels
    '' covers. It is the DRAWN rect, so scaling the view up widens
    '' the projection to match. Full screen this is 320/240 -- the
    '' constant that used to sit here -- so a full-screen render is
    '' unchanged; a square 64x64 view comes out 0.833 and is drawn
    '' round rather than stretched.
    ''
    aspect = (g.env.view_w * g.env.scr_y_res * DISPLAY_W) / _
             (g.env.view_h * g.env.scr_x_res * DISPLAY_H)
    qglM4Persp mtx_prj, g.env.cam_fov, aspect, g.env.z_near, g.env.z_far

    ''
    '' Depth buffer, matching the destination. Conventional first: 160x100
    '' of depth is 32,000 bytes against the 262,416 the memtrace shows
    '' free after the backbuffer, and a page the fillers never have to
    '' map. EMS on a refusal, which is what 320x200's 128,000 gets.
    ''
    '' The scale maps 1/z into 16 bits. 1/z is largest at the near plane,
    '' so 65535 * z_near puts the nearest thing drawn at the top of the
    '' range; anything closer would saturate, and nothing is, because the
    '' clipper drops it first.
    ''
    '' THE BUFFER IS ATTACHED TO THE BACKBUFFER, not held here. Nothing
    '' passes it anywhere afterwards -- a draw reads the depth of the
    '' surface it is drawing on -- so this handle exists only to say
    '' whether the allocation worked. The scale is the projection's and
    '' stays global: every depth buffer in the frame is in its units.
    z_dc = 0
    if ( g.env.no_z = 0 ) then
        '' conventional only when DOS can give it: a refusal makes
        '' qglMemAlloc shrink BASIC's heap, and e1m1 has none to spare
        if ( qglMemAvail( QGL_MEM_LARGEST ) >= 2& * g.env.x_res * g.env.y_res + 1024 ) then
            z_dc = qglSfZNew&( h_dst_dc, QGL_SURF_CMEM )
        end if
        if ( z_dc = 0 ) then z_dc = qglSfZNew&( h_dst_dc, QGL_SURF_EMS )
        if ( z_dc = 0 ) then sys_error "0x0019, no qgl depth buffer"
        zz = qglZScale&( 65535.0 * g.env.z_near )
    end if
    sys_mem_mark "depth"
    
    g.rdr.use_mips = (g.env.no_mip = 0)
    '' follows -lm: with no lightmap data loaded there is nothing to toggle
    g.rdr.lightmap = g.env.use_lm
    g.rdr.rend_mode = g.env.affine
    g.cam.fps_view = -1
    ''
    '' On by default. The cull is a single sign test against the face's own
    '' plane, and a sealed level cannot show a back face, so enabling it must
    '' leave the image untouched while the polygon count falls.
    ''
    g.rdr.backface = -1
    if ( g.env.no_cull ) then g.rdr.backface = 0
    g.rdr.portal = not g.env.no_portal
    g.scr.portal_wire = g.env.pt_wire
    g.scr.stats    = 0
    if ( g.env.want_stats ) then g.scr.stats = -1
    if ( g.env.no_stats ) then g.scr.stats = 0

    '' 3K of far heap, only when a route steers the camera
    if ( g.env.cam_path ) then
        redim cp_x(CP_MAX) as integer
        redim cp_y(CP_MAX) as integer
        redim cp_z(CP_MAX) as integer
        cp_load g, cp_x(), cp_y(), cp_z()
    end if
    g.vis.bad_order = g.env.bad_order
    g.vis.no_ents   = g.env.no_ents
    
    ''
    ''
    ''
    sys_time_init
    g.env.sec_mark = qglTmrTicks()

    do
    	''
    	'' Clear DC
    	''
        if ( g.env.clear_screen = true ) then
            qglDrFill h_dst_dc, 0, 0, g.env.x_res - 1, g.env.y_res - 1, 0
        end if

        ''
        '' Measured once, at the top of the frame, and used by everything that
        '' moves. Every such update multiplies by it, so the game plays the
        '' same whether it runs at 15 fps or 60.
        ''
        g.scr.frame_time = sys_frame_time( g )
        lp0 = sys_now()

        '' Skip the first few frames: they carry the tail of loading and
        '' the first surface builds, which no later frame repeats.
        if ( frame_no > 3 and g.ft.raw_dt > 0.0 ) then
            if ( g.ft.n = 0 ) then
                host_pt_init g
                g.ft.min = g.ft.raw_dt
                g.ft.max = g.ft.raw_dt
            else
                if ( g.ft.raw_dt < g.ft.min ) then g.ft.min = g.ft.raw_dt
                if ( g.ft.raw_dt > g.ft.max ) then g.ft.max = g.ft.raw_dt
            end if
            g.ft.sum = g.ft.sum + g.ft.raw_dt
            g.ft.n   = g.ft.n + 1
        end if

        pt0 = sys_now()
        host_advance g, g.scr.frame_time, brush(), mdl_buffer(), pln_buffer(), _
                      nds_buffer(), cp_x(), cp_y(), cp_z(), tele(), plat(), door(), trig(), _
                      host_accum, host_ticks, mdl_ent(), item(), nail(), mon()
        if ( g.ft.n > 0 ) then
            ptd = sys_now() - pt0
            g.pt.tick_sum = g.pt.tick_sum + ptd
            if ( ptd > g.pt.tick_max ) then g.pt.tick_max = ptd
            if ( ptd < g.pt.tick_min ) then g.pt.tick_min = ptd
        end if

        snd_frame g

        '' cp_advance is called from view.bas now, where the movement
        '' input is assembled -- it steers the player rather than placing
        '' the camera.

        ''
        '' Combine all transforms
        ''
        host_render g, h_dst_dc, mtx_prj, xresh, yresh, tri_buffer(), tex_inf_buff(), _
                     pln_buffer(), nds_buffer(), mdl_buffer(), order_list(), poly_flag(), _
                     gv_buf(), brush(), frustum(), bit_array(), _
                     mip_buff_inf(), cam_up, _
                     mdl_ent(), item(), nail(), mon()


        ''
        '' Benchmark mode: a fixed frame budget makes a run repeatable and
        '' headless. Without it verification needs a live debugger socket to
        '' drive a screenshot, and an identical picture cannot tell a working
        '' build from one that never rebuilt -- the frame count and fps here
        '' can.
        ''
        frame_no = frame_no + 1
        '' -qglface: the LAST frame of the run, not the first. One frame
        '' froze the same face whatever -at and -yaw said -- two yaws 34
        '' degrees apart returned byte-identical vertices -- so the oracle
        '' could never be pointed at a face that looked wrong on screen.
        '' -bench N picks the frame; without it this is still frame 1.
        if ( g.qgl_face and frame_no >= g.env.bench_frames ) then
            dim qglfbad as integer
            qglfbad = qglFaceAll()
            qglVgaShutdown
            system
        end if
        '' -campath ends when the route does, whatever -bench says
        if ( g.env.cam_path and g.cp.done ) then
            host_bench_report g, frame_no, h_dst_dc, brush(), plat(), door(), trig(), mdl_ent(), host_ticks, mon(), mdl_buffer(), nds_buffer(), pln_buffer()
            exit do
        end if
        if ( g.env.bench_ticks > 0 and host_ticks >= g.env.bench_ticks ) then
            host_bench_report g, frame_no, h_dst_dc, brush(), plat(), door(), trig(), mdl_ent(), host_ticks, mon(), mdl_buffer(), nds_buffer(), pln_buffer()
            exit do
        end if
        if ( g.env.bench_frames > 0 and frame_no >= g.env.bench_frames ) then
            host_bench_report g, frame_no, h_dst_dc, brush(), plat(), door(), trig(), mdl_ent(), host_ticks, mon(), mdl_buffer(), nds_buffer(), pln_buffer()
            exit do
        end if

        in_screenshot_key g, h_dst_dc
        ''
        '' RDTSC, not sys_now: present is one call, ~3-4ms against a
        '' clock that ticks every ~6.9ms, so a single sys_now sample only
        '' ever reads as 0 or one whole tick -- the same under-resolution
        '' problem raster and build already needed RDTSC for, just with
        '' one event a frame instead of many to sum. Same glitch guard as
        '' both of those: a negative or implausibly large delta is a
        '' glitched sample (see sys_rdtsc's own doc comment), discarded
        '' rather than folded into the mean.
        ''
        pr0 = sys_rdtsc()
        vid_update g
        scr_pal_shift g, g.scr.frame_time
        ''
        '' -comp: vid_update scaled the view into the composite and left the
        '' screen alone, so the overlay goes on at the mode's own size and one
        '' blit carries the result to video. Drawing it on the screen after a
        '' present is a second pass over live video memory, and it tears.
        ''
        if ( g.env.comp ) then
            ht0 = sys_now()
            scr_draw_hud g, g.env.h_comp_dc, g.env.scr_x_res, g.env.scr_y_res
            if ( g.ft.n > 0 ) then
                htd = sys_now() - ht0
                g.pt.hud_sum = g.pt.hud_sum + htd
                if ( htd > g.pt.hud_max ) then g.pt.hud_max = htd
                if ( htd < g.pt.hud_min ) then g.pt.hud_min = htd
            end if
            qglDrBlit qglVgaScreen(), 0, 0, g.env.h_comp_dc
        end if
        if ( g.ft.n > 0 ) then
            prd = sys_rdtsc() - pr0
            if ( prd >= 0 and prd <= 1000000 ) then
                ptd = prd / 1000000.0
                g.pt.present_sum = g.pt.present_sum + ptd
                if ( ptd > g.pt.present_max ) then g.pt.present_max = ptd
                if ( ptd < g.pt.present_min ) then g.pt.present_min = ptd
                g.pt.present_n = g.pt.present_n + 1
            end if
        end if
        if ( g.ft.n > 0 ) then
            lpd = sys_now() - lp0
            g.pt.loop_sum = g.pt.loop_sum + lpd
            if ( lpd > g.pt.loop_max ) then g.pt.loop_max = lpd
            if ( lpd < g.pt.loop_min ) then g.pt.loop_min = lpd
            g.pt.loop_n = g.pt.loop_n + 1
        end if
        scr_count_frame g

        ''
        '' -benchsecs: a wall-clock budget instead of a frame/tick count, for
        '' fast iteration. g.scr.bench_secs is ticked once per real second by
        '' scr_count_frame just above, so this must run after it.
        ''
        if ( g.env.bench_secs > 0 and g.scr.bench_secs >= g.env.bench_secs ) then
            host_bench_report g, frame_no, h_dst_dc, brush(), plat(), door(), trig(), mdl_ent(), host_ticks, mon(), mdl_buffer(), nds_buffer(), pln_buffer()
            exit do
        end if

    loop while ( g.env.keyboard.esc = FALSE and g.fight.state <> GS_NEXT% )
    
    if ( g.cam.script_file <> 0 ) then close #g.cam.script_file

end sub


''::::
sub host_shutdown
    
    ''
    '' Unhook, give the PIT, the mode and DOS's memory settings back.
    ''
    qglKbdShutdown
    qglMouseShutdown
    qglTmrShutdown
    qglDspShutdown
    qglVgaShutdown
    qglMemShutdown
    
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
sub cp_load ( _
    g as Game, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer _
)
    dim f as integer
    dim i as integer, n as integer
    dim x as integer, y as integer, z as integer

    g.cp.n = 0
    g.cp.i = 0
    g.cp.t = 0.0

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
    g.cp.n = n
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
sub cp_advance ( _
    g as Game, _
    byval dt as single, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer _
)
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
    if ( g.cp.n < 1 or g.cp.done ) then exit sub

    ''
    '' Start ON the route. The spawn is wherever the map puts it, and
    '' waypoint 0 is at one extreme of the level -- so from the spawn the
    '' steering aimed at a target most of a map away and walked straight
    '' into the first wall between. Every waypoint is a verified standing
    '' position, so dropping the player on one is safe; gravity settles it.
    ''
    if ( g.cp.started = 0 ) then
        g.pl.pos.x = cp_x(0)
        g.pl.pos.y = cp_y(0)
        g.pl.pos.z = cp_z(0)
        g.pl.vel.x = 0.0
        g.pl.vel.y = 0.0
        g.pl.vel.z = 0.0
        g.cp.i     = 1
        g.cp.last_x = g.pl.pos.x
        g.cp.last_y = g.pl.pos.y
        g.cp.started  = -1
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
    best  = g.cp.i
    bestd = 1e30
    k = g.cp.i
    do while ( k <= g.cp.i + 12 and k <= g.cp.n-1 )
        dx = cp_x(k) - g.pl.pos.x
        dy = cp_y(k) - g.pl.pos.y
        dl = dx*dx + dy*dy
        if ( dl < bestd ) then
            bestd = dl
            best  = k
        end if
        k = k + 1
    loop
    g.cp.i = best

    '' done when the last waypoint is the nearest and we are on it
    if ( g.cp.i >= g.cp.n-1 ) then
        dx = cp_x(g.cp.n-1) - g.pl.pos.x
        dy = cp_y(g.cp.n-1) - g.pl.pos.y
        if ( sqr( dx*dx + dy*dy ) < CP_REACH * 2.0 ) then
            g.cp.done = -1
            exit sub
        end if
    end if

    ''
    '' Pure pursuit: aim at the first waypoint at least CP_AHEAD away,
    '' not at the one we are about to reach. A near target's bearing
    '' swings wildly as it is approached; a far one's barely moves.
    ''
    k = g.cp.i
    do while ( k < g.cp.n-1 )
        dx = cp_x(k) - g.pl.pos.x
        dy = cp_y(k) - g.pl.pos.y
        if ( sqr( dx*dx + dy*dy ) >= CP_AHEAD ) then exit do
        k = k + 1
    loop
    dx = cp_x(k) - g.pl.pos.x
    dy = cp_y(k) - g.pl.pos.y
    dl = sqr( dx*dx + dy*dy )

    if ( dl > 0.001 ) then
        g.cp.dir_x = dx / dl
        g.cp.dir_y = dy / dl
    end if

    '' Stuck? The hull is against something the path did not know about.
    '' Give up on this waypoint rather than grinding into a wall forever.
    if ( abs(g.pl.pos.x - g.cp.last_x) + abs(g.pl.pos.y - g.cp.last_y) < 0.5 ) then
        g.cp.stuck = g.cp.stuck + 1
        if ( g.cp.stuck > 60 ) then
            g.cp.stuck = 0
            g.cp.i = g.cp.i + 1
            if ( g.cp.i > g.cp.n-1 ) then g.cp.done = -1
        end if
    else
        g.cp.stuck = 0
    end if
    g.cp.last_x = g.pl.pos.x
    g.cp.last_y = g.pl.pos.y
end sub






