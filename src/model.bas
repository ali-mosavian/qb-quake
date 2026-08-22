option explicit
''
'' model.bas -- reading the BSP lumps into the renderer's buffers.
''
'' The staging records (fce, nodetmp, leaftmp, planetmp) and the counts only
'' this module consumes stay local; the buffers the renderer walks are in
'' qshared.bi as COMMON SHARED.
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
'$include: 'q_cam.bi'

'$dynamic
dim shared fce as face                  '' fields the renderer keeps, discard
dim shared nodetmp as node              '' the rest. Also the len() source for
dim shared leaftmp as leaf              '' the lump counts in bspOpen.
dim shared planetmp as plane
dim shared ledg_count as long
dim shared lfc_count as long
dim shared pln_count as long
dim shared mdl_count as long




''::::::::::
'' name: bspOpen
'' desc: Opens the map, reads the header and derives every lump count.
''::::::::::
sub mod_open
    wld.file = freefile
    open rtrim$( env.map_name ) for binary as #wld.file
    
    get #wld.file,, wld.head
    
    wld.tri_count = wld.head.faces.size \ len( fce )
    wld.vtx_count = wld.head.vertices.size \ len( vtx_buffer(0) )
    wld.edg_count = wld.head.edges.size \ len( edg_buffer(0) )
    ledg_count = wld.head.ledges.size \ 4
    wld.lef_count = wld.head.leaves.size \ len( leaftmp )
    lfc_count = wld.head.lface.size \ len( lfc_buffer(0) )
    pln_count = wld.head.planes.size \ len( planetmp )
    wld.nds_count = wld.head.nodes.size \ len( nodetmp )
    mdl_count = wld.head.models.size \ len( mdl_buffer(0) )
    wld.texi_count = wld.head.texinfo.size \ len( tex_inf_buff(0) )
    seek #wld.file, wld.head.miptex.offs+1
    get #wld.file,, wld.numtex    

end sub




''::::::::::
'' name: bspFindSpawn
'' desc: Scans the entity lump for info_player_start.
''::::::::::
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
                            cam.start_angle = val(strm(j+1))                            
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
sub mod_alloc
    redim tri_buffer(wld.tri_count-1) as face2
    redim edg_buffer(wld.edg_count-1) as edge    
    redim ledg_buffer(ledg_count-1) as integer
    redim vtx_buffer(wld.vtx_count-1) as vertex
    redim lef_buffer(wld.lef_count-1) as leaf2
    redim lfc_buffer(lfc_count-1) as integer
    redim pln_buffer(pln_count-1) as plane2
    redim nds_buffer(wld.nds_count-1) as nodeb
    redim mdl_buffer(mdl_count-1) as model
    redim order_list(wld.nds_count-1) as integer
    redim pvs_buffer_a( (wld.head.vislist.size+1)\2 ) as integer
    redim pvs_buffer_b( 4096 ) as integer
    redim poly_flag( 4096 ) as integer
    redim tex_inf_buff(wld.texi_count-1) as texinfo

end sub




''::::::::::
'' name: bspLoadVertices
''::::::::::
sub mod_load_vertexes
    def seg = varseg( vtx_buffer(0) )
    bload "verts.bld", varptr( vtx_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadFaces
''::::::::::
sub mod_load_faces
    def seg = varseg( tri_buffer(0) )
    bload "faces.bld", varptr( tri_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadEdges
''::::::::::
sub mod_load_edges
    def seg = varseg( edg_buffer(0) )
    bload "edges.bld", varptr( edg_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadEdgeIndex
''::::::::::
sub mod_load_surfedges
    def seg = varseg( ledg_buffer(0) )
    bload "ledges.bld", varptr( ledg_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadLeaves
''::::::::::
sub mod_load_leafs
    def seg = varseg( lef_buffer(0) )
    bload "leaves.bld", varptr( lef_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadFaceIndex
''::::::::::
sub mod_load_marksurfaces
    def seg = varseg( lfc_buffer(0) )
    bload "lface.bld", varptr( lfc_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadNodes
''::::::::::
sub mod_load_nodes
    def seg = varseg( nds_buffer(0) )
    bload "nodes.bld", varptr( nds_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadPlanes
''::::::::::
sub mod_load_planes
    def seg = varseg( pln_buffer(0) )
    bload "planes.bld", varptr( pln_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadModels
''::::::::::
sub mod_load_submodels
    def seg = varseg( mdl_buffer(0) )
    bload "models.bld", varptr( mdl_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: bspLoadPvs
''::::::::::
sub mod_load_visibility
    def seg = varseg( pvs_buffer_a(0) )
    bload "pvs.bld", varptr( pvs_buffer_a(0) )
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
sub mod_close
    close #wld.file
    wld.file = 0
end sub
