''
'' Cross-module state.
''
'' DIM SHARED is module scope only; COMMON SHARED is what actually crosses a
'' module boundary, and it has to be declared identically in every module and
'' before any executable statement. Only state that is genuinely shared
'' belongs here -- COMMON arrays are always descriptor addressed, so the hot
'' renderer scratch stays module-local under '$STATIC where it is addressed
'' directly.
''
common shared /qenv/ env as EnvType

''
'' The loading screen advances by one step per lump reader plus the two
'' texture passes. Fourteen sites used to spell the divisor as a literal
'' 14.0 and had to agree with each other by hand; adding a reader without
'' touching all of them would have left the bar short of 100%.
''
const LOAD_STEPS = 14

''
'' Texture atlas grid. tools/mkassets.py lays the textures out in a grid
'' this many cells wide, so the two have to agree; the tool prints the
'' grid it used.
''
const TEXATLAS_COLS = 8


''
'' The map: written by qbsplod.bas, walked by the renderer. Already '$DYNAMIC
'' before the split, so COMMON costs them nothing.
''
type MapState
    head        as header       '' the on-disk lump directory
    file        as integer      '' open handle, owned by model.bas
    numtex      as long         '' counts, all derived from the header
    tri_count   as long
    vtx_count   as long
    edg_count   as long
    lef_count   as long
    nds_count   as long
    texi_count  as long
end type

''
'' The loading screen is its own thing: it exists only between bspOpen and
'' videoOpen, and the map does not own it.
''
type LoadState
    pct         as single       '' 0..100, advanced LOAD_STEPS times
    dc          as long         '' the temporary 320x200 loading DC
end type

common shared /qmapS/ wld as MapState
common shared /qmapS/ ldr as LoadState
common shared /qmapA/ tri_buffer() as face2, edg_buffer() as edge, ledg_buffer() as integer
common shared /qmapA/ vtx_buffer() as vertex, lef_buffer() as leaf2, lfc_buffer() as integer
common shared /qmapA/ mdl_buffer() as model, pln_buffer() as plane2, nds_buffer() as nodeb
common shared /qmapA/ order_list() as integer, pvs_buffer_a() as integer, pvs_buffer_b() as integer
common shared /qmapA/ tex_inf_buff() as texinfo, poly_flag() as integer

''
'' Visibility and traversal: r_bsp.bas walks the tree and marks what is
'' visible; the frame loop and the rasteriser read the result.
''
type VisState
    frame_stamp as integer      '' stamped into polyFlag for visible faces
    ord_count   as long         '' entries written to orderList
end type

common shared /qvisS/ vis as VisState
common shared /qvisA/ bitarray() as integer, frustum() as plane

''
'' Rasteriser state. These were five loose COMMON scalars; grouping them
'' names the subsystem that owns them, and makes it obvious at every use
'' site which subsystem is being read. The member offsets are compile-time
'' constants, so this costs nothing in the draw loop -- env.xRes has been
'' addressed the same way all along.
''
type RenderState
    backface    as integer      '' cull toggle
    usemips     as integer      '' mip toggle
    rendmode    as integer      '' 0 perspective, 1 affine, 2 wireframe
    polys       as integer      '' per-frame counters, reset by presentFrame
    tris        as integer
end type

common shared /qdrwS/ rdr as RenderState
common shared /qdrwA/ h_textr_dc() as long, mip_buff_inf() as miptexb

''
'' The overlay: what the HUD reports, written by the frame loop and read
'' by screen.bas.
''
type ScreenState
    fps         as integer      '' last completed second's frame count
    stats       as integer      '' overlay toggle
    bench_secs  as integer      '' seconds elapsed, for -bench
end type

common shared /qscrS/ scr as ScreenState

''
'' pal is loaded by r_tex.bas, which needs its segment and offset to colour
'' match, and consumed by videoOpen, which installs it and frees it.
''
common shared /qpalS/ pal as long

''
'' Camera and view: r_main.bas moves it, the frame loop and the rasteriser
'' consume the result. pos was /qmapS/ because the map's spawn point sets it,
'' but it belongs to the camera and is read every frame by the backface test.
''
type CamState
    pos         as u3dVector3f  '' eye, from the map's spawn then mouse-driven
    look_at     as u3dVector3f
    start_angle as single       '' spawn yaw, seeds the mouse position
    fpsview     as integer      '' false = the fixed overhead view
    script_file as integer      '' open handle in cammode 1 and 2, else 0
end type

common shared /qcamS/ cam as CamState

''
'' The loading-screen MOD track: started by sys_init.bas, played once
'' the map is up by doMain.
''
common shared /qsndS/ mymod as UGMMOD
