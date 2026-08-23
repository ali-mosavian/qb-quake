type vec3
    x           as single
    y           as single
    z           as single
end type

type vec3i
    x           as integer
    y           as integer
    z           as integer
end type

type boundbox
    min         as vec3
    max         as vec3
end type

type bboundbox
    min         as vec3i
    max         as vec3i
end type

type dentry
    offs        as long
    size        as long
end type

type header
    version     as long
    entities    as dentry
    planes      as dentry
    miptex      as dentry
    vertices    as dentry
    vislist     as dentry
    nodes       as dentry
    texinfo     as dentry
    faces       as dentry
    lightmaps   as dentry
    clipnode    as dentry
    leaves      as dentry
    lface       as dentry
    edges       as dentry
    ledges      as dentry
    models      as dentry
end type

type model
    mins        as vec3
    maxs        as vec3
	origin      as vec3
	headnode0   as long
	headnode1   as long
	headnode2   as long
	headnode3   as long
	visleafs    as long
	firstface   as long
	numfaces    as long
end type

type vertex
    x           as single
    y           as single
    z           as single
end type

type surface
    vector_s    as vec3
    dist_s      as single
    vector_t    as vec3
    dist_t      as single    
    textureid   as long
    animated    as long
end type

type edge
    v0          as integer    
    v1          as integer    
end type

type face
    planeid     as integer
    side        as integer
    ledgeid     as long
    ledgenum    as integer
    texinfoid   as integer
    flag1       as integer
    flag2       as integer
    lightmap    as long    
end type 

type face2
    planeid     as integer
    side        as integer    
    ledgeid     as long
    ledgenum    as integer
    texinfoid   as integer
    lightmap    as long    
end type 

type leaf
    cont        as long
    vislist     as long    
    bound       as bboundbox
    lfaceid     as integer
    lfacenum    as integer
    stuff       as string * 4
end type

type leaf2    
    cont        as long         '' CONTENTS_*: only hull 0 knows about water
    vislist     as long    
    bound       as bboundbox
    lfaceid     as integer
    lfacenum    as integer    
end type

type plane
    norm        as vec3
    dist        as single
    ptype       as long    
end type

type plane2
    norm        as vec3
    dist        as single
    ptype       as integer
end type

type node
    planeid     as long
    child0      as integer    
    child1      as integer    
    bound       as bboundbox
    lfaceid     as integer
    lfacenum    as integer
end type

type nodeb
    planeid     as integer
    child0      as integer    
    child1      as integer
    lfaceid     as integer
    lfacenum    as integer
    bound       as bboundbox
end type

type texinfo
    vecs(3)     as single
    vect(3)     as single
    miptex      as long
    flags       as long
end type


type miptex
    name        as string * 16
    wdth        as long
    hght        as long
    offset(3)   as long
end type

type miptexb    
    wdth        as single
    hght        as single
    lnext       as integer
    liquid      as integer      '' name began with *: scrolls
    anim_base   as integer      '' name began with +N: first frame's index,
    anim_count  as integer      '' and how many frames the chain has
end type


type clipnode
    planenum    as long
    front       as integer
    back        as integer
end type


const FALSE = 0
const TRUE  = -1

type EnvType
    z_far       as single
    z_near      as single    
    
    h_font      as long
    h_video_dc  as long
    h_back_bdc  as long
    
    mouse       as MOUSEINF
    keyboard    as TKBD
    
    fps_timer   as TMR                      '' expires every frame
    sec_timer   as TMR                      '' /       every second
    
    x_res       as integer
    y_res       as integer
    c_fmt       as integer
    pages       as integer
    usepag      as integer
    disclear    as integer
    
    sound       as integer
    camfov      as single
    cammode     as integer
    caminterp   as integer   
    camscrpt    as string * 40

    '' Set from the command line, not from stuff.ini.
    map_name    as string * 64
    bench_frames as integer      '' 0 = run until ESC
    bench_walk  as integer      '' -walk: hold forward, to exercise the
                                '' collision response without a keyboard
    bench_jump  as integer      '' -jump: hold jump, likewise
    bench_strafe as integer     '' -strafe: hold strafe, to check its sign
    start_x     as single       '' -at X Y Z: start here instead of the map's
    start_y     as single       '' spawn point. For reaching a part of the
    start_z     as single       '' level without walking to it first.
    start_set   as integer
    bench_ticks as integer      '' -ticks N: stop after N simulation steps
                                '' rather than N frames, so two runs at
                                '' different framerates simulate exactly the
                                '' same thing and must agree
    
end type

const DEG2RAD# = 3.14159265359 / 180.0

'' defined in main.bas, called from model.bas -- within one module
'' BASIC auto-declares, across modules it needs this.
declare sub draw_bar ( h_dc as long, x as integer, y as integer, wdt as integer, _
                            hgt as integer, percent as single, col as long )
declare sub scr_load_tick ( )
declare sub mod_close ( )
declare sub scr_mip_tick  ( percent as single )
declare sub host_init    ( )
declare sub host_main    ( )
declare sub host_shutdown     ( )
declare sub host_tick ( byval dt as single )
declare sub host_advance ( byval real_dt as single )
declare sub host_render ( byval h_dst_dc as long, mtx_prj as u3dMtrx, _
                         byval xresh as single, byval yresh as single )
declare sub host_bench_report ( frame_no as long, h_dst_dc as long )
declare sub sys_error ( msg as string )
declare sub sys_time_init ( )
declare function sys_frame_time ( ) as single
declare function sys_tick_hz ( ) as single
declare sub r_mark_leaves ( byval nodenr as integer )
declare sub r_draw_world ( model as integer )
declare sub r_draw_brush_model ( byval m as integer )
declare sub v_update_camera ( byval dt as single )
declare sub in_handle_toggles ( )
''
'' pl_move.bas -- player physics
''
declare function pl_hull_contents ( byval node as integer, p as vec3 ) as integer
declare function pl_hull_check ( byval node as integer, byval p1f as single, _
                                 byval p2f as single, p1 as vec3, p2 as vec3 ) as integer
declare sub pl_trace ( start as vec3, fin as vec3 )
declare sub pl_clip_velocity ( v as vec3, norm as vec3 )
declare sub pl_slide_move ( org as vec3, vel as vec3, byval dt as single )
declare sub pl_step_move ( org as vec3, vel as vec3, byval dt as single )
declare function pl_point_contents ( p as vec3 ) as integer
declare sub pl_water_level ( )
declare sub pl_gravity ( byval dt as single )
declare sub pl_init ( )
declare sub pl_move ( byval fwd as single, byval strafe as single, _
                     byval dir_x as single, byval dir_y as single, _
                     byval jump as integer, byval dt as single )

declare sub v_open_script ( )
declare function in_keystroke ( key_down as integer ) as integer
declare sub d_init_turb ( )
declare sub d_draw_faces ( h_dst_dc as long, mtx_fin as u3dMtrx, _
                           xresh as single, yresh as single )
declare sub scr_draw_hud ( h_dst_dc as long )
declare sub vid_update ( h_dst_dc as long, page as integer )
declare sub scr_count_frame ( )
declare sub in_screenshot_key ( h_dst_dc as long )

'' Startup steps, in the order doInit runs them. Each is entered once,
'' which is the whole reason they are separate routines.
declare sub sys_parse_args ( )
declare sub sys_init_tables ( )
declare sub vid_init_ugl ( )
declare sub s_init ( )
declare sub s_start_music ( )
declare sub draw_init_font ( )
declare sub mod_open ( )
declare sub scr_begin_loading ( )
declare sub mod_find_spawn ( )
declare sub mod_alloc ( )
declare sub mod_load_vertexes ( )
declare sub mod_load_faces ( )
declare sub mod_load_edges ( )
declare sub mod_load_surfedges ( )
declare sub mod_load_leafs ( )
declare sub mod_load_marksurfaces ( )
declare sub mod_load_nodes ( )
declare sub mod_load_planes ( )
declare sub mod_load_submodels ( )
declare sub mod_load_visibility ( )
declare sub mod_load_clipnodes ( )

''
'' ent.bas -- entities
''
declare function ent_value ( strm() as string, byval strm_cnt as integer, kname as string ) as string
declare sub ent_vec ( strm() as string, byval strm_cnt as integer, kname as string, v as vec3 )
declare sub ent_load_teleports ( )
declare sub ent_check_teleport ( )
declare function ent_plat_touched ( byval p as integer ) as integer
declare sub ent_move_plats ( byval dt as single )
declare function ent_point_leaf ( p as vec3 ) as integer
declare sub ent_place_models ( )
declare function ent_hits_leaf ( byval m as integer, byval lf as integer ) as integer

declare sub mod_load_texinfo ( )
declare sub mod_load_textures ( )
declare sub mod_link_anims ( )
declare sub vid_init ( )
declare sub in_init ( )
declare sub s_stop_music ( )
declare function r_cull_box ( bbox as bboundbox, frustum() as plane ) as integer
declare sub r_set_frustum ( frustum() as plane, mtx as u3dMtrx )
declare sub com_parse_config ( filename as string )
declare function com_arg ( strm() as string, strm_cnt as integer, linenum as integer ) as string
declare function com_yesno ( strm() as string, strm_cnt as integer, _
                            linenum as integer ) as integer
declare sub com_check_args ( strm() as string, strm_cnt as integer, _
                       byval want as integer, byval linenum as integer )
declare sub com_tokenize ( strm() as string, strm_cnt as integer, _
                     tokenlist as string, stream as string )
                        
                        
type uv
    u           as single
    v           as single
end type


declare sub com_tokenize ( strm() as string, strm_cnt as integer, _
             tokenlist as string, stream as string )
declare function draw_load_font ( flname as string, col as long ) as integer
declare sub draw_string ( dc as long, x as integer, y as integer, _
                            text as string ) 
                            
declare sub scr_screenshot ( flname as string, byval dc as long )

                         
declare sub d_clip_z ( ot_vtx() as u3dVector4f, ot_uv() as uv, ot_cnt as integer, _
                         in_vtx() as u3dVector4f, in_uv() as uv, in_cnt as integer )
                                                    
