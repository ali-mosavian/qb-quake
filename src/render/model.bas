option explicit
''
'' model.bas -- reading the BSP lumps into the renderer's buffers.
''
'' The staging records (fce, nodetmp, leaftmp, planetmp, clptmp) and the
'' counts only this module consumes stay local; the buffers the renderer
'' walks are in qshared.bi as COMMON SHARED.
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
declare function qglArNew ( byval typ as integer, byval elsz as integer, _
                              byval cnt as long, byval slot as integer ) as long
declare function qglArWin ( byval h as long, byval idx as long ) as long
declare function qglMemAlloc ( byval nbytes as long ) as long
declare sub qglMemFree ( byval p as long )
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
''
'' The file layer, qgl's: a plain name or "archive::member", one handle
'' either way. mgl's uar wanted a UAR the caller declared only to pass
'' back.
''
'' flname is NOT byval: VBDOS passes a plain "as string" parameter as a
'' near pointer to its descriptor, which is what the assembly's s:word
'' wants.
''
declare function qglFileOpenBas ( flname as string ) as integer
declare function qglFileSize ( byval h as integer ) as long
declare function qglFileRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglFileClose ( byval h as integer )

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
declare sub mod_load_flat ( _
    flname as string, _
    byval dst as long _
)
declare sub mod_load_planes ( planes() as Plane )
declare sub mod_load_submodels ( models() as Submodel )

''
'' This module's own procedures.
''
declare sub mod_open ( _
    g as Game, _
    models() as Submodel _
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
    plat() as PlatEnt, _
    item() as ItemEnt _
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
declare function mod_pvs_page ( _
    g as Game, _
    byval pg as integer _
) as integer
declare function sb_seg ( byval p as long ) as integer
declare function qglMemAvail ( byval what as integer ) as long
declare function qglGemAlloc ( byval nbytes as long ) as integer
declare function qglGemMap ( byval h as integer, byval pg as integer, _
                             byval slot as integer ) as integer
declare sub qglGemFree ( byval h as integer )

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub r_alloc_pvs ( byval leaf_count as long )
declare sub r_load_portals ( byval leaf_count as long )
declare sub r_load_lfaces ( byval lump_bytes as long )
declare sub ent_load_teleports ( _
    g as Game, _
    models() as Submodel, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    faces() as Face, _
    plat() as PlatEnt, _
    item() as ItemEnt _
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
'' One record of 16,384, which is one EMS page, so a single map reaches
'' the whole table and the rows the builder indexes flat really are
'' contiguous. CM_SLOT is its own window and shares with nothing: qgl's
'' surfaces own slots 0 and 1 (QGL_TEX_SLOT reads, QGL_Z_SLOT and every
'' other qgl write) and everything paged takes turns in 2. This used to
'' say CM_SLOT borrowed the depth buffer's; that stopped being true when
'' depth moved to EMS_WRITEPAGE.
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
    r_load_portals g.wld.count.leaves

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
    dim mapped as long
    dim u as integer
    dim p as long
    dim nbytes as long

    scr_load_stage "faces"

    '' MEM: the draw path reads a face for every face drawn, and EMS would
    '' cost an INT 67h each time. A MEM-backed store needs no slot at all,
    '' so it also cannot collide with the geometry window d_poly maps
    '' between these reads.
    ''
    '' A qgl store, not uglArrLoad. Faces was the first migration because
    '' it is MEM-only: no EMS fallback here, so the hot read path is
    '' unchanged and no access policy had to be decided. Six interleaved
    '' pairs against the mgl version were neutral -- identical min and
    '' max, medians inside one quantisation step -- and the rendered
    '' frame was byte-identical, so the switch that ran the A/B is gone.
    nbytes = clng( g.wld.count.faces ) * len( faces(0) )
    g.wld.store.faces = qglArNew( QGL_AR_MEM, len( faces(0) ), _
                                    clng( g.wld.count.faces ), 0 )
    if ( g.wld.store.faces = 0 ) then sys_error "0x0039, no qgl store for faces"

    '' The block, then the bytes.
    p = qglArWin( g.wld.store.faces, 0 )
    if ( p = 0 ) then sys_error "0x0039, qgl faces store would not map"
    u = qglFileOpenBas( "assets.zip::faces.pag" )
    if ( u = 0 ) then
        sys_error "0x0039, faces.pag would not open"
    end if
    if ( qglFileRead( u, p, nbytes ) <> nbytes ) then
        qglFileClose u
        sys_error "0x0039, faces.pag came up short"
    end if
    qglFileClose u

    '' Hands the descriptor over. NOT ceremony: this is what takes
    '' it out of the far heap's chain, and only BASIC can do that
    '' correctly. Left in, B$FHCompact walks into a descriptor
    '' aimed at memory it does not own and moves it -- the far
    '' heap is then corrupt. The variable still exists afterwards,
    '' which is what qglArMap binds to.
    erase faces

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = qglArMap( g.wld.store.faces, faces(), 0 )

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
    dim u as integer

    scr_load_stage "colormap"

    g.wld.cmap.store = 0
    g.wld.cmap.size = 0

    '' a missing table is not an error -- hud_shade draws opaque instead
    u = qglFileOpenBas( "assets.zip::colmap.bin" )
    if ( u = 0 ) then exit sub
    qglFileClose u

    g.wld.cmap.store = qglArLoadBas&( "assets.zip::colmap.bin", QGL_AR_EMS, 16384, 1&, CM_SLOT )
    if ( g.wld.cmap.store = 0 ) then sys_error "0x0015, colormap would not load"
    g.wld.cmap.size = 16384
end sub



''::::::::::
'' name: mod_load_lightmaps
'' desc: Loads the per-face lightmap table, then the luxels into EMS.
''
''       The table is 16 bytes a face and BLOADs like every other lump. The
''       luxels never could: 71K of them made BASIC fail with 'out of
''       string space' while setmem reported 397K of far heap free. They
''       are now one 8-bit atlas in a qgl EMS store, a row per record --
''       which puts them outside conventional memory entirely rather
''       than merely outside the BASIC heap, and costs no bespoke loader.
''
''       No pointer fixup here: a face's rect is found by mapping its atlas
''       scanline, which sb_build does per build.
''::::::::::
sub mod_load_lightmaps ( _
    g as Game _
)
    scr_load_stage "lightmaps"
    dim u as integer

    g.wld.light.atlas = 0
    g.wld.light.size = 0
    g.wld.light.loaded = 0

    ''
    '' Every luxel in the map, raw rows of LM_ATLAS_W, straight into EMS.
    '' It costs no conventional memory at all. The packed blob it replaces
    '' cost 40K on dm3ish and more on the bigger maps.
    ''
    u = qglFileOpenBas( "assets.zip::lm.bin" )
    if ( u = 0 ) then exit sub
    g.wld.light.size = qglFileSize( u )
    qglFileClose u

    g.wld.light.atlas = qglArLoadBas&( "assets.zip::lm.bin", QGL_AR_EMS, LM_ATLAS_W, _
                                       g.wld.light.size \ LM_ATLAS_W, PAGE_SLOT )
    if ( g.wld.light.atlas <> 0 ) then g.wld.light.loaded = g.wld.light.size

    scr_load_step
end sub




''::::::::::
'' name: mod_load_facevtx
''::::::::::
''
'' Streamed straight into the mapped window, a page at a time, by
'' qglArLoad. There is no conventional-memory staging buffer anywhere in
'' here: the point of the store is that the geometry never lands in low
'' memory, and a loader that read it into an array first would defeat
'' that at the worst possible moment -- while every other buffer is also
'' allocated. mkassets pads the last row, so the member is rows*GEOM_W
'' exactly, which is what the loader demands.
''
sub mod_load_facevtx ( _
    g as Game, _
    gv_buf() as integer _
)
    dim u as integer

    scr_load_stage "face vertices"

    u = qglFileOpenBas( "assets.zip::fgeom.bin" )
    if ( u = 0 ) then
        sys_error "0x0011, fgeom.bin missing"
    end if
    g.wld.geom.rows = cint( qglFileSize( u ) \ GEOM_W )
    qglFileClose u

    '' 108 as a literal, not GEOM_MAXREC \ 2: an expression bound makes the
    '' array dynamic and therefore zero length until a REDIM, and the copy
    '' would write a whole record past it
    redim gv_buf(108) as integer

    g.wld.geom.store = qglArLoadBas&( "assets.zip::fgeom.bin", QGL_AR_EMS, GEOM_W, _
                                      clng( g.wld.geom.rows ), PAGE_SLOT )
    if ( g.wld.geom.store = 0 ) then sys_error "0x0010, the geometry store would not load"

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
        dim mapped as long

    scr_load_stage "bsp nodes"

    ''
    '' EMS first, conventional only as a fallback. qglArLoad streams
    '' nodes.pag a page at a time into the mapped window, so the tree is
    '' never resident -- which is the whole point, and why this is not a
    '' BLOAD followed by a copy.
    ''
    '' QGL_AR_MEM, not QGL_AR_EMS, deliberately. The store is windowed
    '' either way -- the same qglArMap, the same page arithmetic -- but MEM
    '' path computes a segment where the EMS path issues an INT 67h. That
    '' isolates the two costs: if MEM is fast, what the walk cannot afford
    '' is the remap, not the far call.
    ''
    '' It still gets the tree out of BASIC's far heap, which is what FRE(-1)
    '' measures; memAlloc takes it from DOS (upper memory when there is
    '' room), not from the heap the BSP arrays compete for.
    g.wld.store.nodes = qglArLoadBas&( "assets.zip::nodes.pag", QGL_AR_MEM, len( nodes(0) ), _
                                            clng( g.wld.count.nodes ), 0 )
    if ( g.wld.store.nodes = 0 ) then
        g.wld.store.nodes = qglArLoadBas&( "assets.zip::nodes.pag", QGL_AR_EMS, len( nodes(0) ), _
                                                clng( g.wld.count.nodes ), PAGE_SLOT )
    end if
    if ( g.wld.store.nodes = 0 ) then sys_error "0x0030, nodes.pag would not load"

    '' Hands the descriptor over. NOT ceremony: this is what takes
    '' it out of the far heap's chain, and only BASIC can do that
    '' correctly. Left in, B$FHCompact walks into a descriptor
    '' aimed at memory it does not own and moves it -- the far
    '' heap is then corrupt. The variable still exists afterwards,
    '' which is what qglArMap binds to.
    erase nodes

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = qglArMap&( g.wld.store.nodes, nodes(), 0 )

    scr_load_step
end sub




''::::::::::
'' name: mod_load_flat
'' desc: One assets.zip member, whole, to a far destination -- what
''       bload did. The size is the member's own -- the archive
''       carries it, so no caller has to know one.
''::::::::::
sub mod_load_flat ( _
    flname as string, _
    byval dst as long _
)
    dim u as integer
    dim n as long

    u = qglFileOpenBas( flname )
    if ( u = 0 ) then
        sys_error "0x0016, " + flname + " missing"
    end if
    n = qglFileSize( u )
    if ( qglFileRead( u, dst, n ) <> n ) then
        sys_error "0x0017, " + flname + " short read"
    end if
    qglFileClose u
end sub


''::::::::::
'' name: mod_load_planes
''::::::::::
sub mod_load_planes ( planes() as Plane )
    scr_load_stage "planes"
    mod_load_flat "assets.zip::planes.bld", _
        clng( varseg( planes(0) ) ) * 65536& + (clng( varptr( planes(0) ) ) and 65535&)

    scr_load_step
end sub




''::::::::::
'' name: mod_load_submodels
''::::::::::
sub mod_load_submodels ( models() as Submodel )
    scr_load_stage "submodels"
    mod_load_flat "assets.zip::models.bld", _
        clng( varseg( models(0) ) ) * 65536& + (clng( varptr( models(0) ) ) and 65535&)

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
    dim u as integer

    scr_load_stage "visibility"

    dim remain as long, n as long, avail as long
    dim pg as integer, wseg as integer

    g.wld.pvs.ptr = 0
    g.wld.pvs.hnd = 0
    g.wld.pvs.size = 0

    u = qglFileOpenBas( "assets.zip::pvs.bin" )
    if ( u = 0 ) then sys_error "0x0014, visibility lump would not load"
    g.wld.pvs.size = qglFileSize( u )
    '' decided here, not by a refusal: qglMemAlloc answers a DOS refusal
    '' by shrinking BASIC's heap, and that is the memory the map needs
    avail = qglMemAvail( QGL_MEM_LARGEST )
    if ( g.wld.pvs.size > 0 ) then
        if ( avail >= g.wld.pvs.size ) then g.wld.pvs.ptr = qglMemAlloc( g.wld.pvs.size )
    end if
    if ( g.wld.pvs.ptr <> 0 ) then
        if ( qglFileRead( u, g.wld.pvs.ptr, g.wld.pvs.size ) <> g.wld.pvs.size ) then
            qglMemFree g.wld.pvs.ptr
            g.wld.pvs.ptr = 0
        end if
    elseif ( g.wld.pvs.size > 0 ) then
        '' EMS, a page at a time through PAGE_SLOT: 41K of BASIC's heap
        '' on e1m1 otherwise.
        g.wld.pvs.hnd = qglGemAlloc( g.wld.pvs.size )
        remain = g.wld.pvs.size
        pg = 0
        do while ( remain > 0 and g.wld.pvs.hnd <> 0 )
            n = remain
            if ( n > 16384 ) then n = 16384
            wseg = qglGemMap( g.wld.pvs.hnd, pg, PAGE_SLOT )
            if ( wseg = 0 ) then
                qglGemFree g.wld.pvs.hnd
                g.wld.pvs.hnd = 0
            elseif ( qglFileRead( u, clng( wseg ) * 65536&, n ) <> n ) then
                qglGemFree g.wld.pvs.hnd
                g.wld.pvs.hnd = 0
            end if
            remain = remain - n
            pg = pg + 1
        loop
    end if
    qglFileClose u

    if ( g.wld.pvs.ptr = 0 and g.wld.pvs.hnd = 0 ) then sys_error "0x0014, visibility lump would not load"

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
''       held: CM_SLOT is its own (see the block comment above), but a
''       pointer kept across anything that could remap is the bug class
''       this codebase keeps hitting, so it is re-taken instead.
''::::::::::
function mod_cm_map ( _
    g as Game _
) as long
    mod_cm_map = qglArWin( g.wld.cmap.store, 0& )
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
    mod_lm_map = qglArWin( g.wld.light.atlas, clng( row ) )
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
    mod_geom_map = qglArWin( g.wld.geom.store, clng( row ) )
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
'' name: mod_pvs_page
'' desc: The segment holding 16K page pg of the visibility lump: paragraph
''       arithmetic on the conventional block, or the EMS window mapped.
''::::::::::
function mod_pvs_page ( _
    g as Game, _
    byval pg as integer _
) as integer
    dim s as long

    if ( g.wld.pvs.hnd <> 0 ) then
        mod_pvs_page = qglGemMap( g.wld.pvs.hnd, pg, PAGE_SLOT )
        exit function
    end if
    s = ( clng( sb_seg( g.wld.pvs.ptr ) ) and 65535& ) + pg * 1024&
    if ( s > 32767 ) then s = s - 65536&
    mod_pvs_page = cint( s )
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
    plat() as PlatEnt, _
    item() as ItemEnt _
)
    mod_alloc g, faces(), tex_info(), planes(), nodes(), models(), ord(), pflag()
    sys_mem_mark "bsp_arrays"

    mod_load_faces g, faces()
    mod_load_lightmaps g
    sys_mem_mark "lm_table"

    mod_load_facevtx g, gv()
    sys_mem_mark "facevtx"
    mod_load_leafs g
    sys_mem_mark "leafs"
    mod_load_marksurfaces g
    sys_mem_mark "marksurf"
    mod_load_nodes g, nodes()
    sys_mem_mark "nodes"
    mod_load_planes planes()
    sys_mem_mark "planes"
    mod_load_submodels models()
    mod_load_visibility g
    sys_mem_mark "vis"
    mod_load_clipnodes g
    sys_mem_mark "clip_nodes"

    ent_load_teleports g, models(), brush(), tele(), faces(), plat(), item()

end sub
