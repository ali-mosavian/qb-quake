option explicit
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'ems.bi'
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

''
'' d_surf.bas -- the surface cache: where a face's texture and its lightmap,
'' already combined, wait to be drawn.
''
'' A pool of EMS DCs, one per cached surface, and the shape of that is
'' dictated by the filler that has to read them. 8plxtp derives its texel
'' addressing from the DC itself:
''
''     bsf  cx, gs:[DC.xRes]          shift = log2(width)
''     mov  ax, gs:[DC.xRes] : dec ax u mask = width-1
''     mov  bx, gs:[DC.yRes] : dec bx
''     shl  bx, cl                    v mask = (height-1) << shift
''
'' and reaches texels with ds:[bx+si+base] in 16-bit registers, so the width
'' and height must be powers of two -- the masks are dim-1.
''
'' The binding limit is tighter than those 16 bits though. The filler calls
'' rdAccess exactly once, before the span loop, and never again:
''
''     call ul$dctTB[bx].rdAccess     ds:si-> tex
''
'' and for an EMS DC that is a single EMS_MAP of one logical page. One page
'' is 16K. Anything past it is simply never mapped, so a cached surface has
'' to fit 16,384 bytes entire -- 128x128, or 256x64, and no more. 224x224
'' would pad to 65,536 and read garbage from its second page onward.
''
'' That is a per-face mip floor, not a global one: a face is cached at the
'' finest mip whose padded surface still fits a page. On dm3ish 2,008 of the
'' 2,204 lit faces make that at mip 0 and only 196 have to drop to mip 1,
'' and those are the physically largest, which is where half resolution is
'' least visible.
''
'' The padding is never sampled. Surface-local u,v stay inside the real
'' extents, so the wrap masks never fire; the rounding costs about 30% of
'' the 625K working set, which is nothing against the megabytes EMS has.
''
'' DCs are pooled by size class and recycled rather than deleted, because a
'' miss should cost a build, not a uglNew. A flush hands every DC back to
'' its class and bumps the generation, which is what makes every slot stale
'' at once.
''

const SC_MINSH  = 4             '' 16, the smallest class
const SC_MAXSH  = 8             '' 256 on one axis, if the other stays small
const SC_MAXSUM = 14            '' 2^a * 2^b <= 16384: one EMS page, which is
                                '' all a single rdAccess brings in
const SC_NCLS   = 25            '' (SC_MAXSH-SC_MINSH+1) squared
''
'' How many bytes of surfaces to keep. This is EMS, and EMS is the one
'' thing here there is plenty of -- what used to bound the cache was the
'' conventional memory each surface's DC needed for its scanline table,
'' and surfaces no longer have DCs. dm3ish's whole working set is ~640K,
'' so 256 pages is deliberately far past that, room for bigger maps and
'' repeated evictions on a long walk.
''
'' 256 pages is not a size someone chose -- it is the hard ceiling for any
'' EMS DC. ems_New (mgl/src/dct/dctems.asm) packs a scanline's logical
'' page into the ONE BYTE at DC_addrTB's dh position, incremented with
'' "adc dh, 0" and no overflow check. A 257th page wraps dh back to 0 and
'' silently aliases page 0 -- verified on target: a fresh fully-isolated
'' fresh DC scanned row by row is byte-perfect through exactly 256 rows
'' and corrupts on the 257th, every time. Do not raise SC_PAGES past 256;
'' a second store is the only way to hold more than 4 MB of surfaces.
''
''
'' How many surfaces may be resident at once. dm3ish settles at ~230 and a
'' long walk reached 314, so 512 is real headroom -- and it is a HARD bound,
'' which the bump allocator never had: past it the LRU evicts instead of the
'' store filling. 10 bytes each, so the whole table is 5 KB.
''
const SC_NBLK   = 1024
const SC_GRAN   = 256            '' smallest class, 16x16: the offset unit

''
'' Reclaim is keyed on a block's SIZE, not on its class shape. The 25
'' classes are only 7 distinct byte sizes -- 2^a * 2^b is 2^(a+b) and a+b
'' runs 8..14 -- and a 4096-byte block serves (4,8), (5,7), (6,6), (7,5)
'' and (8,4) identically: same bytes, same alignment. Pooling by size
'' instead of by shape turns 25 pools into 7, which is most of what stops
'' one class starving while another holds the store.
''
'' Order o means 2^(o+SC_MINORD) bytes, so o is 0..6 and a block spans
'' 2^o granules. Everything below is a buddy allocator over that: split a
'' larger free block when a small one is wanted, and on free, merge with
'' the buddy at gran XOR 2^o so the large sizes can come back.
''
const SC_MINORD = 8              '' log2(SC_GRAN)
const SC_NORD   = 7              '' SC_MAXSUM - SC_MINORD + 1

const SC_PGBYTES = 16384         '' one EMS page: the widest bps allowed
const SC_PAGES   = 256           '' the max ANY EMS DC can be -- see above
const SC_STORE#  = 4194304#      '' 256 * 16384

''
'' The physical page uglMapEx puts the luxel atlas in. Slots 0 and 1 are
'' where uglBuildSurf's own rdAccess/wrAccess land the texture and the
'' destination surface, so the atlas takes 2 and survives the whole build.
''
''
'' Atlas width, mirroring LM_ATLAS_W in tools/mkassets.py -- the two move
'' together, the same rule the .bld lumps live by. A face's luxel rect is
'' packed into a power-of-two slot aligned to its own size, so it never
'' crosses one scanline and one uglMapEx reaches all of it.
''
'' 8192 is also uglbmp.asm's BMP_MAX_BPS, the widest scanline that loader
'' accepts.
''
const LM_ATLAS_W = 8192

''
'' One luxel, for faces the compiler left unlit. DIM SHARED rather than a
'' literal because the builder wants an address to read it from.
''
'$static
dim shared lm_flat(0) as integer

''
'' The surface store: one big DC holding every cached surface's bytes,
'' which surfaces are bump-allocated inside. It is shaped 16384 wide so
'' that its own scanline table stays small -- see sc_store_open.
''
'' Nothing else here is a DC. A surface gets a view instead: one per size
'' class, re-aimed at the surface's offset before it is built or drawn.
'' uglNewView/uglSetView do the aiming; see their note in ugl.bi for why a
'' view costs so much less than a DC of its own.
''
''
'' THE CACHE COUNTERS. Owned here, not in COMMON: this module and d_poly
'' are the only writers, and the two readers want a picture of the cache,
'' not nine separate variables. sc_stats gives them one.
''
dim shared sc_made as integer
dim shared sc_flushes as long
dim shared sc_peak as long
dim shared sc_hits as integer
dim shared sc_builds as integer
dim shared sc_bpeak as integer
dim shared sc_live as long
dim shared sc_evict as long
dim shared sc_tbuilds as long

dim shared sc_hnd as long               '' the DC that owns every surface's bytes
dim shared sc_next as long              '' bump pointer within it
dim shared sc_cap as long               '' how big it is

''
'' The block table. One entry per surface actually resident, NOT per face --
'' 2,293 faces share at most SC_NBLK blocks, and the far heap has no room to
'' spend on the difference. Everything the LRU needs hangs off here.
''
'' The offset is kept in 256-byte granules so it fits an integer: 256 is the
'' smallest class (16x16), so every block is a whole number of them, and
'' 4 MB / 256 is 16,384 which is inside int16.
''
'' '$DYNAMIC, like everything else here: '$STATIC would put these in
'' DGROUP, which is shared with BASIC's stack and string space and has none
'' to spare -- see sc_desc's note directly below.
'$dynamic
dim shared sc_lhead() as integer        '' per-ORDER LRU of owned blocks, -1
dim shared sc_ltail() as integer        '' empty. Head is least recently used.
dim shared sc_fhead() as integer        '' per-ORDER free blocks, via sc_bnext
dim shared sc_rfree as integer          '' recycled block records, via sc_bnext
dim shared sc_bgrn() as integer         '' block offset / SC_GRAN
dim shared sc_bord() as integer         '' size order: 2^(o+SC_MINORD) bytes
dim shared sc_bown() as integer         '' owning face, -1 if none
dim shared sc_bprev() as integer        '' the class's LRU chain
dim shared sc_bnext() as integer
dim shared sc_bcnt as integer           '' blocks made so far
'$dynamic
'' one drawing DC per size class. '$DYNAMIC, so the array lands in the far
'' heap rather than DGROUP -- DGROUP is shared with BASIC's stack and string
'' space here and has no room to spare.
dim shared sc_desc() as long

''::::::::::
'' name: sc_mipfloor
'' desc: Finest mip at which this face's surface still fits a single EMS
''       page. The renderer takes the coarser of this and its own
''       distance-based choice.
''::::::::::
function sc_mipfloor% ( byval extw as integer, byval exth as integer )
    dim m as integer
    dim w as integer, h as integer

    for m = 0 to 3
        w = extw \ (2 ^ m)
        h = exth \ (2 ^ m)
        if ( w < 1 ) then w = 1
        if ( h < 1 ) then h = 1
        if ( sc_shift%(w) + sc_shift%(h) <= SC_MAXSUM ) then
            sc_mipfloor% = m
            exit function
        end if
    next m
    sc_mipfloor% = 3
end function

''::::::::::
'' name: sc_shift
'' desc: Smallest power-of-two shift that covers v, clamped to the classes
''       the filler can address.
''::::::::::
function sc_shift% ( byval v as integer )
    dim s as integer
    dim p as integer

    s = SC_MINSH
    p = 16
    while ( p < v and s < SC_MAXSH )
        p = p * 2
        s = s + 1
    wend
    sc_shift% = s
end function

''::::::::::
'' name: sc_brec / sc_bput
'' desc: Block records, recycled. A merge consumes one record (two blocks
''       become one), a split produces one, so the count churns and must
''       not just walk sc_bcnt upward forever.
''::::::::::
function sc_brec% ( )
    dim b as integer

    if ( sc_rfree >= 0 ) then
        b = sc_rfree
        sc_rfree = sc_bnext(b)
        sc_brec% = b
        exit function
    end if
    if ( sc_bcnt < SC_NBLK ) then
        sc_brec% = sc_bcnt
        sc_bcnt = sc_bcnt + 1
        exit function
    end if
    sc_brec% = -1
end function

sub sc_bput ( byval b as integer )
    sc_bnext(b) = sc_rfree
    sc_rfree = b
end sub

''::::::::::
'' name: sc_fpush / sc_fpop / sc_ftake
'' desc: The per-order free lists, singly linked through sc_bnext. sc_ftake
''       pulls out one specific granule rather than the head -- that is how
''       a merge finds its buddy, and the lists are short enough that a
''       walk costs nothing.
''::::::::::
sub sc_fpush ( byval b as integer )
    sc_bown(b) = -1
    sc_bnext(b) = sc_fhead( sc_bord(b) )
    sc_fhead( sc_bord(b) ) = b
end sub

function sc_fpop% ( byval ord as integer )
    dim b as integer

    b = sc_fhead(ord)
    if ( b >= 0 ) then sc_fhead(ord) = sc_bnext(b)
    sc_fpop% = b
end function

function sc_ftake% ( byval ord as integer, byval gran as integer )
    dim b as integer, p as integer

    b = sc_fhead(ord)
    p = -1
    while ( b >= 0 )
        if ( sc_bgrn(b) = gran ) then
            if ( p >= 0 ) then sc_bnext(p) = sc_bnext(b) else sc_fhead(ord) = sc_bnext(b)
            sc_ftake% = b
            exit function
        end if
        p = b
        b = sc_bnext(b)
    wend
    sc_ftake% = -1
end function

''::::::::::
'' name: sc_bfree
'' desc: Hands a block back, merging with its buddy for as long as the
''       buddy is also free. The buddy of a block of order o sits at
''       gran XOR 2^o -- the two halves of an aligned 2^(o+1) block differ
''       in exactly that bit -- and the merged block keeps the lower
''       address, which is what keeps it aligned to its new, larger size.
''
''       Without this the store silently sorts itself into small free
''       blocks and can never satisfy a large one again.
''::::::::::
sub sc_bfree ( byval blk as integer )
    dim b as integer, bud as integer, ord as integer, g as integer
    dim more as integer

    b = blk
    sc_bown(b) = -1
    ord = sc_bord(b)
    more = -1
    '' WHILE/WEND has no EXIT in this dialect, hence the flag
    while ( more and ord < SC_NORD - 1 )
        g = sc_bgrn(b) xor cint( 2 ^ ord )
        bud = sc_ftake%( ord, g )
        if ( bud < 0 ) then
            more = 0
        else
            '' the merged block is the lower of the two, one order bigger,
            '' which is what keeps it aligned to its new size
            if ( sc_bgrn(bud) < sc_bgrn(b) ) then
                sc_bput b
                b = bud
            else
                sc_bput bud
            end if
            ord = ord + 1
            sc_bord(b) = ord
        end if
    wend
    sc_fpush b
end sub

''::::::::::
'' name: sc_bsplit
'' desc: A free block of exactly this order, made by halving a bigger one
''       repeatedly. -1 if nothing larger is free. The upper half of each
''       split goes on its own free list, so nothing is lost.
''::::::::::
function sc_bsplit% ( byval ord as integer )
    dim j as integer, b as integer, h as integer

    for j = ord + 1 to SC_NORD - 1
        b = sc_fpop%( j )
        if ( b >= 0 ) then
            while ( sc_bord(b) > ord )
                h = sc_brec%
                if ( h < 0 ) then          '' no record to hold the half
                    sc_fpush b
                    sc_bsplit% = -1
                    exit function
                end if
                sc_bord(b) = sc_bord(b) - 1
                sc_bgrn(h) = sc_bgrn(b) + cint( 2 ^ sc_bord(b) )
                sc_bord(h) = sc_bord(b)
                sc_bprev(h) = -1
                sc_fpush h
            wend
            sc_bsplit% = b
            exit function
        end if
    next j
    sc_bsplit% = -1
end function

''::::::::::
'' name: sc_grab
'' desc: Bump-allocates a surface's bytes. Aligned to its own size, which
''       keeps it inside one 16K logical page: the fillers map a single page
''       and then address the texture flat, so a surface that straddled two
''       would read garbage past the seam. Every size here is a power of two
''       that divides the page, so aligning to it is enough. -1 when full.
''::::::::::
function sc_grab& ( byval sz as long )
    dim o as long

    o = sc_next
    if ( (o mod sz) <> 0 ) then o = o + (sz - (o mod sz))
    if ( o + sz > sc_cap ) then
        sc_grab& = -1
        exit function
    end if
    sc_next = o + sz
    sc_grab& = o
end function

''::::::::::
'' name: sc_lru_unlink / sc_lru_touch
'' desc: The LRU list, both ends O(1). A face is in its class's list exactly
''       while it owns a block, which .ofs >= 0 is the test for -- unlinking
''       one that is not in a list would corrupt the head or the tail.
''::::::::::
sub sc_lru_unlink ( byval b as integer )
    dim c as integer, p as integer, n as integer

    if ( b < 0 ) then exit sub
    c = sc_bord(b)
    p = sc_bprev(b)
    n = sc_bnext(b)
    ''
    '' Existing is not the same as being IN the list: a block just made has
    '' no neighbours yet. Without this test its first link takes the "I am
    '' both ends" branch and clears the class's head and tail, stranding
    '' everything already chained there.
    ''
    if ( p < 0 and n < 0 and sc_lhead(c) <> b ) then exit sub
    if ( p >= 0 ) then sc_bnext(p) = n else sc_lhead(c) = n
    if ( n >= 0 ) then sc_bprev(n) = p else sc_ltail(c) = p
    sc_bprev(b) = -1
    sc_bnext(b) = -1
end sub

''
'' Move to the most-recent end. A cache HIT calls this too -- that is the
'' whole difference between LRU and the bump-and-flush it replaces.
''
sub sc_lru_touch ( byval b as integer )
    dim c as integer, t as integer

    if ( b < 0 ) then exit sub
    c = sc_bord(b)
    if ( sc_ltail(c) = b ) then exit sub         '' already the most recent
    sc_lru_unlink b
    t = sc_ltail(c)
    sc_bprev(b) = t
    sc_bnext(b) = -1
    if ( t >= 0 ) then sc_bnext(t) = b else sc_lhead(c) = b
    sc_ltail(c) = b
end sub

''::::::::::
'' name: sc_init
'' desc: Empties the pool. DCs are made on demand, so nothing is claimed
''       here beyond the bookkeeping.
''::::::::::
function sc_init% ( )
    dim i as integer, j as integer

    sc_gen = 1
    sc_flushes = 0
    sc_peak = 0
    sc_made = 0
    sc_hits = 0
    sc_builds = 0
    sc_bpeak = 0
    sc_live = 0
    sc_evict = 0
    sc_tbuilds = 0

    redim sc_slot(wld.tri_count-1) as scslot
    redim sc_desc(SC_NCLS-1) as long

    redim sc_lhead(SC_NORD-1) as integer
    redim sc_ltail(SC_NORD-1) as integer
    redim sc_fhead(SC_NORD-1) as integer
    redim sc_bgrn(SC_NBLK-1) as integer
    redim sc_bord(SC_NBLK-1) as integer
    redim sc_bown(SC_NBLK-1) as integer
    redim sc_bprev(SC_NBLK-1) as integer
    redim sc_bnext(SC_NBLK-1) as integer
    sc_bcnt = 0

    for i = 0 to SC_NCLS-1
        sc_desc(i) = 0
    next i
    for i = 0 to SC_NORD-1
        sc_lhead(i) = -1
        sc_ltail(i) = -1
        sc_fhead(i) = -1
    next i
    sc_rfree = -1
    ''
    '' REDIM zeroes, and 0 is a perfectly good block index -- "no block"
    '' has to be spelled out or every face would claim to own the first
    '' surface in the store.
    ''
    for i = 0 to wld.tri_count-1
        sc_slot(i).blk = -1
    next i

    sc_hnd  = 0
    sc_next = 0
    sc_cap  = 0

    if ( emsCheck% = 0 ) then
        sc_ok = 0
        sc_init% = 0
        exit function
    end if

    ''
    '' One block for every surface. It is only bytes -- no DC, so no
    '' scanline table and no conventional memory at all.
    ''
    ''
    '' The store itself is NOT claimed here. sc_init runs before vid_init,
    '' which needs a sizeable block of its own and wedges with no error if
    '' it is short -- the same trap the shade table is loaded late to dodge.
    '' Nothing needs a surface until the first one is built, so the handle
    '' is taken then. See sc_store_open.
    ''
    sc_ok = -1
    sc_init% = -1
end function

''::::::::::
'' name: sc_store_open
'' desc: Claims the store DC, on first use. Deliberately not in sc_init --
''       see the note there.
''::::::::::
function sc_store_open% ( )
    if ( sc_hnd <> 0 ) then
        sc_store_open% = -1
        exit function
    end if
    ''
    '' Shaped so its own scanline table stays tiny. bps is capped at one EMS
    '' page, so a 16384-wide DC is exactly one page per scanline: 1.5 MB of
    '' store costs 96 entries, 384 bytes. Shape it 128 wide instead and the
    '' parent's own table would be 49K, which is the very cost being dodged.
    ''
    sc_hnd = uglNew&( UGL.EMS, UGL.8BIT, SC_PGBYTES, SC_PAGES )
    if ( sc_hnd = 0 ) then
        sc_cap = 0
        sc_store_open% = 0
        exit function
    end if
    sc_cap = SC_STORE#
    sc_next = 0
    sc_store_open% = -1
end function

''::::::::::
'' name: sc_flush
'' desc: Every cached surface becomes a miss and every DC goes back to its
''       class. The DCs themselves are kept -- they cost EMS, not
''       correctness, and making them again is the expensive part.
''::::::::::
sub sc_flush
    dim i as integer

    sc_next = 0
    sc_gen = sc_gen + 1
    if ( sc_gen > 16000 ) then sc_gen = 1
    sc_flushes = sc_flushes + 1
    '' a flush is a mass eviction: every surface in the store at once
    sc_evict = sc_evict + sc_live
    sc_live = 0

    for i = 0 to SC_NORD-1
        sc_lhead(i) = -1
        sc_ltail(i) = -1
        sc_fhead(i) = -1
    next i
    sc_rfree = -1
    for i = 0 to wld.tri_count-1
        sc_slot(i).blk = -1
    next i
    sc_bcnt = 0
end sub

''::::::::::
'' name: sc_find
'' desc: The DC holding this face's surface, or 0 if it has to be built.
''       A mip other than the cached one counts as a miss.
''::::::::::
function sc_find& ( byval face as integer, byval mip as integer, _
                    byval w as integer, byval h as integer )
    dim dc as long
    dim a as integer, b as integer, vcls as integer

    if ( sc_ok = 0 ) then
        sc_find& = 0
        exit function
    end if
    if ( sc_slot(face).blk < 0 ) then
        sc_find& = 0
        exit function
    end if
    if ( sc_slot(face).tag <> sc_gen * 4 + mip ) then
        sc_find& = 0
        exit function
    end if
    ''
    '' The view is the CURRENT mip's shape, which is not the block's: a
    '' block is sized once at the face's finest mip, and a coarser mip just
    '' uses less of it. Aiming a smaller view at a larger block's offset is
    '' safe -- the bigger alignment implies the smaller one.
    ''
    a = sc_shift%( w )
    b = sc_shift%( h )
    if ( a + b > SC_MAXSUM ) then
        sc_find& = 0
        exit function
    end if
    vcls = (a - SC_MINSH) * 5 + (b - SC_MINSH)
    dc = sc_desc( vcls )
    if ( dc <> 0 ) then
        if ( uglSetView%( dc, clng( sc_bgrn( sc_slot(face).blk ) ) * SC_GRAN ) = 0 ) then dc = 0
    end if
    if ( dc <> 0 ) then
        sc_hits = sc_hits + 1
        sc_lru_touch sc_slot(face).blk  '' a hit is a use -- the whole point
    end if
    sc_find& = dc
end function

''::::::::::
'' name: sc_alloc
'' desc: A DC big enough for w by h, remembered against the face. Returns 0
''       if the surface is larger than the filler can address or EMS is out.
''::::::::::
function sc_alloc& ( byval face as integer, byval mip as integer, _
                     byval w as integer, byval h as integer, _
                     byval fw as integer, byval fh as integer )
    dim a as integer, b as integer, cidx as integer, bord as integer
    dim dc as long
    dim vic as integer, blk as integer, j as integer, b2 as integer

    dim ofs as long, sz as long

    if ( sc_ok = 0 or w <= 0 or h <= 0 ) then
        sc_alloc& = 0
        exit function
    end if
    if ( sc_hnd = 0 ) then
        if ( sc_store_open% = 0 ) then
            sc_ok = 0                   '' no store, no cache
            sc_alloc& = 0
            exit function
        end if
    end if

    a = sc_shift%( w )
    b = sc_shift%( h )
    if ( a + b > SC_MAXSUM ) then   '' past one EMS page, and rdAccess maps
                                    '' only one, so the rest would be garbage
        sc_alloc& = 0
        exit function
    end if
    cidx = (a - SC_MINSH) * 5 + (b - SC_MINSH)

    ''
    '' One view per class, made once and aimed somewhere new every time.
    '' These are every DC the cache ever makes -- 25 at the very most,
    '' against one per cached surface before.
    ''
    if ( sc_desc(cidx) = 0 ) then
        dc = uglNewView&( sc_hnd, 0, 2 ^ a, 2 ^ b )
        if ( dc = 0 ) then
            sc_alloc& = 0
            exit function
        end if
        sc_desc(cidx) = dc
        sc_made = sc_made + 1
    end if
    dc = sc_desc(cidx)

    ''
    '' The block is sized at the mip being drawn NOW, and grows only if a
    '' finer mip is later wanted. Sizing it at the face's floor mip instead
    '' -- which is what fw and fh are for, and what this used to do -- made
    '' every block as big as the face could ever need: 6.9 KB average, and
    '' the 4 MB store full at roughly 600 surfaces even though most faces
    '' are never seen close up. fw and fh are kept in the signature because
    '' the caller has them and a future shrink-on-demand would want them.
    ''
    bord = (a + b) - SC_MINORD
    sz   = clng(2 ^ a) * clng(2 ^ b)

    ''
    '' Three ways to get bytes, cheapest first: the block this face already
    '' owns, then fresh store while any is left, then the least recently
    '' used surface of the SAME class -- exactly this size and already
    '' aligned to it, so evicting one always suffices and never fragments.
    ''
    blk = sc_slot(face).blk
    if ( blk >= 0 and sc_bord(blk) >= bord ) then
        '' what it already owns is big enough -- a coarser mip just uses
        '' less of it, and not shrinking avoids churn on every mip step
        ofs = clng( sc_bgrn(blk) ) * SC_GRAN
    else
        if ( blk >= 0 ) then
            '' growing: the old block goes back for someone else to use,
            '' which is the leak the bump allocator never plugged
            sc_lru_unlink blk
            sc_bfree blk
            sc_slot(face).blk = -1
            sc_live = sc_live - 1
        end if

        ''
        '' Five ways to get a block, cheapest first. Only the last is an
        '' eviction, and only the very last gives up.
        ''
        blk = sc_fpop%( bord )                  '' 1. already free, right size
        if ( blk < 0 ) then blk = sc_bsplit%( bord )   '' 2. halve a bigger free one
        if ( blk < 0 ) then                     '' 3. fresh store
            ''
            '' Splitting comes BEFORE growing on purpose. The store is the
            '' finite resource and free blocks are already paid for, so
            '' reusing them keeps the high-water mark down and fits more
            '' surfaces; taking virgin store first would leave the free
            '' pool untouched until the store was exhausted.
            ''
            blk = sc_brec%
            if ( blk >= 0 ) then
                ofs = sc_grab&( sz )
                if ( ofs < 0 ) then
                    sc_bput blk
                    blk = -1
                else
                    sc_bgrn(blk) = cint( ofs \ SC_GRAN )
                    sc_bord(blk) = bord
                end if
            end if
        end if
        if ( blk < 0 ) then                     '' 4. evict LRU of this size
            blk = sc_lhead(bord)
            if ( blk >= 0 ) then
                vic = sc_bown(blk)
                if ( vic >= 0 ) then
                    sc_slot(vic).tag = 0
                    sc_slot(vic).blk = -1
                    sc_live  = sc_live - 1
                    sc_evict = sc_evict + 1
                end if
                sc_lru_unlink blk
            end if
        end if
        if ( blk < 0 ) then
            ''
            '' 5. Nothing of this size anywhere, so evict the least
            '' recently used LARGER block and split it down. This is what
            '' stops one size starving while another holds the store --
            '' the failure the per-class version had.
            ''
            for j = bord + 1 to SC_NORD - 1
                vic = sc_lhead(j)
                if ( vic >= 0 ) then
                    b2 = sc_bown(vic)
                    if ( b2 >= 0 ) then
                        sc_slot(b2).tag = 0
                        sc_slot(b2).blk = -1
                        sc_live  = sc_live - 1
                        sc_evict = sc_evict + 1
                    end if
                    sc_lru_unlink vic
                    sc_bfree vic
                    blk = sc_bsplit%( bord )
                    if ( blk >= 0 ) then exit for
                end if
            next j
        end if
        if ( blk < 0 ) then
            '' the backstop, and it should now be unreachable
            sc_flush
            sc_alloc& = 0
            exit function
        end if

        sc_bown(blk) = face
        sc_bprev(blk) = -1
        sc_bnext(blk) = -1
        sc_slot(face).blk = blk
        sc_slot(face).cls = bord
        sc_live = sc_live + 1
    end if
    ofs = clng( sc_bgrn(blk) ) * SC_GRAN
    if ( sc_next > sc_peak ) then sc_peak = sc_next

    sc_slot(face).tag = sc_gen * 4 + mip
    sc_lru_touch blk

    '' aim it at the bytes just claimed, ready for the builder to write
    if ( uglSetView%( dc, ofs ) = 0 ) then
        sc_alloc& = 0
        exit function
    end if

    sc_alloc& = dc
end function

''::::::::::
'' name: sc_reset
'' desc: Drops every slot without giving up the DCs, for when the map
''       changes and the face numbering with it.
''::::::::::
sub sc_reset
    dim i as integer

    for i = 0 to wld.tri_count-1
        sc_slot(i).tag = 0
        sc_slot(i).blk = -1
    next i
    for i = 0 to SC_NORD-1
        sc_lhead(i) = -1
        sc_ltail(i) = -1
        sc_fhead(i) = -1
    next i
    sc_rfree = -1
    sc_bcnt = 0
    sc_next = 0
    sc_gen = 1
end sub

''::::::::::
'' name: sc_shutdown
''::::::::::
sub sc_shutdown
    dim i as integer

    '' views first: they borrow the store's pixels, so the store outlives them
    for i = 0 to SC_NCLS-1
        if ( sc_desc(i) <> 0 ) then uglDelView sc_desc(i)
        sc_desc(i) = 0
    next i
    if ( sc_hnd <> 0 ) then uglDel sc_hnd
    sc_hnd = 0
    sc_cap = 0
    sc_next = 0
    sc_ok = 0
end sub

''::::::::::
'' name: sc_selftest
'' desc: Proves the pool behaves: sizes round up to the class the filler
''       needs, a recycled DC comes back rather than a new one, distinct
''       faces get distinct surfaces, a flush retires every slot, and bytes
''       written to a cached DC read back.
''::::::::::
function sc_selftest% ( )
    dim d0 as long, d1 as long, d2 as long
    dim i as integer, gen0 as integer, made0 as integer
    dim wr(31) as integer, rd(31) as integer
    dim ofs0 as long, live0 as long, flush0 as long, next0 as long
    dim fp as long

    if ( sc_ok = 0 ) then
        sc_selftest% = -1
        exit function
    end if

    sc_reset

    '' 224 rounds to 256, 112 to 128, 20 to 32
    if ( sc_shift%( 224 ) <> 8 ) then sc_selftest% = -2 : exit function
    if ( sc_shift%( 112 ) <> 7 ) then sc_selftest% = -3 : exit function
    if ( sc_shift%( 20 ) <> 5 ) then sc_selftest% = -4 : exit function
    if ( sc_shift%( 16 ) <> 4 ) then sc_selftest% = -5 : exit function

    '' 224x224 pads to 256x256 = 64K, four pages: it must be refused
    if ( sc_alloc&( 9, 0, 224, 224, 224, 224 ) <> 0 ) then sc_selftest% = -6 : exit function
    '' 112x112 pads to 128x128 = 16,384, exactly one page: it must not be
    d0 = sc_alloc&( 0, 0, 112, 112, 112, 112 )
    d1 = sc_alloc&( 1, 0, 112, 96, 112, 96 )
    if ( d0 = 0 ) then sc_selftest% = -7 : exit function
    if ( d1 = 0 ) then sc_selftest% = -8 : exit function
    '' both round to 128x128, so they share a view and differ only in where
    '' it points -- the whole point of the store
    if ( d0 <> d1 ) then sc_selftest% = -18 : exit function
    if ( sc_slot(0).blk = sc_slot(1).blk ) then sc_selftest% = -21 : exit function
    if ( sc_hnd = 0 ) then sc_selftest% = -22 : exit function

    '' and the floor it implies: 224 needs mip 1, 112 does not
    if ( sc_mipfloor%( 224, 224 ) <> 1 ) then sc_selftest% = -19 : exit function
    if ( sc_mipfloor%( 112, 112 ) <> 0 ) then sc_selftest% = -20 : exit function

    if ( sc_find&( 0, 0, 112, 112 ) <> d0 ) then sc_selftest% = -9 : exit function
    if ( sc_find&( 1, 0, 112, 96 ) <> d1 ) then sc_selftest% = -10 : exit function
    if ( sc_find&( 1, 1, 112, 96 ) <> 0 ) then sc_selftest% = -11 : exit function

    '' a write into the last row of the largest class, the 16K page edge
    for i = 0 to 31
        wr(i) = (i * 7 + 3) and 255
        rd(i) = 0
    next i
    uglRowWriteBuff d0, 0, 127, 32, UGL.8BIT, wr(0)
    fp = clng( varseg( rd(0) ) ) * 65536& + (clng( varptr( rd(0) ) ) and 65535&)
    uglRowRead d0, 0, 127, 32, UGL.8BIT, fp
    '' 32 pixels is 32 bytes, the first 16 of a 2-byte-per-element array
    for i = 0 to 15
        if ( rd(i) <> wr(i) ) then sc_selftest% = -12 : exit function
    next i

    '' a flush must retire the slots and hand the DCs back, not make more
    gen0 = sc_gen
    made0 = sc_made
    sc_flush
    if ( sc_gen = gen0 ) then sc_selftest% = -13 : exit function
    if ( sc_find&( 0, 0, 112, 112 ) <> 0 ) then sc_selftest% = -14 : exit function

    '' a flush rewinds the store and makes no new view
    d2 = sc_alloc&( 5, 0, 112, 112, 112, 112 )
    if ( d2 <> d0 ) then sc_selftest% = -15 : exit function
    if ( sc_made <> made0 ) then sc_selftest% = -16 : exit function
    if ( sc_slot(5).blk < 0 ) then sc_selftest% = -23 : exit function
    if ( sc_bgrn( sc_slot(5).blk ) <> 0 ) then sc_selftest% = -33 : exit function

    ''
    '' ---- the LRU itself ---------------------------------------------
    ''
    '' Everything above would pass just as well with the bump-and-flush
    '' this replaced, so prove the part that is actually new: that reuse
    '' happens, that a HIT changes who gets evicted, and that eviction
    '' takes exactly one surface rather than the whole store.
    ''
    sc_reset

    '' fill one class: three faces, three distinct blocks
    d0 = sc_alloc&( 0, 0, 112, 112, 112, 112 )
    d1 = sc_alloc&( 1, 0, 112, 112, 112, 112 )
    d2 = sc_alloc&( 2, 0, 112, 112, 112, 112 )
    if ( d0 = 0 or d1 = 0 or d2 = 0 ) then sc_selftest% = -24 : exit function
    '' PROBE: three allocations should be three new blocks. Separate codes --
    '' a single packed number turned out to have two valid decodes.
    if ( sc_bcnt <> 3 ) then sc_selftest% = -(2000 + sc_bcnt) : exit function
    if ( sc_slot(0).blk < 0 ) then sc_selftest% = -2999 : exit function
    if ( sc_slot(0).blk = sc_slot(1).blk ) then sc_selftest% = -25 : exit function
    if ( sc_slot(1).blk = sc_slot(2).blk ) then sc_selftest% = -26 : exit function

    '' face 0 is the oldest, so touching it must make face 1 the victim
    if ( sc_find&( 0, 0, 112, 112 ) = 0 ) then sc_selftest% = -27 : exit function
    if ( sc_lhead( sc_slot(0).cls ) < 0 ) then sc_selftest% = -28 : exit function
    if ( sc_bown( sc_lhead( sc_slot(0).cls ) ) <> 1 ) then _
        sc_selftest% = -(4000 + sc_bown( sc_lhead( sc_slot(0).cls ) )) : exit function

    '' rebuilding the SAME face at a new mip must reuse its own block, not
    '' take a second one -- this is the leak the old allocator had
    ofs0 = clng( sc_slot(0).blk )
    live0 = sc_live
    flush0 = sc_flushes
    if ( sc_alloc&( 0, 1, 56, 56, 112, 112 ) = 0 ) then sc_selftest% = -29 : exit function
    if ( clng( sc_slot(0).blk ) <> ofs0 ) then sc_selftest% = -30 : exit function
    if ( sc_live <> live0 ) then sc_selftest% = -31 : exit function

    '' and a mip change must not have cost a flush
    if ( sc_flushes <> flush0 ) then sc_selftest% = -32 : exit function

    ''
    '' ---- buddy merge -------------------------------------------------
    ''
    '' Everything above passes with per-class reuse and no buddy logic at
    '' all, so prove the two things only this allocator does. sc_next is
    '' the witness: if a request is served from the free list it does not
    '' move, and if it had to take fresh store it does.
    ''
    '' Two 16x16 blocks are order 0 and land at granules 0 and 1 -- buddies,
    '' since 0 XOR 1 is 2^0. Growing both faces frees both, and the second
    '' free must merge them into one order-1 block.
    ''
    sc_reset
    if ( sc_alloc&( 0, 0, 16, 16, 16, 16 ) = 0 ) then sc_selftest% = -40 : exit function
    if ( sc_alloc&( 1, 0, 16, 16, 16, 16 ) = 0 ) then sc_selftest% = -41 : exit function
    '' grow both: each takes a new order-2 block and hands its order-0 back
    if ( sc_alloc&( 0, 0, 32, 32, 32, 32 ) = 0 ) then sc_selftest% = -42 : exit function
    if ( sc_alloc&( 1, 0, 32, 32, 32, 32 ) = 0 ) then sc_selftest% = -43 : exit function

    next0 = sc_next
    '' 32x16 is 512 bytes, order 1: only the MERGED pair can serve it
    if ( sc_alloc&( 2, 0, 32, 16, 32, 16 ) = 0 ) then sc_selftest% = -44 : exit function
    if ( sc_next <> next0 ) then sc_selftest% = -45 : exit function

    ''
    '' ---- buddy split -------------------------------------------------
    ''
    '' A freed order-2 block must be halved to serve an order-0 request
    '' rather than the store being grown again.
    ''
    sc_reset
    if ( sc_alloc&( 0, 0, 32, 32, 32, 32 ) = 0 ) then sc_selftest% = -46 : exit function
    if ( sc_alloc&( 0, 0, 64, 64, 64, 64 ) = 0 ) then sc_selftest% = -47 : exit function
    next0 = sc_next
    if ( sc_alloc&( 1, 0, 16, 16, 16, 16 ) = 0 ) then sc_selftest% = -48 : exit function
    if ( sc_next <> next0 ) then sc_selftest% = -49 : exit function

    sc_reset
    sc_selftest% = 1
end function


''::::::::::
'' name: sb_seg
'' desc: The segment half of one of mgl's far pointers, as the signed
''       integer DEF SEG wants. Conventional memory reaches past 8000h, so
''       the value is often negative -- the bits are what matter.
''::::::::::
function sb_seg% ( byval p as long )
    dim lo as long, hi as long

    ''
    '' Take the low half off BEFORE dividing. BASIC's \ truncates toward
    '' zero, so on a NEGATIVE pointer -- any segment at or past 8000h,
    '' which the EMS page frame at E000h always is -- p \ 65536 rounds the
    '' wrong way and the segment comes back one paragraph too high.
    ''
    '' It only bites when the offset is non-zero. memAlloc pointers are
    '' paragraph-aligned so they never were, which is why this stood for
    '' as long as it did; uglMapEx hands back offset 8192 for every odd
    '' scanline of an 8192-wide dc, and those faces were reading their
    '' luxels 16 bytes late.
    ''
    lo = p and 65535&
    hi = (p - lo) / 65536&
    sb_seg% = cint( hi )
end function

''::::::::::
'' name: sb_i / sb_u
'' desc: A signed and an unsigned 16-bit read from wherever DEF SEG points.
''::::::::::
function sb_i% ( byval o as long )
    dim v as long

    v = clng( peek( o ) ) + clng( peek( o + 1& ) ) * 256&
    if ( v > 32767 ) then v = v - 65536&
    sb_i% = cint( v )
end function

function sb_u& ( byval o as long )
    sb_u& = clng( peek( o ) ) + clng( peek( o + 1& ) ) * 256&
end function

''::::::::::
'' name: sb_pot
'' desc: v rounded up to a power of two. Luxel grids top out at 17, so the
''       loop runs at most five times and only once per surface build.
''::::::::::
function sb_pot% ( byval v as integer )
    dim p as integer

    p = 1
    while ( p < v )
        p = p * 2
    wend
    sb_pot% = p
end function

''::::::::::
'' name: sb_build
'' desc: Composites one face's texture and lightmap into a cache DC.
''
''       Sets up an SBPARM and hands the texel loop to uglBuildSurf. What
''       stays here is per face, not per texel: the light table, the
''       resampling steps, and normalising the luxel pointer.
''
''       The BASIC loop this replaces is gone from the source but not from
''       the record -- mgl/src/test/surftst.bas checks the assembly against
''       the same arithmetic on a synthetic case, and tools/sbref.py is a
''       Python reference validated against the old BASIC on the target
''       (face 1544 mip 1: 0 of 8192 bytes differ). Change the maths in
''       either place and both must be re-run.
''
''       Three conventions, each got wrong once:
''
''       - The atlas is the whole texture resampled to 64/32/16/8, so an
''         original texel is not an atlas texel. u advances by atlasW/origW
''         per surface texel, in 16.16, and wraps with an AND because the
''         atlas is a power of two. mip_buff_inf.wdth is already 1/origW.
''       - Colormap row 0 is the BRIGHTEST, so a high luxel maps to a LOW
''         row. Quake inverts: t = (255*256 - luxel*264) >> 2, floored at
''         64, row = t >> 8.
''       - The texels must come from the raw atlas. Row 0 is not the
''         identity -- it brightens -- so shading a texel that already went
''         through it collapses the lighting range to almost nothing.
''::::::::::
'' name: sb_dump
'' desc: Builds one face's surface and writes it to surfdump.bin, then the
''       caller quits. tools/surfcheck.py diffs that against sbref.py.
''
''       This exists because every other check sits BELOW the seam that
''       actually broke. sc_selftest checks the cache's bookkeeping; mgl's
''       surftst checks uglBuildSurf against a BASIC reference but hands it
''       a pointer of its own making; and the asset round-trip check reads
''       the atlas in Python, running no target code at all. None of them
''       touch sb_build turning a uglMapEx result into a far pointer --
''       which is where a truncating divide put 56% of faces 16 bytes off
''       their luxels, on real assets, with all three of those green.
''
''       So it drives the real sb_build on the real map, and the sizing
''       below is d_poly's, not a paraphrase: extents from the luxel grid,
''       floor-divided by the mip, padded up to the size class.
''::::::::::
sub sb_dump ( byval face as integer, byval mip as integer )
    dim mt as long
    dim o as long
    dim lmw as integer, lmh as integer
    dim ew as integer, eh as integer
    dim sw as integer, sh as integer
    dim pw as integer, ph as integer
    dim mi as integer, dc as long
    dim x as integer, y as integer
    dim fh as integer
    dim row as string

    if ( face < 0 or face > wld.tri_count - 1 ) then
        print "dumpsurf: face"; face; "out of range 0.."; wld.tri_count - 1
        exit sub
    end if

    ''
    '' -dumpsurf runs outside the face loop, so nothing has fetched this
    '' face's record yet. Fetch it here, into the same shared buffer the
    '' renderer uses, so the sb_build call below reads exactly what it
    '' would have read mid-frame.
    ''
    sb_fetch face
    lmw = gv_buf(GEOM_LMOFS + 4)
    lmh = gv_buf(GEOM_LMOFS + 5)

    '' d_poly's sizing, and sbref.py's: the padded extent is what the
    '' builder fills, not the face's own sw by sh
    ew = (lmw - 1) * 16
    eh = (lmh - 1) * 16
    sw = ew \ (2 ^ mip)
    sh = eh \ (2 ^ mip)
    if ( sw < 1 ) then sw = 1
    if ( sh < 1 ) then sh = 1
    pw = 2 ^ sc_shift%( sw )
    ph = 2 ^ sc_shift%( sh )

    mi = tex_inf_buff( tri_buffer(face).texinfoid ).miptex

    dc = sc_alloc&( face, mip, sw, sh, pw, ph )
    if ( dc = 0 ) then
        print "dumpsurf: sc_alloc failed for face"; face; "mip"; mip
        exit sub
    end if

    sb_build dc, h_rawtx_dc( mi*4 + mip ), face, mip, pw, ph

    fh = freefile
    open "surfdump.bin" for binary as #fh
    put #fh, , pw
    put #fh, , ph
    for y = 0 to ph - 1
        row = space$( pw )
        for x = 0 to pw - 1
            mid$( row, x + 1, 1 ) = chr$( uglPGet&( dc, x, y ) and 255& )
        next x
        put #fh, , row
    next y
    close #fh

    print "dumpsurf: face"; face; "mip"; mip; "->"; pw; "x"; ph
end sub

''::::::::::
sub sb_build ( byval dc as long, byval tex as long, _
               byval face as integer, byval mip as integer, _
               byval sw as integer, byval sh as integer )
    dim mt as long

    '' Counted here rather than at the call site: this IS the build, so the
    '' counter cannot drift away from the thing it counts.
    sc_builds  = sc_builds + 1
    sc_tbuilds = sc_tbuilds + 1


    dim au as long, av as long, du as long, dv as long
    dim aw as integer, msk as integer
    dim lmw as integer, lmh as integer
    dim lmx as long, lmy as integer, lmp as long
    dim tms as integer, tmt as integer
    dim o as long
    dim mi as integer, recip as single
    dim sbp as SBPARM
    dim lseg as long, lofs16 as long

    aw = 64 \ (2 ^ mip)
    msk = aw - 1
    mi = tex_inf_buff( tri_buffer(face).texinfoid ).miptex

    ''
    '' Out of the record d_draw_faces already fetched, NOT out of the
    '' window it came from. GEOM_SLOT does not still hold that page by the
    '' time a build runs -- something between the fetch and here remaps it,
    '' and the header read back as zeros, which hangs uglBuildSurf on a 0x0
    '' luxel grid. The copy is the only safe source, and it is free.
    ''
    lmy = gv_buf(GEOM_LMOFS)            '' atlas scanline, -1 if unlit
    lmx = clng( gv_buf(GEOM_LMOFS + 1) ) and 65535&
    tms = gv_buf(GEOM_LMOFS + 2)
    tmt = gv_buf(GEOM_LMOFS + 3)
    lmw = gv_buf(GEOM_LMOFS + 4)
    lmh = gv_buf(GEOM_LMOFS + 5)

    ''
    '' The luxels live in one EMS atlas dc. lm_map hands back the face's
    '' scanline and this points at the rect inside it; uglBuildSurf's own
    '' texture and destination go to slots 0 and 1 without disturbing it.
    ''
    '' An unlit face has no rect at all. It used to compute a pointer from
    '' the -1 sentinel and read whatever that landed on; point it at one
    '' flat luxel instead, so its surface comes out evenly lit rather than
    '' lit by whatever was in memory.
    ''
    if ( lmy < 0 ) then
        lseg   = clng( varseg( lm_flat(0) ) )
        lofs16 = clng( varptr( lm_flat(0) ) ) and 65535&
        lmw    = 1
        lmh    = 1
    else
        lmp    = lm_map&( lmy )
        lseg   = clng( sb_seg%( lmp ) )
        lofs16 = (lmp and 65535&) + lmx
    end if

    '' atlas texels per surface texel, 16.16. wdth is 1/origW already.
    recip = mip_buff_inf(mi).wdth
    du = clng( aw * 65536.0 * recip ) * clng(2 ^ mip)
    recip = mip_buff_inf(mi).hght
    dv = clng( aw * 65536.0 * recip ) * clng(2 ^ mip)

    au = clng(tms) * (du \ clng(2 ^ mip))
    av = clng(tmt) * (dv \ clng(2 ^ mip))

    sbp.lmptr = lseg * 65536& + lofs16
    ''
    '' Atlas bytes per luxel row. The slot is padded to a power of two in
    '' each dimension for alignment, so the rows are pot(lmw) apart even
    '' though only lmw of each is ours.
    ''
    sbp.lmstride = clng( sb_pot%( lmw ) )
    sbp.cmapptr = cm_map&
    sbp.au0 = au
    sbp.av0 = av
    sbp.du  = du
    sbp.dv  = dv
    sbp.sw  = sw
    sbp.sh  = sh
    sbp.lmw = lmw
    sbp.lmh = lmh
    '' stp is 2^(4-mip) by construction, so its log2 needs no loop
    sbp.shft = 4 - mip
    sbp.msk  = msk

    if ( uglBuildSurf%( dc, tex, _
                        clng( varseg( sbp ) ) * 65536& + _
                        (clng( varptr( sbp ) ) and 65535&) ) = 0 ) then
        '' only a luxel grid too big for the builder's stack buffer gets
        '' here; leave the surface as it is rather than half-composite it
    end if
end sub



''::::::::::
'' name: sb_fetch
'' desc: Copies one face's geometry record into gv_buf.
''
''       The renderer does this inline, per face, because it is on the hot
''       path; this is for callers that are not in the face loop and still
''       need the record -- currently just -dumpsurf.
''::::::::::
sub sb_fetch ( byval face as integer )
    dim mt as long
    dim gp as long, gn as integer, dst as long

    gn = GEOM_MAXREC
    if ( tri_buffer(face).geom_ofs + gn > GEOM_W ) then
        gn = GEOM_W - tri_buffer(face).geom_ofs
    end if

    gp = geom_map&( tri_buffer(face).geom_row )
    dst = clng( varseg( gv_buf(0) ) ) * 65536& + _
          (clng( varptr( gv_buf(0) ) ) and 65535&)
    memCopy dst, gp + clng( tri_buffer(face).geom_ofs ), clng( gn )
end sub

''::::::::::
'' name: sc_stats
'' desc: Fills a scstat with the current counters. One crossing instead of
''       nine, and the counters stay this module's.
''::::::::::
sub sc_stats ( s as scstat )
    s.hits    = sc_hits
    s.builds  = sc_builds
    s.bpeak   = sc_bpeak
    s.made    = sc_made
    s.live    = sc_live
    s.evict   = sc_evict
    s.flushes = sc_flushes
    s.peak    = sc_peak
    s.tbuilds = sc_tbuilds
end sub

''::::::::::
'' name: sc_frame_end
'' desc: Closes the frame's counters and returns what it built. The peak is
''       kept BEFORE the reset because a hitch is one bad frame and an
''       average over the run hides it.
''
''       This ran in the HUD's end-of-frame code, which meant the overlay
''       was doing the cache's bookkeeping -- and doing it only when the
''       overlay was compiled in.
''::::::::::
function sc_frame_end% ()
    sc_frame_end% = sc_builds
    if ( sc_builds > sc_bpeak ) then sc_bpeak = sc_builds
    sc_hits   = 0
    sc_builds = 0
end function
