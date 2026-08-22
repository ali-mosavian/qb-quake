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
defint a-z
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
'$include: 'quakedef.bi'

'$static
dim shared poly(64) as u3dVector4f
dim shared polyb(32) as u3dVector4f
dim shared prj_u(32) as single
dim shared prj_v(32) as single
dim shared prj_w(32) as single
dim shared prj_x(32) as single
dim shared prj_y(32) as single
dim shared su0 as single, su1 as single, su2 as single, su3 as single
dim shared sv0 as single, sv1 as single, sv2 as single, sv3 as single
dim shared tw as single, th as single
dim shared uvbuff(64) as uv
dim shared uvbuffb(32) as uv
dim shared vcnt as integer, mipidx as integer
dim shared vtx(31) as tritype
dim shared vx as single, vy as single, vz as single




'':::::::
defint a-z
sub d_clip_z ( otVtx() as u3dVector4f, otUV() as uv, otCnt as integer, _
                     inVtx() as u3dVector4f, inUV() as uv, inCnt as integer )

    dim n as integer
    dim scl as single
    dim dsti as integer, tmCnt as integer
    dim src1 as integer, src2 as integer

    for  n = 0 to inCnt-1
        src1 = n
        src2 = (n + 1) mod inCnt
        
        if ( inVtx(src1).w >= env.z_near ) then
            otVtx(dsti).x = inVtx(src1).x
            otVtx(dsti).y = inVtx(src1).y
            otVtx(dsti).z = inVtx(src1).z
            otVtx(dsti).w = inVtx(src1).w
            otUV(dsti).u = inUV(src1).u
            otUV(dsti).v = inUV(src1).v
            
            dsti = dsti + 1 
            
            if ( inVtx(src2).w >= env.z_near ) then
                goto continuenfa
            end if
        else
            if ( inVtx(src2).w < env.z_near ) then
                goto continuenfa
            end if
        end if

        scl = ((env.z_near - inVtx(src1).w) / (inVtx(src2).w - inVtx(src1).w))
     
        otVtx(dsti).x = inVtx(src1).x + (inVtx(src2).x-inVtx(src1).x)*scl
        otVtx(dsti).y = inVtx(src1).y + (inVtx(src2).y-inVtx(src1).y)*scl
        otVtx(dsti).z = inVtx(src1).z
        otVtx(dsti).w = env.z_near        
        otUV(dsti).u = inUV(src1).u + (inUV(src2).u-inUV(src1).u)*scl
        otUV(dsti).v = inUV(src1).v + (inUV(src2).v-inUV(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfa:        
    next n
    
    otCnt = dsti
    if ( otCnt < 3 ) then exit sub
    dsti = 0
    
    for  n = 0 to otCnt-1
        src1 = n
        src2 = (n + 1) mod otCnt
        
        if ( otVtx(src1).w <= env.z_far ) then
            inVtx(dsti).x = otVtx(src1).x
            inVtx(dsti).y = otVtx(src1).y
            inVtx(dsti).z = otVtx(src1).z
            inVtx(dsti).w = otVtx(src1).w
            inUV(dsti).u = otUV(src1).u
            inUV(dsti).v = otUV(src1).v
            
            dsti = dsti + 1 
            
            if ( otVtx(src2).w <= env.z_far ) then
                goto continuenfb
            end if
        else
            if ( otVtx(src2).w > env.z_far ) then
                goto continuenfb
            end if
        end if

        scl = ((env.z_far - otVtx(src1).w) / (otVtx(src2).w - otVtx(src1).w))
     
        inVtx(dsti).x = otVtx(src1).x + (otVtx(src2).x-otVtx(src1).x)*scl
        inVtx(dsti).y = otVtx(src1).y + (otVtx(src2).y-otVtx(src1).y)*scl
        inVtx(dsti).z = otVtx(src1).z
        inVtx(dsti).w = env.z_far        
        inUV(dsti).u = otUV(src1).u + (otUV(src2).u-otUV(src1).u)*scl
        inUV(dsti).v = otUV(src1).v + (otUV(src2).v-otUV(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfb:
    next n
    
    otCnt = dsti    
    
end sub



''::::::::::
'' name: bspDrawFaces
'' desc: Draws the faces the BSP walk marked, in the walk's back to
''       front order.
''
'' One call per frame. Everything inside it runs per node, per face,
'' per vertex or per triangle and is therefore written out in place.
''::::::::::
'' ==========================================================================
''  RASTER
'' ==========================================================================
defint a-z
sub d_draw_faces ( hDstDC as long, mtxFin as u3dMtrx, _
                   xresh as single, yresh as single )
    dim dp as single
    dim polycnt as integer
    dim mi as integer, m as integer
    dim leafIndx as integer, leafEnd as integer, ti as integer, i as integer
    dim pid as integer, lid as integer, tex as integer, j as integer
    dim EdgeIdx as integer, v0 as integer
    dim zl as single
    dim miplevel as integer, texIndx as integer
    dim p2 as integer, p3 as integer

   ''
   '' Draw nodes
   ''       
    for mi = 0 to vis.ord_count-1
        m = order_list(mi)
            
        leafIndx = nds_buffer(m).lfaceid
        leafEnd = leafIndx + nds_buffer(m).lfacenum-1
        
        for  ti = leafIndx to leafEnd            
            i = ti
                   
            if ( poly_flag(i) = vis.frame_stamp ) then
                
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
                pid = tri_buffer(i).planeid
                dp  = cam.pos.x*pln_buffer(pid).norm.x + _
                      cam.pos.y*pln_buffer(pid).norm.z + _
                      cam.pos.z*pln_buffer(pid).norm.y - _
                      pln_buffer(pid).dist
                      
                if ( tri_buffer(i).side ) then dp = -dp
                
                if ( rdr.backface = 0 or dp > 0.01 ) then
                	
        		''
        		'' Build polygon
        		''
                    lid = tri_buffer(i).ledgeid
                    tex = tri_buffer(i).texinfoid
                    mipidx = tex_inf_buff(tex).miptex
                    vcnt = tri_buffer(i).ledgenum
                    
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
                    su0 = tex_inf_buff(tex).vecs(0) * tw
                    su1 = tex_inf_buff(tex).vecs(1) * tw
                    su2 = tex_inf_buff(tex).vecs(2) * tw
                    su3 = tex_inf_buff(tex).vecs(3) * tw
                    sv0 = tex_inf_buff(tex).vect(0) * th
                    sv1 = tex_inf_buff(tex).vect(1) * th
                    sv2 = tex_inf_buff(tex).vect(2) * th
                    sv3 = tex_inf_buff(tex).vect(3) * th
                    
                    for  j = 0 to vcnt-1
                        EdgeIdx = ledg_buffer(lid+j)
                        
                        if ( EdgeIdx >= 0 ) then
                            v0 = edg_buffer(EdgeIdx).v0
                        else                        
                            v0 = edg_buffer(-EdgeIdx).v1
                        end if

                        ''
                        '' One fetch per component. The vertex was read
                        '' nine times before: three for the position and
                        '' three for each texture axis.
                        ''
                        vx = vtx_buffer(v0).x
                        vy = vtx_buffer(v0).y
                        vz = vtx_buffer(v0).z

                        polyb(j).x = vx
                        polyb(j).y = vz
                        polyb(j).z = vy
                        polyb(j).w = 1.0
                        
                        uvbuffb(j).u = su0*vx + su1*vy + su2*vz + su3
                        uvbuffb(j).v = sv0*vx + sv1*vy + sv2*vz + sv3
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
                    u3dMtrxByVec4 polyb(0), len( polyb(0) ), mtxFin, _
                                  polyb(0), len( polyb(0) ), vcnt
                    d_clip_z poly(), uvbuff(), polycnt, polyb(), uvbuffb(), vcnt

        			''
        			'' If more then 2 vertices, rasterize
        			''
                    if polycnt > 2 then
                    	
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
                    for  j = 0 to polycnt-1
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
                    if ( rdr.rendmode = 0 ) then
                        for  j = 0 to polycnt-1
                            prj_u(j) = uvbuffb(j).u * prj_w(j)
                            prj_v(j) = uvbuffb(j).v * prj_w(j)
                        next j
                    elseif ( rdr.rendmode = 1 ) then
                        for  j = 0 to polycnt-1
                            prj_u(j) = uvbuffb(j).u
                            prj_v(j) = uvbuffb(j).v
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
                    zl! = 0.0
                    for  j = 0 to polycnt-1
                        zl! = zl! + polyb(j).w
                    next j
                    zl! = zl! / polycnt

                    if  ( zl! >= 1400.0 ) then
                        miplevel = 3
                    elseif  ( zl! >= 560.0 ) then
                        miplevel = 2
                    elseif  ( zl! >= 280.0 ) then
                        miplevel = 1
                    else
                        miplevel = 0
                    end if

                    if ( rdr.usemips ) then
                        texIndx = mipidx*4+miplevel
                    else
                        texIndx = mipidx*4
                    end if
                        for j = 0 to polycnt-3
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

                            if ( rdr.rendmode = 2 ) then
                                uglTriF hDstDC, vtx(j), 200
                                uglLine hDstDC, vtx(j).v1.x, vtx(j).v1.y, vtx(j).v2.x, vtx(j).v2.y, 0
                                uglLine hDstDC, vtx(j).v2.x, vtx(j).v2.y, vtx(j).v3.x, vtx(j).v3.y, 0
                                uglLine hDstDC, vtx(j).v3.x, vtx(j).v3.y, vtx(j).v1.x, vtx(j).v1.y, 0
                            else
                                vtx(j).v1.u = prj_u(0)
                                vtx(j).v1.v = prj_v(0)
                                vtx(j).v2.u = prj_u(p2)
                                vtx(j).v2.v = prj_v(p2)
                                vtx(j).v3.u = prj_u(p3)
                                vtx(j).v3.v = prj_v(p3)

                                if ( rdr.rendmode = 0 ) then
                                    uglTriTP hDstDC, vtx(j), 0, h_textr_dc(texIndx)
                                else
                                    uglTriT hDstDC, vtx(j), 0, h_textr_dc(texIndx)
                                end if
                            end if

                            rdr.tris = rdr.tris + 1                                
                        next j
                        
                    end if
                end if
                
                rdr.polys = rdr.polys + 1
            end if
            
        next ti
    next mi        
end sub
