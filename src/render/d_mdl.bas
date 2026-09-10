option explicit
''
'' d_mdl.bas -- one alias (.mdl) model, drawn as real geometry: rotate,
'' project through the SAME mtx_fin the world uses, backface-cull, draw.
''
'' First proven standalone in src/test/mdlbas.bas (no C, no BSP, its own
'' toy fixed camera) before being wired in here against the real one.
'' Things found there carry straight over -- see
'' ~/work/badlogic/mgl/docs/issues/ems-texture-and-zbuffer-dropouts.md:
'' an EMS skin over one page (16,384 bytes) silently drops triangles under
'' uglTriT, so mkmdl.py's own resample has to keep it under that; and the
'' per-vertex rotation is one call over the whole array, not one call per
'' vertex.
''
'' Vertices are packed bytes (trivertx_t, one per axis), flat and
'' frame-major, in ONE EMS page (raw qglGemAlloc/qglGemMap, g.mdl.vtx_hnd) --
'' read with PEEK. See q_mdl.bi's own note for the three designs tried
'' before this one and exactly which measurement ruled each out: a
'' space$()'d BASIC string (hit BASIC's own "string space" ceiling), a
'' uglArrLoad EMS array (uglArrNew's store table is UA_MAX=4, all taken),
'' and memAlloc'd conventional memory (fits the allocator, not the
'' budget -- only ~13KB free by the time the model loads).
''
'$include: 'qgl.bi'
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'

'' Just above the soldier's own 170 -- DGROUP is tight (LINK L2041 at 511),
'' and nothing here needs headroom for a model this codebase does not have.
const MDL_MAXV = 191

'' UV fixed-point -> Single: must match mkmdl.py's own UV_SCALE.
const MDL_UV_SCALE = 32767.0

'' Clip-ring ceiling. Five planes, one added corner each, three to start:
'' eight corners, so nine is the highest index a ring can reach.
const MDL_CLIPV = 9

'' MdlTri/MdlState come from q_mdl.bi -- shared with main.bas (mdl_load's
'' caller) and h_frame.bas (mdl_draw's caller).

'' qglRsPoly's vertex, five singles. Spelled here because BASIC cannot
'' be handed an array of a type it has not seen; qgl.bi is generated
'' from qgl.inc and carries constants only.
type QglVtx
    x as single
    y as single
    z as single
    u as single
    v as single
end type

''
'' qgl's, declared in the narrowest place that can see them.
''
declare function qglRsPoly ( byval dst as long, _
                             seg v as any, _
                             byval cnt as integer, _
                             byval mode as integer, _
                             byval src as long ) as integer
declare function qglSfZMode ( byval surf as long, byval mode as integer ) as integer
declare function qglSfNew ( _
    byval wid as integer, _
    byval hgt as integer, _
    byval whr as integer _
) as long
declare function qglSfWrRow ( byval s as long, byval y as integer ) as long
declare function qglGemAlloc ( byval nbytes as long ) as integer
declare function qglGemMap ( byval h as integer, byval pg as integer, _
                             byval slot as integer ) as integer
declare sub qglGemFree ( byval h as integer )
declare sub qglSfFree ( byval s as long )
declare function qglFileOpenBas ( flname as string ) as integer
declare function qglFileSize ( byval h as integer ) as long
declare function qglFileRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglFileClose ( byval h as integer )

''
'' This module's own procedures.
''
declare function mdl_draw_tris ( _
    tri() as MdlTri, _
    byval ntri as integer, _
    byval nvert as integer, _
    byval frame as integer, _
    org as Vec3, _
    byval cyaw as single, _
    byval syaw as single, _
    scale as Vec3, _
    origin as Vec3, _
    byval vtx_hnd as integer, _
    byval skin as long, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
) as integer

''::::::::::::::
'' name: mdl_load
'' desc: reads <name>.geo (mkmdl.py's own output) and <name[:5]>skn.raw,
''       both loose files beside the exe -- mkmdl.py does not pack them
''       into base.dat/assets.zip, so this is a plain OPEN and a plain
''       qglFileRead, not the "archive::path" convention
''       mod_load_textures uses.
''::::::::::::::
sub mdl_load ( _
    g as Game, _
    mdlname as string, _
    tri() as MdlTri _
)
    dim fh as integer, ti as integer
    dim hdr as string * 38
    dim geopath as string, skinpath as string, vtxpath as string
    dim u as integer
    dim vtxbytes as long
    dim vtxseg as integer
    dim skin_w as integer, skin_h as integer
    dim skfh as integer, skrow as integer, skptr as long
    dim ex as single, ey as single

    g.mdl.loaded = 0
    geopath = mdlname + ".geo"
    vtxpath = left$(mdlname, 5) + "vtx.bin"
    skinpath = left$(mdlname, 5) + "skn.raw"

    fh = freefile
    open geopath for binary as #fh
    '' Binary OPEN CREATES the file when it is missing. So a tree whose
    '' data/assets was never generated got a zero-byte soldier.geo, a
    '' header of zeroes, ntri 0, and `redim tri( -1 )` -- runtime error 9
    '' at line 0, nothing naming the file or the cause. Say which file.
    if ( lof( fh ) < len( hdr ) ) then
        close #fh
        sys_error "0x0044, " + geopath + " missing or truncated, run make assets"
    end if
    get #fh, 1, hdr
    g.mdl.ntri     = cvi( mid$( hdr, 5, 2 ) )
    g.mdl.nvert    = cvi( mid$( hdr, 7, 2 ) )
    g.mdl.nframe   = cvi( mid$( hdr, 9, 2 ) )
    skin_w         = cvi( mid$( hdr, 11, 2 ) )
    skin_h         = cvi( mid$( hdr, 13, 2 ) )
    g.mdl.scale.x  = cvs( mid$( hdr, 15, 4 ) )
    g.mdl.scale.y  = cvs( mid$( hdr, 19, 4 ) )
    g.mdl.scale.z  = cvs( mid$( hdr, 23, 4 ) )
    g.mdl.origin.x = cvs( mid$( hdr, 27, 4 ) )
    g.mdl.origin.y = cvs( mid$( hdr, 31, 4 ) )
    g.mdl.origin.z = cvs( mid$( hdr, 35, 4 ) )
    '' Vertex bytes span 0..255, so this is the box every frame fits in;
    '' the yaw rotates about the origin, so the horizontal reach is a
    '' radius. What r_mdl_visible tests instead of 170 vertices.
    ex = abs( g.mdl.origin.x )
    if ( abs( g.mdl.origin.x + 255.0 * g.mdl.scale.x ) > ex ) then ex = abs( g.mdl.origin.x + 255.0 * g.mdl.scale.x )
    ey = abs( g.mdl.origin.y )
    if ( abs( g.mdl.origin.y + 255.0 * g.mdl.scale.y ) > ey ) then ey = abs( g.mdl.origin.y + 255.0 * g.mdl.scale.y )
    g.mdl.radius = sqr( ex*ex + ey*ey )
    g.mdl.zlo = g.mdl.origin.z
    g.mdl.zhi = g.mdl.origin.z + 255.0 * g.mdl.scale.z
    if ( g.mdl.nvert > MDL_MAXV + 1 ) then close #fh : exit sub
    if ( g.mdl.ntri < 1 or g.mdl.nvert < 1 or g.mdl.nframe < 1 ) then
        close #fh
        sys_error "0x0045, " + geopath + " header is empty, run make assets"
    end if

    sys_mem_mark "mdl_pre_redim"
    redim tri( g.mdl.ntri - 1 ) as MdlTri
    sys_mem_mark "mdl_post_tri_redim"

    '' whole-array Get silently left every element zero here (found in
    '' the standalone test, src/test/mdldiag.bas) -- ReDim's runtime size
    '' does not seem to reach it. Per-record Get is what every OTHER
    '' loader in this codebase already does.
    for ti = 0 to g.mdl.ntri - 1
        get #fh, , tri( ti )
    next ti
    close #fh
    sys_mem_mark "mdl_post_tri_gets"

    '' Vertices: one EMS page, raw qglGemAlloc/qglGemMap (not a Surface
    '' or a store) -- see this module's own header comment for the three
    '' designs tried and ruled out before this one. PAGE_SLOT, not a
    '' dedicated slot: slots 0 and 1 are the surfaces' own read and write
    '' windows -- every textured triangle drawn anywhere, world or model,
    '' remaps one of those two internally, so claiming either one just
    '' means fighting the busiest traffic in the renderer for no reason.
    '' PAGE_SLOT is what nodes/leaves/clips/lightmap/geometry already
    '' share safely, and this shares it the same way they do: mapped
    '' fresh immediately before each read, never held across another
    '' call.
    vtxbytes = clng( g.mdl.nframe ) * clng( g.mdl.nvert ) * 3
    g.mdl.vtx_hnd = qglGemAlloc( vtxbytes )
    if ( g.mdl.vtx_hnd <> 0 ) then
        vtxseg = qglGemMap( g.mdl.vtx_hnd, 0, PAGE_SLOT )
        if ( vtxseg <> 0 ) then
            u = qglFileOpenBas( vtxpath )
            if ( u <> 0 ) then
                if ( qglFileRead( u, clng( vtxseg ) * 65536&, vtxbytes ) <> vtxbytes ) then
                    qglGemFree g.mdl.vtx_hnd
                    g.mdl.vtx_hnd = 0
                end if
                qglFileClose u
            else
                qglGemFree g.mdl.vtx_hnd
                g.mdl.vtx_hnd = 0
            end if
        else
            qglGemFree g.mdl.vtx_hnd
            g.mdl.vtx_hnd = 0
        end if
    end if
    sys_mem_mark "mdl_post_vert_load"
    if ( g.mdl.vtx_hnd = 0 ) then exit sub

    '' EMS, and <= 16,384 bytes: that is one page, and qglRsPoly refuses
    '' a texture crossing two because the texel base is a patched
    '' immediate no filler remaps mid-polygon. mkmdl.py's resample keeps
    '' it true and writes the resulting size into the .geo header, so the
    '' two sizes cannot drift.
    ''
    '' Read a row at a time. The pointer qglSfWrRow hands back maps an
    '' EMS page, and the read that consumes it is the next statement --
    '' nothing maps in between, so the window cannot move under it.
    g.mdl.skin = qglSfNew&( skin_w, skin_h, QGL_SURF_EMS )
    if ( g.mdl.skin = 0 ) then exit sub

    skfh = qglFileOpenBas%( skinpath )
    if ( skfh = 0 ) then
        qglSfFree g.mdl.skin
        g.mdl.skin = 0
        exit sub
    end if
    for skrow = 0 to skin_h - 1
        skptr = qglSfWrRow&( g.mdl.skin, skrow )
        if ( qglFileRead&( skfh, skptr, clng( skin_w ) ) <> skin_w ) then
            qglFileClose skfh
            qglSfFree g.mdl.skin
            g.mdl.skin = 0
            exit sub
        end if
    next skrow
    qglFileClose skfh
    sys_mem_mark "mdl_post_skin"

    g.mdl.loaded = -1
end sub

''::::::::::::::
'' name: mdl_draw
'' desc: one model, one frame, textured, through mtx_fin -- the same
''       lookAt*projection matrix host_render already built for the
''       world this frame, so scale and FOV match exactly. org is the
''       model's world position, BSP space (Z up); yaw is degrees.
''       The work is d_alias.c's; this picks the frame and hands over.
''       Depth-tested like a brush entity (d_faces.c's own convention:
''       the world only WRITES, arrives front to back by BSP order; an
''       object dropped into that order without the world's own
''       ordering guarantee has to TEST).
''::::::::::::::
sub mdl_draw ( _
    g as Game, _
    tri() as MdlTri, _
    ent as MdlEnt, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
)
    dim frame as integer
    dim rad as single

    if ( g.mdl.loaded = 0 ) then exit sub

    '' ent.anim_frame is mdl_think's own state (pl_move.bas), 0..7
    '' within whichever cycle ent.state selects: the SAME tick that
    '' picks the movement distance picks the displayed frame. Stand
    '' frames then run frames, contiguous in the one EMS-page vertex
    '' block (mkmdl.py's own order): frame 8 is run1.
    select case ent.state
    case MDL_ST_STAND% : frame = ent.anim_frame
    case MDL_ST_RUN%   : frame = MDL_STAND_FRAMES% + ent.anim_frame
    case MDL_ST_DEAD%  : frame = MDL_STAND_FRAMES% + MDL_RUN_FRAMES% + ent.anim_frame
    case else          : frame = MDL_STAND_FRAMES% + MDL_RUN_FRAMES% + MDL_DEATH_FRAMES% + ent.anim_frame
    end select

    '' Everything from here is d_alias.c: the vertex rotation and
    '' transform, the clip, the projection and the raster calls, once
    '' per model rather than 328 BASIC iterations.
    rad = ent.yaw * 0.017453293
    g.pt.mtri_n = g.pt.mtri_n + mdl_draw_tris( tri(), g.mdl.ntri, g.mdl.nvert, frame, _
                                               ent.pos, cos( rad ), sin( rad ), _
                                               g.mdl.scale, g.mdl.origin, _
                                               g.mdl.vtx_hnd, g.mdl.skin, mtx_fin, _
                                               xresh, yresh, z_near, dst )
end sub
