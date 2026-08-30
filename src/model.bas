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
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_snd.bi'
'$include: 'q_game.bi'

''
'' This module's own procedures.
''
declare sub mod_alloc ( _
    g as Game, _
    faces() as Face, _
    texinf() as TexInfo, _
    planes() as Plane, _
    nodes() as Node, _
    models() as Submodel, _
    ord() as integer, _
    pflag() as integer _
)
declare sub mod_load_faces ( _
    g as Game, _
    faces() as Face _
)
declare sub mod_load_facevtx ( _
    g as Game, _
    gv_buf() as integer _
)
declare sub mod_load_nodes ( _
    g as Game, _
    nodes() as Node _
)
declare sub mod_load_clipnodes ( _
    g as Game _
)
declare sub mod_load_leafs ( _
    g as Game _
)
declare sub mod_load_lightmaps ( _
    g as Game _
)
declare sub mod_load_marksurfaces ( _
    g as Game _
)
declare sub mod_load_visibility ( _
    g as Game _
)
declare sub mod_load_planes ( planes() as Plane )
declare sub mod_load_submodels ( models() as Submodel )
declare sub mod_spawn_from_block ( _
    g as Game, _
    block as string _
)

''
'' This module's own procedures.
''
declare sub mod_open ( _
    g as Game, _
    models() as Submodel _
)
declare sub mod_find_spawn ( _
    g as Game _
)
declare function mod_lm_map ( _
    g as Game, _
    byval row as integer _
) as long
declare sub mod_load_world ( _
    g as Game, _
    faces() as Face, _
    tex_info() as TexInfo, _
    planes() as Plane, _
    nodes() as Node, _
    models() as Submodel, _
    ord() as integer, _
    pflag() as integer, _
    gv() as integer, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    face_mdl() as integer, _
    plat() as PlatEnt _
)
declare sub mod_load_colormap ( _
    g as Game _
)
declare sub mod_close ( _
    g as Game _
)
declare function mod_cm_ready ( _
    g as Game _
) as integer
declare function mod_cm_bytes ( _
    g as Game _
) as long
declare function mod_lm_bytes ( _
    g as Game _
) as long
declare function mod_lm_got ( _
    g as Game _
) as long
declare function mod_geom_rows ( _
    g as Game _
) as integer
declare function mod_pvs_base ( _
    g as Game _
) as long

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub r_alloc_pvs ( byval leaf_count as long )
declare sub r_load_lfaces ( byval lump_bytes as long )
declare sub ent_load_teleports ( _
    g as Game, _
    models() as Submodel, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    face_mdl() as integer, _
    plat() as PlatEnt _
)
declare sub pl_load_hulls ( _
    g as Game _
)
declare sub r_load_leaves ( _
    g as Game _
)

'$dynamic
dim shared fce as DiskFace                  '' fields the renderer keeps, discard
dim shared node_tmp as DiskNode              '' the rest. Also the len() source for
dim shared leaf_tmp as DiskLeaf              '' the lump counts in bspOpen.
dim shared plane_tmp as DiskPlane
dim shared clip_tmp as DiskClipNode           '' clipnode narrowed the live type;
                                         '' this stays the on-disk 8 bytes
dim shared vtxtmp as DiskVertex            '' vtx_buffer narrowed to Q13.3; this
                                         '' stays the on-disk 12 float bytes
dim shared tex_info_tmp as DiskTexInfo       '' tex_inf_buff dropped flags and
                                         '' narrowed miptex; this stays the
                                         '' on-disk 40 bytes
''
'' THE COLORMAP. Owned here -- mod_load_colormap is what creates it, and
'' the two readers (sb_build, hud_shade) want the same thing from it: a
'' pointer to the mapped table. They get that from mod_cm_map( wld ), so CM_SLOT
'' stops being a constant three modules have to agree about.
''
'' One row of 16,384, which is one EMS page, so a single uglMapEx reaches
'' the whole table and the rows the builder indexes flat really are
'' contiguous. CM_SLOT borrows the depth buffer's: a surface build is not
'' a scanline, nothing writes depth during one, and the depth publish
'' remaps its slot on every scanline anyway, so it repairs itself with no
'' explicit restore.
''
const CM_SLOT = 3

''
'' THE LIGHTMAP ATLAS AND THE GEOMETRY STORE. Owned here for the same
'' reason as the colormap: mod_load_lightmaps and mod_load_geometry make
'' them, and their readers want a scanline or a row out of them rather
'' than the handle. Which EMS slot a resource is mapped into is a
'' property of the resource, not of whoever reads it, so the slot came
'' along too -- both take turns in PAGE_SLOT. See q_map.bi for why taking
'' turns in one window is safe.
''


''
'' THE VISIBILITY LUMP. memAlloc'd, not a uGL store -- r_bsp reaches it by
'' DEF SEG and an offset rather than as an array, so all it needs is the
'' base. pvs_size is read nowhere else and stays private.
''

dim shared ledg_count as long
dim shared pln_count as long




''::::::::::
'' name: mod_open
'' desc: Opens the map, reads the header and derives every lump count.
''::::::::::
sub mod_open ( _
    g as Game, _
    models() as Submodel _
)
    g.wld.file.handle = freefile
    open rtrim$( g.env.map_name ) for binary as #g.wld.file.handle
    
    get #g.wld.file.handle,, g.wld.file.head
    
    g.wld.count.faces = g.wld.file.head.faces.size \ len( fce )
    g.wld.count.verts = g.wld.file.head.vertices.size \ len( vtxtmp )
    g.wld.count.edges = g.wld.file.head.edges.size \ 4
    ledg_count = g.wld.file.head.ledges.size \ 4
    g.wld.count.leaves = g.wld.file.head.leaves.size \ len( leaf_tmp )
    pln_count = g.wld.file.head.planes.size \ len( plane_tmp )
    g.wld.count.nodes = g.wld.file.head.nodes.size \ len( node_tmp )
    g.wld.count.models = g.wld.file.head.models.size \ len( models(0) )
    g.wld.count.tex_infos = g.wld.file.head.tex_info.size \ len( tex_info_tmp )
    g.wld.count.clips = g.wld.file.head.clip_node.size \ len( clip_tmp )
    seek #g.wld.file.handle, g.wld.file.head.mip_tex.offs+1
    get #g.wld.file.handle,, g.wld.count.textures    

end sub




''::::::::::
'' name: mod_find_spawn
'' desc: Scans the entity lump for info_player_start.
''::::::::::
sub mod_spawn_from_block ( _
    g as Game, _
    block as string _
)
    dim strm(50) as string
    dim strm_cnt as integer
    dim j as integer

    if ( instr( block, "info_player_start" ) = 0 ) then exit sub

    com_tokenize strm(), strm_cnt, " {}" + chr$(34) + chr$(10) + chr$(13), block

    for  j = 0 to strm_cnt-1
        if ( strm(j) = "origin" ) then
            '' BSP is Z-up and the camera is Y-up, so y and z swap here
            g.cam.pos.x = val( strm(j+1) )
            g.cam.pos.z = val( strm(j+2) )
            g.cam.pos.y = val( strm(j+3) )
        end if

        if ( strm(j) = "angle" ) then g.cam.start_angle = val( strm(j+1) )
    next j

end sub




''::::::::::
'' name: mod_find_spawn
'' desc: Scans the entity lump for the spawn point. Braces delimit the
''       blocks; each complete one goes to mod_spawn_from_block, which
''       decides whether it is the one we want.
''::::::::::
sub mod_find_spawn ( _
    g as Game _
)
    dim entity as string
    dim ch as string
    dim i as integer, open_at as integer

    entity$ = space$( g.wld.file.head.entities.size )
    seek #g.wld.file.handle, g.wld.file.head.entities.offs+1
    get #g.wld.file.handle,, entity$

    for  i = 1 to len( entity$ )
        ch$ = mid$( entity$, i, 1 )

        if ( ch$ = "{" ) then open_at = i

        if ( ch$ = "}" and open_at > 0 ) then
            mod_spawn_from_block g, mid$( entity$, open_at, i-open_at+1 )
            open_at = 0
        end if
    next i

    scr_load_step

end sub




''::::::::::
'' name: mod_alloc
'' desc: Sizes every level buffer from the counts bspOpen derived.
''::::::::::
sub mod_alloc ( _
    g as Game, _
    faces() as Face, _
    texinf() as TexInfo, _
    planes() as Plane, _
    nodes() as Node, _
    models() as Submodel, _
    ord() as integer, _
    pflag() as integer _
)
    '' ONE element; uglArrNew1D takes it over in mod_load_faces
    redim faces(0) as Face

    '' ONE element; uglArrNew1D takes it over in mod_load_leafs
    redim planes(pln_count-1) as Plane
    '' ONE element. uglArrNew1D takes the descriptor over in
    '' mod_load_nodes and the tree lives in EMS -- see q_map.bi.
    redim nodes(0) as Node
    redim models(g.wld.count.models-1) as Submodel
    redim ord(g.wld.count.nodes-1) as integer
    '' r_bsp sizes its own PVS bits; it states why over there.
    r_alloc_pvs g.wld.count.leaves

    '' Sized to the map, not a fixed 4096: poly_flag is indexed by face
    '' 0..wld.count.faces-1, and e3m6 has 6,985 faces -- a fixed 4096 was too
    '' SMALL there, an out-of-bounds write waiting to happen, not just
    '' wasted space on the smaller maps.
    redim pflag( g.wld.count.faces-1 ) as integer
    redim texinf(g.wld.count.tex_infos-1) as TexInfo

end sub









''::::::::::
'' name: mod_load_faces
''::::::::::
sub mod_load_faces ( _
    g as Game, _
    faces() as Face _
)
    dim f as FILE
    dim mapped as long

    scr_load_stage "faces"

    '' MEM: the draw path reads a face for every face drawn, and EMS would
    '' cost an INT 67h each time. A MEM-backed store needs no slot at all,
    '' so it also cannot collide with the geometry window d_poly maps
    '' between these reads.
    g.wld.store.faces = uglArrNew&( UGL.MEM, len( faces(0) ), g.wld.count.faces, 0 )
    if ( g.wld.store.faces = 0 ) then sys_error "0x0039, no room for the faces"

    '' Hands the descriptor over. NOT ceremony: this is what takes
    '' it out of the far heap's chain, and only BASIC can do that
    '' correctly. Left in, B$FHCompact walks into a descriptor
    '' aimed at memory it does not own and moves it -- the far
    '' heap is then corrupt. The variable still exists afterwards,
    '' which is what uglArrMap binds to.
    erase faces


    if ( fileOpen%( f, "faces.pag", F4READ ) = 0 ) then
        sys_error "0x003A, faces.pag missing"
    end if
    if ( uglArrLoad%( f, g.wld.store.faces ) = 0 ) then
        fileClose f
        sys_error "0x003B, faces.pag short or unreadable"
    end if
    fileClose f

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = uglArrMap&( g.wld.store.faces, faces(), 0 )

    scr_load_step
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
sub mod_load_colormap ( _
    g as Game _
)
    dim f as FILE

    scr_load_stage "colormap"

    dim p as long

    g.wld.cmap.dc = 0
    g.wld.cmap.size = 0

    if ( fileOpen( f, "colmap.bin", F4READ ) = 0 ) then exit sub

    g.wld.cmap.dc = uglNew&( UGL.EMS, UGL.8BIT, 16384, 1 )
    if ( g.wld.cmap.dc <> 0 ) then
        p = uglMapEx&( g.wld.cmap.dc, 0, CM_SLOT )
        if ( p <> 0 ) then
            if ( fileReadH( f, p, 16384 ) = 16384 ) then
                g.wld.cmap.size = 16384
            end if
        end if
    end if

    fileClose f

    if ( g.wld.cmap.size = 0 ) then sys_error "0x0015, colormap would not load"
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
sub mod_load_lightmaps ( _
    g as Game _
)
    scr_load_stage "lightmaps"
    dim f as FILE
    dim got as long

    g.wld.light.atlas = 0
    g.wld.light.size = 0

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
        g.wld.light.size = fileSize( f )
        fileClose f
    end if
    g.wld.light.atlas = uglNewBMPEx( UGL.EMS, UGL.8BIT, "lm.bmp", BMPOPT.NO332 )
    if ( g.wld.light.atlas <> 0 ) then
        g.wld.light.loaded = g.wld.light.size
    else
        g.wld.light.loaded = 0
    end if

    scr_load_step
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
sub mod_load_facevtx ( _
    g as Game, _
    gv_buf() as integer _
)
    dim f as FILE
    dim y as integer
    dim p as long

    scr_load_stage "face vertices"

    if ( fileOpen( f, "fgeom.bin", F4READ ) = 0 ) then
        sys_error "0x0011, fgeom.bin missing"
    end if

    '' 108 as a literal, not GEOM_MAXREC \ 2: an expression bound makes the
    '' array dynamic and therefore zero length until a REDIM, and memCopy
    '' would write a whole record past it
    redim gv_buf(108) as integer

    g.wld.geom.rows = cint( (fileSize&( f ) + GEOM_W - 1) \ GEOM_W )
    g.wld.geom.dc = uglNew&( UGL.EMS, UGL.8BIT, GEOM_W, g.wld.geom.rows )
    if ( g.wld.geom.dc = 0 ) then sys_error "0x0010, no EMS for the geometry store"

    for y = 0 to g.wld.geom.rows-1
        p = uglMapEx&( g.wld.geom.dc, y, PAGE_SLOT )
        if ( p = 0 ) then sys_error "0x0012, geometry store will not map"
        if ( fileReadH( f, p, GEOM_W ) <> GEOM_W ) then
            sys_error "0x0013, fgeom.bin short read"
        end if
    next y

    fileClose f

    scr_load_step
end sub









''::::::::::
'' name: mod_load_leafs
''::::::::::
sub mod_load_leafs ( _
    g as Game _
)
    scr_load_stage "bsp leaves"

    '' r_bsp owns the leaves -- it is the heaviest reader and the only one
    '' that needs the array itself. All the loader passes is the count.
    r_load_leaves g

    scr_load_step
end sub




''::::::::::
'' name: mod_load_marksurfaces
''::::::::::
sub mod_load_marksurfaces ( _
    g as Game _
)
    '' r_bsp owns the list -- it is the only reader. All it needs is how
    '' many bytes the lump holds.
    r_load_lfaces g.wld.file.head.lface.size

    scr_load_step
end sub




''::::::::::
'' name: mod_load_nodes
''::::::::::
sub mod_load_nodes ( _
    g as Game, _
    nodes() as Node _
)
    dim f as FILE
    dim mapped as long

    scr_load_stage "bsp nodes"

    ''
    '' EMS first, conventional only as a fallback. uglArrLoad streams
    '' nodes.pag a page at a time into the mapped window, so the tree is
    '' never resident -- which is the whole point, and why this is not a
    '' BLOAD followed by a copy.
    ''
    '' UGL.MEM, not UGL.EMS, deliberately. The store is windowed either
    '' way -- the same uglArrMap, the same page arithmetic -- but the MEM
    '' path computes a segment where the EMS path issues an INT 67h. That
    '' isolates the two costs: if MEM is fast, what the walk cannot afford
    '' is the remap, not the far call.
    ''
    '' It still gets the tree out of BASIC's far heap, which is what FRE(-1)
    '' measures; memAlloc takes it from DOS (upper memory when there is
    '' room), not from the heap the BSP arrays compete for.
    g.wld.store.nodes = uglArrNew&( UGL.MEM, len( nodes(0) ), g.wld.count.nodes, 0 )
    if ( g.wld.store.nodes = 0 ) then
        g.wld.store.nodes = uglArrNew&( UGL.EMS, len( nodes(0) ), g.wld.count.nodes, PAGE_SLOT )
    end if
    if ( g.wld.store.nodes = 0 ) then sys_error "0x0030, no room for the node tree"

    '' Hands the descriptor over. NOT ceremony: this is what takes
    '' it out of the far heap's chain, and only BASIC can do that
    '' correctly. Left in, B$FHCompact walks into a descriptor
    '' aimed at memory it does not own and moves it -- the far
    '' heap is then corrupt. The variable still exists afterwards,
    '' which is what uglArrMap binds to.
    erase nodes

    '' Hands the descriptor over: this is what takes it out of the far
    '' heap's chain, and only BASIC can do it correctly.

    if ( fileOpen%( f, "nodes.pag", F4READ ) = 0 ) then
        sys_error "0x0031, nodes.pag missing"
    end if
    if ( uglArrLoad%( f, g.wld.store.nodes ) = 0 ) then
        fileClose f
        sys_error "0x0032, nodes.pag short or unreadable"
    end if
    fileClose f

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = uglArrMap&( g.wld.store.nodes, nodes(), 0 )

    scr_load_step
end sub




''::::::::::
'' name: mod_load_planes
''::::::::::
sub mod_load_planes ( planes() as Plane )
    scr_load_stage "planes"
    def seg = varseg( planes(0) )
    bload "planes.bld", varptr( planes(0) )
    def seg

    scr_load_step
end sub




''::::::::::
'' name: mod_load_submodels
''::::::::::
sub mod_load_submodels ( models() as Submodel )
    scr_load_stage "submodels"
    def seg = varseg( models(0) )
    bload "models.bld", varptr( models(0) )
    def seg

    scr_load_step
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
sub mod_load_clipnodes ( _
    g as Game _
)
    scr_load_stage "clip hulls"

    '' pl_move owns the hulls -- it is the only reader -- so it makes the
    '' store and binds its own array. All the loader still knows is how
    '' many there are.
    pl_load_hulls g

    scr_load_step
end sub




''::::::::::
'' name: mod_load_visibility
''::::::::::
sub mod_load_visibility ( _
    g as Game _
)
    dim f as FILE

    scr_load_stage "visibility"

    g.wld.pvs.ptr = 0
    g.wld.pvs.size = 0

    if ( fileOpen( f, "pvs.bin", F4READ ) <> 0 ) then
        g.wld.pvs.size = fileSize&( f )
        if ( g.wld.pvs.size > 0 ) then
            g.wld.pvs.ptr = memAlloc( g.wld.pvs.size )
            if ( g.wld.pvs.ptr <> 0 ) then
                if ( fileReadH( f, g.wld.pvs.ptr, g.wld.pvs.size ) <> g.wld.pvs.size ) then
                    memFree g.wld.pvs.ptr
                    g.wld.pvs.ptr = 0
                    g.wld.pvs.size = 0
                end if
            else
                g.wld.pvs.size = 0
            end if
        end if
        fileClose f
    end if

    if ( g.wld.pvs.ptr = 0 ) then sys_error "0x0014, visibility lump would not load"

    scr_load_step
end sub


''::::::::::
'' name: mod_close
'' desc: Releases the map file. r_tex.bas used to do this at the end of
''       texLoadAll -- the module that opened the file was not the module
''       that closed it, and the handle's lifetime spanned two modules
''       with nothing naming the contract.
''::::::::::
sub mod_close ( _
    g as Game _
)
    close #g.wld.file.handle
    g.wld.file.handle = 0
end sub

''::::::::::
'' name: mod_cm_map( wld )
'' desc: The colormap, mapped, as a far pointer. Mapped per call and never
''       held: CM_SLOT is the depth buffer's, so anything that touched
''       depth in between has already taken it back.
''::::::::::
function mod_cm_map ( _
    g as Game _
) as long
    mod_cm_map = uglMapEx&( g.wld.cmap.dc, 0, CM_SLOT )
end function

''::::::::::
'' name: mod_cm_ready( wld )
'' desc: Whether a full table actually loaded. Callers that can fall back
''       -- hud_shade draws an opaque slab instead -- ask this first.
''::::::::::
function mod_cm_ready ( _
    g as Game _
) as integer
    mod_cm_ready = ( g.wld.cmap.size >= 16384 )
end function

''::::::::::
'' name: mod_cm_bytes( wld )
'' desc: Table size, for the bench report.
''::::::::::
function mod_cm_bytes ( _
    g as Game _
) as long
    mod_cm_bytes = g.wld.cmap.size
end function

''::::::::::
'' name: mod_lm_map
'' desc: One scanline of the luxel atlas, mapped, as a far pointer. The
''       packer keeps a face's whole rect inside one scanline, so a single
''       mapping reaches all of it.
''::::::::::
function mod_lm_map ( _
    g as Game, _
    byval row as integer _
) as long
    mod_lm_map = uglMapEx&( g.wld.light.atlas, row, PAGE_SLOT )
end function

''::::::::::
'' name: mod_lm_bytes( wld ) / mod_lm_got( wld )
'' desc: Atlas size on disk, and how much of it actually loaded, for the
''       bench report.
''::::::::::
function mod_lm_bytes ( _
    g as Game _
) as long
    mod_lm_bytes = g.wld.light.size
end function

function mod_lm_got ( _
    g as Game _
) as long
    mod_lm_got = g.wld.light.loaded
end function

''::::::::::
'' name: mod_geom_map
'' desc: One row of the geometry store, mapped, as a far pointer. The
''       builder keeps a face's whole record inside one row, so the row
''       end is also the end of the mapped window.
''::::::::::
function mod_geom_map ( _
    g as Game, _
    byval row as integer _
) as long
    mod_geom_map = uglMapEx&( g.wld.geom.dc, row, PAGE_SLOT )
end function

''::::::::::
'' name: mod_geom_rows( wld )
'' desc: How many rows the store has, for the bench report.
''::::::::::
function mod_geom_rows ( _
    g as Game _
) as integer
    mod_geom_rows = g.wld.geom.rows
end function

''::::::::::
'' name: mod_pvs_base( wld )
'' desc: Far pointer to the visibility lump. Fixed for the whole run, so
''       callers hoist it rather than asking per leaf.
''::::::::::
function mod_pvs_base ( _
    g as Game _
) as long
    mod_pvs_base = g.wld.pvs.ptr
end function


''::::::::::
'' name: mod_load_world
'' desc: Every lump of the open map, in the order they depend on each other.
''       mod_alloc sizes the arrays from the header first; the stores bind
''       into them after.
''
''       Textures are not here: they are their own load phase, timed
''       separately, and mod_tex.bas owns them.
''::::::::::
sub mod_load_world ( _
    g as Game, _
    faces() as Face, _
    tex_info() as TexInfo, _
    planes() as Plane, _
    nodes() as Node, _
    models() as Submodel, _
    ord() as integer, _
    pflag() as integer, _
    gv() as integer, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    face_mdl() as integer, _
    plat() as PlatEnt _
)
    mod_alloc g, faces(), tex_info(), planes(), nodes(), models(), ord(), pflag()
    sys_mem_mark "bsp_arrays"

    mod_load_faces g, faces()
    mod_load_lightmaps g
    sys_mem_mark "lm_table"

    mod_load_facevtx g, gv()
    mod_load_leafs g
    mod_load_marksurfaces g
    mod_load_nodes g, nodes()
    mod_load_planes planes()
    mod_load_submodels models()
    mod_load_visibility g
    mod_load_clipnodes g
    sys_mem_mark "clip_nodes"

    ent_load_teleports g, models(), brush(), tele(), face_mdl(), plat()

end sub
