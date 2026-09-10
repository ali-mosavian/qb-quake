option explicit
''
'' r_bsp.bas -- BSP traversal and visibility.
''
'' Decompresses the PVS for the camera's leaf, walks the tree front to back
'' culling against the frustum, and records the draw order the rasteriser
'' follows. Quake splits it the same way: r_bsp.c decides what is seen, the
'' d_ side draws it.
''
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
'$include: 'qgl.bi'

''
'' This module's own procedures.
''
''
'' qgl's paged-array store. flname is NOT byval: VBDOS passes a plain
'' "as string" parameter as a near pointer to its descriptor, which is
'' what the assembly wants.
''
declare function qglArLoadBas ( _
    flname as string, _
    byval typ as integer, _
    byval elsz as integer, _
    byval cnt as long, _
    byval slot as integer _
) as long
declare function qglArMap ( _
    byval h as long, _
    a() as any, _
    byval idx as long _
) as long

declare sub mod_load_flat ( _
    flname as string, _
    byval dst as long _
)
declare function r_portal_mark ( _
    mtx as Mat4, _
    byval cam_leaf as integer, _
    byval visleafs as integer, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    idx() as integer, _
    ref() as integer, _
    pvsb() as integer, _
    outb() as integer _
) as integer
declare sub r_portal_draw ( _
    byval dc as long, _
    mtx as Mat4, _
    byval visleafs as integer, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval clr as integer, _
    idx() as integer, _
    ref() as integer, _
    seen() as integer _
)
declare sub r_mark_leaves ( _
    g as Game, _
    byval nodenr as integer, _
    campos as Vec3, _
    nodes() as Node, _
    planes() as Plane, _
    bit_array() as integer, _
    pvsb() as integer _
)
declare function r_cull_box ( _
    bbox as Bounds, _
    frustum() as DiskPlane _
) as integer
declare function r_node_side ( _
    byval node_idx as integer, _
    pt as Vec3, _
    nodes() as Node, _
    planes() as Plane _
)
declare function r_plane_dist ( _
    p as Vec3, _
    pl as Plane _
) as single

''
'' This module's own procedures.
''
declare function r_cam_plane_dist ( _
    pt as Vec3, _
    pl as Plane _
) as single
declare sub r_emit_entities ( _
    g as Game, _
    byval nodenr as integer, _
    byval model_count as long, _
    campos as Vec3, _
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
declare sub r_draw_world ( _
    g as Game, _
    byval model as integer, _
    campos as Vec3, _
    mtx_fin as Mat4, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane, _
    bit_array() as integer _
)
declare sub r_set_frustum ( _
    frustum() as DiskPlane, _
    mtx as Mat4 _
)
declare sub r_load_lfaces ( byval lump_bytes as long )
declare sub r_alloc_pvs ( byval leaf_count as long )
declare sub r_load_leaves ( _
    g as Game _
)
declare function r_leaf_contents ( byval leafnr as integer ) as integer
declare sub r_leaf_bound ( byval leafnr as integer, b as Bounds )

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare function sb_seg ( byval p as long ) as integer
declare function mod_pvs_base ( _
    g as Game _
) as long

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
dim shared lfc_buffer() as integer
dim shared pvs_buffer_b() as integer
'' Portals, rebuilt offline by tools/mkportals.py: pt_idx is one entry per
'' leaf plus one, so a leaf's refs are pt_idx(l)..pt_idx(l+1)-1 and the last
'' entry is the ref count; pt_ref is seven shorts a ref, the neighbouring
'' leaf and the portal's bsp-space box. pvs_now is what the walk reads:
'' the PVS narrowed to what the portals reach from where the eye is.
dim shared pt_idx() as integer
dim shared pt_ref() as integer
dim shared pvs_now() as integer

dim shared r_ignore_pvs as integer
'$dynamic
dim shared pvs_leaf as integer
dim shared dbg_camleaf as integer
dim shared dbg_pvscull as integer

''
'' The two walk routines call each other, so whichever comes second in the
'' file needs declaring first. Module-local, so this does not belong in
'' bspfile.bi with the cross-module declarations.
''
declare sub r_recursive_world_node ( _
    g as Game, _
    byval nodenr as integer, _
    byval model_count as long, _
    models() as Submodel, _
    brush() as BrushModel, _
    cpos as Vec3, _
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

'' sys.bas. Only caller in this module is r_draw_world, timing its own
'' two sub-phases -- narrowest place that can see it.
declare function sys_now ( ) as single



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
        if ( r_plane_dist( p, planes( nodes(nodenr).plane_id ) ) >= 0.0 ) then
            nodenr = nodes(nodenr).child0
        else
            nodenr = nodes(nodenr).child1
        end if
    loop

    r_point_leaf = not nodenr
end function

function r_cam_plane_dist ( _
    pt as Vec3, _
    pl as Plane _
) as single
    r_cam_plane_dist = pt.x*pl.norm.x + _
                   pt.y*pl.norm.z + _
                   pt.z*pl.norm.y - pl.dist
end function

'' Which side of a node's splitting plane a point falls on: -1 front, 0 behind.
function r_node_side ( _
    byval node_idx as integer, _
    pt as Vec3, _
    nodes() as Node, _
    planes() as Plane _
)
    if ( r_cam_plane_dist( pt, planes( nodes(node_idx).plane_id ) ) > 0.0 ) then
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
    g as Game, _
    byval nodenr as integer, _
    byval model_count as long, _
    campos as Vec3, _
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

    if ( ign or g.vis.bad_order or g.vis.no_ents ) then exit sub

    for  m = 1 to model_count-1
        if ( brush(m).draw and brush(m).node = nodenr ) then
            g.vis.ent_left = g.vis.ent_left - 1
            ign = true
            r_recursive_world_node g, int( models(m).head_node0 ), _
                              model_count, models(), brush(), _
                              campos, ign, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvsb(), pflag(), ord(), fru()
            ign = false
        end if
    next m

end sub



''
'' r_recursive_world_node now lives in src/r_walk.c, compiled with bcc and
'' linked in under this same name -- the declare above is the only trace
'' of it left in this module. See r_walk.c's own header for why: the
'' BASIC version recompiled into 405 instructions per the /A listing;
'' three separate C designs, on the same compiler and flags, all beat
'' that by roughly half, the best (a static near helper taking one
'' pre-unpacked context pointer) by more than that.
''
'' Kept as an EXTERNAL declare only -- see the git history for this file
'' (commit 198b883 and earlier) for the original BASIC recursive body,
'' if this ever needs to be reverted or compared against again.
''



'':::::::::
sub r_draw_world ( _
    g as Game, _
    byval model as integer, _
    campos as Vec3, _
    mtx_fin as Mat4, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane, _
    pflag() as integer, _
    ord() as integer, _
    fru() as DiskPlane, _
    bit_array() as integer _
)
    dim i as integer
    dim pt0 as single, ptd as single
    ''
    '' Reset tree state
    ''
    g.vis.ord_count = 0
    g.vis.cul_leafs = 0
    g.vis.drw_leafs = 0
    
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
    if ( g.vis.frame_stamp = 32767 ) then
        for  i = 0 to g.wld.count.faces-1
            pflag(i) = 0
        next i
        g.vis.frame_stamp = 0
    end if
    g.vis.frame_stamp = g.vis.frame_stamp + 1
    
    ''
    '' Extract pvs
    ''
    pt0 = sys_now()
    r_mark_leaves g, int(models(model).head_node0), campos, nodes(), planes(), bit_array(), _
                   pvs_buffer_b()
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.mark_sum = g.pt.mark_sum + ptd
        if ( ptd > g.pt.mark_max ) then g.pt.mark_max = ptd
    end if

    ''
    '' Narrow the PVS to what the portals reach from this eye. The PVS is a
    '' fact about the LEAF -- visible from anywhere in it, looking anywhere --
    '' so it cannot tell a doorway behind you from one in front. This can, and
    '' runs every frame because the answer moves when you turn.
    ''
    '' Writes pvs_now rather than pvs_buffer_b, which r_mark_leaves rebuilds
    '' only on a leaf change -- a bit cleared there stays cleared.
    ''
    g.vis.pt_culled = 0
    if ( g.rdr.portal ) then
        g.vis.pt_culled = r_portal_mark( mtx_fin, dbg_camleaf, _
                                          int( g.wld.count.leaves-1 ), _
                                          g.env.x_res / 2.0, g.env.y_res / 2.0, _
                                          g.env.z_near, pt_idx(), pt_ref(), _
                                          pvs_buffer_b(), pvs_now() )
    end if
    if ( g.vis.pt_culled < 0 or g.rdr.portal = 0 ) then
        for  i = 0 to g.wld.count.leaves-1
            pvs_now(i) = pvs_buffer_b(i)
        next i
    end if

    ''
    '' How many brush entities the walk still has to place. Once it is zero
    '' the per-node test below costs nothing.
    ''
    g.vis.ent_left = 0
    for  i = 1 to g.wld.count.models-1
        if ( brush(i).draw ) then g.vis.ent_left = g.vis.ent_left + 1
    next i

    ''
    '' Traverse tree
    ''
    pt0 = sys_now()
    r_recursive_world_node g, int( models(model).head_node0 ), _
                              g.wld.count.models, models(), brush(), campos, r_ignore_pvs, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvs_now(), pflag(), ord(), fru()
    if ( g.ft.n > 0 ) then
        ptd = sys_now() - pt0
        g.pt.walk_sum = g.pt.walk_sum + ptd
        if ( ptd > g.pt.walk_max ) then g.pt.walk_max = ptd
    end if

    ''
    '' -badorder reproduces what this used to do: every brush entity appended
    '' once the world is finished, so all of them draw in front of it. Kept
    '' so the fix can be shown rather than asserted.
    ''
    if ( g.vis.bad_order and g.vis.no_ents = false ) then
        for  i = 1 to g.wld.count.models-1
            if ( brush(i).draw ) then
                r_ignore_pvs = true
                r_recursive_world_node g, int( models(i).head_node0 ), _
                              g.wld.count.models, models(), brush(), campos, r_ignore_pvs, _
                              nodes(), planes(), lef_buffer(), lfc_buffer(), _
                              pvs_now(), pflag(), ord(), fru()
                r_ignore_pvs = false
            end if
        next i
    end if
    
end sub





'':::::::::
sub r_set_frustum ( _
    frustum() as DiskPlane, _
    mtx as Mat4 _
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
'' name: r_mdl_visible
'' desc: Whether a model at org can show at all: its box against the
''       frustum, then the leaves its box reaches against the PVS as the
''       portal flood left it. Conservative both ways -- the box is the
''       largest any frame at any yaw needs, and a leaf is tested at the
''       box's corners and centre, so a model straddling into a visible
''       leaf is drawn. Every rejection here is 170 vertices and 328
''       triangles mdl_draw does not transform in BASIC.
''::::::::::
function r_mdl_visible ( _
    org as Vec3, _
    byval radius as single, _
    byval zlo as single, _
    byval zhi as single, _
    nodes() as Node, _
    planes() as Plane, _
    frustum() as DiskPlane _
) as integer
    dim bb as Bounds
    dim p as Vec3
    dim i as integer, leaf as integer

    r_mdl_visible = 0
    bb.min.x = cint( org.x - radius ) : bb.max.x = cint( org.x + radius )
    bb.min.y = cint( org.y - radius ) : bb.max.y = cint( org.y + radius )
    bb.min.z = cint( org.z + zlo )    : bb.max.z = cint( org.z + zhi )
    if ( r_cull_box( bb, frustum() ) = 0 ) then exit function

    for i = 0 to 8
        if ( i = 8 ) then
            p = org
            p.z = org.z + (zlo + zhi) * 0.5
        else
            if ( i and 1 ) then p.x = bb.max.x else p.x = bb.min.x
            if ( i and 2 ) then p.y = bb.max.y else p.y = bb.min.y
            if ( i and 4 ) then p.z = bb.max.z else p.z = bb.min.z
        end if
        leaf = r_point_leaf( p, nodes(), planes() )
        if ( leaf > 0 ) then
            if ( pvs_now( leaf ) ) then r_mdl_visible = -1 : exit function
        end if
    next i
end function




''::::::::::
sub r_mark_leaves ( _
    g as Game, _
    byval nodenr as integer, _
    campos as Vec3, _
    nodes() as Node, _
    planes() as Plane, _
    bit_array() as integer, _
    pvsb() as integer _
)
    dim pvs_base as long
    dim mp as long
    dim v as long
    dim l as long
    dim j as long
    dim bit as long
    dim byte as integer
    dim i as integer

    pvs_base = mod_pvs_base ( g )
    
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
    dbg_camleaf = not nodenr
    if ( nodenr = pvs_leaf ) then exit sub
    pvs_leaf = nodenr
    
    '' 
    '' Setup
    ''    
    v = lef_buffer( not nodenr ).vis_list
    if ( v = -2 ) then sys_error "Leaf has no pvs data."
        
    '' memAlloc is paragraph-aligned, so the block's own offset is zero
    '' and v is the offset within it exactly as the lump stores it
    v = v + (pvs_base and 65535&)
    def seg = sb_seg( pvs_base )
    
    if ( lef_buffer( not nodenr ).vis_list = -1 ) then
        for  i = 0 to g.wld.count.leaves-1
            pvsb(i) = -1
        next i           

        exit sub
    end if
    
    '' 
    '' Extract the pvs data
    ''
    l = 1
    while ( l < g.wld.count.leaves )
        
        if ( peek( v ) = 0 ) then
            j = l
            l = l + 8& * peek( v+1 ) 
            if ( l > g.wld.count.leaves ) then l = g.wld.count.leaves
            
            for  j = j to l-1
                pvsb(j) = 0
            next j
            
            '' one here, one at the bottom of the loop: a zero run is
            '' marker plus count, and Mod_DecompressVis advances past
            '' both
            v = v + 1
        else
            byte = peek(v)
            
            for  bit = 0 to 7
                ''
                '' A run can carry past the last leaf; in real mode that
                '' writes over whatever follows the array.
                ''
                if ( l >= g.wld.count.leaves ) then exit for
                
                        
                if ( byte and bit_array(bit) ) then
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
sub r_load_lfaces ( byval lump_bytes as long )
    dim n as long

    n = lump_bytes \ len( lfc_buffer(0) )
    redim lfc_buffer( n-1 ) as integer

    mod_load_flat "assets.zip::lface.bld", _
        clng( varseg( lfc_buffer(0) ) ) * 65536& + (clng( varptr( lfc_buffer(0) ) ) and 65535&)
end sub

''::::::::::
'' name: r_alloc_pvs
'' desc: One visibility bit per leaf.
''
''       Sized to the map, not a fixed 4096: r_mark_leaves indexes this
''       0..lef_count-1, and a run can carry past the last leaf -- in real
''       mode that writes over whatever follows the array.
''::::::::::
sub r_alloc_pvs ( byval leaf_count as long )
    redim pvs_buffer_b( leaf_count-1 ) as integer
end sub

''::::::::::
'' name: r_load_portals
'' desc: The portal adjacency, out of assets.zip -- tools/mkportals.py.
''
''       The index is one short per leaf plus one, and that last entry is
''       the ref count, which is not in the bsp: loading the index first is
''       what sizes the refs.
''::::::::::
sub r_load_portals ( byval leaf_count as long )
    dim nrefs as long

    redim pvs_now( leaf_count-1 ) as integer
    redim pt_idx( leaf_count ) as integer
    mod_load_flat "assets.zip::portalidx.bld", _
        clng( varseg( pt_idx(0) ) ) * 65536& + (clng( varptr( pt_idx(0) ) ) and 65535&)

    nrefs = pt_idx( leaf_count )
    if ( nrefs <= 0 ) then exit sub

    redim pt_ref( nrefs*7 - 1 ) as integer
    mod_load_flat "assets.zip::portalref.bld", _
        clng( varseg( pt_ref(0) ) ) * 65536& + (clng( varptr( pt_ref(0) ) ) and 65535&)
end sub

''::::::::::
'' name: r_portal_outline
'' desc: Outline every portal the flood went through this frame. The
''       portal store and pvs_now are this module's, so the caller hands
''       in the destination and the arrays never leave.
''::::::::::
sub r_portal_outline ( _
    g as Game, _
    byval dc as long, _
    mtx_fin as Mat4 _
)
    r_portal_draw dc, mtx_fin, int( g.wld.count.leaves-1 ), _
                   g.env.x_res / 2.0, g.env.y_res / 2.0, g.env.z_near, _
                   251, pt_idx(), pt_ref(), pvs_now()
end sub

''::::::::::
'' name: r_load_leaves
'' desc: Builds the leaf store and binds it. The loader passes the count
''       and nothing else -- where the leaves live is this module's.
''::::::::::
sub r_load_leaves ( _
    g as Game _
)
    dim mapped as long

    redim lef_buffer(0) as Leaf

    '' MEM first: the far heap is the fragmented pool, and taking a 34K
    '' array out of it leaves a larger contiguous hole behind even when the
    '' total free does not change.
    ''
    g.wld.store.leaves = qglArLoadBas&( "assets.zip::leaves.pag", QGL_AR_MEM, len( lef_buffer(0) ), _
                                             clng( g.wld.count.leaves ), 0 )
    if ( g.wld.store.leaves = 0 ) then
        g.wld.store.leaves = qglArLoadBas&( "assets.zip::leaves.pag", QGL_AR_EMS, len( lef_buffer(0) ), _
                                                 clng( g.wld.count.leaves ), PAGE_SLOT )
    end if
    if ( g.wld.store.leaves = 0 ) then sys_error "0x0036, leaves.pag would not load"

    '' Hands the descriptor over. NOT ceremony: this is what takes it out
    '' of the far heap's chain, and only BASIC can do that correctly. Left
    '' in, B$FHCompact walks into a descriptor aimed at memory it does not
    '' own and moves it -- the far heap is then corrupt. The variable still
    '' exists afterwards, which is what qglArMap binds to.
    erase lef_buffer

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = qglArMap&( g.wld.store.leaves, lef_buffer(), 0 )
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

''::::::::::
'' name: r_leaf_bound
'' desc: One leaf's own bounding box. Same reasoning as r_leaf_contents:
''       a caller that wants one leaf's box (spreading spawns across the
''       map's own rooms, not the whole array) does not justify sharing
''       lef_buffer itself.
''::::::::::
sub r_leaf_bound ( byval leafnr as integer, b as Bounds )
    b = lef_buffer( leafnr ).bound
end sub

''::::::::::
'' name: rb_dbg_camleaf
'' desc: The leaf r_mark_leaves resolved the camera into. Temporary:
''       it checks the one assumption the PVS analysis rests on.
''::::::::::
function rb_dbg_camleaf ( ) as integer
    rb_dbg_camleaf = dbg_camleaf
end function
