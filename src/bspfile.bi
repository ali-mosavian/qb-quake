type Vec3
    x           as single
    y           as single
    z           as single
end type

type Vec3i
    x           as integer
    y           as integer
    z           as integer
end type

''
'' What the screen is physically, whatever its pixel count. Every
'' mode here is shown on a 4:3 display, which is why a 320x200
'' mode's pixels are not square.
''
const DISPLAY_W = 4.0
const DISPLAY_H = 3.0

type Bounds
    min         as Vec3i
    max         as Vec3i
end type

type LumpEntry
    offs        as long
    size        as long
end type

type BspHeader
    version     as long
    entities    as LumpEntry
    planes      as LumpEntry
    mip_tex      as LumpEntry
    vertices    as LumpEntry
    vis_list     as LumpEntry
    nodes       as LumpEntry
    tex_info     as LumpEntry
    faces       as LumpEntry
    lightmaps   as LumpEntry
    clip_node    as LumpEntry
    leaves      as LumpEntry
    lface       as LumpEntry
    edges       as LumpEntry
    ledges      as LumpEntry
    models      as LumpEntry
end type

'' A world submodel at run time -- doors, lifts, trigger volumes. Submodel
'' above is the record on disk; this is what moves and what gets decided per
'' frame. Four arrays indexed by the same submodel number, so one type.
type BrushModel
    draw        as integer      '' emitted this frame. A trigger volume is
                                '' not: its brush exists to be walked into,
                                '' and drawing it hangs a slab of teleport
                                '' texture in mid air.
    solid       as integer      '' stops the player. Not the same question as
                                '' draw -- a func_illusionary is drawn and not
                                '' solid -- though every entity in dm3ish
                                '' answers both the same way.
    zofs        as single       '' how far it has moved from where the map put
                                '' it, along z, the only axis anything in
                                '' dm3ish travels. The renderer adds it to
                                '' every vertex; the collision subtracts it
                                '' from the traced point. Same thing from
                                '' either end.
    node        as integer      '' world node it sorts at. Bit 15 set means
                                '' the box fell inside one leaf.
end type

type Submodel
    mins        as Vec3
    maxs        as Vec3
	origin      as Vec3
	head_node0   as long
	head_node1   as long
	head_node2   as long
	head_node3   as long
	vis_leafs    as long
	first_face   as long
	num_faces    as long
end type

type DiskVertex
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

type DiskFace
    plane_id     as integer
    side        as integer
    ledge_id     as long
    ledge_num    as integer
    tex_info_id   as integer
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
type Face
    plane_id     as integer
    side        as integer
    geom_row    as integer      '' this face's record in the geometry
    geom_ofs    as integer      '' store: the row uglMapEx maps, and the
                                '' byte offset of the record inside it.
                                '' Replaces the old ledgeid/ledgenum pair
                                '' in the same ten bytes -- and needs no
                                '' unwrapping on read, which ledgeid did
    tex_info_id   as integer
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
type SurfBuild
    lmptr       as long         '' -> this face's rect in the luxel atlas
    lm_stride    as long         '' atlas bytes per row. Long only so every
                                '' field below keeps its offset; the high
                                '' half is never read
    cmap_ptr     as long         '' -> colormap[64][256]
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
type CacheStats
    hits        as integer      '' per FRAME -- a build costs milliseconds,
    builds      as integer      '' so what hitches is how many land in one
    bpeak       as integer      '' frame. bpeak is the worst frame seen,
                                '' which is what a hitch is actually made of.
    made        as integer      '' slots created at init
    live        as long         '' blocks currently resident
    evict       as long         '' blocks thrown out over the run
    flushes     as long         '' whole-cache flushes over the run
    peak        as long         '' high-water bytes in the cache DC
    total_builds     as long         '' builds over the whole run
end type

type CacheSlot
    blk         as integer      '' index into the block table, -1 for none
    tag         as integer      '' generation * 4 + mip the CONTENT holds
    cls         as integer      '' size class of the block, fixed per face
    stag        as integer      '' the face's light style epoch the CONTENT
                                '' holds -- see ls_epoch in d_surf.bas. Costs
                                '' 2 bytes/face on top of the 6 already kept
                                '' minimal; not yet re-measured against e1m1's
                                '' tighter far-heap margin (see AGENTS.md).
end type

type DiskLeaf
    cont        as long
    vis_list     as long    
    bound       as Bounds
    lface_id     as integer
    lface_num    as integer
    stuff       as string * 4
end type

'' cont narrowed long->integer: CONTENTS_* is always one of six small
'' negatives (-1..-6, q_pl.bi), and pl_point_contents already returns it
'' as an integer -- the long here only ever held a value that fits in one.
type Leaf
    cont        as integer      '' CONTENTS_*: only hull 0 knows about water
    vis_list     as long
    bound       as Bounds
    lface_id     as integer
    lface_num    as integer
end type

type DiskPlane
    norm        as Vec3
    dist        as single
    ptype       as long    
end type

type Plane
    norm        as Vec3
    dist        as single
    ptype       as integer
end type

type DiskNode
    plane_id     as long
    child0      as integer    
    child1      as integer    
    bound       as Bounds
    lface_id     as integer
    lface_num    as integer
end type

type Node
    plane_id     as integer
    child0      as integer    
    child1      as integer
    lface_id     as integer
    lface_num    as integer
    bound       as Bounds
end type

type DiskTexInfo
    vecs(3)     as single
    vect(3)     as single
    mip_tex      as long
    flags       as long
end type

'' flags is dropped: nothing reads it -- confirmed by grep, no `.flags`
'' anywhere in src/*.bas. miptex narrows long->integer: it indexes this
'' map's own texture list, max seen across all target maps is 72.
type TexInfo
    vecs(3)     as single
    vect(3)     as single
    mip_tex      as integer
end type

type DiskMipTex
    name        as string * 16
    wdth        as long
    hght        as long
    offset(3)   as long
end type

type MipTex    
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
type ClipNode
    plane_num    as integer
    front       as integer
    back        as integer
end type

'' Unconverted, 8-byte shape (long+short+short), matching wld.head.clipnode's
'' own on-disk record size exactly. mod_open's wld.clp_count = size \ len(...)
'' reads the ORIGINAL .bsp file directly, so it needs the ORIGINAL record
'' size -- same reason fce/nodetmp/leaftmp/planetmp exist below.
type DiskClipNode
    plane_num    as long
    front       as integer
    back        as integer
end type

const FALSE = 0
const TRUE  = -1

type Env
    z_far       as single
    z_near      as single    
    
    h_font      as long
    h_video_dc  as long
    h_back_bdc  as long
    
    mouse       as MOUSEINF
    keyboard    as TKBD
    
    fps_timer   as TMR                      '' expires every frame
    sec_timer   as TMR                      '' /       every second
    
    ''
    '' The RENDER target, which need not be the video mode. Everything
    '' that draws -- the projection, the backbuffer, the hud, a
    '' screenshot -- is this size; only the mode and the mouse are the
    '' screen's. A smaller view centred on a 320x200 screen costs
    '' proportionally less backbuffer: 150x150 is 22,500 bytes of
    '' conventional memory against 64,000.
    ''
    x_res       as integer
    y_res       as integer
    scr_x_res   as integer      '' the video mode itself
    scr_y_res   as integer
    view_x      as integer      '' where the view sits on it, centred
    view_y      as integer
    view_w      as integer      '' and how big it is drawn -- the same
    view_h      as integer      '' as x_res/y_res unless scaled
    c_fmt       as integer
    pages       as integer
    use_paging      as integer
    clear_screen    as integer
    
    sound       as integer
    cam_fov      as single
    cam_mode     as integer
    cam_interp   as integer   
    cam_script    as string * 40

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
    cam_path     as integer      '' -campath: fly the A* route from
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
    dump_tex    as integer      '' -dumptex: read every cell back through
                                '' its view and write texdump.bmp
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

''
'' pl_move.bas -- player physics
''

'' Startup steps, in the order doInit runs them. Each is entered once,
'' which is the whole reason they are separate routines.

''
'' ent.bas -- entities
''

                        
                        
type TexCoord
    u           as single
    v           as single
end type

                            

                         
                                                    

''
'' r_bsp.bas
''

''
'' mod_tex.bas
''

''
'' model.bas
''

''
'' screen.bas
''

''
'' Procedures whose signatures can be read from here.
''
declare function r_point_leaf ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
declare sub com_tokenize ( _
    strm() as string, _
    strm_cnt as integer, _
    token_list as string, _
    stream as string _
)
declare sub com_tokenize ( _
    strm() as string, _
    strm_cnt as integer, _
    token_list as string, _
    stream as string _
)
declare sub sc_stats ( s as CacheStats )
declare sub scr_load_stage ( msg as string )
declare sub scr_load_step ( )
declare sub sys_error ( msg as string )
declare sub sys_mem_mark ( tag as string )
