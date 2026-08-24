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
''
'' Liquid perturbation, Quake's. Each coordinate is displaced by a sine of
'' the OTHER one, which is what makes the surface roll rather than slide.
''
'' The constants are Quake's converted out of texels: it displaces by 8
'' texels of 64, and our u and v are already divided by the texture size,
'' so the amplitude is 8/64. Its table index is (other*0.125 + time)*256/2pi;
'' ours takes a normalised coordinate, so the 0.125 absorbs the texture
'' width and becomes 8*40.74.
''
const TURB_AMP#      = 0.125
const TURB_FREQ#     = 326.0
const TURB_RATE#     = 40.74

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
''
'' h_textr_dc holds a BYTE OFFSET into tx_store, not a DC. Every texture and
'' mip lives in that one store; a view per mip size, re-aimed with uglSetView,
'' stands in for the 160 DCs this used to be. A DC costs conventional memory
'' for its scanline table, and loading each texture into one of its own also
'' fragmented the heap with 160 alloc/free cycles. mkassets.py now packs the
'' whole set into one image, loaded by a single uglNewBMPEx.
''
common shared /drw_a/ h_textr_dc() as long, mip_buff_inf() as miptexb
'' Raw-index offsets, used only under -lm: the surface builder shades
'' through the full colormap and must not be handed a texel that already
'' went through row 0. Same layout as the shaded set, hence the same
'' offsets -- see mkassets.py's shaded/raw note.
common shared /drw_a/ h_rawtx_dc() as long
''
'' The two stores, and one view per mip size (64/32/16/8) into each.
'' tx_rview is the -lm twin, so a raw-index texture can be aimed at without
'' disturbing the view the draw path is using.
''
common shared /drw_a/ tx_store as long, tx_rstore as long
common shared /drw_a/ tx_view() as long, tx_rview() as long
