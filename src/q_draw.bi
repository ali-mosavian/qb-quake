''
'' Rasteriser state and the textures it samples.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' How fast a liquid surface drifts, in texture widths per second. Quake
'' warps liquids with a sine per vertex; this scrolls the whole face, which
'' costs two adds and reads as a current rather than a ripple.
''
const LIQ_FLOW_U#    = 0.15
const LIQ_FLOW_V#    = 0.10

type RenderState
    backface    as integer      '' cull toggle
    usemips     as integer      '' mip toggle
    rendmode    as integer      '' 0 perspective, 1 affine, 2 wireframe
    polys       as integer      '' per-frame counters, cleared by scr_count_frame
    tris        as integer
    anim_time   as single       '' seconds since the map started. Simulation
                                '' time really, but animation is its only
                                '' consumer, and putting it here keeps main.bas
                                '' from having to see every map array to hold a
                                '' single float.
end type

common shared /drw_s/ rdr as RenderState
common shared /drw_a/ h_textr_dc() as long, mip_buff_inf() as miptexb
