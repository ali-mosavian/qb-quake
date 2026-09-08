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
'' frame-major, in ONE EMS page (raw emsAlloc/emsMapEx, g.mdl.vtx_hnd) --
'' read with PEEK. See q_mdl.bi's own note for the three designs tried
'' before this one and exactly which measurement ruled each out: a
'' space$()'d BASIC string (hit BASIC's own "string space" ceiling), a
'' uglArrLoad EMS array (uglArrNew's store table is UA_MAX=4, all taken),
'' and memAlloc'd conventional memory (fits the allocator, not the
'' budget -- only ~13KB free by the time the model loads).
''
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'qgl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'ems.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bspfile.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_snd.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'

'' Just above the soldier's own 170 -- DGROUP is tight (LINK L2041 at 511),
'' and nothing here needs headroom for a model this codebase does not have.
const MDL_MAXV = 191

'' UV fixed-point -> Single: must match mkmdl.py's own UV_SCALE.
const MDL_UV_SCALE = 32767.0

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
                             byval src as long, _
                             byval zsf as long, _
                             byval zmode as integer ) as integer
declare function host_z_dc ( ) as long

''
'' This module's own procedures.
''
declare sub mdl_rotate_all ( _
    g as Game, _
    byval frame as integer, _
    byval yaw as single, _
    wxr() as single, _
    wyr() as single, _
    wzr() as single _
)
'' Scratch, per-vertex: sits after '$STATIC deliberately, same reasoning
'' as d_poly.bas's own prj_x/prj_y/prj_w -- touched per vertex per frame,
'' and not COMMON because nothing outside this module reads it.
dim shared mdl_wxr( MDL_MAXV ) as single
dim shared mdl_wyr( MDL_MAXV ) as single
dim shared mdl_wzr( MDL_MAXV ) as single
dim shared mdl_sx( MDL_MAXV ) as single
dim shared mdl_sy( MDL_MAXV ) as single
dim shared mdl_sw( MDL_MAXV ) as single
dim shared mdl_okv( MDL_MAXV ) as integer

''::::::::::::::
'' name: mdl_load
'' desc: reads <name>.geo (mkmdl.py's own output) and <name[:5]>skn.bmp,
''       both loose files beside the exe -- mkmdl.py does not pack them
''       into base.dat/assets.zip, so this is plain OPEN/uglNewBMPEx, not
''       the "archive::path" convention mod_load_textures uses.
''::::::::::::::
sub mdl_load ( _
    g as Game, _
    mdlname as string, _
    tri() as MdlTri _
)
    dim fh as integer, ti as integer
    dim hdr as string * 38
    dim geopath as string, skinpath as string, vtxpath as string
    dim u as UAR
    dim vtxbytes as long
    dim vtxseg as integer

    g.mdl.loaded = 0
    geopath = mdlname + ".geo"
    vtxpath = left$(mdlname, 5) + "vtx.bin"
    skinpath = left$(mdlname, 5) + "skn.bmp"

    fh = freefile
    open geopath for binary as #fh
    get #fh, 1, hdr
    g.mdl.ntri     = cvi( mid$( hdr, 5, 2 ) )
    g.mdl.nvert    = cvi( mid$( hdr, 7, 2 ) )
    g.mdl.nframe   = cvi( mid$( hdr, 9, 2 ) )
    g.mdl.scale.x  = cvs( mid$( hdr, 15, 4 ) )
    g.mdl.scale.y  = cvs( mid$( hdr, 19, 4 ) )
    g.mdl.scale.z  = cvs( mid$( hdr, 23, 4 ) )
    g.mdl.origin.x = cvs( mid$( hdr, 27, 4 ) )
    g.mdl.origin.y = cvs( mid$( hdr, 31, 4 ) )
    g.mdl.origin.z = cvs( mid$( hdr, 35, 4 ) )
    if ( g.mdl.nvert > MDL_MAXV + 1 ) then close #fh : exit sub

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

    '' Vertices: one EMS page, raw emsAlloc/emsMapEx (not a uGL DC or
    '' array) -- see this module's own header comment for the three
    '' designs tried and ruled out before this one. PAGE_SLOT, not a
    '' dedicated slot: slots 0 and 1 are hardwired to uglBuildSurf's and
    '' uglTriT's own rdAccess/wrAccess (uglwin.asm) -- every textured
    '' triangle drawn anywhere, world or model, remaps one of those two
    '' internally, so claiming either one just means fighting the busiest
    '' traffic in the renderer for no reason. PAGE_SLOT is what nodes/
    '' leaves/clips/lightmap/geometry already share safely, and this
    '' shares it the same way they do: mapped fresh immediately before
    '' each read, never held across another call.
    vtxbytes = clng( g.mdl.nframe ) * clng( g.mdl.nvert ) * 3
    g.mdl.vtx_hnd = emsAlloc%( vtxbytes )
    if ( g.mdl.vtx_hnd <> 0 ) then
        vtxseg = emsMapEx%( g.mdl.vtx_hnd, 0, PAGE_SLOT )
        if ( vtxseg <> 0 ) then
            if ( uarOpen( u, vtxpath, F4READ ) <> 0 ) then
                if ( uarReadH( u, clng( vtxseg ) * 65536&, vtxbytes ) <> vtxbytes ) then
                    emsFree g.mdl.vtx_hnd
                    g.mdl.vtx_hnd = 0
                end if
                uarClose u
            else
                emsFree g.mdl.vtx_hnd
                g.mdl.vtx_hnd = 0
            end if
        else
            emsFree g.mdl.vtx_hnd
            g.mdl.vtx_hnd = 0
        end if
    end if
    sys_mem_mark "mdl_post_vert_load"
    if ( g.mdl.vtx_hnd = 0 ) then exit sub

    '' UGL.EMS: the skin must be <= 16,384 bytes (one EMS page) or uglTriT
    '' silently drops triangles -- see mgl/docs/issues/ems-texture-and-
    '' zbuffer-dropouts.md. mkmdl.py's own skin resample keeps this true.
    g.mdl.skin = uglNewBMPEx&( UGL.EMS%, UGL.8BIT%, skinpath, BMPOPT.NO332% )
    sys_mem_mark "mdl_post_skin"
    if ( g.mdl.skin = 0 ) then exit sub

    g.mdl.loaded = -1
end sub

''::::::::::::::
'' name: mdl_rotate_all
'' desc: the WHOLE vertex array, one call -- not one call per vertex.
''       Writes wxr()/wyr()/wzr(), BSP space (Z up), for every vertex of
''       this frame. yaw is degrees, rotating the model's local +X
''       (forward) into the world the same way d_mdl.c's real-geometry
''       path does. g.mdl.vtx_hnd is one EMS page (emsAlloc), mapped
''       through PAGE_SLOT -- flat, frame-major, one PEEK per byte, same
''       as reading through any other far pointer.
''::::::::::::::
sub mdl_rotate_all ( _
    g as Game, _
    byval frame as integer, _
    byval yaw as single, _
    wxr() as single, _
    wyr() as single, _
    wzr() as single _
)
    dim v as integer, voff as long
    dim cy as single, sn as single, rx as single, ry as single
    dim rad as single
    dim bx as integer, by as integer, bz as integer
    dim vtxseg as integer

    rad = yaw * 0.017453293
    cy = cos( rad ) : sn = sin( rad )

    '' PAGE_SLOT, shared with nodes/leaves/clips/lightmap/geometry --
    '' emsMapEx's own slot-cache check (ems.bi) means this costs nothing
    '' when nobody else has claimed the slot since our own last read, and
    '' a real remap (still correct, just not free) when they have.
    vtxseg = emsMapEx%( g.mdl.vtx_hnd, 0, PAGE_SLOT )
    def seg = vtxseg

    for v = 0 to g.mdl.nvert - 1
        voff = ( clng( frame ) * g.mdl.nvert + v ) * 3
        bx = peek( voff )
        by = peek( voff + 1 )
        bz = peek( voff + 2 )

        rx = csng( bx ) * g.mdl.scale.x + g.mdl.origin.x
        ry = csng( by ) * g.mdl.scale.y + g.mdl.origin.y
        wxr( v ) = rx * cy - ry * sn
        wyr( v ) = rx * sn + ry * cy
        wzr( v ) = csng( bz ) * g.mdl.scale.z + g.mdl.origin.z
    next v
    def seg   '' restore the default segment -- see peektest.bas's own note
end sub

''::::::::::::::
'' name: mdl_draw
'' desc: one model, one frame, textured, through mtx_fin -- the same
''       lookAt*projection matrix host_render already built for the
''       world this frame, so scale and FOV match exactly. org is the
''       model's world position, BSP space (Z up); yaw is degrees.
''       Depth-tested like a brush entity (d_faces.c's own convention:
''       the world only WRITES, arrives front to back by BSP order; an
''       object dropped into that order without the world's own
''       ordering guarantee has to TEST).
''::::::::::::::
sub mdl_draw ( _
    g as Game, _
    tri() as MdlTri, _
    ent as MdlEnt, _
    mtx_fin as u3dMtrx, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
)
    dim v as integer, j as integer, a as integer, b as integer, c as integer
    dim wx as single, wy as single, wz as single
    dim rx as single, ry as single, rz as single    '' renderer space, Y up
    dim tw as single, rw as single
    dim area as single
    dim t as TriType
    dim zm as integer
    dim frame as integer
    dim qdst as long
    dim qskin as long
    dim qzsf as long
    dim qz as integer
    dim qv(2) as QglVtx

    if ( g.mdl.loaded = 0 ) then exit sub

    '' ent.anim_frame is mdl_think's own state (pl_move.bas), 0..7
    '' within whichever cycle ent.state selects -- the SAME tick that
    '' picks the monster's movement distance also picks its displayed
    '' frame, matching soldier.qc's state-machine frames exactly rather
    '' than a fixed 10Hz-of-wall-clock guess. Stand frames then run
    '' frames, contiguous in the one EMS-page vertex block (mkmdl.py's
    '' own order): frame 8 is run1.
    if ( ent.state = MDL_ST_STAND% ) then
        frame = ent.anim_frame
    else
        frame = MDL_STAND_FRAMES% + ent.anim_frame
    end if
    mdl_rotate_all g, frame, ent.yaw, mdl_wxr(), mdl_wyr(), mdl_wzr()

    for v = 0 to g.mdl.nvert - 1
        '' BSP space (Z up), model-local rotation already applied, now
        '' translated to the world position --
        wx = ent.pos.x + mdl_wxr( v )
        wy = ent.pos.y + mdl_wyr( v )
        wz = ent.pos.z + mdl_wzr( v )

        '' -- then swapped to renderer space (Y up) the same way
        '' d_faces.c reads a raw BSP vertex: x unchanged, z becomes y.
        rx = wx : ry = wz : rz = wy

        tw = rx * mtx_fin.m14 + ry * mtx_fin.m24 + rz * mtx_fin.m34 + mtx_fin.m44
        if ( tw < z_near ) then
            mdl_okv( v ) = 0
        else
            rw = 1.0 / tw
            mdl_sx( v ) = xresh + ( rx * mtx_fin.m11 + ry * mtx_fin.m21 + rz * mtx_fin.m31 + mtx_fin.m41 ) * rw * xresh
            mdl_sy( v ) = yresh - ( rx * mtx_fin.m12 + ry * mtx_fin.m22 + rz * mtx_fin.m32 + mtx_fin.m42 ) * rw * yresh
            mdl_sw( v ) = rw
            mdl_okv( v ) = -1
        end if
    next v

    '' qgl from here: the destination and the skin are both mgl DCs, and
    '' an mgl DC is a qgl Surface, so both go straight through. The skin
    '' is EMS and is handed to every triangle, so its page is mapped
    '' inside the draw that reads it and never held across one.
    qdst  = dst
    qskin = g.mdl.skin
    qzsf  = host_z_dc&
    zm    = QGL_Z_TEST
    if ( qzsf = 0 ) then zm = QGL_Z_OFF

    for j = 0 to g.mdl.ntri - 1
        a = tri( j ).a : b = tri( j ).b : c = tri( j ).c
        if ( mdl_okv( a ) and mdl_okv( b ) and mdl_okv( c ) ) then
            area = ( mdl_sx(b) - mdl_sx(a) ) * ( mdl_sy(c) - mdl_sy(a) ) _
                 - ( mdl_sx(c) - mdl_sx(a) ) * ( mdl_sy(b) - mdl_sy(a) )
            if ( area < 0.0 ) then
                t.v1.x = mdl_sx(a) : t.v1.y = mdl_sy(a) : t.v1.z = mdl_sw(a)
                t.v1.u = csng( tri(j).u1 ) / MDL_UV_SCALE : t.v1.v = csng( tri(j).v1 ) / MDL_UV_SCALE
                t.v2.x = mdl_sx(b) : t.v2.y = mdl_sy(b) : t.v2.z = mdl_sw(b)
                t.v2.u = csng( tri(j).u2 ) / MDL_UV_SCALE : t.v2.v = csng( tri(j).v2 ) / MDL_UV_SCALE
                t.v3.x = mdl_sx(c) : t.v3.y = mdl_sy(c) : t.v3.z = mdl_sw(c)
                t.v3.u = csng( tri(j).u3 ) / MDL_UV_SCALE : t.v3.v = csng( tri(j).v3 ) / MDL_UV_SCALE
                qv(0).x = t.v1.x : qv(0).y = t.v1.y : qv(0).z = t.v1.z
                qv(0).u = t.v1.u : qv(0).v = t.v1.v
                qv(1).x = t.v2.x : qv(1).y = t.v2.y : qv(1).z = t.v2.z
                qv(1).u = t.v2.u : qv(1).v = t.v2.v
                qv(2).x = t.v3.x : qv(2).y = t.v3.y : qv(2).z = t.v3.z
                qv(2).u = t.v3.u : qv(2).v = t.v3.v
                qz = qglRsPoly%( qdst, qv(0), 3, QGL_M_PTEX, _
                                 qskin, qzsf, zm )
            end if
        end if
    next j
end sub
