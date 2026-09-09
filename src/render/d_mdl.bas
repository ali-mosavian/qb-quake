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
''
'' The archive reader, qgl's. mgl's uar carried an inflate and a UAR the
'' caller had to declare and then only pass back; every member is stored
'' now, and a handle is enough.
''
'' flname is NOT byval: VBDOS passes a plain "as string" parameter as a
'' near pointer to its descriptor, which is what the assembly's s:word
'' wants.
''
declare function qglZipOpenBas ( flname as string ) as integer
declare function qglZipSize ( byval h as integer ) as long
declare function qglZipRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglZipClose ( byval h as integer )
declare sub qglSfFree ( byval s as long )
declare function qglFileOpenBas ( flname as string ) as integer
declare function qglFileRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglFileClose ( byval h as integer )

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
'' Clip space, not screen space. A near-plane clip has to interpolate
'' BEFORE the perspective divide -- that is the whole point of it -- so
'' these hold the numerators and w, and the divide happens per emitted
'' corner down in the triangle loop.
dim shared mdl_cx( MDL_MAXV ) as single
dim shared mdl_cy( MDL_MAXV ) as single
dim shared mdl_cw( MDL_MAXV ) as single
dim shared mdl_okv( MDL_MAXV ) as integer

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
            u = qglZipOpenBas( vtxpath )
            if ( u <> 0 ) then
                if ( qglZipRead( u, clng( vtxseg ) * 65536&, vtxbytes ) <> vtxbytes ) then
                    emsFree g.mdl.vtx_hnd
                    g.mdl.vtx_hnd = 0
                end if
                qglZipClose u
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
    dim v as integer, j as integer, k as integer, k2 as integer
    dim wx as single, wy as single, wz as single
    dim rx as single, ry as single, rz as single    '' renderer space, Y up
    dim rw as single
    dim area as single
    dim zm as integer
    dim frame as integer
    dim qdst as long
    dim qskin as long
    dim qz as integer
    '' Five planes add at most one corner each, so eight is the ceiling
    '' and MDL_CLIPV is nine. qglRsPoly scans any convex polygon.
    dim qv( MDL_CLIPV ) as QglVtx
    dim ia(2) as integer                            '' the triangle's corners
    dim cbx(1, MDL_CLIPV) as single                 '' the ping-pong rings,
    dim cby(1, MDL_CLIPV) as single                 '' clip space
    dim cbw(1, MDL_CLIPV) as single
    dim cbu(1, MDL_CLIPV) as single
    dim cbv(1, MDL_CLIPV) as single
    dim cd( MDL_CLIPV ) as single                   '' distance to this plane
    dim cn(1) as integer
    dim sbuf as integer, dbuf as integer, cp as integer
    dim nin as integer, nout as integer
    dim f as single

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

        '' No divide here. A vertex in front of the near plane by a
        '' hair has a colossal 1/w, and projecting it flings the corner
        '' thousands of pixels off screen -- which is what the triangle
        '' loop below used to draw, as a sliver stretched across the
        '' frame. Keep w and clip against it first.
        mdl_cw( v ) = rx * mtx_fin.m14 + ry * mtx_fin.m24 + rz * mtx_fin.m34 + mtx_fin.m44
        mdl_cx( v ) = rx * mtx_fin.m11 + ry * mtx_fin.m21 + rz * mtx_fin.m31 + mtx_fin.m41
        mdl_cy( v ) = rx * mtx_fin.m12 + ry * mtx_fin.m22 + rz * mtx_fin.m32 + mtx_fin.m42
        mdl_okv( v ) = ( mdl_cw( v ) >= z_near )
    next v

    '' qgl from here: the destination and the skin are both Surfaces.
    '' The skin is EMS and is handed to every triangle, so its page is
    '' mapped inside the draw that reads it and never held across one.
    ''
    '' A model tests depth, never merely writes it: it is drawn after the
    '' world, which the BSP order already put in front of it where it
    '' belongs. Set once for the whole model -- nothing between these
    '' triangles draws anything else -- and left OFF for us by qglSfZMode
    '' itself when the destination has no depth buffer, which is -noz.
    qdst  = dst
    qskin = g.mdl.skin
    zm    = qglSfZMode%( qdst, QGL_Z_TEST )

    for j = 0 to g.mdl.ntri - 1
        ia(0) = tri( j ).a : ia(1) = tri( j ).b : ia(2) = tri( j ).c
        nout = 0

        if ( mdl_okv( ia(0) ) or mdl_okv( ia(1) ) or mdl_okv( ia(2) ) ) then
            sbuf  = 0
            cn(0) = 3
            for k = 0 to 2
                cbx(0, k) = mdl_cx( ia(k) )
                cby(0, k) = mdl_cy( ia(k) )
                cbw(0, k) = mdl_cw( ia(k) )
            next k
            cbu(0, 0) = csng( tri(j).u1 ) / MDL_UV_SCALE
            cbu(0, 1) = csng( tri(j).u2 ) / MDL_UV_SCALE
            cbu(0, 2) = csng( tri(j).u3 ) / MDL_UV_SCALE
            cbv(0, 0) = csng( tri(j).v1 ) / MDL_UV_SCALE
            cbv(0, 1) = csng( tri(j).v2 ) / MDL_UV_SCALE
            cbv(0, 2) = csng( tri(j).v3 ) / MDL_UV_SCALE

            '' Sutherland-Hodgman in CLIP space against all five planes:
            '' w >= z_near, then |x| <= w and |y| <= w, which is the view
            '' rectangle expressed before the divide.
            ''
            '' qgl clips to the view rectangle too (clip.asm), but AFTER
            '' the divide, and by then the damage is done: a corner whose
            '' w is a hair above z_near projects to tens of thousands of
            '' pixels, and clipping that to the rect does not discard the
            '' triangle -- it stretches the surviving sliver across the
            '' frame. That is the wandering streak. Clipping x and y
            '' against w here bounds every projected corner to the
            '' viewport, so nothing reaches qgl that it has to rescue.
            for cp = 0 to 4
                nin = 0
                for k = 0 to cn(sbuf) - 1
                    select case cp
                    case 0    : cd(k) = cbw(sbuf, k) - z_near
                    case 1    : cd(k) = cbw(sbuf, k) - cbx(sbuf, k)
                    case 2    : cd(k) = cbw(sbuf, k) + cbx(sbuf, k)
                    case 3    : cd(k) = cbw(sbuf, k) - cby(sbuf, k)
                    case else : cd(k) = cbw(sbuf, k) + cby(sbuf, k)
                    end select
                    if ( cd(k) >= 0.0 ) then nin = nin + 1
                next k

                if ( nin = 0 ) then
                    cn(sbuf) = 0
                    exit for
                end if

                '' Wholly inside: the ring is already the answer for this
                '' plane, and copying it would only cost.
                if ( nin < cn(sbuf) ) then
                    dbuf = 1 - sbuf
                    nout = 0
                    for k = 0 to cn(sbuf) - 1
                        k2 = k + 1 : if ( k2 = cn(sbuf) ) then k2 = 0

                        if ( cd(k) >= 0.0 ) then
                            cbx(dbuf, nout) = cbx(sbuf, k)
                            cby(dbuf, nout) = cby(sbuf, k)
                            cbw(dbuf, nout) = cbw(sbuf, k)
                            cbu(dbuf, nout) = cbu(sbuf, k)
                            cbv(dbuf, nout) = cbv(sbuf, k)
                            nout = nout + 1
                        end if

                        if ( (cd(k) >= 0.0) <> (cd(k2) >= 0.0) ) then
                            f = cd(k) / ( cd(k) - cd(k2) )
                            cbx(dbuf, nout) = cbx(sbuf,k) + f * ( cbx(sbuf,k2) - cbx(sbuf,k) )
                            cby(dbuf, nout) = cby(sbuf,k) + f * ( cby(sbuf,k2) - cby(sbuf,k) )
                            cbw(dbuf, nout) = cbw(sbuf,k) + f * ( cbw(sbuf,k2) - cbw(sbuf,k) )
                            cbu(dbuf, nout) = cbu(sbuf,k) + f * ( cbu(sbuf,k2) - cbu(sbuf,k) )
                            cbv(dbuf, nout) = cbv(sbuf,k) + f * ( cbv(sbuf,k2) - cbv(sbuf,k) )
                            nout = nout + 1
                        end if
                    next k
                    cn(dbuf) = nout
                    sbuf     = dbuf
                end if
            next cp

            nout = cn(sbuf)
        end if

        if ( nout >= 3 ) then
            '' The divide, finally, on corners that are all inside the
            '' frustum and so all project onto the viewport.
            for k = 0 to nout - 1
                rw = 1.0 / cbw( sbuf, k )
                qv(k).x = xresh + cbx( sbuf, k ) * rw * xresh
                qv(k).y = yresh - cby( sbuf, k ) * rw * yresh
                qv(k).z = rw
                '' RAW u and v, not u/w. The model is drawn affine --
                '' QGL_M_TEX below, uglTriT's mode, which is what this
                '' path has always been -- and the affine filler steps u
                '' and v linearly in screen space, so it wants the
                '' coordinates themselves. Only QGL_M_PTEX owes the
                '' divided pair (d_faces.c's pu[j] = vt_u[j]*rw).
                qv(k).u = cbu( sbuf, k )
                qv(k).v = cbv( sbuf, k )
            next k

            '' Backface after the clip, not before: clipping preserves
            '' winding, so the first three corners answer for all of them.
            area = ( qv(1).x - qv(0).x ) * ( qv(2).y - qv(0).y ) _
                 - ( qv(2).x - qv(0).x ) * ( qv(1).y - qv(0).y )
            if ( area < 0.0 ) then
                qz = qglRsPoly%( qdst, qv(0), nout, QGL_M_TEX, qskin )
            end if
        end if
    next j
end sub
