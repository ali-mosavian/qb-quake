option explicit
''
'' model.bas -- reading the BSP lumps into the renderer's buffers.
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
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'quakedef.bi'

'$dynamic
dim shared fce as face                  '' fields the renderer keeps, discard
dim shared nodetmp as node              '' the rest. Also the len() source for
dim shared leaftmp as leaf              '' the lump counts in bspOpen.
dim shared planetmp as plane
dim shared ledgCount as long
dim shared lfcCount as long
dim shared plnCount as long
dim shared mdlCount as long




''::::::::::
'' name: bspOpen
'' desc: Opens the map, reads the header and derives every lump count.
''::::::::::
defint a-z
sub bspOpen
    bspFile = freefile
    open rtrim$( env.mapName ) for binary as #bspFile
    
    get #bspFile,, bsphead
    
    triCount = bsphead.faces.size \ len( fce )
    vtxCount = bsphead.vertices.size \ len( vtxBuffer(0) )
    edgCount = bsphead.edges.size \ len( edgBuffer(0) )
    ledgCount = bsphead.ledges.size \ 4
    lefCount = bsphead.leaves.size \ len( leaftmp )
    lfcCount = bsphead.lface.size \ len( lfcBuffer(0) )
    plnCount = bsphead.planes.size \ len( planetmp )
    ndsCount = bsphead.nodes.size \ len( nodetmp )
    mdlCount = bsphead.models.size \ len( mdlBuffer(0) )
    texiCount = bsphead.texinfo.size \ len( texInfBuff(0) )
    seek #bspFile, bsphead.miptex.offs+1
    get #bspFile,, numtex    

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
    seek #bspFile, bsphead.entities.offs+1
    get #bspFile,, entity$
    
    dim strm(50) as string
    dim strm_cnt as integer
    dim char as string, class as string
    dim new as integer, fchar as integer, j as integer

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
    
    loading = loading + 100.0/LOAD_STEPS
    drwLoadTick    

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
    def seg = varseg( vtxBuffer(0) )
    bload "verts.bld", varptr( vtxBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadFaces
''::::::::::
defint a-z
sub bspLoadFaces
    def seg = varseg( triBuffer(0) )
    bload "faces.bld", varptr( triBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadEdges
''::::::::::
defint a-z
sub bspLoadEdges
    def seg = varseg( edgBuffer(0) )
    bload "edges.bld", varptr( edgBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadEdgeIndex
''::::::::::
defint a-z
sub bspLoadEdgeIndex
    def seg = varseg( ledgBuffer(0) )
    bload "ledges.bld", varptr( ledgBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadLeaves
''::::::::::
defint a-z
sub bspLoadLeaves
    def seg = varseg( lefBuffer(0) )
    bload "leaves.bld", varptr( lefBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadFaceIndex
''::::::::::
defint a-z
sub bspLoadFaceIndex
    def seg = varseg( lfcBuffer(0) )
    bload "lface.bld", varptr( lfcBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadNodes
''::::::::::
defint a-z
sub bspLoadNodes
    def seg = varseg( ndsBuffer(0) )
    bload "nodes.bld", varptr( ndsBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadPlanes
''::::::::::
defint a-z
sub bspLoadPlanes
    def seg = varseg( plnBuffer(0) )
    bload "planes.bld", varptr( plnBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadModels
''::::::::::
defint a-z
sub bspLoadModels
    def seg = varseg( mdlBuffer(0) )
    bload "models.bld", varptr( mdlBuffer(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub




''::::::::::
'' name: bspLoadPvs
''::::::::::
defint a-z
sub bspLoadPvs
    def seg = varseg( pvsBufferA(0) )
    bload "pvs.bld", varptr( pvsBufferA(0) )
    def seg

    loading = loading + (100.0/LOAD_STEPS)
    drwLoadTick
end sub


''::::::::::
'' name: bspClose
'' desc: Releases the map file. r_tex.bas used to do this at the end of
''       texLoadAll -- the module that opened the file was not the module
''       that closed it, and the handle's lifetime spanned two modules
''       with nothing naming the contract.
''::::::::::
defint a-z
sub bspClose
    close #bspFile
    bspFile = 0
end sub
