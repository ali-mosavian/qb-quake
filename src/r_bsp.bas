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
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'

'$static
''
'' Set while a brush entity is being walked. Its leaves are not in the
'' world's visibility set -- the PVS answers questions about where the
'' camera can see from, and a door or a lift is not part of that -- so
'' the test is skipped and the frustum decides alone.
''
''
'' THE MARKSURFACE LIST AND THE PVS BITS. Owned here: this module is the
'' only code that reads either at run time. They sat in COMMON because
'' model.bas allocated and BLOADed them, which is a load-time write, not
'' a share -- so the loader hands over the sizes and r_bsp does the rest.
''
dim shared lef_buffer() as Leaf
dim shared h_lef as long
dim shared lfc_buffer() as integer
dim shared pvs_buffer_b() as integer

dim shared r_ignore_pvs as integer
'$dynamic
dim shared pvs_leaf as integer

''
'' The two walk routines call each other, so whichever comes second in the
'' file needs declaring first. Module-local, so this does not belong in
'' bspfile.bi with the cross-module declarations.
''
declare sub r_recursive_world_node ( _
    byval nodenr as integer, _
    byval nmodels as long, _
    models() as Submodel, _
    brush() as BrushModel, _
    cpos as u3dVector3f, _
    vs as VisState, _
    byval ign as integer, _
    nds() as Node, _
    pln() as Plane, _
    lef() as Leaf, _
    lfc() as integer, _
    pvsb() as integer, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane _
)



''::::::::::::
'' ==========================================================================
''  BSP WALK
'' ==========================================================================
'' Takes a RENDERER point: Y-up there, Z-up in the BSP, so y pairs with norm.z.
'' Single, not double: returning double moved two edge-on faces onto the
'' other side of their plane.
function r_plane_dist ( _
    p as Vec3, _
    pl as Plane _
) as single
    r_plane_dist = p.x*pl.norm.x + _
                   p.y*pl.norm.y + _
                   p.z*pl.norm.z - pl.dist
end function

'' The leaf holding p, walking hull 0. Bit 15 marks a leaf; NOT is its index.
function r_point_leaf ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
    dim nodenr as integer

    nodenr = 0
    do while ( (nodenr and &h8000) = 0 )
        if ( r_plane_dist( p, planes( nodes(nodenr).planeid ) ) >= 0.0 ) then
            nodenr = nodes(nodenr).child0
        else
            nodenr = nodes(nodenr).child1
        end if
    loop

    r_point_leaf = not nodenr
end function

function r_cam_plane_dist ( _
    pt as u3dVector3f, _
    pl as Plane _
) as single
    r_cam_plane_dist = pt.x*pl.norm.x + _
                   pt.y*pl.norm.z + _
                   pt.z*pl.norm.y - pl.dist
end function

'' Which side of a node's splitting plane a point falls on: -1 front, 0 behind.
function r_node_side ( _
    byval node_idx as integer, _
    pt as u3dVector3f, _
    nodes() as Node, _
    planes() as Plane _
)
    if ( r_cam_plane_dist( pt, planes( nodes(node_idx).planeid ) ) > 0.0 ) then
        r_node_side = -1
        exit function
    end if
    r_node_side = 0
end function




''::::::::::
'' name: r_emit_entities
'' desc: Draws every brush entity whose place in the order is this node.
''
''       Called from the walk at the one moment everything further away has
''       been emitted and nothing nearer has, which is the whole of what
''       makes a painter's algorithm work. ent_find_node picks the node.
''
''       Its own SUB rather than inline because r_recursive_world_node is
''       STATIC: its locals are shared with its own recursion, and a loop
''       counter read across the nested call below would not survive one.
''       A separate SUB gets a frame of its own. r_ignore_pvs still has to
''       stop the nested walk re-entering here, which would not terminate.
''::::::::::
sub r_emit_entities ( _
    byval nodenr as integer, _
    byval nmodels as long, _
    campos as u3dVector3f, _
    vis as VisState, _
    ign as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane, _
    pvsb() as integer, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane _
)
    dim m as integer

    if ( ign or vis.bad_order or vis.no_ents ) then exit sub

    for  m = 1 to nmodels-1
        if ( brush(m).draw and brush(m).node = nodenr ) then
            vis.ent_left = vis.ent_left - 1
            ign = true
            r_recursive_world_node int( models(m).headnode0 ), _
                              nmodels, models(), brush(), _
                              campos, vis, ign, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvsb(), pflag(), ord(), fru()
            ign = false
        end if
    next m

end sub



sub r_recursive_world_node ( _
    byval nodenr as integer, _
    byval nmodels as long, _
    models() as Submodel, _
    brush() as BrushModel, _
    cpos as u3dVector3f, _
    vs as VisState, _
    byval ign as integer, _
    nds() as Node, _
    pln() as Plane, _
    lef() as Leaf, _
    lfc() as integer, _
    pvsb() as integer, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane _
) static
    dim dp as single
    dim frst as integer, last as integer, i as integer
    dim pid as integer, side as integer
    dim mp as long

    
    ''
    '' If bit 15 is set we are at the end of the branch. We
	'' draw the leaf and go back.
	''
	
	if ( nodenr and &h8000 ) then
	    '' leaf: `not nodenr` is its index. One map covers bound,
	    '' lfaceid and lfacenum -- the store pads pages, so a record
	    '' never straddles one.
	    
	    ''
	    '' Check pvs and bounding volume
	    ''
	    if ( (ign or pvsb(not nodenr)) and _
	         r_cull_box( lef(not nodenr).bound, fru() ) ) then
	    
	        frst = lef(not nodenr).lfaceid
	        last = frst+lef(not nodenr).lfacenum
	        
	        for  i = frst to last-1	            
	            pflag(lfc(i)) = vs.frame_stamp
	        next i
	        
	        
    	    ''
    	    '' Put leaf in ordering list
    	    ''
    	    ''
    	    '' A brush entity small enough to fit inside one leaf is drawn
    	    '' on arrival at that leaf. Anything larger straddles a plane
    	    '' and is emitted at a node instead, further down.
    	    ''
    	    if ( vs.ent_left ) then r_emit_entities nodenr, nmodels, cpos, vs, ign, _
                                        models(), brush(), nds(), pln(), _
                                        pvsb(), pflag(), ord(), fru()

    	    vs.drw_leafs = vs.drw_leafs + 1
        else 
            vs.cul_leafs = vs.cul_leafs + 1
        end if
        
	    exit sub
    end if    
    

    '' .bound goes in BY REFERENCE, so r_cull_box reads it straight out of
    '' the EMS window. That holds only because r_cull_box maps nothing.
    if ( not r_cull_box( nds(nodenr).bound, fru() ) ) then
        exit sub
    end if
    
    if ( r_cam_plane_dist( cpos, pln( nds(nodenr).planeid ) ) >= 0.0 ) then
        side = 1
    else
        side = 0
    end if
    
    if ( side ) then
    	''
    	'' We are at the front side of a node. First walk the
    	'' back nodes, then the front nodes.
    	''
    		
        '' No map here: the one at the top of the sub still holds -- the
        '' cull and the plane maths between them do not touch the slot.
        r_recursive_world_node nds(nodenr).child1, nmodels, models(), brush(), cpos, vs, ign, nds(), pln(), lef(), lfc(), pvsb(), pflag(), ord(), fru()
        if ( vs.ent_left ) then r_emit_entities nodenr, nmodels, cpos, vs, ign, _
                                        models(), brush(), nds(), pln(), _
                                        pvsb(), pflag(), ord(), fru()
	    ord(vs.ord_count) = nodenr
	    vs.ord_count = vs.ord_count + 1
        r_recursive_world_node nds(nodenr).child0, nmodels, models(), brush(), cpos, vs, ign, nds(), pln(), lef(), lfc(), pvsb(), pflag(), ord(), fru()
        
    else
        ''
	    '' We are at the back side of a node. First walk the
	    '' front nodes, then the back nodes.
	    ''
    		
        '' likewise: still covered by the map at the top of the sub
        r_recursive_world_node nds(nodenr).child0, nmodels, models(), brush(), cpos, vs, ign, nds(), pln(), lef(), lfc(), pvsb(), pflag(), ord(), fru()        
        if ( vs.ent_left ) then r_emit_entities nodenr, nmodels, cpos, vs, ign, _
                                        models(), brush(), nds(), pln(), _
                                        pvsb(), pflag(), ord(), fru()
	    ord(vs.ord_count) = nodenr
	    vs.ord_count = vs.ord_count + 1        
        r_recursive_world_node nds(nodenr).child1, nmodels, models(), brush(), cpos, vs, ign, nds(), pln(), lef(), lfc(), pvsb(), pflag(), ord(), fru()
    end if
    

end sub



'':::::::::
sub r_draw_world ( _
    byval model as integer, _
    byval nmodels as long, _
    byval nleafs as long, _
    byval nfaces as long, _
    campos as u3dVector3f, _
    vis as VisState, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane, _
    bitarray() as integer _
)
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
        for  i = 0 to nfaces-1
            pflag(i) = 0
        next i
        vis.frame_stamp = 0
    end if
    vis.frame_stamp = vis.frame_stamp + 1
    
    ''
    '' Extract pvs
    ''
    r_mark_leaves int(models(model).headnode0), nleafs, campos, _
                  nodes(), planes(), bitarray(), pvs_buffer_b()
    
    ''
    '' How many brush entities the walk still has to place. Once it is zero
    '' the per-node test below costs nothing.
    ''
    vis.ent_left = 0
    for  i = 1 to nmodels-1
        if ( brush(i).draw ) then vis.ent_left = vis.ent_left + 1
    next i

    ''
    '' Traverse tree
    ''
    r_recursive_world_node int( models(model).headnode0 ), _
                              nmodels, models(), brush(), campos, vis, r_ignore_pvs, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvs_buffer_b(), pflag(), ord(), fru()

    ''
    '' -badorder reproduces what this used to do: every brush entity appended
    '' once the world is finished, so all of them draw in front of it. Kept
    '' so the fix can be shown rather than asserted.
    ''
    if ( vis.bad_order and vis.no_ents = false ) then
        for  i = 1 to nmodels-1
            if ( brush(i).draw ) then
                r_ignore_pvs = true
                r_recursive_world_node int( models(i).headnode0 ), _
                              nmodels, models(), brush(), campos, vis, r_ignore_pvs, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvs_buffer_b(), pflag(), ord(), fru()
                r_ignore_pvs = false
            end if
        next i
    end if
    
end sub





'':::::::::
sub r_set_frustum ( _
    frustum() as DiskPlane, _
    mtx as u3dMtrx _
)
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
function r_cull_box ( _
    bbox as Bounds, _
    frustum() as DiskPlane _
) as integer
    dim dp as single
    dim near_point as DiskVertex
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
sub r_mark_leaves ( _
    byval nodenr as integer, _
    byval nleafs as long, _
    campos as u3dVector3f, _
    nodes() as Node, _
    planes() as Plane, _
    bitarray() as integer, _
    pvsb() as integer _
)
    dim mp as long
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
        '' r_node_side maps nodenr itself and nothing since has
        '' remapped, so the children are readable without a second call
        if ( r_node_side( nodenr, campos, nodes(), planes() ) ) then
            nodenr = nodes(nodenr).child0
        else
            nodenr = nodes(nodenr).child1
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
        
    '' memAlloc is paragraph-aligned, so the block's own offset is zero
    '' and v is the offset within it exactly as the lump stores it
    v = v + (mod_pvs_base and 65535&)
    def seg = sb_seg( mod_pvs_base )
    
    if ( lef_buffer( not nodenr ).vislist = -1 ) then
        for  i = 0 to nleafs-1
            pvsb(i) = -1
        next i           

        exit sub
    end if
    
    '' 
    '' Extract the pvs data
    ''
    l = 1
    while ( l < nleafs )
        
        if ( peek( v ) = 0 ) then
            j = l
            l = l + 8& * peek( v+1 ) 
            if ( l > nleafs ) then l = nleafs
            
            for  j = j to l-1
                pvsb(j) = 0
            next j
            
            v = v + 1
        else
            byte = peek(v)
            
            for  bit = 0 to 7
                ''
                '' A run can carry past the last leaf; in real mode that
                '' writes over whatever follows the array.
                ''
                if ( l >= nleafs ) then exit for
                
                        
                if ( byte and bitarray(bit) ) then
                    pvsb(l) = 1
                else                 
                    pvsb(l) = 0
                end if
                
                l = l + 1
            next bit            
        end if            
            
        v = v + 1        
    wend


end sub 



''::::::::::
'' name: r_load_lfaces
'' desc: Sizes and loads the marksurface list from its lump byte count.
''       The elements are plain integers, so the count is the lump over
''       len() of one -- taken here, where the array actually lives.
''::::::::::
sub r_load_lfaces ( byval lumpbytes as long )
    dim n as long

    n = lumpbytes \ len( lfc_buffer(0) )
    redim lfc_buffer( n-1 ) as integer

    def seg = varseg( lfc_buffer(0) )
    bload "lface.bld", varptr( lfc_buffer(0) )
    def seg
end sub

''::::::::::
'' name: r_alloc_pvs
'' desc: One visibility bit per leaf.
''
''       Sized to the map, not a fixed 4096: r_mark_leaves indexes this
''       0..lef_count-1, and a run can carry past the last leaf -- in real
''       mode that writes over whatever follows the array.
''::::::::::
sub r_alloc_pvs ( byval nleafs as long )
    redim pvs_buffer_b( nleafs-1 ) as integer
end sub

''::::::::::
'' name: r_load_leaves
'' desc: Builds the leaf store and binds it. The loader passes the count
''       and nothing else -- where the leaves live is this module's.
''::::::::::
sub r_load_leaves ( byval cnt as long )
    dim f as FILE
    dim mapped as long

    redim lef_buffer(0) as Leaf

    '' MEM first: the far heap is the fragmented pool, and taking a 34K
    '' array out of it leaves a larger contiguous hole behind even when the
    '' total free does not change.
    ''
    h_lef = uglArrNew&( UGL.MEM, len( lef_buffer(0) ), cnt, 0 )
    if ( h_lef = 0 ) then
        h_lef = uglArrNew&( UGL.EMS, len( lef_buffer(0) ), cnt, PAGE_SLOT )
    end if
    if ( h_lef = 0 ) then sys_error "0x0036, no room for the leaves"

    '' Hands the descriptor over. NOT ceremony: this is what takes it out
    '' of the far heap's chain, and only BASIC can do that correctly. Left
    '' in, B$FHCompact walks into a descriptor aimed at memory it does not
    '' own and moves it -- the far heap is then corrupt. The variable still
    '' exists afterwards, which is what uglArrMap binds to.
    erase lef_buffer

    if ( fileOpen%( f, "leaves.pag", F4READ ) = 0 ) then
        sys_error "0x0037, leaves.pag missing"
    end if
    if ( uglArrLoad%( f, h_lef ) = 0 ) then
        fileClose f
        sys_error "0x0038, leaves.pag short or unreadable"
    end if
    fileClose f

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = uglArrMap&( h_lef, lef_buffer(), 0 )
end sub

''::::::::::
'' name: r_leaf_contents
'' desc: The contents field of one leaf. pl_move's point test walks the
''       node tree itself and needs exactly this at the end of it, which
''       is not reason enough for the whole array to be shared.
''::::::::::
function r_leaf_contents ( byval leafnr as integer ) as integer
    r_leaf_contents = lef_buffer( leafnr ).cont
end function
