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
sub mod_open
    wld.file = freefile
    open rtrim$( env.mapName ) for binary as #wld.file
    
    get #wld.file,, wld.head
    
    wld.triCount = wld.head.faces.size \ len( fce )
    wld.vtxCount = wld.head.vertices.size \ len( vtxBuffer(0) )
    wld.edgCount = wld.head.edges.size \ len( edgBuffer(0) )
    ledgCount = wld.head.ledges.size \ 4
    wld.lefCount = wld.head.leaves.size \ len( leaftmp )
    lfcCount = wld.head.lface.size \ len( lfcBuffer(0) )
    plnCount = wld.head.planes.size \ len( planetmp )
    wld.ndsCount = wld.head.nodes.size \ len( nodetmp )
    mdlCount = wld.head.models.size \ len( mdlBuffer(0) )
    wld.texiCount = wld.head.texinfo.size \ len( texInfBuff(0) )
    seek #wld.file, wld.head.miptex.offs+1
    get #wld.file,, wld.numtex    

end sub




''::::::::::
'' name: bspFindSpawn
'' desc: Scans the entity lump for info_player_start.
''::::::::::
defint a-z
sub mod_find_spawn
    dim i as integer
    dim entity as string

    entity$ = space$( wld.head.entities.size )
    seek #wld.file, wld.head.entities.offs+1
    get #wld.file,, entity$
    
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
                    com_tokenize strm(), strm_cnt, " {}"+chr$(34)+chr$(10)+chr$(13), class$
                    
                    for j = 0 to strm_cnt-1
                        if strm(j) = "origin" then
                            cam.pos.x = val(strm(j+1))
                            cam.pos.z = val(strm(j+2))
                            cam.pos.y = val(strm(j+3))
                        end if
                        
                        if strm(j) = "angle" then
                            cam.startAngle = val(strm(j+1))                            
                        end if                        
                    next j
                end if
            end if
        end if    
    next i
    
    ldr.pct = ldr.pct + 100.0/LOAD_STEPS
    scr_load_tick    

end sub




''::::::::::
'' name: bspAlloc
'' desc: Sizes every level buffer from the counts bspOpen derived.
''::::::::::
defint a-z
sub mod_alloc
    redim triBuffer(wld.triCount-1) as face2
    redim edgBuffer(wld.edgCount-1) as edge    
    redim ledgBuffer(ledgCount-1) as integer
    redim vtxBuffer(wld.vtxCount-1) as vertex
    redim lefBuffer(wld.lefCount-1) as leaf2
    redim lfcBuffer(lfcCount-1) as integer
    redim plnBuffer(plnCount-1) as plane2
    redim ndsBuffer(wld.ndsCount-1) as nodeb
    redim mdlBuffer(mdlCount-1) as model
    redim orderList(wld.ndsCount-1) as integer
    redim pvsBufferA( (wld.head.vislist.size+1)\2 ) as integer
    redim pvsBufferB( 4096 ) as integer
    redim polyFlag( 4096 ) as integer
    redim texInfBuff(wld.texiCount-1) as texinfo

end sub




''::::::::::
'' name: bspLoadVertices
''::::::::::
defint a-z
sub mod_load_vertexes
    def seg = varseg( vtxBuffer(0) )
    bload "verts.bld", varptr( vtxBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadFaces
''::::::::::
defint a-z
sub mod_load_faces
    def seg = varseg( triBuffer(0) )
    bload "faces.bld", varptr( triBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadEdges
''::::::::::
defint a-z
sub mod_load_edges
    def seg = varseg( edgBuffer(0) )
    bload "edges.bld", varptr( edgBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadEdgeIndex
''::::::::::
defint a-z
sub mod_load_surfedges
    def seg = varseg( ledgBuffer(0) )
    bload "ledges.bld", varptr( ledgBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadLeaves
''::::::::::
defint a-z
sub mod_load_leafs
    def seg = varseg( lefBuffer(0) )
    bload "leaves.bld", varptr( lefBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadFaceIndex
''::::::::::
defint a-z
sub mod_load_marksurfaces
    def seg = varseg( lfcBuffer(0) )
    bload "lface.bld", varptr( lfcBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadNodes
''::::::::::
defint a-z
sub mod_load_nodes
    def seg = varseg( ndsBuffer(0) )
    bload "nodes.bld", varptr( ndsBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadPlanes
''::::::::::
defint a-z
sub mod_load_planes
    def seg = varseg( plnBuffer(0) )
    bload "planes.bld", varptr( plnBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadModels
''::::::::::
defint a-z
sub mod_load_submodels
    def seg = varseg( mdlBuffer(0) )
    bload "models.bld", varptr( mdlBuffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadPvs
''::::::::::
defint a-z
sub mod_load_visibility
    def seg = varseg( pvsBufferA(0) )
    bload "pvs.bld", varptr( pvsBufferA(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub


''::::::::::
'' name: bspClose
'' desc: Releases the map file. r_tex.bas used to do this at the end of
''       texLoadAll -- the module that opened the file was not the module
''       that closed it, and the handle's lifetime spanned two modules
''       with nothing naming the contract.
''::::::::::
defint a-z
sub mod_close
    close #wld.file
    wld.file = 0
end sub
