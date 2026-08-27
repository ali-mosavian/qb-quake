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
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'

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
dim shared vcnt as integer, mipidx as integer

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
    h_dst_dc as long, _
    mtx_fin as u3dMtrx, _
    xresh as single, _
    yresh as single, _
    byval face_count as long, _
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
    dim mip_level as integer, tex_indx as integer
    dim p2 as integer, p3 as integer
    dim liquid as integer
    dim tu as single, tv as single
    dim tqi as long, tqj as long
    dim turbph as single
    dim zofs as single
    dim lm_on as integer, lm_use as integer
    dim lm_tms as integer, lm_tmt as integer
    dim lm_extw as integer, lm_exth as integer
    dim lm_mip as integer, lm_floor as integer
    dim lm_sw as integer, lm_sh as integer
    dim lm_fw as integer, lm_fh as integer
    dim z_want as integer, z_have as integer, z_avail as integer
    dim lm_cm as integer
    dim lm_dc as long, src_dc as long
    dim lm_su as single, lm_sv as single

   ''
   '' Draw nodes
   ''       
    '' -1 is no mode at all, so the first face always installs one rather
    '' than trusting whatever the previous frame or the overlay left set.
    z_have = -1

    '' Asked once, not per face: whether a depth buffer exists cannot change
    '' inside a frame.
    z_avail = host_z_on
    turbph = rdr.anim_time * TURB_RATE#


    ''
    '' The per-face lightmap table lives in a memAlloc'd block, so it is
    '' reached by DEF SEG and an offset rather than as an array. The segment
    '' is fixed for the whole frame; only the offset moves.
    ''
    '' rdr.lightmap as well as env.use_lm: the flag says whether the data
    '' was loaded at all, the toggle says whether to use it right now.
    '' Clearing this turns every face below into a plain textured one,
    '' which is exactly what an unlit face already does.
    lm_use = 0
    if ( env.use_lm and rdr.lightmap and sc_ready <> 0 ) then lm_use = -1

    ''
    '' Where memCopy puts a face's record. Hoisted: VARSEG/VARPTR on a
    '' DIM SHARED array cannot move, and working it out per face is a
    '' cost per drawn face for an answer that never changes.
    ''
    gv_dst = clng( varseg( gv_buf(0) ) ) * 65536& + _
             (clng( varptr( gv_buf(0) ) ) and 65535&)

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
                
            if ( rdr.backface <> 0 and dp <= 0.01 ) then goto next_face

                	
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
            gp = mod_geom_map( tri_buffer(i).geom_row )
            gn = GEOM_MAXREC
            if ( tri_buffer(i).geom_ofs + gn > GEOM_W ) then
                gn = GEOM_W - tri_buffer(i).geom_ofs
            end if
            memCopy gv_dst, gp + clng( tri_buffer(i).geom_ofs ), clng( gn )

            vcnt = gv_buf(0)
            tex = tri_buffer(i).tex_info_id
            mipidx = tex_inf_buff(tex).mip_tex

            liquid = mip_buff_inf(mipidx).liquid
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
            tw = mip_buff_inf(mipidx).wdth
            th = mip_buff_inf(mipidx).hght

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
                 mip_buff_inf(mipidx).anim_count <= 1 ) then
                if ( gv_buf(GEOM_LMOFS) >= 0 ) then
                    lm_tms  = gv_buf(GEOM_LMOFS + 2)
                    lm_tmt  = gv_buf(GEOM_LMOFS + 3)
                    lm_extw = (gv_buf(GEOM_LMOFS + 4) - 1) * 16
                    lm_exth = (gv_buf(GEOM_LMOFS + 5) - 1) * 16
                    if ( lm_extw > 0 and lm_exth > 0 ) then lm_on = -1
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
            if ( mip_buff_inf(mipidx).anim_count > 1 ) then
                mipidx = mip_buff_inf(mipidx).anim_base + _
                         (int( rdr.anim_time * 5.0 ) mod mip_buff_inf(mipidx).anim_count)
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
            d_clip_z poly(), uvbuff(), poly_cnt, polyb(), uv_buff_b(), vcnt, env.z_near, env.z_far

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
            if ( rdr.rend_mode = 0 ) then
                for  j = 0 to poly_cnt-1
                    prj_u(j) = uv_buff_b(j).u * prj_w(j)
                    prj_v(j) = uv_buff_b(j).v * prj_w(j)
                next j
            elseif ( rdr.rend_mode = 1 ) then
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

            if ( rdr.use_mips ) then
                tex_indx = mipidx*4+mip_level
            else
                tex_indx = mipidx*4
            end if

            ''
            '' The cached surface, now that the mip is settled. sc_mipfloor
            '' is the finest mip whose padded surface still fits the single
            '' EMS page the filler maps, so it is a floor on the distance
            '' choice, never a substitute for it.
            ''
            src_dc = h_textr_dc(tex_indx)
            if ( lm_on ) then
                lm_mip = mip_level
                if ( rdr.use_mips = 0 ) then lm_mip = 0
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

                lm_dc = sc_find( i, lm_mip, lm_sw, lm_sh )
                if ( lm_dc = 0 ) then
                    lm_dc = sc_alloc( i, lm_mip, lm_sw, lm_sh, lm_fw, lm_fh, face_count )
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
                        sb_build lm_dc, h_rawtx_dc(mipidx*4 + lm_mip), _
                                 i, lm_mip, 2 ^ sc_shift( lm_sw ), _
                                 2 ^ sc_shift( lm_sh ), _
                                 tri_buffer(), tex_inf_buff(), gv_buf(), _
                                 mip_buff_inf()
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
                    if ( rdr.rend_mode = 0 ) then
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
                ''
                '' One convex polygon, one call -- no fan pivot, so no
                '' internal edges for the rasteriser to seam along.
                '' Wireframe mode still fans, it wants the triangles.
                ''
                if ( env.poly_tp and poly_cnt <= 12 ) then
                    for  j = 0 to poly_cnt-1
                        pvtx(j).x = prj_x(j)
                        pvtx(j).y = prj_y(j)
                        pvtx(j).z = prj_w(j)
                        pvtx(j).u = prj_u(j)
                        pvtx(j).v = prj_v(j)
                    next j

                    uglPolyTP h_dst_dc, pvtx(0), poly_cnt, 0, src_dc
                    rdr.tris = rdr.tris + (poly_cnt-2)
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

                    if ( rdr.rend_mode = 2 ) then
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

                        if ( rdr.rend_mode = 0 ) then
                            uglTriTP h_dst_dc, vtx(j), 0, src_dc
                        else
                            uglTriT h_dst_dc, vtx(j), 0, src_dc
                        end if
                    end if

                    rdr.tris = rdr.tris + 1                                
                next j

poly_done:
            end if

            rdr.polys = rdr.polys + 1

next_face:
        next ti
    next mi        
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
