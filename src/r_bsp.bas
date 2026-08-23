option explicit
''
'' r_bsp.bas -- BSP traversal and visibility.
''
'' Decompresses the PVS for the camera's leaf, walks the tree front to back
'' culling against the frustum, and records the draw order the rasteriser
'' follows. Quake splits it the same way: r_bsp.c decides what is seen, the
'' d_ side draws it.
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
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_cam.bi'
'$include: 'q_ent.bi'

'$static
''
'' Set while a brush entity is being walked. Its leaves are not in the
'' world's visibility set -- the PVS answers questions about where the
'' camera can see from, and a door or a lift is not part of that -- so
'' the test is skipped and the frustum decides alone.
''
dim shared r_ignore_pvs as integer
'$dynamic
dim shared pvs_leaf as integer



''::::::::::::
'' ==========================================================================
''  BSP WALK
'' ==========================================================================
function r_classify_point ( nodenr as integer ) as integer
    dim dp as single
  
    dp = cam.pos.x*pln_buffer(nds_buffer(nodenr).planeid).norm.x + _
          cam.pos.y*pln_buffer(nds_buffer(nodenr).planeid).norm.z + _
          cam.pos.z*pln_buffer(nds_buffer(nodenr).planeid).norm.y
          
    if ( (dp-pln_buffer(nds_buffer(nodenr).planeid).dist) > 0.0 ) then
        r_classify_point = -1
    else
        r_classify_point = 0
    end if
    
end function




sub r_recursive_world_node ( byval nodenr as integer ) static
    dim dp as single
    dim frst as integer, last as integer, i as integer
    dim pid as integer, side as integer
    dim ebm as integer

    
    ''
    '' If bit 15 is set we are at the end of the branch. We
	'' draw the leaf and go back.
	''
	
	if ( nodenr and &h8000 ) then
	    
	    ''
	    '' Check pvs and bounding volume
	    ''
	    if ( (r_ignore_pvs or pvs_buffer_b(not nodenr)) and _
	         r_cull_box( lef_buffer(not nodenr).bound, frustum() ) ) then
	    
	        frst = lef_buffer(not nodenr).lfaceid
	        last = frst+lef_buffer(not nodenr).lfacenum
	        
	        for  i = frst to last-1	            
	            poly_flag(lfc_buffer(i)) = vis.frame_stamp
	        next i
	        
	        
    	    ''
    	    '' Put leaf in ordering list
    	    ''
    	    ''
    	    '' Any brush entity sitting in this leaf is drawn now, while the
    	    '' walk is here. Appending it after the world instead puts it in
    	    '' front of everything -- there is no depth buffer, and back to
    	    '' front order is the only thing making any of this correct.
    	    ''
    	    '' This SUB is declared STATIC, so its locals are shared with every
    	    '' call including its own recursion. The existing code survives
    	    '' that by never reading a local across a recursive call. ebm is
    	    '' read across one, so it is protected differently: r_ignore_pvs
    	    '' is set before the nested call and the loop below is skipped
    	    '' when it is set, so the nested walk cannot reach this loop and
    	    '' cannot touch ebm.
    	    ''
    	    if ( r_ignore_pvs = false and vis.bad_order = false ) then
    	        for  ebm = 1 to wld.mdl_count-1
    	            if ( mdl_draw(ebm) and mdl_done(ebm) = false ) then
    	                if ( ent_hits_leaf( ebm, not nodenr ) ) then
    	                    mdl_done(ebm) = true
    	                    r_ignore_pvs  = true
    	                    r_recursive_world_node int( mdl_buffer(ebm).headnode0 )
    	                    r_ignore_pvs  = false
    	                end if
    	            end if
    	        next ebm
    	    end if

    	    vis.drw_leafs = vis.drw_leafs + 1
        else 
            vis.cul_leafs = vis.cul_leafs + 1
        end if
        
	    exit sub
    end if    
    
    if ( not r_cull_box( nds_buffer(nodenr).bound, frustum() ) ) then
        exit sub
    end if
    
    pid = nds_buffer(nodenr).planeid
    dp  = cam.pos.x*pln_buffer(pid).norm.x + _
          cam.pos.y*pln_buffer(pid).norm.z + _
          cam.pos.z*pln_buffer(pid).norm.y
          
    if ( dp-pln_buffer(pid).dist >= 0.0 ) then
        side = 1
    else
        side = 0
    end if
    
    if ( side ) then
    	''
    	'' We are at the front side of a node. First walk the
    	'' back nodes, then the front nodes.
    	''
    		
        r_recursive_world_node nds_buffer(nodenr).child1
	    order_list(vis.ord_count) = nodenr
	    vis.ord_count = vis.ord_count + 1
        r_recursive_world_node nds_buffer(nodenr).child0
        
    else
        ''
	    '' We are at the back side of a node. First walk the
	    '' front nodes, then the back nodes.
	    ''
    		
        r_recursive_world_node nds_buffer(nodenr).child0        
	    order_list(vis.ord_count) = nodenr
	    vis.ord_count = vis.ord_count + 1        
        r_recursive_world_node nds_buffer(nodenr).child1
    end if
    

end sub



'':::::::::
sub r_draw_world ( model as integer )
    dim i as integer
    ''
    '' Reset tree state
    ''
    vis.ord_count = 0
    vis.cul_leafs = 0
    vis.drw_leafs = 0
    
    ''
    '' Advance the frame stamp instead of clearing every face flag.
    ''
    '' The clear walked all triCount faces every frame -- 1,600 on e1m7,
    '' 5,500 on the episode maps -- to reset flags that only the few hundred
    '' faces of the visible leaves ever set. Comparing against the stamp is
    '' the same test where it is used, and the pass runs once per 32,767
    '' frames instead. The wrap is checked BEFORE the increment because
    '' QuickBASIC traps integer overflow at run time rather than wrapping.
    ''
    if ( vis.frame_stamp = 32767 ) then
        for  i = 0 to wld.tri_count-1
            poly_flag(i) = 0
        next i
        vis.frame_stamp = 0
    end if
    vis.frame_stamp = vis.frame_stamp + 1
    
    ''
    '' Extract pvs
    ''
    r_mark_leaves int(mdl_buffer(model).headnode0)
    
    ''
    '' Traverse tree
    ''
    r_recursive_world_node int(mdl_buffer(model).headnode0)

    ''
    '' -badorder reproduces what this used to do: every brush entity appended
    '' once the world is finished, so all of them draw in front of it. Kept
    '' so the fix can be shown rather than asserted.
    ''
    if ( vis.bad_order ) then
        for  i = 1 to wld.mdl_count-1
            if ( mdl_draw(i) ) then
                r_ignore_pvs = true
                r_recursive_world_node int( mdl_buffer(i).headnode0 )
                r_ignore_pvs = false
            end if
        next i
    end if
    
end sub





'':::::::::
sub r_set_frustum ( frustum() as plane, mtx as u3dMtrx )
    dim i as integer
    dim d as single

    ''
    '' Left clipping plane    
    ''
    frustum(0).norm.x = -(mtx.m14 + mtx.m11)
    frustum(0).norm.y = -(mtx.m24 + mtx.m21)
    frustum(0).norm.z = -(mtx.m34 + mtx.m31)
    frustum(0).dist   = -(mtx.m44 + mtx.m41)
    
    ''
    '' Right clipping plane    
    ''
    frustum(1).norm.x = -(mtx.m14 - mtx.m11)
    frustum(1).norm.y = -(mtx.m24 - mtx.m21)
    frustum(1).norm.z = -(mtx.m34 - mtx.m31)
    frustum(1).dist   = -(mtx.m44 - mtx.m41)
    
    ''
    '' Top clipping plane    
    ''
    frustum(2).norm.x = -(mtx.m14 - mtx.m12)
    frustum(2).norm.y = -(mtx.m24 - mtx.m22)
    frustum(2).norm.z = -(mtx.m34 - mtx.m32)
    frustum(2).dist   = -(mtx.m44 - mtx.m42)
    
    ''
    '' Bottom clipping plane    
    ''
    frustum(3).norm.x = -(mtx.m14 + mtx.m12)
    frustum(3).norm.y = -(mtx.m24 + mtx.m22)
    frustum(3).norm.z = -(mtx.m34 + mtx.m32)
    frustum(3).dist   = -(mtx.m44 + mtx.m42)
    
   
    ''
    '' Near clipping plane    
    ''
    frustum(4).norm.x = -(mtx.m14 + mtx.m13)
    frustum(4).norm.y = -(mtx.m24 + mtx.m23)
    frustum(4).norm.z = -(mtx.m34 + mtx.m33)
    frustum(4).dist   = -(mtx.m44 + mtx.m43)
    
    ''
    '' Far clipping plane    
    ''
    frustum(5).norm.x = -(mtx.m14 - mtx.m13)
    frustum(5).norm.y = -(mtx.m24 - mtx.m23)
    frustum(5).norm.z = -(mtx.m34 - mtx.m33)
    frustum(5).dist   = -(mtx.m44 - mtx.m43)
       
    
    ''
    '' Normalize
    ''
    for  i = 0 to 5
        d = 1.0 / sqr( frustum(i).norm.x*frustum(i).norm.x + _
                       frustum(i).norm.y*frustum(i).norm.y + _
                       frustum(i).norm.z*frustum(i).norm.z )
                  
        frustum(i).norm.x = frustum(i).norm.x * d
        frustum(i).norm.y = frustum(i).norm.y * d
        frustum(i).norm.z = frustum(i).norm.z * d
        frustum(i).dist   = frustum(i).dist   * d        
    next i

end sub




'':::::::::
function r_cull_box ( bbox as bboundbox, frustum() as plane ) as integer
    dim dp as single
    dim near_point as vertex
    dim i as integer


    for  i = 0 to 5
        if ( frustum(i).norm.x > 0.0 ) then
            if ( frustum(i).norm.y > 0.0 ) then
                if ( frustum(i).norm.z > 0.0 ) then
                    near_point.x = bbox.min.x
                    near_point.y = bbox.min.z
                    near_point.z = bbox.min.y
                else
                    near_point.x = bbox.min.x
                    near_point.y = bbox.min.z
                    near_point.z = bbox.max.y
                end if
            else
                if ( frustum(i).norm.z > 0.0 ) then
                    near_point.x = bbox.min.x
                    near_point.y = bbox.max.z
                    near_point.z = bbox.min.y
                else
                    near_point.x = bbox.min.x
                    near_point.y = bbox.max.z
                    near_point.z = bbox.max.y
                end if
            end if
        else
            if ( frustum(i).norm.y > 0.0 ) then
                if ( frustum(i).norm.z > 0.0 ) then
                    near_point.x = bbox.max.x
                    near_point.y = bbox.min.z
                    near_point.z = bbox.min.y
                else
                    near_point.x = bbox.max.x
                    near_point.y = bbox.min.z
                    near_point.z = bbox.max.y
                end if
            else
                if ( frustum(i).norm.z > 0.0 ) then
                    near_point.x = bbox.max.x
                    near_point.y = bbox.max.z
                    near_point.z = bbox.min.y
                else
                    near_point.x = bbox.max.x
                    near_point.y = bbox.max.z
                    near_point.z = bbox.max.y
                end if
            end if
        end if            
            
        dp = frustum(i).norm.x*near_point.x + frustum(i).norm.y*near_point.y + _
             frustum(i).norm.z*near_point.z
             
        if ( (dp+frustum(i).dist) > 0 ) then
            r_cull_box = 0
            exit function
        end if
    next i    
    
    r_cull_box = -1
end function




''::::::::::
sub r_mark_leaves ( byval nodenr as integer )
    dim v as long
    dim l as long
    dim j as long
    dim bit as long
    dim byte as integer
    dim i as integer
    
    ''
    '' Find the node that the camera is in
    ''
    while not ( nodenr and &h8000 )
        if ( r_classify_point( nodenr ) ) then
            nodenr = nds_buffer(nodenr).child0
        else
            nodenr = nds_buffer(nodenr).child1
        end if            
    wend

    ''
    '' The visible set only changes when the camera changes leaf, and the
    '' camera spends most frames in one. Unpacking the same run-length data
    '' every frame -- and writing one entry per leaf in the map while doing
    '' it -- was the largest fixed cost in the walk.
    ''
    if ( nodenr = pvs_leaf ) then exit sub
    pvs_leaf = nodenr
    
    '' 
    '' Setup
    ''    
    v = lef_buffer( not nodenr ).vislist
    if ( v = -2 ) then sys_error "Leaf has no pvs data."
        
    v = v + varptr( pvs_buffer_a(0) )
    def seg = varseg( pvs_buffer_a(0) )
    
    if ( lef_buffer( not nodenr ).vislist = -1 ) then
        for  i = 0 to wld.lef_count-1
            pvs_buffer_b(i) = -1
        next i           

        exit sub
    end if
    
    '' 
    '' Extract the pvs data
    ''
    l = 1
    while ( l < wld.lef_count )
        
        if ( peek( v ) = 0 ) then
            j = l
            l = l + 8& * peek( v+1 ) 
            if ( l > wld.lef_count ) then l = wld.lef_count
            
            for  j = j to l-1
                pvs_buffer_b(j) = 0
            next j
            
            v = v + 1
        else
            byte = peek(v)
            
            for  bit = 0 to 7
                ''
                '' A run can carry past the last leaf; in real mode that
                '' writes over whatever follows the array.
                ''
                if ( l >= wld.lef_count ) then exit for
                
                        
                if ( byte and bitarray(bit) ) then
                    pvs_buffer_b(l) = 1
                else                 
                    pvs_buffer_b(l) = 0
                end if
                
                l = l + 1
            next bit            
        end if            
            
        v = v + 1        
    wend


end sub 



''::::::::::
'' name: r_draw_brush_model
'' desc: Adds a brush entity's faces to the frame, after r_draw_world has
''       done the world. Deliberately does not reset ord_count or the frame
''       stamp: it is adding to the draw order, not starting a new one.
''::::::::::
sub r_draw_brush_model ( byval m as integer )

    r_ignore_pvs = true
    r_recursive_world_node int( mdl_buffer(m).headnode0 )
    r_ignore_pvs = false

end sub
