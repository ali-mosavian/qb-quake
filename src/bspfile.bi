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

'' Q13.3 fixed point: coordinate * 8, rounded, stored as a signed integer.
'' dm3ish alone only needed Q12.4 (+-1056), but checking the shareware
'' episode against the packer's own bounds check found six of the nine real
'' maps overflow it -- start.bsp and e1m1 reach +-3200. Q13.3 (13 bits of
'' range, +-4096, 3 fractional bits, 1/8 unit) covers all nine with margin.
'' See mkassets.py's verts.bld packer for the bounds check on the scale,
'' and d_poly.bas's vx/vy/vz reads for the dequantise (divide back by 8
'' into a single) that undoes it. The buffer stays fixed point in memory;
'' nothing reads a raw .x/.y/.z off it.
type vertex2
    x           as integer
    y           as integer
    z           as integer
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

'' lightmap (the LIGHTING-lump byte offset) is dropped: nothing reads it --
'' the per-face lightmap header replaced it entirely, and nobody removed the
'' field when that landed. Confirmed by grep: no `.lightmap` read anywhere
'' in src/*.bas.
''
'' ledgeid narrowed long->integer: it is a ledges.bld index, unsigned by
'' nature, and e3m6's max is 32,880 -- 113 over signed int16 range. Packed
'' as the two's-complement bit pattern (mkassets.py), so the reader must
'' undo the same wrap: value + 65536 when it comes back negative. See
'' d_poly.bas where lid is read.
type face2
    planeid     as integer
    side        as integer
    geom_row    as integer      '' this face's record in the geometry
    geom_ofs    as integer      '' store: the row uglMapEx maps, and the
                                '' byte offset of the record inside it.
                                '' Replaces the old ledgeid/ledgenum pair
                                '' in the same ten bytes -- and needs no
                                '' unwrapping on read, which ledgeid did
    texinfoid   as integer
end type

''
'' What BASIC needs per face, and nothing more: texturemins, to shift a
'' face's texture coordinates into its own surface's space before drawing.
'' Where the luxels are, how big they are and which styles they use is read
'' once per cache miss by the builder, out of the face's geometry record -- keeping it out of
'' the far heap BLOAD allocates from, which turned out to run out first.
''
''
'' A face's slot in the surface cache. tag packs the generation and the
'' mip it was built at, so a flush invalidates every slot by incrementing
'' one counter, and a face drawn at a new mip misses without extra state.
''
'' A cached face no longer owns a DC. The bytes live in one EMS block that
'' carries no descriptor at all (emsAlloc, not uglNew), and the drawing DC
'' is one shared descriptor per size class, repointed at this offset just
'' before use. A DC costs sizeof(DC) + yRes*4 bytes of CONVENTIONAL memory
'' for its scanline address table, so one per cached surface is what put
'' the old pool into BASIC's string heap.
''
'' What uglBuildSurf needs to composite one surface. Mirrors the SBPARM
'' struc in mgl/src/ugl/uglsurf.asm field for field -- the two must move
'' together, the same rule the .bld lumps live by.
''
type SBPARM
    lmptr       as long         '' -> this face's rect in the luxel atlas
    lmstride    as long         '' atlas bytes per row. Long only so every
                                '' field below keeps its offset; the high
                                '' half is never read
    cmapptr     as long         '' -> colormap[64][256]
    au0         as long         '' initial u, 16.16
    av0         as long         '' initial v, 16.16
    du          as long         '' u step per texel
    dv          as long         '' v step per row
    sw          as integer      '' surface width  (padded)
    sh          as integer      '' surface height (padded)
    lmw         as integer      '' luxel grid width
    lmh         as integer      '' luxel grid height
    shft        as integer      '' log2(texels per luxel)
    msk         as integer      '' texture wrap mask
end type

''
'' One per face, and SIX bytes not eight -- there is one of these for every
'' face in the map (2,293 on dm3ish) against maybe 400 cached surfaces, so
'' anything per-face is the expensive place to put state. The LRU links live
'' in the block table instead, which is sized by surfaces. Growing this to
'' twelve bytes was enough to hard-fault the program at load: the far heap
'' has ~14 KB spare and a REDIM that cannot be honestly satisfied corrupts
'' rather than failing (see docs/knowledge/dos-mcb-memory-diagnosis.md).
''
'' cls is fixed for a face's lifetime, sized at its mip FLOOR rather than the
'' mip it is currently drawn at. That is what keeps this simple: a face reuses
'' its own block across mip changes (a coarser mip needs less room and fits),
'' so no block is ever orphaned, and class membership never moves -- which is
'' what makes same-class eviction always fit.
''
''
'' A snapshot of the cache counters. One call fills it, so the HUD does not
'' make seven separate crossings a frame and the counters themselves stay
'' inside d_surf.bas.
''
type scstat
    hits        as integer      '' per FRAME -- a build costs milliseconds,
    builds      as integer      '' so what hitches is how many land in one
    bpeak       as integer      '' frame. bpeak is the worst frame seen,
                                '' which is what a hitch is actually made of.
    made        as integer      '' slots created at init
    live        as long         '' blocks currently resident
    evict       as long         '' blocks thrown out over the run
    flushes     as long         '' whole-cache flushes over the run
    peak        as long         '' high-water bytes in the cache DC
    tbuilds     as long         '' builds over the whole run
end type

type scslot
    blk         as integer      '' index into the block table, -1 for none
    tag         as integer      '' generation * 4 + mip the CONTENT holds
    cls         as integer      '' size class of the block, fixed per face
end type



type leaf
    cont        as long
    vislist     as long    
    bound       as bboundbox
    lfaceid     as integer
    lfacenum    as integer
    stuff       as string * 4
end type

'' cont narrowed long->integer: CONTENTS_* is always one of six small
'' negatives (-1..-6, q_pl.bi), and pl_point_contents already returns it
'' as an integer -- the long here only ever held a value that fits in one.
type leaf2
    cont        as integer      '' CONTENTS_*: only hull 0 knows about water
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

'' flags is dropped: nothing reads it -- confirmed by grep, no `.flags`
'' anywhere in src/*.bas. miptex narrows long->integer: it indexes this
'' map's own texture list, max seen across all target maps is 72.
type texinfo2
    vecs(3)     as single
    vect(3)     as single
    miptex      as integer
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


'' planenum narrowed long->integer: verified max value across all 9 target
'' maps is 2,736 (e1m3), 12x under int16 range. On-disk clipnode_t stays
'' 8 bytes (long+short+short) -- see cliptmp below, the len() source for
'' wld.clp_count, which must NOT shrink with this type.
type clipnode
    planenum    as integer
    front       as integer
    back        as integer
end type

'' Unconverted, 8-byte shape (long+short+short), matching wld.head.clipnode's
'' own on-disk record size exactly. mod_open's wld.clp_count = size \ len(...)
'' reads the ORIGINAL .bsp file directly, so it needs the ORIGINAL record
'' size -- same reason fce/nodetmp/leaftmp/planetmp exist below.
type cliptmp
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
    start_yaw   as single       '' -yaw D: face this way instead of the spawn
    yaw_set     as integer      '' angle. For aiming a headless run at a thing.
    no_ents     as integer      '' -noents: draw no brush entities at all. The
                                '' reference image for "is this entity leaking
                                '' through the wall in front of it".
    bad_order   as integer      '' -badorder: put brush entities back after the
                                '' world walk, the bug this flag exists to show.
    poly_tp     as integer      '' -polytp: emit whole convex polygons via
                                '' uglPolyTP instead of fanning each face
                                '' into triangles. A/B against the proven
                                '' uglTriTP path.
    no_z        as integer      '' -noz: skip the depth buffer entirely
    campath     as integer      '' -campath: fly the A* route from
                                '' campath.bin instead of standing still.
                                '' The old bench rendered ONE viewpoint, so
                                '' peak, low and mean were the same number
                                '' and a change that only hurt expensive
                                '' views was invisible.
    no_draw     as integer      '' -nodraw: run the frontend (BSP walk, PVS,
                                '' visibility) and SKIP rasterising. Isolates
                                '' what a change to the walk costs from what
                                '' the rasteriser costs -- paging the node
                                '' tree moves the first and not the second,
                                '' so a full-frame timing buries the effect
                                '' under fill.
    no_stats    as integer      '' -nostats: the overlay covers a third of the
                                '' frame, which is a third of what a screenshot
                                '' was taken to look at.
    bench_ticks as integer      '' -ticks N: stop after N simulation steps
                                '' rather than N frames, so two runs at
                                '' different framerates simulate exactly the
                                '' same thing and must agree
    use_lm      as integer      '' -lm: composite lightmaps through the
                                '' surface cache. sb_build hands its texel
                                '' loop to uglBuildSurf now, so the old
                                '' "too slow to default on" reason is gone;
                                '' still opt-in only because the mip-floor
                                '' streaks trim edges -- see the surface
                                '' cache knowledge note.
    dump_set    as integer      '' -dumpsurf given at all. Face 0 is a real
                                '' face, so dump_face alone cannot say.
    dump_face   as integer      '' -dumpsurf F M: build face F at mip M, write
    dump_mip    as integer      '' the composited surface to surfdump.bin and
                                '' quit. tools/surfcheck.py diffs that against
                                '' sbref.py -- the only check that covers
                                '' sb_build's own pointer arithmetic, which
                                '' every other test sits below.
    bench_secs  as integer      '' -benchsecs N: stop after N real seconds
                                '' (scr.bench_secs, ticked by scr_count_frame),
                                '' rather than a fixed frame/tick count -- a
                                '' short, wall-clock-bounded run for iteration.

end type

const DEG2RAD# = 3.14159265359 / 180.0

'' defined in main.bas, called from model.bas -- within one module
'' BASIC auto-declares, across modules it needs this.
declare sub draw_bar ( h_dc as long, x as integer, y as integer, wdt as integer, _
                            hgt as integer, percent as single )
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
declare sub r_load_leaves ( byval cnt as long )
declare function r_leaf_contents ( byval leafnr as integer ) as integer
declare sub r_load_lfaces ( byval lumpbytes as long )
declare sub r_alloc_pvs ( byval nleafs as long )
declare sub r_draw_world ( model as integer )
declare sub r_draw_brush_model ( byval m as integer )
declare sub v_update_camera ( byval dt as single )
declare sub in_handle_toggles ( )
''
'' pl_move.bas -- player physics
''
declare sub pl_load_hulls ( byval cnt as long )
declare function pl_hull_rec ( ) as integer
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
declare sub sys_mem_mark ( tag as string )
declare function sys_mem_count ( ) as integer
declare function sys_mem_tag ( byval i as integer ) as string
declare function sys_mem_val ( byval i as integer ) as long
declare function sys_mem_fre ( byval i as integer ) as long
declare sub vid_init_ugl ( )
declare sub s_init ( )
declare sub s_start_music ( )
declare sub draw_init_font ( )
declare sub mod_open ( )
declare sub scr_begin_loading ( )
declare sub mod_find_spawn ( )
declare sub mod_alloc ( )

declare sub mod_load_faces ( )
declare sub mod_load_lightmaps ( )
declare sub sc_stats ( s as scstat )
declare function sc_frame_end ( ) as integer
declare function mod_geom_map ( byval row as integer ) as long
declare function mod_geom_rows ( ) as integer
declare function mod_pvs_base ( ) as long
declare function host_z_on ( ) as integer
declare function mod_lm_map ( byval row as integer ) as long
declare function mod_lm_bytes ( ) as long
declare function mod_lm_got ( ) as long
declare function mod_cm_map ( ) as long
declare function mod_cm_ready ( ) as integer
declare function mod_cm_bytes ( ) as long
declare sub mod_load_colormap ( )
declare sub sc_init ( )
declare function sc_ready ( ) as integer
declare function sc_held ( byval face as integer ) as integer
declare function sc_store_open ( ) as integer
declare sub sc_point ( byval dc as long, byval ofs as long, byval rows as integer )
declare function sc_grab ( byval sz as long ) as long
declare function sc_shift ( byval v as integer ) as integer
declare function sc_mipfloor ( byval extw as integer, byval exth as integer ) as integer
declare sub sc_flush ( )
declare function sc_find ( byval face as integer, byval mip as integer, byval w as integer, byval h as integer ) as long
declare function sc_alloc ( byval face as integer, byval mip as integer, byval w as integer, byval h as integer, byval fw as integer, byval fh as integer ) as long
declare sub sc_lru_unlink ( byval b as integer )
declare sub sc_lru_touch ( byval b as integer )
declare sub sc_reset ( )
declare sub sc_shutdown ( )
declare function sc_selftest ( ) as integer
declare function sb_seg ( byval p as long ) as integer
declare sub sb_fetch ( byval face as integer )
declare function sb_i ( byval o as long ) as integer
declare function sb_u ( byval o as long ) as long
declare function sb_pot ( byval v as integer ) as integer
declare sub sb_dump ( byval face as integer, byval mip as integer )
declare sub sb_build ( byval dc as long, byval tex as long, byval face as integer, byval mip as integer, byval sw as integer, byval sh as integer )
declare sub mod_load_facevtx ( )
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
declare function ent_find_node ( byval m as integer ) as integer

declare sub mod_load_texinfo ( )
declare sub mod_load_textures ( )
declare sub mod_link_anims ( )
declare sub vid_init ( )
declare sub in_init ( )
declare sub s_stop_music ( )
declare function r_plane_dist ( pt as u3dVector3f, pl as plane2 ) as single
declare function r_node_side ( byval node_idx as integer, pt as u3dVector3f, _
                              nodes() as nodeb, planes() as plane2 ) as integer
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
declare sub scr_load_palette ( )
declare sub bg_band ( x0 as integer, x1 as integer, y0 as integer, y1 as integer )
declare sub draw_spinner ( )
declare sub bevel ( x0 as integer, y0 as integer, x1 as integer, y1 as integer, hi as integer, lo as integer, raised as integer )
declare sub rivet ( x as integer, y as integer )
declare sub draw_logo ( text as string, x as integer, y as integer, sc as integer )
declare sub hud_panel ( dc as long, x as integer, y as integer, w as integer, h as integer, title as string )
declare sub hud_row ( dc as long, x as integer, w as integer, y as integer, label as string, value as string )
declare sub hud_bar ( dc as long, x as integer, y as integer, w as integer, h as integer, percent as single )
declare sub scr_hud_colors ( )
declare sub hud_shade ( dc as long, x0 as integer, y0 as integer, x1 as integer, y1 as integer, rw as integer )
declare sub hud_num ( dc as long, x as integer, y as integer, sc as integer, txt as string, col as integer )
declare sub hud_vu ( dc as long, x as integer, y as integer, w as integer, h as integer, percent as single, ch as integer )
declare sub hud_graph ( dc as long, x as integer, y as integer, h as integer, buf() as integer, mx as integer )
declare sub scr_load_chrome ( )
declare sub scr_load_stage ( msg as string )
declare sub draw_string_scl ( dc as long, x as integer, y as integer, scale as single, text as string )
declare sub draw_string_r ( dc as long, xright as integer, y as integer, text as string )
declare sub draw_pct ( dc as long, xright as integer, y as integer, percent as single )
declare sub draw_string ( dc as long, x as integer, y as integer, _
                            text as string ) 
                            
declare sub scr_screenshot ( flname as string, byval dc as long )

                         
declare sub d_clip_z ( ot_vtx() as u3dVector4f, ot_uv() as uv, ot_cnt as integer, _
                         in_vtx() as u3dVector4f, in_uv() as uv, in_cnt as integer )
                                                    
