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
    lightmap    as integer      '' lightmap toggle. Only the per-frame gate
                                '' in d_poly reads it, so switching it off
                                '' costs nothing and leaves every built
                                '' surface resident -- switching back on is
                                '' instant, with no rebuild
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
common shared /drw_a/ h_textr_dc() as long, mip_buff_inf() as MipTex
'' Raw-index atlases, sized and filled only under -lm: the surface builder
'' shades through the full colormap and must not be handed a t* texel that
'' already went through row 0. See mkassets.py's r*/t* note.
common shared /drw_a/ h_rawtx_dc() as long

''
'' d_poly.bas. Declared here: d_draw_faces names RenderState.
''
declare sub d_clip_z ( _
    ot_vtx() as u3dVector4f, _
    ot_uv() as TexCoord, _
    ot_cnt as integer, _
    in_vtx() as u3dVector4f, _
    in_uv() as TexCoord, _
    in_cnt as integer, _
    byval z_near as single, _
    byval z_far as single _
)
declare sub d_draw_faces ( _
    h_dst_dc as long, _
    mtx_fin as u3dMtrx, _
    xresh as single, _
    yresh as single, _
    campos as u3dVector3f, _
    rdr as RenderState, _
    env as Env, _
    byval frame_stamp as integer, _
    byval ord_count as integer, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    face_mdl() as integer, _
    brush() as BrushModel, _
    pln_buffer() as Plane, _
    nds_buffer() as Node, _
    mip_buff_inf() as MipTex, _
    h_rawtx_dc() as long, _
    h_textr_dc() as long, _
    order_list() as integer, _
    poly_flag() as integer _
)
