option explicit
''
'' model.bas -- reading the BSP lumps into the renderer's buffers.
''
'' The staging records (fce, nodetmp, leaftmp, planetmp, clptmp) and the
'' counts only this module consumes stay local; the buffers the renderer
'' walks are in qshared.bi as COMMON SHARED.
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
dim shared clptmp as cliptmp           '' clipnode narrowed the live type;
                                         '' this stays the on-disk 8 bytes
dim shared vtxtmp as vertex            '' vtx_buffer narrowed to Q13.3; this
                                         '' stays the on-disk 12 float bytes
dim shared texinfotmp as texinfo       '' tex_inf_buff dropped flags and
                                         '' narrowed miptex; this stays the
                                         '' on-disk 40 bytes
dim shared ledg_count as long
dim shared lfc_count as long
dim shared pln_count as long




''::::::::::
'' name: mod_open
'' desc: Opens the map, reads the header and derives every lump count.
''::::::::::
sub mod_open
    wld.file = freefile
    open rtrim$( env.map_name ) for binary as #wld.file
    
    get #wld.file,, wld.head
    
    wld.tri_count = wld.head.faces.size \ len( fce )
    wld.vtx_count = wld.head.vertices.size \ len( vtxtmp )
    wld.edg_count = wld.head.edges.size \ 4
    ledg_count = wld.head.ledges.size \ 4
    wld.lef_count = wld.head.leaves.size \ len( leaftmp )
    lfc_count = wld.head.lface.size \ len( lfc_buffer(0) )
    pln_count = wld.head.planes.size \ len( planetmp )
    wld.nds_count = wld.head.nodes.size \ len( nodetmp )
    wld.mdl_count = wld.head.models.size \ len( mdl_buffer(0) )
    wld.texi_count = wld.head.texinfo.size \ len( texinfotmp )
    wld.clp_count = wld.head.clipnode.size \ len( clptmp )
    seek #wld.file, wld.head.miptex.offs+1
    get #wld.file,, wld.numtex    

end sub




''::::::::::
'' name: mod_find_spawn
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
'' name: mod_alloc
'' desc: Sizes every level buffer from the counts bspOpen derived.
''::::::::::
sub mod_alloc
    redim tri_buffer(wld.tri_count-1) as face2

    redim lef_buffer(wld.lef_count-1) as leaf2
    redim lfc_buffer(lfc_count-1) as integer
    redim pln_buffer(pln_count-1) as plane2
    redim nds_buffer(wld.nds_count-1) as nodeb
    redim mdl_buffer(wld.mdl_count-1) as model
    redim order_list(wld.nds_count-1) as integer
    '' Sized to the map like every buffer above it, not a fixed 4096: r_bsp.bas
    '' indexes pvs_buffer_b 0..wld.lef_count-1 and poly_flag by face index
    '' 0..wld.tri_count-1 (see its own comment: "a run can carry past the last
    '' leaf; in real mode that writes over whatever follows the array"). e3m6
    '' has 6,985 faces -- a fixed 4096 was too SMALL for poly_flag there, an
    '' out-of-bounds write waiting to happen, not just wasted space on the
    '' smaller maps.
    redim pvs_buffer_b( wld.lef_count-1 ) as integer
    redim poly_flag( wld.tri_count-1 ) as integer
    redim tex_inf_buff(wld.texi_count-1) as texinfo2
    redim clp_buffer(wld.clp_count-1) as clipnode

end sub









''::::::::::
'' name: mod_load_faces
''::::::::::
sub mod_load_faces
    scr_load_stage "faces"
    def seg = varseg( tri_buffer(0) )
    bload "faces.bld", varptr( tri_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_colormap
'' desc: The 64-shade table the builder shades through.
''
''       A BASIC array, not memAlloc. Once low memory is tight enough DOS
''       satisfies a 16K request from an upper memory block -- the probe
''       came back with segment 0D0A8h, which is 835K, and memAvail did not
''       move because the block came from a different arena entirely.
''       Merely holding that block wedges the program. Nothing here needs
''       memAlloc's paragraph alignment: the builder only PEEKs the table.
''::::::::::
sub mod_load_colormap
    dim f as FILE

    scr_load_stage "colormap"

    dim p as long

    cm_dc = 0
    cm_size = 0

    if ( fileOpen( f, "colmap.bin", F4READ ) = 0 ) then exit sub

    cm_dc = uglNew&( UGL.EMS, UGL.8BIT, 16384, 1 )
    if ( cm_dc <> 0 ) then
        p = uglMapEx&( cm_dc, 0, CM_SLOT )
        if ( p <> 0 ) then
            if ( fileReadH( f, p, 16384 ) = 16384 ) then
                cm_size = 16384
            end if
        end if
    end if

    fileClose f

    if ( cm_size = 0 ) then sys_error "0x0015, colormap would not load"
end sub



''::::::::::
'' name: mod_load_lightmaps
'' desc: Loads the per-face lightmap table, then the luxels into EMS.
''
''       The table is 16 bytes a face and BLOADs like every other lump. The
''       luxels never could: 71K of them made BASIC fail with 'out of
''       string space' while setmem reported 397K of far heap free. They
''       are now one 8-bit atlas in a single EMS dc, loaded by uglNewBMPEx
''       exactly as the textures are -- which puts them outside
''       conventional memory entirely rather than merely outside the BASIC
''       heap, and costs no bespoke loader at all.
''
''       No pointer fixup here: a face's rect is found by mapping its atlas
''       scanline, which sb_build does per build.
''::::::::::
sub mod_load_lightmaps
    scr_load_stage "lightmaps"
    dim f as FILE
    dim got as long

    lm_atlas = 0
    lm_size = 0

    lm_info = 0
    lm_isize = 0

    if ( fileOpen( f, "lmface.bin", F4READ ) <> 0 ) then
        lm_isize = fileSize( f )
        lm_info = memAlloc( lm_isize )
        if ( lm_info <> 0 ) then
            if ( fileReadH( f, lm_info, lm_isize ) <> lm_isize ) then
                memFree lm_info
                lm_info = 0
                lm_isize = 0
            end if
        else
            lm_isize = 0
        end if
        fileClose f
    end if

    ''
    '' Every luxel in the map, as one 8-bit EMS dc built straight from a
    '' BMP -- the same path mod_tex.bas takes for the textures, and
    '' BMPOPT.NO332 for the same reason: these bytes are luxel values, not
    '' colours for uGL to remap through its own palette.
    ''
    '' It costs no conventional memory at all. The packed blob it replaces
    '' cost 40K on dm3ish and more on the bigger maps.
    ''
    if ( fileOpen( f, "lm.bmp", F4READ ) <> 0 ) then
        lm_size = fileSize( f )
        fileClose f
    end if
    lm_atlas = uglNewBMPEx( UGL.EMS, UGL.8BIT, "lm.bmp", BMPOPT.NO332 )
    if ( lm_atlas <> 0 ) then
        lm_read = lm_size
    else
        lm_read = 0
    end if

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_facevtx
''::::::::::
''
'' Read straight into the mapped window, a row at a time. There is no
'' conventional-memory staging buffer anywhere in here: the point of the
'' store is that the geometry never lands in low memory, and a loader
'' that read it into an array first would defeat that at the worst
'' possible moment -- while every other buffer is also allocated.
''
sub mod_load_facevtx
    dim f as FILE
    dim y as integer
    dim p as long

    scr_load_stage "face vertices"

    if ( fileOpen( f, "fgeom.bin", F4READ ) = 0 ) then
        sys_error "0x0011, fgeom.bin missing"
    end if

    geom_rows = cint( (fileSize&( f ) + GEOM_W - 1) \ GEOM_W )
    geom_dc = uglNew&( UGL.EMS, UGL.8BIT, GEOM_W, geom_rows )
    if ( geom_dc = 0 ) then sys_error "0x0010, no EMS for the geometry store"

    for y = 0 to geom_rows-1
        p = uglMapEx&( geom_dc, y, GEOM_SLOT )
        if ( p = 0 ) then sys_error "0x0012, geometry store will not map"
        if ( fileReadH( f, p, GEOM_W ) <> GEOM_W ) then
            sys_error "0x0013, fgeom.bin short read"
        end if
    next y

    fileClose f

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub









''::::::::::
'' name: mod_load_leafs
''::::::::::
sub mod_load_leafs
    scr_load_stage "bsp leaves"
    def seg = varseg( lef_buffer(0) )
    bload "leaves.bld", varptr( lef_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_marksurfaces
''::::::::::
sub mod_load_marksurfaces
    def seg = varseg( lfc_buffer(0) )
    bload "lface.bld", varptr( lfc_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_nodes
''::::::::::
sub mod_load_nodes
    scr_load_stage "bsp nodes"
    def seg = varseg( nds_buffer(0) )
    bload "nodes.bld", varptr( nds_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_planes
''::::::::::
sub mod_load_planes
    scr_load_stage "planes"
    def seg = varseg( pln_buffer(0) )
    bload "planes.bld", varptr( pln_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_submodels
''::::::::::
sub mod_load_submodels
    scr_load_stage "submodels"
    def seg = varseg( mdl_buffer(0) )
    bload "models.bld", varptr( mdl_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_clipnodes
'' desc: The collision hulls: a second set of bsp trees over the same
''       planes, each expanded by a bounding box so that tracing a POINT
''       through hull n is equivalent to sweeping that box through the
''       world. Hull 1 is the 32x32x56 player.
''
''       The lump was loaded by nothing until now -- pl_move is its first
''       consumer, and the dead declaration for it was deleted in the
''       first cleanup commit of this refactor.
''::::::::::
sub mod_load_clipnodes
    scr_load_stage "clip hulls"
    def seg = varseg( clp_buffer(0) )
    bload "clip.bld", varptr( clp_buffer(0) )
    def seg

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub




''::::::::::
'' name: mod_load_visibility
''::::::::::
sub mod_load_visibility
    dim f as FILE

    scr_load_stage "visibility"

    pvs_ptr = 0
    pvs_size = 0

    if ( fileOpen( f, "pvs.bin", F4READ ) <> 0 ) then
        pvs_size = fileSize&( f )
        if ( pvs_size > 0 ) then
            pvs_ptr = memAlloc( pvs_size )
            if ( pvs_ptr <> 0 ) then
                if ( fileReadH( f, pvs_ptr, pvs_size ) <> pvs_size ) then
                    memFree pvs_ptr
                    pvs_ptr = 0
                    pvs_size = 0
                end if
            else
                pvs_size = 0
            end if
        end if
        fileClose f
    end if

    if ( pvs_ptr = 0 ) then sys_error "0x0014, visibility lump would not load"

    ldr.pct = ldr.pct + (100.0/LOAD_STEPS)
    scr_load_tick
end sub


''::::::::::
'' name: mod_close
'' desc: Releases the map file. r_tex.bas used to do this at the end of
''       texLoadAll -- the module that opened the file was not the module
''       that closed it, and the handle's lifetime spanned two modules
''       with nothing naming the contract.
''::::::::::
sub mod_close
    close #wld.file
    wld.file = 0
end sub
