''
'' The map: what mod_* loads, and what the renderer walks.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' The loading screen advances by one step per lump reader plus the two
'' texture passes. Fourteen sites used to spell the divisor as a literal 14.0
'' and had to agree with each other by hand.
''
'' 14 since the vertex, edge and surfedge readers became one: mkassets.py
'' resolves the whole mesh into per-face corner lists, so there is a single
'' lump, and it is read into EMS rather than into an array.
''
const LOAD_STEPS = 14

type MapState
    head        as header       '' the on-disk lump directory
    file        as integer      '' open handle, owned by model.bas
    numtex      as long         '' counts, all derived from the header
    tri_count   as long
    vtx_count   as long
    edg_count   as long
    lef_count   as long
    nds_count   as long
    texi_count  as long
    clp_count   as long         '' collision hull nodes
    mdl_count   as long         '' submodels: the world is 0, brush entities
                                '' such as doors and teleport triggers follow
end type

''
'' The loading screen exists only between mod_open and vid_init, and the map
'' does not own it.
''
type LoadState
    pct         as single       '' 0..100, advanced LOAD_STEPS times
    dc          as long         '' the temporary 320x200 loading DC
end type

common shared /map_s/ wld as MapState
common shared /map_s/ ldr as LoadState

''
'' Written by model.bas, walked by the renderer. A TYPE cannot contain an
'' array, so these stay loose.
''
''
'' ===================================================================
'' /surf/ -- THE RASTERISER'S PIPELINE
''
'' Read by d_poly and d_surf, plus one line in main. Those two modules
'' are one pipeline split across two files and this block is the seam
'' between them.
''
'' gv_buf is the one entry that could still leave: it is not map data
'' but a staging row holding the face currently being drawn, which
'' d_poly fills and d_surf reads. That is a handoff, not shared state.
'' ===================================================================
''
common shared /surf/ tri_buffer() as face2
'' The leaves are NOT here any more -- r_bsp.bas owns them and loads
'' them; pl_move asks rb_leaf_contents for the one field it wants.

''
'' The geometry store. Every face's corner positions written out flat, in
'' order, in one EMS dc -- so the vertex array and the surfedge list are
'' not in conventional memory at all, and neither is the edge table that
'' used to join them.
''
'' The renderer's inner loop only ever asked the mesh one question: what
'' are this face's corners? An indexed mesh cannot answer without both
'' tables resident. Flat, it streams: one uglMapEx and one memCopy per
'' DRAWN face, and the working set is a single face -- no cache, no
'' eviction, no prefetch, and no cliff when the view opens out.
''
'' GEOM_W must match mkassets.py's: it is the row uglMapEx maps, and the
'' builder guarantees no record straddles one.
''
'' A record is a corner count, then the 16-byte lightmap header, then the
'' corners -- so gv_buf(0) is nvtx, gv_buf(1..8) the header, and the
'' positions start at gv_buf(9).
''
''
'' THE SHARED PAGING WINDOW.
''
'' EMS gives four physical slots. uglBuildSurf takes 0 and 1 for its own
'' source and destination, the colormap holds 3 for the whole run, and
'' everything else that needs a window takes turns in 2.
''
'' "Takes turns" is safe because every user maps it immediately before
'' reading and copies what it wants straight out: the geometry row is
'' memCopy'd into gv_buf, the luxel scanline is read inside sb_build, and
'' the node/clip/leaf stores only touch it on the EMS fallback path that
'' runs when conventional memory was too small to hold them. Nothing
'' holds the window across a call that could remap it.
''
'' This was four constants -- GEOM_SLOT, LM_SLOT, NODE_SLOT, CLIP_SLOT --
'' in three files, all equal to 2. Four names for one physical slot hid
'' exactly the property that has to be reasoned about.
''
const PAGE_SLOT = 2

const GEOM_W = 8192
''
'' The BSP nodes take turns in PAGE_SLOT too. emsMapEx consults the
'' EMS layer's record of what a slot holds before remapping, so the
'' alternation costs a compare when the page has not moved. The walk
'' finishes before drawing starts, so it is one remap per ordered node.
''
'' only used if MEM refuses; shares the same physical page
const GEOM_MAXVTX = 33
const GEOM_LMOFS = 1            '' gv_buf index of the lightmap header
const GEOM_VTX0  = 9            '' gv_buf index of the first corner
const GEOM_MAXREC = 18 + GEOM_MAXVTX * 6

'' The geometry store is NOT here any more -- model.bas owns it and
'' PAGE_SLOT with it; d_poly and d_surf ask for a row through geom_map.

''
'' The face record most recently fetched by d_draw_faces. Shared because
'' sb_build wants the lightmap header out of it and must NOT go back to
'' the window it came from: PAGE_SLOT is not still holding that page by
'' the time a build runs -- measured, it reads zeros -- and a 0x0 luxel
'' grid hangs the builder. One fetch per face, one reader of the copy.
''
common shared /surf/ gv_buf() as integer
''
'' The BSP nodes live in EMS, not in BASIC's heap. nds_buffer is a ONE
'' ELEMENT stub whose descriptor uglArrNew1D takes over; nodes.pag streams
'' in through uglArrLoad, 16k at a time, straight into the mapped window,
'' so the tree never occupies conventional memory at any point -- not even
'' while loading. 60,500 bytes of it on e1m1.
''
'' Every nds_buffer(i) must be preceded by uglArrMap for that i. One map
'' per node visit covers all of its fields: the store pads pages, so a
'' record never straddles one.
''
'' The node store's EMS fallback takes PAGE_SLOT as well. Safe because
'' emsMapEx consults the EMS layer's own record of what a slot holds
'' before it remaps -- so alternating between node pages and geometry
'' pages costs a compare when the page is already there, and a real remap
'' only when it genuinely differs. The walk finishes before drawing
'' starts, so the alternation is one per ordered node, not per face.
''
''
'' ===================================================================
'' /world/ -- THE BSP ITSELF
''
'' Read by r_bsp, ent, pl_move and d_poly: rendering, physics and
'' entities all ask the same geometry the same questions, and all of it
'' is subscripted inside loops. An accessor would give up the native
'' subscript that is the whole reason these are flat stores, and
'' ownership needs a single reader, which none of them has.
''
'' This is the residue of the de-globalization, not a leftover of it:
'' shared because the data genuinely is.
'' ===================================================================
''
common shared /world/ h_nds as long
common shared /world/ mdl_buffer() as model, pln_buffer() as plane2, nds_buffer() as nodeb
''
'' lfc_buffer and pvs_buffer_b are NOT here any more. r_bsp.bas is their
'' only run-time reader; they looked shared only because model.bas loaded
'' them, so r_bsp loads them itself now.
''
common shared /surf/ order_list() as integer
''
'' The compressed visibility lump, in a memAlloc'd block rather than an
'' array. It is walked once per frame -- and only when the camera changes
'' leaf -- by a PEEK loop over a byte offset, so it never wanted to be an
'' array of integers in the first place; nothing indexes it. 8K on dm3ish
'' and 40K on e1m1, which is the largest single item on that map.
''
'' The visibility lump is NOT here any more. model.bas allocates it and
'' hands out its base through pvs_base; pvs_size never left that module
'' at all, so it needs no accessor.
common shared /surf/ tex_inf_buff() as texinfo2, poly_flag() as integer

''
'' The collision hulls. Separate trees from the render nodes: same planes,
'' different topology, expanded by the player's bounding box so a point trace
'' through them is equivalent to a box trace through the world.
''
''
'' The collision hulls are NOT here any more. pl_move.bas owns them:
'' it is the only code that reads them, so it declares the array, the
'' handle, and the loader. They were global for one reason -- an array
'' has to be visible where it is indexed and REDIM forces module level
'' -- and uglArr's split of create-from-bind removes it.
''
''
'' The leaves, paged out of the far heap. That heap is the FRAGMENTED one
'' -- FRE(-1) reports the largest free block, not the total -- so moving a
'' 34K array out of it is worth more than the byte count suggests: what it
'' buys is a bigger contiguous hole for the allocations that follow, which
'' is what actually fails first.
''
'' The faces. 55,160 bytes on e1m1, the largest single item left.
common shared /surf/ h_tri as long

''
'' Lightmaps. The luxels are one 8-bit atlas in a single EMS dc, loaded by
'' uglNewBMPEx exactly as the textures are -- so they cost no conventional
'' memory at all, where the old packed blob cost 40K on dm3ish and more on
'' bigger maps. A face's rect is fetched with one uglMapEx into PAGE_SLOT,
'' which the atlas packer guarantees is a single page.
''
'' The per-face placement table is not a block of its own: it rides in
'' each face's geometry record, so one mapping and one copy fetch the
'' corners and the lightmap placement together. It used to be 36,688 bytes
'' of upper memory on dm3ish -- and 88,256 on e1m1, where it does not fit
'' up there and took conventional memory instead, which is what stopped
'' that map loading.
''
'' The atlas handle is NOT here any more. model.bas loads it and owns
'' PAGE_SLOT with it; sb_build asks for a scanline through lm_map rather
'' than mapping a slot it does not own.
''
'' The depth buffer. World faces write through it without testing -- the
'' BSP walk already hands them over front to back, so a test would only
'' ever agree with the order they arrive in. Brush entities (doors, plats)
'' come afterwards and DO test, because nothing about their order relates
'' to the world they move through.
''
''
'' A memory trace, for working out where conventional memory goes. Each
'' entry is a named point in startup with two numbers: memAvail, which is
'' the largest free DOS block, and FRE(-1), the largest free block in
'' BASIC's far heap. Both are needed. The heap is taken from DOS in one
'' bite at startup, so a REDIM costs FRE and memAvail does not move --
'' which is exactly what makes the BSP arrays invisible to a DOS-side
'' measurement. The bench report dumps both as deltas. Costs 21 longs and is worth having permanently: the
'' answer changes every time a buffer moves in or out of EMS, and
'' reasoning about it from struct sizes gets the answer wrong.
''
'' The marks themselves live in sys.bas -- it is the only writer, and the
'' only other module that wants them is main.bas, which reads them back
'' through sys_mem_count/tag/val/fre to format its two reports. Keeping the
'' formatting there and the storage here is the split that matters; a shared
'' array was never needed for it.
const MEM_MARKS = 20

'' The depth buffer is NOT here any more -- main.bas creates it and
'' d_poly asks z_on whether depth is available.
''
'' The colormap: 64 light levels x 256 colours, in a memAlloc'd block.
''
'' It used to be a BASIC array on the grounds that a 16K memAlloc lands in
'' an upper memory block once low memory is tight, and that merely holding
'' that block wedged the program inside vid_init. That is no longer where
'' the evidence points: the visibility lump lands in upper memory on every
'' run and nothing wedges. The difference was when the block was taken,
'' not where it landed -- this one is allocated AFTER the mode switch,
'' which is what vid_init was short of memory for.
''
'' Nothing here needs an array. BASIC never indexes it; both readers want
'' a far pointer, one for uglBuildSurf and one for uglShadeRect.
''
'' It lives in EMS rather than in a memAlloc'd block. memAlloc DOES place
'' a block in upper memory -- the visibility lump lands there -- but there
'' is only so much of it, and by the time the colormap loads the 16K no
'' longer fits: measured, it came back out of conventional memory and cost
'' exactly what the array had.
''
'' The colormap is NOT here any more. model.bas loads it and owns the
'' dc, the size and CM_SLOT; d_surf and screen ask for it through
'' cm_map/cm_ready rather than mapping a slot they do not own.
''
''
'' Surface cache state. In COMMON rather than d_surf.bas's own DIM SHARED
'' because DIM SHARED is scoped to the module that writes it, and the
'' renderer and the bench report both read these.
''
'' The surface cache is NOT here any more -- none of it. d_surf.bas keeps
'' the slot table, the generation and the ready flag; d_poly asks sc_held
'' which mip a face already has cached, and sc_ready whether there is a
'' cache at all.
''
'' The counters are NOT here any more. d_surf.bas keeps them and hands
'' out a scstat snapshot; screen.bas and main.bas read that instead of
'' nine shared longs, and the per-frame roll that used to live in the
'' HUD went back to the cache as sc_frame_end.
''
