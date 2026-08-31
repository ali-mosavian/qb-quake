option explicit
''
'' d_poly.bas -- the polygon rasteriser.
''
'' Builds each face's texture coordinates, transforms and clips to the near
'' and far planes, projects once per vertex, and hands the fan to uGL.
'' Quake's d_ files are this same layer: r_bsp decides what is seen, this
'' draws it.
''
'' Every scratch buffer below sits AFTER '$STATIC deliberately. In the
'' '$DYNAMIC region each element costs a descriptor indirection, and these
'' are touched per vertex per frame. It is also why none of them are
'' COMMON: COMMON arrays are always descriptor addressed.
''
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
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
'$include: 'q_game.bi'

''
'' This module's own procedures.
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

''
'' This module's own procedures.
''
declare sub d_draw_faces ( _
    g as Game, _
    h_dst_dc as long, _
    mtx_fin as u3dMtrx, _
    xresh as single, _
    yresh as single, _
    campos as u3dVector3f, _
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
    order_list() as integer, _
    poly_flag() as integer _
)
declare sub d_init_turb ( )

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare function r_cam_plane_dist ( _
    pt as u3dVector3f, _
    pl as Plane _
) as single
declare function sc_find ( _
    byval face as integer, _
    byval mip as integer, _
    byval w as integer, _
    byval h as integer, _
    byval stag as integer _
)
declare function sc_mipfloor ( _
    byval extw as integer, _
    byval exth as integer _
) as integer
declare function host_z_on ( ) as integer
declare function sc_held ( byval face as integer ) as integer
declare function sc_ready ( ) as integer
declare function sc_shift ( byval v as integer ) as integer
declare function ls_epoch ( byval style as integer ) as integer
declare function sys_rdtsc ( ) as long
'' r_span.c investigative prototype: global edge list -> sorted spans,
'' Quake's r_edge.c approach, timed against real per-frame polygons.
'' Draws nothing; only caller is d_draw_faces's own timing below.
declare sub r_span_emit_poly ( _
    byval poly_cnt as integer, _
    vx() as single, _
    vy() as single, _
    byval depth as single _
)
declare function r_span_flush ( byval screen_w as integer, byval screen_h as integer ) as integer
declare function r_span_overflow_count ( ) as integer
declare function sc_alloc ( _
    g as Game, _
    byval face as integer, _
    byval mip as integer, _
    byval w as integer, _
    byval h as integer, _
    byval fw as integer, _
    byval fh as integer, _
    byval stag as integer _
)
declare sub sb_build ( _
    g as Game, _
    byval dc as long, _
    byval tex as long, _
    byval face as integer, _
    byval mip as integer, _
    byval sw as integer, _
    byval sh as integer, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    mip_buff_inf() as MipTex, _
    pln_buffer() as Plane _
)

'$static
''
'' Quake's turbsin. A table because two sines per vertex of every
'' liquid face is not something to compute in the draw loop.
''
dim shared turb_sin( 255 ) as single
dim shared poly(64) as u3dVector4f
dim shared polyb(32) as u3dVector4f
''
'' gv_buf lives in COMMON (q_map.bi) so sb_build can read the lightmap
'' header from the copy instead of from the window it came from.
dim shared prj_u(32) as single
dim shared prj_v(32) as single
dim shared prj_w(32) as single
dim shared prj_x(32) as single
dim shared prj_y(32) as single
dim shared su0 as single, su1 as single, su2 as single, su3 as single
dim shared sv0 as single, sv1 as single, sv2 as single, sv3 as single
dim shared tw as single, th as single
dim shared uvbuff(64) as TexCoord
dim shared uv_buff_b(32) as TexCoord
dim shared vcnt as integer, tex_id as integer

dim shared vtx(31) as tritype
''
'' Whole-face vertex buffer for uglPolyTP. The clipper caps a polygon at
'' SH_MAXV (12); faces arriving here are already z-clipped, so 16 is
'' headroom rather than a limit worth policing.
''
dim shared pvtx(15) as vector3f
dim shared vx as single, vy as single, vz as single

'' vtx_buffer is Q13.3 fixed point (bspfile.bi's vertex2); every read
'' multiplies back up to world-space float. A multiply, not a divide --
'' cheaper on the FPU and this runs per vertex per visible face per frame.
const VTX_UNSCALE# = 1.0 / 8.0




'':::::::
sub d_clip_z ( _
    ot_vtx() as u3dVector4f, _
    ot_uv() as TexCoord, _
    ot_cnt as integer, _
    in_vtx() as u3dVector4f, _
    in_uv() as TexCoord, _
    in_cnt as integer, _
    byval z_near as single, _
    byval z_far as single _
)

    dim n as integer
    dim scl as single
    dim dsti as integer, tm_cnt as integer
    dim src1 as integer, src2 as integer

    for  n = 0 to in_cnt-1
        src1 = n
        src2 = (n + 1) mod in_cnt
        
        if ( in_vtx(src1).w >= z_near ) then
            ot_vtx(dsti).x = in_vtx(src1).x
            ot_vtx(dsti).y = in_vtx(src1).y
            ot_vtx(dsti).z = in_vtx(src1).z
            ot_vtx(dsti).w = in_vtx(src1).w
            ot_uv(dsti).u = in_uv(src1).u
            ot_uv(dsti).v = in_uv(src1).v
            
            dsti = dsti + 1 
            
            if ( in_vtx(src2).w >= z_near ) then
                goto continuenfa
            end if
        else
            if ( in_vtx(src2).w < z_near ) then
                goto continuenfa
            end if
        end if

        scl = ((z_near - in_vtx(src1).w) / (in_vtx(src2).w - in_vtx(src1).w))
     
        ot_vtx(dsti).x = in_vtx(src1).x + (in_vtx(src2).x-in_vtx(src1).x)*scl
        ot_vtx(dsti).y = in_vtx(src1).y + (in_vtx(src2).y-in_vtx(src1).y)*scl
        ot_vtx(dsti).z = in_vtx(src1).z
        ot_vtx(dsti).w = z_near        
        ot_uv(dsti).u = in_uv(src1).u + (in_uv(src2).u-in_uv(src1).u)*scl
        ot_uv(dsti).v = in_uv(src1).v + (in_uv(src2).v-in_uv(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfa:        
    next n
    
    ot_cnt = dsti
    if ( ot_cnt < 3 ) then exit sub
    dsti = 0
    
    for  n = 0 to ot_cnt-1
        src1 = n
        src2 = (n + 1) mod ot_cnt
        
        if ( ot_vtx(src1).w <= z_far ) then
            in_vtx(dsti).x = ot_vtx(src1).x
            in_vtx(dsti).y = ot_vtx(src1).y
            in_vtx(dsti).z = ot_vtx(src1).z
            in_vtx(dsti).w = ot_vtx(src1).w
            in_uv(dsti).u = ot_uv(src1).u
            in_uv(dsti).v = ot_uv(src1).v
            
            dsti = dsti + 1 
            
            if ( ot_vtx(src2).w <= z_far ) then
                goto continuenfb
            end if
        else
            if ( ot_vtx(src2).w > z_far ) then
                goto continuenfb
            end if
        end if

        scl = ((z_far - ot_vtx(src1).w) / (ot_vtx(src2).w - ot_vtx(src1).w))
     
        in_vtx(dsti).x = ot_vtx(src1).x + (ot_vtx(src2).x-ot_vtx(src1).x)*scl
        in_vtx(dsti).y = ot_vtx(src1).y + (ot_vtx(src2).y-ot_vtx(src1).y)*scl
        in_vtx(dsti).z = ot_vtx(src1).z
        in_vtx(dsti).w = z_far        
        in_uv(dsti).u = ot_uv(src1).u + (ot_uv(src2).u-ot_uv(src1).u)*scl
        in_uv(dsti).v = ot_uv(src1).v + (ot_uv(src2).v-ot_uv(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfb:
    next n
    
    ot_cnt = dsti    
    
end sub



''::::::::::
'' name: d_draw_faces
'' desc: Draws the faces the BSP walk marked, in the walk's back to
''       front order.
''
'' One call per frame. Everything inside it runs per node, per face,
'' per vertex or per triangle and is therefore written out in place.
''::::::::::
'' ==========================================================================
''  RASTER
'' ==========================================================================
sub d_draw_faces ( _
    g as Game, _
    h_dst_dc as long, _
    mtx_fin as u3dMtrx, _
    xresh as single, _
    yresh as single, _
    campos as u3dVector3f, _
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
    order_list() as integer, _
    poly_flag() as integer _
)
    dim dp as single
    dim poly_cnt as integer
    dim mi as integer, m as integer
    dim leaf_indx as integer, leaf_end as integer, ti as integer, i as integer
    dim pid as integer, tex as integer, j as integer
    dim mt as long
    dim mp as long
    dim v0 as integer, gn as integer

    dim gp as long, gv_dst as long
    dim zl as single
    dim mip_level as integer, draw_mip as integer
    dim tex_dc as long
    dim p2 as integer, p3 as integer
    dim liquid as integer
    dim tu as single, tv as single
    dim tqi as long, tqj as long
    dim turbph as single
    dim zofs as single
    dim lm_on as integer, lm_use as integer
    dim lm_tms as integer, lm_tmt as integer
    dim lm_extw as integer, lm_exth as integer
    dim lm_stag as integer
    dim dl_pl as Plane, dl_pdist as single
    dim lm_mip as integer, lm_floor as integer
    dim lm_sw as integer, lm_sh as integer
    dim lm_fw as integer, lm_fh as integer
    dim z_want as integer, z_have as integer, z_avail as integer
    dim lm_cm as integer
    dim lm_dc as long, src_dc as long
    dim lm_su as single, lm_sv as single
    dim rt0 as long, rast_cyc as long, rdt as single
    dim rface as long
    dim bt0 as long, build_cyc as long, bdt as single
    dim bface as long
    dim at0 as long, aim_cyc as long, adt as single
    dim aface as long
    dim et0 as long, emit_cyc as long, edt as single
    dim eface as long
    dim ft0 as long, fdt as single, sface as long
    dim span_cnt as integer

   ''
   '' Draw nodes
   ''       
    '' -1 is no mode at all, so the first face always installs one rather
    '' than trusting whatever the previous frame or the overlay left set.
    z_have = -1

    '' Asked once, not per face: whether a depth buffer exists cannot change
    '' inside a frame.
    z_avail = host_z_on
    turbph = g.rdr.anim_time * TURB_RATE#


    ''
    '' The per-face lightmap table lives in a memAlloc'd block, so it is
    '' reached by DEF SEG and an offset rather than as an array. The segment
    '' is fixed for the whole frame; only the offset moves.
    ''
    '' g.rdr.lightmap as well as g.env.use_lm: the flag says whether the data
    '' was loaded at all, the toggle says whether to use it right now.
    '' Clearing this turns every face below into a plain textured one,
    '' which is exactly what an unlit face already does.
    lm_use = 0
    if ( g.env.use_lm and g.rdr.lightmap and sc_ready <> 0 ) then lm_use = -1

    rast_cyc = 0
    build_cyc = 0
    aim_cyc = 0
    emit_cyc = 0

    for mi = 0 to ord_count-1
        m = order_list(mi)
            
        '' One map per ordered node, then the face loop below maps
        '' geometry through the SAME physical slot. The alternation costs
        '' a real remap each way, but only once per node rather than once
        '' per face -- and emsMapEx skips it entirely when the page has
        '' not moved.
        leaf_indx = nds_buffer(m).lface_id
        leaf_end = leaf_indx + nds_buffer(m).lface_num-1
        
        for  ti = leaf_indx to leaf_end            
            i = ti
                   
            ''
            '' Two guards instead of two nested ifs. BASIC has no CONTINUE,
            '' so the skip is a GOTO to a label at the end of the loop body
            '' -- which is precisely what Quake's C writes as `continue` in
            '' this same loop. It takes the face body from column 20 to 12.
            ''
            if ( poly_flag(i) <> frame_stamp ) then goto next_face

                
            ''
            '' Backface cull.
            ''
            '' Signed distance from the camera to the face's plane,
            '' with the face's side folded into the sign: side 0 is a
            '' face pointing along the plane normal, side 1 one
            '' pointing against it, and a face is only ever visible
            '' from its own front. One sign test then decides it.
            ''
            '' Three separate faults used to make this inert. It read
            '' triBuffer(nodenr), and nodenr does not exist in this
            '' scope -- under defint a-z QuickBASIC created it as an
            '' integer 0, so every face in the map was tested against
            '' face 0's plane. It added the plane distance where the
            '' rest of the file (bspClasifypoint, bspWalkNodeB)
            '' subtracts it. And all three branches assigned
            '' drawply = 1, so nothing was ever rejected and the HUD's
            '' "backface culling: enabled" was reporting a switch that
            '' did nothing.
            ''
            '' one map per face: it covers planeid, side, geom_row,
            '' geom_ofs and texinfoid, and nothing between them remaps this
            '' array (the geometry window is a different store entirely).
            dp = r_cam_plane_dist( campos, pln_buffer( tri_buffer(i).plane_id ) )
                      
            if ( tri_buffer(i).side ) then dp = -dp
                
            if ( g.rdr.backface <> 0 and dp <= 0.01 ) then goto next_face

                	
		''
		'' Build polygon
		''
            ''
            '' This face's corners, out of the geometry store. Copy up to
            '' the end of the row and no further: the builder keeps a
            '' record inside one row, so the row end is also the end of
            '' the mapped EMS window, and a fixed-size copy from a record
            '' near it would read off the page.
            ''
            '' Where memCopy puts the record. Taken per face, NOT hoisted
            '' out of the loop: gv_buf is a far-heap array and the runtime
            '' relocates it, so a pointer cached at entry can go stale
            '' mid-frame. It did -- every copy after the move landed
            '' somewhere else, gv_buf kept the first face's record, and
            '' every face then shared one cached surface.
            ''
            gv_dst = clng( varseg( gv_buf(0) ) ) * 65536& + _
                     (clng( varptr( gv_buf(0) ) ) and 65535&)

            gp = mod_geom_map ( g, tri_buffer(i).geom_row )
            gn = GEOM_MAXREC
            if ( tri_buffer(i).geom_ofs + gn > GEOM_W ) then
                gn = GEOM_W - tri_buffer(i).geom_ofs
            end if
            memCopy gv_dst, gp + clng( tri_buffer(i).geom_ofs ), clng( gn )

            vcnt = gv_buf(0)
            tex = tri_buffer(i).tex_info_id
            tex_id = tex_inf_buff(tex).mip_tex

            liquid = mip_buff_inf(tex_id).liquid
            zofs   = brush( face_mdl(i) ).zofs

            ''
            '' Depth mode follows what this face belongs to. face_mdl is 0
            '' for the world and the submodel index for a brush entity.
            ''
            '' The world only writes: r_draw_world hands its faces over
            '' front to back, so a test could never reject anything the
            '' order had not already settled, and rejecting costs a
            '' compare per pixel for nothing. Brush entities test, because
            '' a door swinging through a doorway has no such guarantee.
            ''
            '' Only switched when it actually changes -- faces arrive in
            '' large runs from the same model, so this is a handful of
            '' calls a frame rather than one per face.
            ''
            if ( z_avail <> 0 ) then
                if ( face_mdl(i) = 0 ) then
                    z_want = UGL.Z.WRITE%
                else
                    z_want = UGL.Z.TEST%
                end if
                if ( z_want <> z_have ) then
                    z_have = uglZMode%( z_want )
                end if
            end if
                    
            ''
            '' Texture axes, scaled by the texture size once per
            '' face rather than per vertex.
            ''
            '' Each of these was an array index plus a UDT member
            '' fetch inside the vertex loop, and the size was a
            '' further two fetches and two multiplies per vertex.
            '' Folding the size into the axes is exact -- it is
            '' the same product in a different order -- and
            '' nothing downstream wants the unscaled value.
            ''
            tw = mip_buff_inf(tex_id).wdth
            th = mip_buff_inf(tex_id).hght

            ''
            '' Is this face a surface-cache candidate? It must have a
            '' lightmap (ofs_hi = -1 marks one that does not), and it must
            '' not be a liquid -- those perturb their own coordinates per
            '' vertex -- or animated, which would rebuild the surface every
            '' time the frame index moved.
            ''
            '' Straight out of the record copied above -- the lightmap
            '' header rides with the corners, so there is no second block
            '' to map and no DEF SEG here at all. gv_buf(GEOM_LMOFS) is
            '' the atlas scanline, -1 on an unlit face.
            lm_on = 0
            if ( lm_use and liquid = 0 and _
                 mip_buff_inf(tex_id).anim_count <= 1 ) then
                if ( gv_buf(GEOM_LMOFS) >= 0 ) then
                    lm_tms  = gv_buf(GEOM_LMOFS + 2)
                    lm_tmt  = gv_buf(GEOM_LMOFS + 3)
                    lm_extw = (gv_buf(GEOM_LMOFS + 4) - 1) * 16
                    lm_exth = (gv_buf(GEOM_LMOFS + 5) - 1) * 16
                    if ( lm_extw > 0 and lm_exth > 0 ) then lm_on = -1
                    ''
                    '' The style id the baked plane belongs to -- mkassets
                    '' packs it as the low byte of styles01 (GEOM_LMOFS+6)
                    '' and has all along; nothing read it until now. The
                    '' epoch is looked up per face rather than cached,
                    '' which costs one array read and is what lets sc_find
                    '' notice a style changed without this module knowing
                    '' anything about how styles work.
                    ''
                    lm_stag = ls_epoch( gv_buf(GEOM_LMOFS + 6) and 255 )

                    ''
                    '' A face the dynamic light can reach must rebuild
                    '' EVERY frame it stays in range, and once more the
                    '' frame after it leaves to wash the glow back out --
                    '' matching it here forces exactly that: the miss
                    '' happens the instant the face is decided to be a
                    '' candidate at all, before sc_find ever sees it, so a
                    '' plain style-epoch match can never paper over it. -1
                    '' never collides with a real epoch, which is always
                    '' >= 0, so the frame the light leaves still misses
                    '' once against the stale -1 this frame wrote, then
                    '' settles back to matching on the frame after that.
                    ''
                    dl_pl = pln_buffer( tri_buffer(i).plane_id )
                    dl_pdist = g.rdr.dlight.pos.x * dl_pl.norm.x + _
                               g.rdr.dlight.pos.y * dl_pl.norm.y + _
                               g.rdr.dlight.pos.z * dl_pl.norm.z - dl_pl.dist
                    if ( abs( dl_pdist ) < g.rdr.dlight.radius ) then lm_stag = -1
                end if
            end if

            ''
            '' A cached face's coordinates stay in ORIGINAL TEXEL units --
            '' the surface is a piece of the texture, not the whole of it,
            '' so the shift to surface-local space needs the unscaled value
            '' and cannot be applied until the mip is known (below). Every
            '' other face normalises against the atlas here as before.
            ''
            if ( lm_on ) then
                su0 = tex_inf_buff(tex).vecs(0)
                su1 = tex_inf_buff(tex).vecs(1)
                su2 = tex_inf_buff(tex).vecs(2)
                su3 = tex_inf_buff(tex).vecs(3)
                sv0 = tex_inf_buff(tex).vect(0)
                sv1 = tex_inf_buff(tex).vect(1)
                sv2 = tex_inf_buff(tex).vect(2)
                sv3 = tex_inf_buff(tex).vect(3)
            else
                su0 = tex_inf_buff(tex).vecs(0) * tw
                su1 = tex_inf_buff(tex).vecs(1) * tw
                su2 = tex_inf_buff(tex).vecs(2) * tw
                su3 = tex_inf_buff(tex).vecs(3) * tw
                sv0 = tex_inf_buff(tex).vect(0) * th
                sv1 = tex_inf_buff(tex).vect(1) * th
                sv2 = tex_inf_buff(tex).vect(2) * th
                sv3 = tex_inf_buff(tex).vect(3) * th
            end if

            ''
            '' Animation, once per face rather than per vertex.
            ''
            '' An animated texture swaps which image is sampled, so it costs
            '' nothing but the index arithmetic.
            ''
            if ( mip_buff_inf(tex_id).anim_count > 1 ) then
                tex_id = mip_buff_inf(tex_id).anim_base + _
                         (int( g.rdr.anim_time * 5.0 ) mod mip_buff_inf(tex_id).anim_count)
            end if
                    
            for  j = 0 to vcnt-1
                ''
                '' Straight out of the copied record -- no vertex
                '' index, no edge, no indirection at all.
                ''
                v0 = j*3 + GEOM_VTX0
                vx = gv_buf(v0    ) * VTX_UNSCALE#
                vy = gv_buf(v0 + 1) * VTX_UNSCALE#
                vz = gv_buf(v0 + 2) * VTX_UNSCALE#

                polyb(j).x = vx
                polyb(j).y = vz + zofs
                polyb(j).z = vy
                polyb(j).w = 1.0
                        
                uv_buff_b(j).u = su0*vx + su1*vy + su2*vz + su3
                uv_buff_b(j).v = sv0*vx + sv1*vy + sv2*vz + sv3

                ''
                '' A liquid displaces each coordinate by a sine of the
                '' other, so the surface rolls rather than slides.
                ''
                '' Per vertex, which is as fine as this renderer can do
                '' it: Quake perturbs per span, inside its own texture
                '' mapper, and uGL's mapper is not ours to change.
                ''
                if ( liquid ) then
                    tu = uv_buff_b(j).u
                    tv = uv_buff_b(j).v
                    tqi = int( tv*TURB_FREQ# + turbph ) and 255
                    tqj = int( tu*TURB_FREQ# + turbph ) and 255
                    uv_buff_b(j).u = tu + turb_sin(tqi)
                    uv_buff_b(j).v = tv + turb_sin(tqj)
                end if
            next j

            ''
            '' The lightmap extent that used to be computed here
            '' -- the min/max of u and v over the face, the 16
            '' unit block round-down, smax, tmax, size and the
            '' lightmap offset -- was never read by anything. It
            '' cost four compares per vertex and a divide per
            '' axis per face to produce values that were
            '' overwritten on the next face. Removed; the lump is
            '' still loaded, so it can come back with a consumer.
            ''

                    
            ''
            '' Transform and clip to near and far
            ''
            u3dMtrxByVec4 polyb(0), len( polyb(0) ), mtx_fin, _
                          polyb(0), len( polyb(0) ), vcnt
            d_clip_z poly(), uvbuff(), poly_cnt, polyb(), uv_buff_b(), vcnt, g.env.z_near, g.env.z_far

			''
			'' If more then 2 vertices, rasterize
			''
            if poly_cnt > 2 then
                    	
            ''
            '' Project every vertex of the polygon once, then let
            '' the fan reference the results.
            ''
            '' The fan divided and projected all three corners of
            '' every triangle it emitted. Vertex 0 is in every
            '' triangle of a fan and was re-divided for each one,
            '' and each interior vertex appears in two triangles
            '' and was divided twice: a 7-gon paid 15 reciprocals
            '' where 7 do. On a 486 without a fast divide that is
            '' the most expensive line in the loop.
            ''
            for  j = 0 to poly_cnt-1
                prj_w(j) = 1.0 / polyb(j).w
                prj_x(j) = xresh + polyb(j).x*prj_w(j)*xresh
                prj_y(j) = yresh - polyb(j).y*prj_w(j)*yresh
            next j

            ''
            '' The same argument for the texture coordinates: the
            '' perspective divide belongs to the vertex, not to
            '' each triangle that happens to share it. Choosing
            '' the mode out here also leaves ONE copy of the
            '' vertex assignment below instead of the three
            '' near-identical copies the mode branches used to
            '' carry.
            ''
            if ( g.rdr.rend_mode = 0 ) then
                for  j = 0 to poly_cnt-1
                    prj_u(j) = uv_buff_b(j).u * prj_w(j)
                    prj_v(j) = uv_buff_b(j).v * prj_w(j)
                next j
            elseif ( g.rdr.rend_mode = 1 ) then
                for  j = 0 to poly_cnt-1
                    prj_u(j) = uv_buff_b(j).u
                    prj_v(j) = uv_buff_b(j).v
                next j
            end if

            ''
            '' Mip level, once per face.
            ''
            '' This used to run per triangle, on the mean of that
            '' triangle's three vertices -- and every fan triangle
            '' includes the pivot, so the two halves of a quad could
            '' straddle a threshold and land on different mips. The
            '' mips are box filtered resamples at different sizes, so
            '' a one texel mortar line falls on a different texel row
            '' in each: the seam shows as the texture stepping a
            '' couple of pixels along the fan diagonal. Quake picks a
            '' mip per surface, and so does this now.
            ''
            zl = 0.0
            for  j = 0 to poly_cnt-1
                zl = zl + polyb(j).w
            next j
            zl = zl / poly_cnt

            if  ( zl >= 1400.0 ) then
                mip_level = 3
            elseif  ( zl >= 560.0 ) then
                mip_level = 2
            elseif  ( zl >= 280.0 ) then
                mip_level = 1
            else
                mip_level = 0
            end if

            if ( g.rdr.use_mips ) then
                draw_mip = mip_level
            else
                draw_mip = 0
            end if

            ''
            '' The cached surface, now that the mip is settled. sc_mipfloor
            '' is the finest mip whose padded surface still fits the single
            '' EMS page the filler maps, so it is a floor on the distance
            '' choice, never a substitute for it.
            ''
            if ( lm_on ) then
                lm_mip = mip_level
                if ( g.rdr.use_mips = 0 ) then lm_mip = 0
                lm_floor = sc_mipfloor( lm_extw, lm_exth )
                if ( lm_mip < lm_floor ) then lm_mip = lm_floor

                ''
                '' Sticky mip. zl above is the average w over the CLIPPED
                '' vertices, so it moves when the camera merely rotates -- a
                '' face sitting near one of the thresholds flips mip every
                '' few frames, and every flip is a full rebuild because
                '' sc_find keys on the mip. Keep whatever this face is
                '' already cached at unless the new choice is more than one
                '' level away: one mip of error is not visible, and the
                '' rebuild it saves is milliseconds.
                ''
                '' The generation has to match too, or a stale tag from
                '' before a flush would pin the mip to a surface that is no
                '' longer there.
                ''
                lm_cm = sc_held( i )
                if ( lm_cm >= 0 ) then
                    if ( abs( lm_mip - lm_cm ) <= 1 ) then lm_mip = lm_cm
                    if ( lm_mip < lm_floor ) then lm_mip = lm_floor
                end if

                lm_sw = lm_extw \ (2 ^ lm_mip)
                lm_sh = lm_exth \ (2 ^ lm_mip)
                if ( lm_sw < 1 ) then lm_sw = 1
                if ( lm_sh < 1 ) then lm_sh = 1

                ''
                '' The block is sized at the face's FLOOR mip, so it stays
                '' the same block whatever mip is drawn -- see sc_alloc.
                ''
                lm_fw = lm_extw \ (2 ^ lm_floor)
                lm_fh = lm_exth \ (2 ^ lm_floor)
                if ( lm_fw < 1 ) then lm_fw = 1
                if ( lm_fh < 1 ) then lm_fh = 1

                lm_dc = sc_find( i, lm_mip, lm_sw, lm_sh, lm_stag )
                if ( lm_dc = 0 ) then
                    bt0 = sys_rdtsc()
                    lm_dc = sc_alloc ( g, i, lm_mip, lm_sw, lm_sh, lm_fw, lm_fh, lm_stag )
                    if ( lm_dc <> 0 ) then
                        ''
                        '' Build the DC's WHOLE padded extent, not just the
                        '' surface's own sw by sh. The face's far edge lands
                        '' exactly on texel sw, one past the last one a
                        '' sw-wide fill writes, so every face was drawing a
                        '' black seam of recycled DC along two of its sides.
                        '' sb_build clamps its luxel and atlas reads, so the
                        '' extra columns come out edge-extended.
                        ''
                        '' hoisted: BC will not take a call inside another
                        '' call's argument list
                        tex_dc = mod_tex_raw( g, tex_id, lm_mip )
                        sb_build g, lm_dc, tex_dc, i, lm_mip, _
                                  2 ^ sc_shift( lm_sw ), 2 ^ sc_shift( lm_sh ), _
                                  tri_buffer(), tex_inf_buff(), gv_buf(), mip_buff_inf(), _
                                  pln_buffer()
                    end if
                    ''
                    '' Same glitch guard as the raster timer below -- see
                    '' sys_rdtsc's own doc comment. Builds are rare enough
                    '' per frame that a single discarded sample barely
                    '' moves the sum, unlike leaving a glitched one in.
                    ''
                    bface = sys_rdtsc() - bt0
                    if ( bface >= 0 and bface <= 1000000 ) then
                        build_cyc = build_cyc + bface
                    end if
                end if

                if ( lm_dc <> 0 ) then
                    ''
                    '' Texel units -> surface-local, normalised against the
                    '' DC's padded size: subtract the surface origin, divide
                    '' by the texels-per-surface-texel the mip implies. In
                    '' perspective mode the coordinates are already over w,
                    '' so the origin has to be scaled by w to match.
                    ''
                    lm_su = 1.0 / ((2 ^ lm_mip) * (2 ^ sc_shift( lm_sw )))
                    lm_sv = 1.0 / ((2 ^ lm_mip) * (2 ^ sc_shift( lm_sh )))
                    if ( g.rdr.rend_mode = 0 ) then
                        for  j = 0 to poly_cnt-1
                            prj_u(j) = (prj_u(j) - lm_tms*prj_w(j)) * lm_su
                            prj_v(j) = (prj_v(j) - lm_tmt*prj_w(j)) * lm_sv
                        next j
                    else
                        for  j = 0 to poly_cnt-1
                            prj_u(j) = (prj_u(j) - lm_tms) * lm_su
                            prj_v(j) = (prj_v(j) - lm_tmt) * lm_sv
                        next j
                    end if
                    src_dc = lm_dc
                else
                    ''
                    '' No surface to be had -- the class was exhausted or the
                    '' DC would not fit. The coordinates are still in texel
                    '' units, so put them back on the atlas scale.
                    ''
                    for  j = 0 to poly_cnt-1
                        prj_u(j) = prj_u(j) * tw
                        prj_v(j) = prj_v(j) * th
                    next j
                    lm_on = 0
                end if
            end if

            '' the texture itself, only where no cached surface stands in
            if ( lm_on = 0 ) then
                ''
                '' Isolates uglSetView's own cost from the triangle
                '' mappers below: mod_tex_shaded only calls it when the
                '' cell it wants differs from the one its view is already
                '' aimed at, so most calls land here and return at once.
                '' Same glitch guard as raster/build -- see sys_rdtsc.
                ''
                at0 = sys_rdtsc()
                src_dc = mod_tex_shaded( g, tex_id, draw_mip )
                aface = sys_rdtsc() - at0
                if ( aface >= 0 and aface <= 1000000 ) then
                    aim_cyc = aim_cyc + aface
                end if
            end if

            ''
            '' r_span.c prototype: same projected vertices uGL is about
            '' to receive, timed the same way as aim/build/raster above.
            ''
            et0 = sys_rdtsc()
            r_span_emit_poly poly_cnt, prj_x(), prj_y(), prj_w(0)
            eface = sys_rdtsc() - et0
            if ( eface >= 0 and eface <= 1000000 ) then
                emit_cyc = emit_cyc + eface
            end if

                ''
                '' One convex polygon, one call -- no fan pivot, so no
                '' internal edges for the rasteriser to seam along.
                '' Wireframe mode still fans, it wants the triangles.
                ''
                rt0 = sys_rdtsc()
                if ( g.env.poly_tp and poly_cnt <= 12 ) then
                    for  j = 0 to poly_cnt-1
                        pvtx(j).x = prj_x(j)
                        pvtx(j).y = prj_y(j)
                        pvtx(j).z = prj_w(j)
                        pvtx(j).u = prj_u(j)
                        pvtx(j).v = prj_v(j)
                    next j

                    uglPolyTP h_dst_dc, pvtx(0), poly_cnt, 0, src_dc
                    g.rdr.tris = g.rdr.tris + (poly_cnt-2)
                    goto poly_done
                end if

                for j = 0 to poly_cnt-3
                    p2 = j+1
                    p3 = j+2


                    ''
                    '' Rasterize. Vertex 0 is the fan pivot.
                    ''
                    vtx(j).v1.z = prj_w(0)
                    vtx(j).v2.z = prj_w(p2)
                    vtx(j).v3.z = prj_w(p3)
                    vtx(j).v1.x = prj_x(0)
                    vtx(j).v1.y = prj_y(0)
                    vtx(j).v2.x = prj_x(p2)
                    vtx(j).v2.y = prj_y(p2)
                    vtx(j).v3.x = prj_x(p3)
                    vtx(j).v3.y = prj_y(p3)

                    if ( g.rdr.rend_mode = 2 ) then
                        uglTriF h_dst_dc, vtx(j), 200
                        uglLine h_dst_dc, vtx(j).v1.x, vtx(j).v1.y, vtx(j).v2.x, vtx(j).v2.y, 0
                        uglLine h_dst_dc, vtx(j).v2.x, vtx(j).v2.y, vtx(j).v3.x, vtx(j).v3.y, 0
                        uglLine h_dst_dc, vtx(j).v3.x, vtx(j).v3.y, vtx(j).v1.x, vtx(j).v1.y, 0
                    else
                        vtx(j).v1.u = prj_u(0)
                        vtx(j).v1.v = prj_v(0)
                        vtx(j).v2.u = prj_u(p2)
                        vtx(j).v2.v = prj_v(p2)
                        vtx(j).v3.u = prj_u(p3)
                        vtx(j).v3.v = prj_v(p3)

                        if ( g.rdr.rend_mode = 0 ) then
                            uglTriTP h_dst_dc, vtx(j), 0, src_dc
                        else
                            uglTriT h_dst_dc, vtx(j), 0, src_dc
                        end if
                    end if

                    g.rdr.tris = g.rdr.tris + 1                                
                next j

poly_done:
            end if

            ''
            '' Both paths through the block above -- the single-call
            '' convex case and the triangle fan -- land here, so this
            '' catches whichever one ran. Accumulated per face rather
            '' than reported per face: sys_rdtsc costs a far call of its
            '' own, and a Game-struct write on top of that per face would
            '' be measuring the measurement.
            ''
            '' Guarded rather than added directly: on a long run the raw
            '' counter has been measured reading back near zero for a
            '' single call, unrelated to the sign-bit wrap sys_rdtsc
            '' already corrects for -- traced to the dynamic core's own
            '' RDTSC virtualization, not something this arithmetic can
            '' fix. One microsecond cap of a million (a full second, on a
            '' single face) is nowhere near real rasterise cost and
            '' nowhere near a genuine measurement either, so a delta
            '' outside 0..CAP is a glitched sample, discarded exactly as
            '' sys_frame_time already discards a negative frame_tmr wrap.
            ''
            rface = sys_rdtsc() - rt0
            if ( rface >= 0 and rface <= 1000000 ) then
                rast_cyc = rast_cyc + rface
            end if

            g.rdr.polys = g.rdr.polys + 1

next_face:
        next ti
    next mi

    ''
    '' r_span.c prototype, flush half: every polygon this frame has been
    '' emitted above, so this resolves them into the final span list --
    '' see r_span.c's own header for why this is the call that would end
    '' up interleaved with drawing, one scanline at a time, rather than
    '' materialising the whole frame's spans first.
    ''
    ft0 = sys_rdtsc()
    span_cnt = r_span_flush( g.env.x_res, g.env.y_res )
    sface = sys_rdtsc() - ft0

    if ( g.ft.n > 0 ) then
        '' rast_cyc is a sum of MICROSECOND deltas now, sys_rdtsc having
        '' already divided by cyc_per_us on every call -- just seconds
        '' from here, no sys_rdtsc_hz() needed at the call site at all.
        rdt = rast_cyc / 1000000.0
        g.pt.raster_sum = g.pt.raster_sum + rdt
        if ( rdt > g.pt.raster_max ) then g.pt.raster_max = rdt

        adt = aim_cyc / 1000000.0
        g.pt.aim_sum = g.pt.aim_sum + adt
        if ( adt > g.pt.aim_max ) then g.pt.aim_max = adt

        bdt = build_cyc / 1000000.0
        g.pt.build_sum = g.pt.build_sum + bdt
        if ( bdt > g.pt.build_max ) then g.pt.build_max = bdt

        edt = emit_cyc / 1000000.0
        g.pt.emit_sum = g.pt.emit_sum + edt
        if ( edt > g.pt.emit_max ) then g.pt.emit_max = edt

        if ( sface >= 0 and sface <= 1000000 ) then
            fdt = sface / 1000000.0
            g.pt.span_sum = g.pt.span_sum + fdt
            if ( fdt > g.pt.span_max ) then g.pt.span_max = fdt
        end if
    end if
end sub



''::::::::::
'' name: d_init_turb
'' desc: Builds the turbulence table once. Quake's is 8 texels of a 64 wide
''       texture; ours is in the normalised units the draw loop works in, so
''       the amplitude is that ratio.
''::::::::::
sub d_init_turb
    dim i as integer

    for  i = 0 to 255
        turb_sin(i) = TURB_AMP# * sin( i * (2.0*3.14159265 / 256.0) )
    next i

end sub
