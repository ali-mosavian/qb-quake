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

'' BSAVE's own header, still on the front of colmap.bld: a type byte, then
'' the segment and offset it was saved from, then the length.
const CM_HDR    = 7

const SC_MINSH  = 4             '' 16, the smallest class
const SC_MAXSH  = 8             '' 256 on one axis, if the other stays small
const SC_MAXSUM = 14            '' 2^a * 2^b <= 16384: one EMS page, which is
                                '' all a single rdAccess brings in
const SC_NCLS   = 25            '' (SC_MAXSH-SC_MINSH+1) squared
const SC_PERCLS = 12            '' DCs kept per class. 48 across 25 classes
                                '' is up to 1200 live EMS DCs; dm3ish alone
                                '' made 228 in two frames.

''
'' The 16 light levels of the face being built, rebuilt at the top of each
'' sb_build from the two header bytes (base, range) that prefix the face's
'' packed luxel nibbles: level(j) = base + (j*range + 7) \ 15. Per face
'' because a global 16-level palette banded -- each face spans a narrow
'' slice of the 0..255 range, and 16 linear steps across its own slice are
'' visually exact. mkassets.py's encode_plane writes the matching encoder.
''
'$static
dim shared lm_ftab(15) as integer
'$dynamic

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

    redim sc_slot(wld.tri_count-1) as scslot
    redim sc_pool(SC_NCLS-1, SC_PERCLS-1) as long
    redim sc_nmade(SC_NCLS-1) as integer
    redim sc_nused(SC_NCLS-1) as integer

    for i = 0 to SC_NCLS-1
        sc_nmade(i) = 0
        sc_nused(i) = 0
        for j = 0 to SC_PERCLS-1
            sc_pool(i, j) = 0
        next j
    next i

    if ( emsCheck% = 0 ) then
        sc_ok = 0
        sc_init% = 0
        exit function
    end if

    sc_ok = -1
    sc_init% = -1
end function

''::::::::::
'' name: sc_flush
'' desc: Every cached surface becomes a miss and every DC goes back to its
''       class. The DCs themselves are kept -- they cost EMS, not
''       correctness, and making them again is the expensive part.
''::::::::::
sub sc_flush
    dim i as integer

    for i = 0 to SC_NCLS-1
        sc_nused(i) = 0
    next i
    sc_gen = sc_gen + 1
    if ( sc_gen > 16000 ) then sc_gen = 1
    sc_flushes = sc_flushes + 1
end sub

''::::::::::
'' name: sc_find
'' desc: The DC holding this face's surface, or 0 if it has to be built.
''       A mip other than the cached one counts as a miss.
''::::::::::
function sc_find& ( byval face as integer, byval mip as integer )
    if ( sc_ok = 0 ) then
        sc_find& = 0
        exit function
    end if
    if ( sc_slot(face).tag <> sc_gen * 4 + mip ) then
        sc_find& = 0
        exit function
    end if
    sc_find& = sc_slot(face).dc
end function

''::::::::::
'' name: sc_alloc
'' desc: A DC big enough for w by h, remembered against the face. Returns 0
''       if the surface is larger than the filler can address or EMS is out.
''::::::::::
function sc_alloc& ( byval face as integer, byval mip as integer, _
                     byval w as integer, byval h as integer )
    dim a as integer, b as integer, cidx as integer
    dim dc as long

    if ( sc_ok = 0 or w <= 0 or h <= 0 ) then
        sc_alloc& = 0
        exit function
    end if

    a = sc_shift%( w )
    b = sc_shift%( h )
    if ( a + b > SC_MAXSUM ) then   '' past one EMS page, and rdAccess maps
                                    '' only one, so the rest would be garbage
        sc_alloc& = 0
        exit function
    end if
    cidx = (a - SC_MINSH) * 5 + (b - SC_MINSH)

    if ( sc_nused(cidx) < sc_nmade(cidx) ) then
        dc = sc_pool(cidx, sc_nused(cidx))            '' recycle
    else
        if ( sc_nmade(cidx) >= SC_PERCLS ) then
            sc_flush                                '' class exhausted
            sc_alloc& = 0
            exit function
        end if
        dc = uglNew&( UGL.EMS, UGL.8BIT, 2 ^ a, 2 ^ b )
        if ( dc = 0 ) then
            sc_alloc& = 0
            exit function
        end if
        sc_pool(cidx, sc_nmade(cidx)) = dc
        sc_nmade(cidx) = sc_nmade(cidx) + 1
        sc_made = sc_made + 1
        sc_peak = sc_peak + clng(2 ^ a) * clng(2 ^ b)
    end if

    sc_nused(cidx) = sc_nused(cidx) + 1

    sc_slot(face).dc = dc
    sc_slot(face).tag = sc_gen * 4 + mip

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
    next i
    for i = 0 to SC_NCLS-1
        sc_nused(i) = 0
    next i
    sc_gen = 1
end sub

''::::::::::
'' name: sc_shutdown
''::::::::::
sub sc_shutdown
    dim i as integer, j as integer

    for i = 0 to SC_NCLS-1
        for j = 0 to sc_nmade(i)-1
            if ( sc_pool(i, j) <> 0 ) then uglDel sc_pool(i, j)
            sc_pool(i, j) = 0
        next j
        sc_nmade(i) = 0
        sc_nused(i) = 0
    next i
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
    if ( sc_alloc&( 9, 0, 224, 224 ) <> 0 ) then sc_selftest% = -6 : exit function
    '' 112x112 pads to 128x128 = 16,384, exactly one page: it must not be
    d0 = sc_alloc&( 0, 0, 112, 112 )
    d1 = sc_alloc&( 1, 0, 112, 96 )
    if ( d0 = 0 ) then sc_selftest% = -7 : exit function
    if ( d1 = 0 ) then sc_selftest% = -8 : exit function
    if ( d0 = d1 ) then sc_selftest% = -18 : exit function

    '' and the floor it implies: 224 needs mip 1, 112 does not
    if ( sc_mipfloor%( 224, 224 ) <> 1 ) then sc_selftest% = -19 : exit function
    if ( sc_mipfloor%( 112, 112 ) <> 0 ) then sc_selftest% = -20 : exit function

    if ( sc_find&( 0, 0 ) <> d0 ) then sc_selftest% = -9 : exit function
    if ( sc_find&( 1, 0 ) <> d1 ) then sc_selftest% = -10 : exit function
    if ( sc_find&( 1, 1 ) <> 0 ) then sc_selftest% = -11 : exit function

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
    if ( sc_find&( 0, 0 ) <> 0 ) then sc_selftest% = -14 : exit function

    d2 = sc_alloc&( 5, 0, 112, 112 )
    if ( d2 <> d0 ) then sc_selftest% = -15 : exit function
    if ( sc_made <> made0 ) then sc_selftest% = -16 : exit function

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
    dim v as long

    v = (p \ 65536&) and 65535&
    if ( v > 32767 ) then v = v - 65536&
    sb_seg% = cint( v )
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
'' name: sb_build
'' desc: Composites one face's texture and lightmap into a cache DC.
''
''       The reference implementation, in BASIC and deliberately slow: the
''       assembly has to match it byte for byte, and the conventions are far
''       easier to get right here. Three of them, each got wrong once:
''
''       This used to die in BASIC's string heap ("String space corrupt")
''       after rendering correctly for a while. It was the pool size, not
''       any of the arithmetic: SC_PERCLS was 48, so 25 classes could hold
''       1200 live EMS DCs and dm3ish made 228 in two frames. Moving the
''       shade table out of BASIC's memory did NOT fix it and the fill
''       extent below did NOT cause it -- both were ruled out by test
''       before the pool was. -lm still defaults off only because this
''       builder is a per-texel BASIC reference and far too slow.
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
sub sb_build ( byval dc as long, byval tex as long, _
               byval face as integer, byval mip as integer, _
               byval sw as integer, byval sh as integer )
    dim x as integer, y as integer
    dim ax as integer, ay as integer
    dim au as long, av as long, du as long, dv as long
    dim aw as integer, msk as integer
    dim lmw as integer, lmh as integer, lofs as long
    dim tms as integer, tmt as integer
    dim stp as integer, lx as integer, ly as integer
    dim tx as long, ty as long
    dim l00 as long, l10 as long, l01 as long, l11 as long
    dim lt as long, lb as long, light as long
    dim t as long, row as integer, texel as integer
    dim o as long, iseg as integer, lmsg as integer, cmsg as integer
    dim nidx as long, nbyt as long
    dim lbase as integer, lrng as integer, lj as integer
    dim cmofs as long
    dim mi as integer, recip as single

    aw = 64 \ (2 ^ mip)
    msk = aw - 1
    mi = tex_inf_buff( tri_buffer(face).texinfoid ).miptex

    iseg = sb_seg%( lm_info )
    lmsg = sb_seg%( lm_base )
    ''
    '' The shade table sits in its own memAlloc'd block, so the segment is
    '' its far pointer's and the table starts past the BSAVE header the
    '' file still carries.
    ''
    cmsg  = sb_seg%( cm_base )
    cmofs = (clng( cm_base ) and 65535&) + CM_HDR

    def seg = iseg
    o = clng(face) * 16&
    lofs = clng( sb_i%( o ) ) * 65536& + sb_u&( o + 2& )
    tms = sb_i%( o + 4& )
    tmt = sb_i%( o + 6& )
    lmw = sb_i%( o + 8& )
    lmh = sb_i%( o + 10& )
    def seg

    ''
    '' This face's 16 light levels, from the two header bytes ahead of its
    '' luxel nibbles. See lm_ftab's declaration for why they are per face.
    ''
    def seg = lmsg
    lbase = cint( peek( lofs ) )
    lrng  = cint( peek( lofs + 1& ) )
    def seg
    for lj = 0 to 15
        lm_ftab(lj) = lbase + (lj * lrng + 7) \ 15
    next lj
    lofs = lofs + 2&

    '' atlas texels per surface texel, 16.16. wdth is 1/origW already.
    recip = mip_buff_inf(mi).wdth
    du = clng( aw * 65536.0 * recip ) * clng(2 ^ mip)
    recip = mip_buff_inf(mi).hght
    dv = clng( aw * 65536.0 * recip ) * clng(2 ^ mip)

    stp = 16 \ (2 ^ mip)

    av = clng(tmt) * (dv \ clng(2 ^ mip))
    for y = 0 to sh-1
        ay = cint( (av \ 65536&) and clng(msk) )

        ly = y \ stp
        if ( ly > lmh-2 ) then ly = lmh-2
        if ( ly < 0 ) then ly = 0
        ty = (clng(y) - clng(ly) * clng(stp)) * 65536& \ clng(stp)
        if ( ty > 65536& ) then ty = 65536&

        au = clng(tms) * (du \ clng(2 ^ mip))
        for x = 0 to sw-1
            ax = cint( (au \ 65536&) and clng(msk) )
            texel = uglPGet( tex, ax, ay )

            lx = x \ stp
            if ( lx > lmw-2 ) then lx = lmw-2
            if ( lx < 0 ) then lx = 0
            tx = (clng(x) - clng(lx) * clng(stp)) * 65536& \ clng(stp)
            if ( tx > 65536& ) then tx = 65536&

            ''
            '' Luxels are 4-bit indices into this face's lm_ftab, two packed
            '' per byte, low nibble first (mkassets.py's encode_plane/pack).
            '' nidx is the luxel's position in that nibble stream; nidx\2
            '' is its byte, nidx and 1 picks which half.
            ''
            def seg = lmsg
            nidx = clng(ly) * clng(lmw) + clng(lx)
            nbyt = clng( peek( lofs + (nidx \ 2&) ) )
            if ( (nidx and 1&) <> 0 ) then l00 = lm_ftab( (nbyt \ 16&) and 15& ) else l00 = lm_ftab( nbyt and 15& )

            nidx = clng(ly) * clng(lmw) + clng(lx) + 1&
            nbyt = clng( peek( lofs + (nidx \ 2&) ) )
            if ( (nidx and 1&) <> 0 ) then l10 = lm_ftab( (nbyt \ 16&) and 15& ) else l10 = lm_ftab( nbyt and 15& )

            nidx = clng(ly+1) * clng(lmw) + clng(lx)
            nbyt = clng( peek( lofs + (nidx \ 2&) ) )
            if ( (nidx and 1&) <> 0 ) then l01 = lm_ftab( (nbyt \ 16&) and 15& ) else l01 = lm_ftab( nbyt and 15& )

            nidx = clng(ly+1) * clng(lmw) + clng(lx) + 1&
            nbyt = clng( peek( lofs + (nidx \ 2&) ) )
            if ( (nidx and 1&) <> 0 ) then l11 = lm_ftab( (nbyt \ 16&) and 15& ) else l11 = lm_ftab( nbyt and 15& )
            def seg

            lt = (l00 * (65536& - tx) + l10 * tx) \ 65536&
            lb = (l01 * (65536& - tx) + l11 * tx) \ 65536&
            light = (lt * (65536& - ty) + lb * ty) \ 65536&

            t = (65280& - light * 264&) \ 4&
            if ( t < 64& ) then t = 64&
            row = cint( t \ 256& )
            if ( row > 63 ) then row = 63

            def seg = cmsg
            uglPSet dc, x, y, clng( peek( cmofs + clng(row) * 256& + clng(texel) ) )
            def seg

            au = au + du
        next x
        av = av + dv
    next y
end sub

