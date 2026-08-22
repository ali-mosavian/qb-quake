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
const LOAD_STEPS = 14

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
common shared /map_a/ vtx_buffer() as vertex, lef_buffer() as leaf2, lfc_buffer() as integer
common shared /map_a/ mdl_buffer() as model, pln_buffer() as plane2, nds_buffer() as nodeb
common shared /map_a/ order_list() as integer, pvs_buffer_a() as integer, pvs_buffer_b() as integer
common shared /map_a/ tex_inf_buff() as texinfo, poly_flag() as integer
