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

''
'' What d_draw_faces hands d_face.c for one face: the texture axes
'' already folded with the texture size, the liquid phase, the clip
'' planes and the viewport half-extents. zl and poly_cnt come back.
'' Mirrored in qcshared.h -- change one and change the other.
''
''
'' What d_draw_faces needs out of Game, gathered ONCE per frame by the
'' caller so the C loop never has to know Game's layout. Mirrored in
'' qcshared.h -- change one and change the other.
''
type DrawParams
    h_dst_dc    as long
    tex_ofs_ptr as long      '' far pointer to g.wld.tex.ofs(0)
    turb_ptr    as long      '' far pointer to d_poly.bas's turb_sin(0)
    xresh       as single
    yresh       as single
    z_near      as single
    z_far       as single
    anim_time   as single
    dl_x        as single
    dl_y        as single
    dl_z        as single
    dl_radius   as single
    build_us    as long      '' out: microseconds spent in sb_build
    frame_stamp as integer
    ord_count   as integer
    use_lm      as integer
    lightmap    as integer
    backface    as integer
    rend_mode   as integer
    use_mips    as integer
    poly_tp     as integer
    span_draw   as integer
    x_res       as integer
    y_res       as integer
    prof        as integer
    polys       as integer   '' out
    tris        as integer   '' out
    lm_want     as integer   '' out: faces that asked for a surface
    lm_fallback as integer   '' out: ...and did not get one
    k_mip       as long      '' out: sums of the sc_find key inputs
    k_sw        as long
    k_sh        as long
    k_stag      as long
    k_v0        as long
    k_lm        as long
    k_hdr       as long      '' faces whose record has a lightmap
    k_ext       as long      '' ...and non-zero extents
    k_n         as long      '' sc_find calls
end type

type FaceSetup
    su(3)       as single    '' u axis, x y z and offset
    sv(3)       as single    '' v axis, likewise
    zofs        as single    '' brush entity offset, on renderer y
    turbph      as single
    z_near      as single
    z_far       as single
    xresh       as single
    yresh       as single
    zl          as single    '' out: mean w over the clipped vertices
    liquid      as integer
    vcnt        as integer
    rend_mode   as integer
    poly_cnt    as integer   '' out
end type
const TURB_FREQ#     = 326.0
const TURB_RATE#     = 40.74

''
'' One light, following the player -- Quake's own dl_t, minus the parts
'' this renderer has no emitter for (no rockets, no muzzle flashes). pos
'' is BSP space, Z-up, the same convention PlayerState.pos already
'' documents, and the only convention Plane.norm and TexInfo.vecs
'' understand -- r_cam_plane_dist's inline Y/Z swap is for a Y-up point
'' and does not apply here.
''
type DynLight
    pos     as Vec3        '' BSP space, Z-up
    radius  as single       '' brightness added at pos itself, 0 at radius
end type

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
    dlight      as DynLight     '' the player-following test light
end type

'' Raw-index atlases, sized and filled only under -lm: the surface builder
'' shades through the full colormap and must not be handed a t* texel that
'' already went through row 0. See mkassets.py's r*/t* note.

''
'' d_poly.bas. Declared here: d_draw_faces names RenderState.
''

''
'' Procedures whose signatures can be read from here.
''
