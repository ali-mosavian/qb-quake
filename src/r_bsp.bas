option explicit
''
'' r_bsp.bas -- BSP traversal and visibility.
''
'' Decompresses the PVS for the camera's leaf, walks the tree front to back
'' culling against the frustum, and records the draw order the rasteriser
'' follows. Quake splits it the same way: r_bsp.c decides what is seen, the
'' d_ side draws it.
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

'$dynamic
dim shared culLeafs as integer
dim shared drwLeafs as integer
dim shared pvsLeaf as integer



''::::::::::::
'' ==========================================================================
''  BSP WALK
'' ==========================================================================
defint a-z
function bspClasifypoint% ( nodenr as integer )
    dim dp as single
  
    dp! = cam.pos.x*plnBuffer(ndsBuffer(nodenr).planeid).norm.x + _
          cam.pos.y*plnBuffer(ndsBuffer(nodenr).planeid).norm.z + _
          cam.pos.z*plnBuffer(ndsBuffer(nodenr).planeid).norm.y
          
    if ( (dp!-plnBuffer(ndsBuffer(nodenr).planeid).dist) > 0.0 ) then
        bspClasifypoint% = -1
    else
        bspClasifypoint% = 0
    end if
    
end function




defint a-z
sub bspWalkNodeB ( byval nodenr as integer ) static
    dim dp as single
    dim frst as integer, last as integer, i as integer
    dim pid as integer, side as integer

    
    ''
    '' If bit 15 is set we are at the end of the branch. We
	'' draw the leaf and go back.
	''
	
	if ( nodenr and &h8000 ) then
	    
	    ''
	    '' Check pvs and bounding volume
	    ''
	    if ( pvsBufferB(not nodenr) and _
	         BBoxInFrustum( lefBuffer(not nodenr).bound, frustum() ) ) then
	    
	        frst = lefBuffer(not nodenr).lfaceid
	        last = frst+lefBuffer(not nodenr).lfacenum
	        
	        for  i = frst to last-1	            
	            polyFlag(lfcBuffer(i)) = vis.frameStamp
	        next i
	        
	        
    	    ''
    	    '' Put leaf in ordering list
    	    ''
    	    drwLeafs = drwLeafs + 1
        else 
            culLeafs = culLeafs + 1
        end if
        
	    exit sub
    end if    
    
    if ( not BBoxInFrustum( ndsBuffer(nodenr).bound, frustum() ) ) then
        exit sub
    end if
    
    pid = ndsBuffer(nodenr).planeid
    dp  = cam.pos.x*plnBuffer(pid).norm.x + _
          cam.pos.y*plnBuffer(pid).norm.z + _
          cam.pos.z*plnBuffer(pid).norm.y
          
    if ( dp-plnBuffer(pid).dist >= 0.0 ) then
        side = 1
    else
        side = 0
    end if
    
    if ( side ) then
    	''
    	'' We are at the front side of a node. First walk the
    	'' back nodes, then the front nodes.
    	''
    		
        bspWalkNodeB ndsBuffer(nodenr).child1
	    orderList(vis.ordCount) = nodenr
	    vis.ordCount = vis.ordCount + 1
        bspWalkNodeB ndsBuffer(nodenr).child0
        
    else
        ''
	    '' We are at the back side of a node. First walk the
	    '' front nodes, then the back nodes.
	    ''
    		
        bspWalkNodeB ndsBuffer(nodenr).child0        
	    orderList(vis.ordCount) = nodenr
	    vis.ordCount = vis.ordCount + 1        
        bspWalkNodeB ndsBuffer(nodenr).child1
    end if
    

end sub



'':::::::::
defint a-z
sub bspShowModel ( model as integer )
    dim i as integer
    ''
    '' Reset tree state
    ''
    vis.ordCount = 0
    culLeafs = 0
    drwLeafs = 0
    
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
    if ( vis.frameStamp = 32767 ) then
        for  i = 0 to wld.triCount-1
            polyFlag(i) = 0
        next i
        vis.frameStamp = 0
    end if
    vis.frameStamp = vis.frameStamp + 1
    
    ''
    '' Extract pvs
    ''
    pvsInit int(mdlBuffer(model).headnode0)
    
    ''
    '' Traverse tree
    ''
    bspWalkNodeB int(mdlBuffer(model).headnode0)
    
end sub





'':::::::::
defint a-z
sub ExtractFrustum ( frustum() as plane, mtx as u3dMtrx )
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
defint a-z
function BBoxInFrustum% ( bbox as bboundbox, frustum() as plane )
    dim dp as single
    dim nearPoint as vertex
    dim i as integer


    for  i = 0 to 5
        if ( frustum(i).norm.x > 0.0 ) then
            if ( frustum(i).norm.y > 0.0 ) then
                if ( frustum(i).norm.z > 0.0 ) then
                    NearPoint.x = bbox.min.x
                    NearPoint.y = bbox.min.z
                    NearPoint.z = bbox.min.y
                else
                    NearPoint.x = bbox.min.x
                    NearPoint.y = bbox.min.z
                    NearPoint.z = bbox.max.y
                end if
            else
                if ( frustum(i).norm.z > 0.0 ) then
                    NearPoint.x = bbox.min.x
                    NearPoint.y = bbox.max.z
                    NearPoint.z = bbox.min.y
                else
                    NearPoint.x = bbox.min.x
                    NearPoint.y = bbox.max.z
                    NearPoint.z = bbox.max.y
                end if
            end if
        else
            if ( frustum(i).norm.y > 0.0 ) then
                if ( frustum(i).norm.z > 0.0 ) then
                    NearPoint.x = bbox.max.x
                    NearPoint.y = bbox.min.z
                    NearPoint.z = bbox.min.y
                else
                    NearPoint.x = bbox.max.x
                    NearPoint.y = bbox.min.z
                    NearPoint.z = bbox.max.y
                end if
            else
                if ( frustum(i).norm.z > 0.0 ) then
                    NearPoint.x = bbox.max.x
                    NearPoint.y = bbox.max.z
                    NearPoint.z = bbox.min.y
                else
                    NearPoint.x = bbox.max.x
                    NearPoint.y = bbox.max.z
                    NearPoint.z = bbox.max.y
                end if
            end if
        end if            
            
        dp = frustum(i).norm.x*NearPoint.x + frustum(i).norm.y*NearPoint.y + _
             frustum(i).norm.z*NearPoint.z
             
        if ( (dp+frustum(i).dist) > 0 ) then
            BBoxInFrustum% = 0
            exit function
        end if
    next i    
    
    BBoxInFrustum% = -1
end function




''::::::::::
defint a-z
sub pvsInit ( byval nodenr as integer )
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
        if ( bspClasifypoint( nodenr ) ) then
            nodenr = ndsBuffer(nodenr).child0
        else
            nodenr = ndsBuffer(nodenr).child1
        end if            
    wend

    ''
    '' The visible set only changes when the camera changes leaf, and the
    '' camera spends most frames in one. Unpacking the same run-length data
    '' every frame -- and writing one entry per leaf in the map while doing
    '' it -- was the largest fixed cost in the walk.
    ''
    if ( nodenr = pvsLeaf ) then exit sub
    pvsLeaf = nodenr
    
    '' 
    '' Setup
    ''    
    v = lefBuffer( not nodenr ).vislist
    if ( v = -2 ) then ExitError "Leaf has no pvs data."
        
    v = v + varptr( pvsBufferA(0) )
    def seg = varseg( pvsBufferA(0) )
    
    if ( lefBuffer( not nodenr ).vislist = -1 ) then
        for  i = 0 to wld.lefCount-1
            pvsBufferB(i) = -1
        next i           

        exit sub
    end if
    
    '' 
    '' Extract the pvs data
    ''
    l = 1
    while ( l < wld.lefCount )
        
        if ( peek( v ) = 0 ) then
            j = l
            l = l + 8& * peek( v+1 ) 
            if ( l > wld.lefCount ) then l = wld.lefCount
            
            for  j = j to l-1
                pvsBufferB(j) = 0
            next j
            
            v = v + 1
        else
            byte = peek(v)
            
            for  bit = 0 to 7
                ''
                '' A run can carry past the last leaf; in real mode that
                '' writes over whatever follows the array.
                ''
                if ( l >= wld.lefCount ) then exit for
                
                        
                if ( byte and bitarray(bit) ) then
                    pvsBufferB(l) = 1
                else                 
                    pvsBufferB(l) = 0
                end if
                
                l = l + 1
            next bit            
        end if            
            
        v = v + 1        
    wend


end sub 
