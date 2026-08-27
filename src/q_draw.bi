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
    use_mips     as integer      '' mip toggle
    lightmap    as integer      '' lightmap toggle. Only the per-frame gate
                                '' in d_poly reads it, so switching it off
                                '' costs nothing and leaves every built
                                '' surface resident -- switching back on is
                                '' instant, with no rebuild
    rend_mode    as integer      '' 0 perspective, 1 affine, 2 wireframe
    polys       as integer      '' per-frame counters, cleared by scr_count_frame
    tris        as integer
    anim_time   as single       '' seconds since the map started. Simulation
                                '' time really, but animation is its only
                                '' consumer, and putting it here keeps main.bas
                                '' from having to see every map array to hold a
                                '' single float.
end type

common shared /drw_a/ h_textr_dc() as long, mip_buff_inf() as MipTex
'' Raw-index atlases, sized and filled only under -lm: the surface builder
'' shades through the full colormap and must not be handed a t* texel that
'' already went through row 0. See mkassets.py's r*/t* note.
common shared /drw_a/ h_rawtx_dc() as long

''
'' d_poly.bas. Declared here: d_draw_faces names RenderState.
''

''
'' Procedures whose signatures can be read from here.
''
