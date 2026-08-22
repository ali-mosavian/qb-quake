''
'' qbsplod.bas -- reading the BSP lumps into the renderer's buffers.
''
'' The staging records (fce, nodetmp, leaftmp, planetmp) and the counts only
'' this module consumes stay local; the buffers the renderer walks are in
'' qshared.bi as COMMON SHARED.
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
'$include: 'quakedef.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'

'$dynamic
dim shared visCount as long
dim shared texCount as long
dim shared fce as face                  '' fields the renderer keeps, discard
dim shared nodetmp as node              '' the rest. Also the len() source for
dim shared leaftmp as leaf              '' the lump counts in bspOpen.
dim shared planetmp as plane
dim shared ledgCount as long
dim shared lfcCount as long
dim shared plnCount as long
dim shared mdlCount as long
dim shared clpCount as long
dim shared txcBuffer( 1 ) as uv
dim shared clpBuffer( 1 ) as clipnode




''::::::::::
'' name: bspOpen
'' desc: Opens the map, reads the header and derives every lump count.
''::::::::::
defint a-z
sub bspOpen
    open command$ for binary as #1 
    
    dim vtx as vertex   
    dim fce as face
    dim nodetmp as node
    dim leaftmp as leaf
    dim planetmp as plane
    
    get #1,, bsphead
    
    triCount = bsphead.faces.size \ len( fce )
    vtxCount = bsphead.vertices.size \ len( vtxBuffer(0) )
    edgCount = bsphead.edges.size \ len( edgBuffer(0) )
    ledgCount = bsphead.ledges.size \ 4
    lefCount = bsphead.leaves.size \ len( leaftmp )
    lfcCount = bsphead.lface.size \ len( lfcBuffer(0) )
    plnCount = bsphead.planes.size \ len( planetmp )
    ndsCount = bsphead.nodes.size \ len( nodetmp )
    mdlCount = bsphead.models.size \ len( mdlBuffer(0) )
    visCount = bsphead.vislist.size
    texiCount = bsphead.texinfo.size \ len( texInfBuff(0) )
    clpCount = bsphead.clipnode.size \ len( clpBuffer(0) )
    seek #1, bsphead.miptex.offs+1
    get #1,, numtex    
    texCount = numtex

end sub




''::::::::::
'' name: bspFindSpawn
'' desc: Scans the entity lump for info_player_start.
''::::::::::
defint a-z
sub bspFindSpawn
    dim i as integer
    dim entity as string

    entity$ = space$( bsphead.entities.size )
    seek #1, bsphead.entities.offs+1
    get #1,, entity$
    
    dim strm(50) as string
    dim strm_cnt as integer

    for  i = 1 to len( entity$ )    
        char$ = mid$( entity$, i, 1 )

        if char$ = "{" then 
            new = 1
            fchar = i
        end if
            
        if char$ = "}" then 
            if new = 1 then
                class$ = mid$( entity$, fchar, i-fchar+1 )
                
                if instr( class$, "info_player_start" ) then
                    strtok strm(), strm_cnt, " {}"+chr$(34)+chr$(10)+chr$(13), class$
                    
                    for j = 0 to strm_cnt-1
                        if strm(j) = "origin" then
                            camPos.x = val(strm(j+1))
                            camPos.z = val(strm(j+2))
                            camPos.y = val(strm(j+3))
                        end if
                        
                        if strm(j) = "angle" then
                            startAngle = val(strm(j+1))                            
                        end if                        
                    next j
                end if
            end if
        end if    
    next i
    
    loading = loading + 100.0/14.0
    drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1    

end sub




''::::::::::
'' name: bspAlloc
'' desc: Sizes every level buffer from the counts bspOpen derived.
''::::::::::
defint a-z
sub bspAlloc
    redim triBuffer(triCount-1) as face2
    redim edgBuffer(edgCount-1) as edge    
    redim ledgBuffer(ledgCount-1) as integer
    redim vtxBuffer(vtxCount-1) as vertex
    redim txcBuffer(vtxCount-1) as uv
    redim lefBuffer(lefCount-1) as leaf2
    redim lfcBuffer(lfcCount-1) as integer
    redim plnBuffer(plnCount-1) as plane2
    redim ndsBuffer(ndsCount-1) as nodeb
    redim mdlBuffer(mdlCount-1) as model
    redim orderList(ndsCount-1) as integer
    redim pvsBufferA( (bsphead.vislist.size+1)\2 ) as integer
    redim pvsBufferB( 4096 ) as integer
    redim polyFlag( 4096 ) as integer
    redim texInfBuff(texiCount-1) as texinfo

end sub




''::::::::::
'' name: bspLoadVertices
''::::::::::
defint a-z
sub bspLoadVertices
    dim i as integer

    seek #1, bsphead.vertices.offs+1
    for  i = 0 to vtxCount-1
        get #1,, vtxBuffer(i)
        loading = loading + ((100.0/14.0)/vtxCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i

end sub




''::::::::::
'' name: bspLoadFaces
''::::::::::
defint a-z
sub bspLoadFaces
    dim i as integer

    seek #1, bsphead.faces.offs+1
    for  i = 0 to triCount-1
        get #1,, fce
        triBuffer(i).planeid = fce.planeid
        triBuffer(i).side = fce.side
        triBuffer(i).ledgeid = fce.ledgeid
        triBuffer(i).ledgenum = fce.ledgenum
        triBuffer(i).texinfoid = fce.texinfoid
        triBuffer(i).lightmap = fce.lightmap
        loading = loading + ((100.0/14.0)/triCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i    

end sub




''::::::::::
'' name: bspLoadEdges
''::::::::::
defint a-z
sub bspLoadEdges
    dim i as integer

    seek #1, bsphead.edges.offs+1
    for  i = 0 to edgCount-1
        get #1,, edgBuffer(i)
        loading = loading + ((100.0/14.0)/edgCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i        

end sub




''::::::::::
'' name: bspLoadEdgeIndex
''::::::::::
defint a-z
sub bspLoadEdgeIndex
    dim i as integer

    seek #1, bsphead.ledges.offs+1
    for  i = 0 to ledgCount-1
        get #1,, tmp&
        ledgBuffer(i) = tmp&
        loading = loading + ((100.0/14.0)/ledgCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i    

end sub




''::::::::::
'' name: bspLoadLeaves
''::::::::::
defint a-z
sub bspLoadLeaves
    dim i as integer

    seek #1, bsphead.leaves.offs+1
    for  i = 0 to lefCount-1        
        get #1,, leaftmp
        lefBuffer(i).vislist = leaftmp.vislist
        swap lefBuffer(i).bound, leaftmp.bound
        lefBuffer(i).lfaceid = leaftmp.lfaceid
        lefBuffer(i).lfacenum = leaftmp.lfacenum
        loading = loading + ((100.0/14.0)/lefCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i        

end sub




''::::::::::
'' name: bspLoadFaceIndex
''::::::::::
defint a-z
sub bspLoadFaceIndex
    dim i as integer

    seek #1, bsphead.lface.offs+1
    for  i = 0 to lfcCount-1
        get #1,, lfcBuffer(i)
        loading = loading + ((100.0/14.0)/lfcCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i                

end sub




''::::::::::
'' name: bspLoadNodes
''::::::::::
defint a-z
sub bspLoadNodes
    dim i as integer

    seek #1, bsphead.nodes.offs+1
    for  i = 0 to ndsCount-1
        get #1,, nodetmp
        ndsBuffer(i).planeid = nodetmp.planeid
        ndsBuffer(i).child0  = nodetmp.child0
        ndsBuffer(i).child1  = nodetmp.child1
        ndsBuffer(i).lfaceid = nodetmp.lfaceid
        ndsBuffer(i).lfacenum = nodetmp.lfacenum
        
        ndsBuffer(i).bound.min.x = nodetmp.bound.min.x
        ndsBuffer(i).bound.min.y = nodetmp.bound.min.y
        ndsBuffer(i).bound.min.z = nodetmp.bound.min.z
        ndsBuffer(i).bound.max.x = nodetmp.bound.max.x
        ndsBuffer(i).bound.max.y = nodetmp.bound.max.y
        ndsBuffer(i).bound.max.z = nodetmp.bound.max.z
        
        loading = loading + ((100.0/14.0)/ndsCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i

end sub




''::::::::::
'' name: bspLoadPlanes
''::::::::::
defint a-z
sub bspLoadPlanes
    dim i as integer

    seek #1, bsphead.planes.offs+1
    for  i = 0 to plnCount-1
        get #1,, planetmp
        plnBuffer(i).norm.x = planetmp.norm.x
        plnBuffer(i).norm.y = planetmp.norm.y
        plnBuffer(i).norm.z = planetmp.norm.z
        plnBuffer(i).dist = planetmp.dist
        
        loading = loading + ((100.0/14.0)/plnCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i    

end sub




''::::::::::
'' name: bspLoadModels
''::::::::::
defint a-z
sub bspLoadModels
    dim i as integer

    seek #1, bsphead.models.offs+1
    for  i = 0 to mdlCount-1
        get #1,, mdlBuffer(i)
        
        loading = loading + ((100.0/14.0)/mdlCount)
        if ( (i and 127) = 0 ) then drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1
    next i

end sub




''::::::::::
'' name: bspLoadPvs
''::::::::::
defint a-z
sub bspLoadPvs
    dim i as integer

    seek #1, bsphead.vislist.offs+1
    for  i = 0 to (bsphead.vislist.size\2)-1
        get #1,, pvsBufferA(i)
    next i
    
    if ( bsphead.vislist.size mod 2 ) then
        get #1,, pvsBufferA(i)
    end if
    loading = loading + (100.0/14.0)
    drwLoadingBar loadDC, (320-150)\2, (200-20)\2, 150, 20, loading, -1 

end sub
