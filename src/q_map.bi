''
'' The map: what mod_* loads, and what the renderer walks.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' The loading screen advances by one step per lump reader plus the two
'' texture passes. Fourteen sites used to spell the divisor as a literal 14.0
'' and had to agree with each other by hand.
''
const LOAD_STEPS = 16

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
    clp_count   as long         '' collision hull nodes
    mdl_count   as long         '' submodels: the world is 0, brush entities
                                '' such as doors and teleport triggers follow
end type

''
'' The loading screen exists only between mod_open and vid_init, and the map
'' does not own it.
''
type LoadState
    pct         as single       '' 0..100, advanced LOAD_STEPS times
    dc          as long         '' the temporary 320x200 loading DC
end type

common shared /map_s/ wld as MapState
common shared /map_s/ ldr as LoadState

''
'' Written by model.bas, walked by the renderer. A TYPE cannot contain an
'' array, so these stay loose.
''
common shared /map_a/ tri_buffer() as face2, edg_buffer() as edge, ledg_buffer() as integer
common shared /map_a/ vtx_buffer() as vertex2, lef_buffer() as leaf2, lfc_buffer() as integer
common shared /map_a/ mdl_buffer() as model, pln_buffer() as plane2, nds_buffer() as nodeb
common shared /map_a/ order_list() as integer, pvs_buffer_a() as integer, pvs_buffer_b() as integer
common shared /map_a/ tex_inf_buff() as texinfo2, poly_flag() as integer

''
'' The collision hulls. Separate trees from the render nodes: same planes,
'' different topology, expanded by the player's bounding box so a point trace
'' through them is equivalent to a box trace through the world.
''
common shared /map_a/ clp_buffer() as clipnode

''
'' Lightmaps. The per-face table is small enough for BASIC, but the luxels
'' are not: 71K on dm3ish, and asking BASIC's far heap for that failed even
'' with 397K reportedly free. They go in a memAlloc'd block instead, which
'' also drops BLOAD's 64K cap, so the blob is one raw file.
''
common shared /map_a/ lmt_buffer() as lmtmin
common shared /map_a/ lm_base as long, lm_size as long, lm_read as long
common shared /map_a/ lm_info as long, lm_isize as long
'' A BASIC array, not memAlloc: a 16K memAlloc lands in an upper memory
'' block once low memory is tight, and merely holding that block wedges the
'' program -- tried, and it wedges inside vid_init with no error. See the
'' OKF memory map. Only PEEK ever touches it.
common shared /map_a/ cm_buf() as integer, cm_size as long
''
'' Surface cache state. In COMMON rather than d_surf.bas's own DIM SHARED
'' because DIM SHARED is scoped to the module that writes it, and the
'' renderer and the bench report both read these.
''
common shared /map_a/ sc_slot() as scslot

common shared /map_a/ sc_gen as integer, sc_ok as integer, sc_made as integer
common shared /map_a/ sc_flushes as long, sc_peak as long
