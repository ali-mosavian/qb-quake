/*
 * sc.c -- the surface cache. C port of d_surf.bas's sc_* slice.
 *
 * A pool of EMS DCs, one per cached surface, and the shape of that is
 * dictated by the filler that has to read them. 8plxtp derives its
 * texel addressing from the DC itself, reaching texels with 16-bit
 * registers, so the width and height must be powers of two.
 *
 * The filler calls rdAccess exactly once, before the span loop, and
 * for an EMS DC that is a single EMS_MAP of one logical page -- 16K.
 * Anything past it is simply never mapped, so a cached surface has to
 * fit 16,384 bytes entire: 128x128, or 256x64, and no more.
 *
 * DCs are pooled by size class and recycled rather than deleted,
 * because a miss should cost a build, not a uglNew. sc_flush hands
 * every DC back to its class and bumps the generation, which is what
 * makes every slot stale at once.
 *
 * Reclaim is keyed on a block's SIZE, not its class shape: 2^a * 2^b
 * is 2^(a+b), so a 4096-byte block serves (4,8), (5,7), (6,6), (7,5)
 * and (8,4) identically. Everything below sc_alloc's class lookup is a
 * buddy allocator over SIZE: split a larger free block when a small
 * one is wanted, and on free, merge with the buddy at gran XOR 2^order
 * so the large sizes can come back.
 */

#include <alloc.h>
#include <stddef.h>

#include <string.h>
#include "sc.h"
#include "dos.h"       /* memAlloc/memFree -- mgl's, not Borland's */
#include "uglpatch.h"
#include "ems.h"

/* Smallest power-of-two shift that covers v, clamped to the classes
   the filler can address. */
short sc_shift( short v )
{
    short s = SC_MINSH, p = 16;
    while ( p < v && s < SC_MAXSH ) { p *= 2; s++; }
    return s;
}

short sc_mipfloor( short extw, short exth )
{
    short m, w, h;

    for ( m = 0; m < 4; m++ ) {
        w = extw >> m;
        h = exth >> m;
        if ( w < 1 ) w = 1;
        if ( h < 1 ) h = 1;
        if ( sc_shift( w ) + sc_shift( h ) <= SC_MAXSUM ) return m;
    }
    return 3;
}

/* Block records, recycled. A merge consumes one record (two blocks
   become one), a split produces one, so the count churns and must not
   just walk bcnt upward forever. */
static short sc_brec( SurfCache far *sc )
{
    short b;

    if ( sc->rfree >= 0 ) {
        b = sc->rfree;
        sc->rfree = sc->bnext[b];
        return b;
    }
    if ( sc->bcnt < SC_NBLK ) return sc->bcnt++;
    return -1;
}

static void sc_bput( SurfCache far *sc, short b )
{
    sc->bnext[b] = sc->rfree;
    sc->rfree = b;
}

/* The per-order free lists, singly linked through bnext. sc_ftake
   pulls out one specific granule rather than the head -- that is how
   a merge finds its buddy, and the lists are short enough that a walk
   costs nothing. */
static void sc_fpush( SurfCache far *sc, short b )
{
    sc->bown[b] = -1;
    sc->bnext[b] = sc->fhead[ sc->bord[b] ];
    sc->fhead[ sc->bord[b] ] = b;
}

static short sc_fpop( SurfCache far *sc, short ord )
{
    short b = sc->fhead[ord];
    if ( b >= 0 ) sc->fhead[ord] = sc->bnext[b];
    return b;
}

static short sc_ftake( SurfCache far *sc, short ord, short gran )
{
    short b = sc->fhead[ord], p = -1;

    while ( b >= 0 ) {
        if ( sc->bgrn[b] == gran ) {
            if ( p >= 0 ) sc->bnext[p] = sc->bnext[b];
            else          sc->fhead[ord] = sc->bnext[b];
            return b;
        }
        p = b;
        b = sc->bnext[b];
    }
    return -1;
}

/*
 * Hands a block back, merging with its buddy for as long as the buddy
 * is also free. The buddy of a block of order o sits at gran XOR 2^o
 * -- the two halves of an aligned 2^(o+1) block differ in exactly that
 * bit -- and the merged block keeps the lower address, which is what
 * keeps it aligned to its new, larger size.
 */
static void sc_bfree( SurfCache far *sc, short blk )
{
    short b = blk, bud, ord, g;

    sc->bown[b] = -1;
    ord = sc->bord[b];

    while ( ord < SC_NORD - 1 ) {
        g = sc->bgrn[b] ^ (short) (1 << ord);
        bud = sc_ftake( sc, ord, g );
        if ( bud < 0 ) break;

        /* the merged block is the lower of the two, one order bigger,
           which is what keeps it aligned to its new size */
        if ( sc->bgrn[bud] < sc->bgrn[b] ) {
            sc_bput( sc, b );
            b = bud;
        } else {
            sc_bput( sc, bud );
        }
        ord++;
        sc->bord[b] = ord;
    }
    sc_fpush( sc, b );
}

/* A free block of exactly this order, made by halving a bigger one
   repeatedly. -1 if nothing larger is free. The upper half of each
   split goes on its own free list, so nothing is lost. */
static short sc_bsplit( SurfCache far *sc, short ord )
{
    short j, b, h;

    for ( j = ord + 1; j < SC_NORD; j++ ) {
        b = sc_fpop( sc, j );
        if ( b < 0 ) continue;

        while ( sc->bord[b] > ord ) {
            h = sc_brec( sc );
            if ( h < 0 ) {   /* no record to hold the half */
                sc_fpush( sc, b );
                return -1;
            }
            sc->bord[b]--;
            sc->bgrn[h] = sc->bgrn[b] + (short) (1 << sc->bord[b]);
            sc->bord[h] = sc->bord[b];
            sc->bprev[h] = -1;
            sc_fpush( sc, h );
        }
        return b;
    }
    return -1;
}

/* Bump-allocates a surface's bytes. Aligned to its own size, which
   keeps it inside one 16K logical page: the fillers map a single page
   and then address the texture flat, so a surface that straddled two
   would read garbage past the seam. -1 when full. */
static long sc_grab( SurfCache far *sc, long sz )
{
    long o = sc->next;
    if ( (o % sz) != 0 ) o += sz - (o % sz);
    if ( o + sz > sc->cap ) return -1;
    sc->next = o + sz;
    return o;
}

/* The LRU list, both ends O(1). A face is in its class's list exactly
   while it owns a block, which .blk >= 0 is the test for -- unlinking
   one that is not in a list would corrupt the head or the tail. */
static void sc_lru_unlink( SurfCache far *sc, short b )
{
    short c, p, n;

    if ( b < 0 ) return;
    c = sc->bord[b];
    p = sc->bprev[b];
    n = sc->bnext[b];

    /* Existing is not the same as being IN the list: a block just
       made has no neighbours yet. Without this test its first link
       takes the "I am both ends" branch and clears the class's head
       and tail, stranding everything already chained there. */
    if ( p < 0 && n < 0 && sc->lhead[c] != b ) return;
    if ( p >= 0 ) sc->bnext[p] = n; else sc->lhead[c] = n;
    if ( n >= 0 ) sc->bprev[n] = p; else sc->ltail[c] = p;
    sc->bprev[b] = -1;
    sc->bnext[b] = -1;
}

/* Move to the most-recent end. A cache HIT calls this too -- that is
   the whole difference between LRU and the bump-and-flush it replaced. */
static void sc_lru_touch( SurfCache far *sc, short b )
{
    short c, t;

    if ( b < 0 ) return;
    c = sc->bord[b];
    if ( sc->ltail[c] == b ) return;   /* already the most recent */
    sc_lru_unlink( sc, b );
    t = sc->ltail[c];
    sc->bprev[b] = t;
    sc->bnext[b] = -1;
    if ( t >= 0 ) sc->bnext[t] = b; else sc->lhead[c] = b;
    sc->ltail[c] = b;
}

static void sc_reset_lists( SurfCache far *sc )
{
    short i;
    for ( i = 0; i < SC_NORD; i++ ) {
        sc->lhead[i] = -1;
        sc->ltail[i] = -1;
        sc->fhead[i] = -1;
    }
    sc->rfree = -1;
}

short sc_init( SurfCache far *sc, short face_count )
{
    short i;

    sc->gen = 1;
    sc->flushes = 0;
    sc->peak    = 0;
    sc->made    = 0;
    sc->hits    = 0;
    sc->builds  = 0;
    sc->bpeak   = 0;
    sc->live    = 0;
    sc->evict   = 0;
    sc->tbuilds = 0;
    sc->dlit    = 0;

    sc->slot = (CacheSlot far *) memAlloc( (long) face_count * (long) sizeof(CacheSlot) );
    sc->bgrn  = (short far *) memAlloc( (long) SC_NBLK * (long) sizeof(short) );
    sc->bord  = (short far *) memAlloc( (long) SC_NBLK * (long) sizeof(short) );
    sc->bown  = (short far *) memAlloc( (long) SC_NBLK * (long) sizeof(short) );
    sc->bprev = (short far *) memAlloc( (long) SC_NBLK * (long) sizeof(short) );
    sc->bnext = (short far *) memAlloc( (long) SC_NBLK * (long) sizeof(short) );
    if ( !sc->slot || !sc->bgrn || !sc->bord || !sc->bown || !sc->bprev || !sc->bnext ) {
        sc->ok = 0;
        return 0;
    }

    for ( i = 0; i < SC_NCLS; i++ ) sc->desc[i] = 0;
    sc_reset_lists( sc );
    sc->bcnt = 0;
    for ( i = 0; i < face_count; i++ ) sc->slot[i].blk = -1;

    sc->hnd  = 0;
    sc->next = 0;
    sc->cap  = 0;

    if ( !emsCheck() ) {
        sc->ok = 0;
        return 1;
    }

    /* The store itself is not claimed here -- nothing needs a surface
       until the first one is built. See sc_store_open. */
    sc->ok = -1;
    return 1;
}

/* Claims the store DC, on first use. Deliberately not in sc_init: the
   store needs a large contiguous EMS allocation, and claiming it
   before vid_init has taken its own share risks losing the race for
   no reason -- nothing needs a surface until the first one is built. */
static short sc_store_open( SurfCache far *sc )
{
    if ( sc->hnd != 0 ) return -1;

    /* Shaped so its own scanline table stays tiny. bps is capped at
       one EMS page, so a 16384-wide DC is exactly one page per
       scanline. */
    sc->hnd = uglNew( UGL_EMS, UGL_8BIT, (int) SC_PGBYTES, SC_PAGES );
    if ( sc->hnd == 0 ) {
        sc->cap = 0;
        return 0;
    }
    sc->cap  = SC_STORE;
    sc->next = 0;
    return -1;
}

void sc_reset( SurfCache far *sc, short face_count )
{
    short i;

    for ( i = 0; i < face_count; i++ ) {
        sc->slot[i].tag = 0;
        sc->slot[i].blk = -1;
    }
    sc_reset_lists( sc );
    sc->bcnt = 0;
    sc->next = 0;
    sc->gen  = 1;
}

void sc_shutdown( SurfCache far *sc )
{
    short i;

    /* views first: they borrow the store's pixels, so the store
       outlives them */
    for ( i = 0; i < SC_NCLS; i++ ) {
        if ( sc->desc[i] != 0 ) uglDel( &sc->desc[i] );
        sc->desc[i] = 0;
    }
    if ( sc->hnd != 0 ) uglDel( &sc->hnd );
    sc->hnd  = 0;
    sc->cap  = 0;
    sc->next = 0;
    sc->ok   = 0;

    if ( sc->slot )  farfree( (void far *) sc->slot );
    if ( sc->bgrn )  farfree( (void far *) sc->bgrn );
    if ( sc->bord )  farfree( (void far *) sc->bord );
    if ( sc->bown )  farfree( (void far *) sc->bown );
    if ( sc->bprev ) farfree( (void far *) sc->bprev );
    if ( sc->bnext ) farfree( (void far *) sc->bnext );
    sc->slot = 0; sc->bgrn = 0; sc->bord = 0;
    sc->bown = 0; sc->bprev = 0; sc->bnext = 0;
}

void sc_flush( SurfCache far *sc, short face_count )
{
    short i;

    sc->next = 0;
    sc->gen++;
    if ( sc->gen > 16000 ) sc->gen = 1;
    sc->flushes++;
    /* a flush is a mass eviction: every surface in the store at once */
    sc->evict += sc->live;
    sc->live = 0;

    sc_reset_lists( sc );
    for ( i = 0; i < face_count; i++ ) sc->slot[i].blk = -1;
    sc->bcnt = 0;
}

PDC sc_find( SurfCache far *sc, short face, short mip, short w, short h, short stag, long *aim_ofs )
{
    PDC dc;
    short a, b, vcls;

    if ( !sc->ok ) return 0;
    if ( sc->slot[face].blk < 0 ) return 0;
    if ( sc->slot[face].tag != sc->gen * 4 + mip ) return 0;
    /* A tag match says the mip and generation are right; stag is the
       SEPARATE axis -- the face's light style may have moved on since
       this block was built, and that has nothing to do with mip or gen. */
    if ( sc->slot[face].stag != stag ) return 0;

    /* The view is the CURRENT mip's shape, which is not the block's: a
       block is sized once at the face's finest mip, and a coarser mip
       just uses less of it. Aiming a smaller view at a larger block's
       offset is safe -- the bigger alignment implies the smaller one. */
    a = sc_shift( w );
    b = sc_shift( h );
    if ( a + b > SC_MAXSUM ) return 0;

    vcls = (a - SC_MINSH) * 5 + (b - SC_MINSH);
    dc = sc->desc[vcls];
    if ( dc != 0 ) {
        *aim_ofs = (long) sc->bgrn[ sc->slot[face].blk ] * SC_GRAN;
        if ( !uglSetView( dc, *aim_ofs ) ) dc = 0;
    }
    if ( dc != 0 ) {
        sc->hits++;
        sc_lru_touch( sc, sc->slot[face].blk );   /* a hit is a use --
                                                       the whole point */
    }
    return dc;
}

PDC sc_alloc( SurfCache far *sc, short face, short mip, short w, short h, short fw, short fh,
              short stag, short face_count, long *aim_ofs )
{
    short a, b, cidx, bord;
    PDC dc;
    short vic, blk, j, b2;
    long ofs, sz;

    (void) fw; (void) fh;   /* kept in the signature for a future
                                shrink-on-demand -- see sc.h */

    if ( !sc->ok || w <= 0 || h <= 0 ) return 0;
    if ( sc->hnd == 0 ) {
        if ( !sc_store_open( sc ) ) {
            sc->ok = 0;   /* no store, no cache */
            return 0;
        }
    }

    a = sc_shift( w );
    b = sc_shift( h );
    if ( a + b > SC_MAXSUM ) return 0;   /* past one EMS page, and
                                             rdAccess maps only one */
    cidx = (a - SC_MINSH) * 5 + (b - SC_MINSH);

    /* One view per class, made once and aimed somewhere new every
       time -- every DC the cache ever makes, 25 at the very most,
       against one per cached surface before. */
    if ( sc->desc[cidx] == 0 ) {
        dc = uglNewView( sc->hnd, 0, (short) (1 << a), (short) (1 << b) );
        if ( dc == 0 ) return 0;
        sc->desc[cidx] = dc;
        sc->made++;
    }
    dc = sc->desc[cidx];

    /* The block is sized at the mip being drawn NOW, and grows only if
       a finer mip is later wanted -- sizing at the face's floor mip
       instead made every block as big as the face could ever need. */
    bord = (a + b) - SC_MINORD;
    sz   = (long) (1L << a) * (1L << b);

    /* Three ways to get bytes, cheapest first: the block this face
       already owns, then fresh store while any is left, then the
       least recently used surface of the SAME class -- exactly this
       size and already aligned to it, so evicting one always suffices
       and never fragments. */
    blk = sc->slot[face].blk;
    if ( blk >= 0 && sc->bord[blk] >= bord ) {
        /* what it already owns is big enough -- a coarser mip just
           uses less of it, and not shrinking avoids churn every step */
        ofs = (long) sc->bgrn[blk] * SC_GRAN;
    } else {
        if ( blk >= 0 ) {
            /* growing: the old block goes back for someone else --
               the leak the bump allocator never plugged */
            sc_lru_unlink( sc, blk );
            sc_bfree( sc, blk );
            sc->slot[face].blk = -1;
            sc->live--;
        }

        /* Five ways to get a block, cheapest first. Only the last is
           an eviction, and only the very last gives up. */
        blk = sc_fpop( sc, bord );                   /* 1. free, right size */
        if ( blk < 0 ) blk = sc_bsplit( sc, bord );   /* 2. halve a bigger free one */
        if ( blk < 0 ) {                               /* 3. fresh store */
            /* Splitting comes BEFORE growing on purpose: the store is
               the finite resource and free blocks are already paid
               for, so reusing them keeps the high-water mark down. */
            blk = sc_brec( sc );
            if ( blk >= 0 ) {
                ofs = sc_grab( sc, sz );
                if ( ofs < 0 ) {
                    sc_bput( sc, blk );
                    blk = -1;
                } else {
                    sc->bgrn[blk] = (short) (ofs / SC_GRAN);
                    sc->bord[blk] = bord;
                }
            }
        }
        if ( blk < 0 ) {                               /* 4. evict LRU of this size */
            blk = sc->lhead[bord];
            if ( blk >= 0 ) {
                vic = sc->bown[blk];
                if ( vic >= 0 ) {
                    sc->slot[vic].tag = 0;
                    sc->slot[vic].blk = -1;
                    sc->live--;
                    sc->evict++;
                }
                sc_lru_unlink( sc, blk );
            }
        }
        if ( blk < 0 ) {
            /* 5. Nothing of this size anywhere, so evict the least
               recently used LARGER block and split it down -- what
               stops one size starving while another holds the store. */
            for ( j = bord + 1; j < SC_NORD; j++ ) {
                vic = sc->lhead[j];
                if ( vic < 0 ) continue;
                b2 = sc->bown[vic];
                if ( b2 >= 0 ) {
                    sc->slot[b2].tag = 0;
                    sc->slot[b2].blk = -1;
                    sc->live--;
                    sc->evict++;
                }
                sc_lru_unlink( sc, vic );
                sc_bfree( sc, vic );
                blk = sc_bsplit( sc, bord );
                if ( blk >= 0 ) break;
            }
        }
        if ( blk < 0 ) {
            /* the backstop, and it should now be unreachable */
            sc_flush( sc, face_count );
            return 0;
        }

        sc->bown[blk]  = face;
        sc->bprev[blk] = -1;
        sc->bnext[blk] = -1;
        sc->slot[face].blk = blk;
        sc->slot[face].cls = bord;
        sc->live++;
    }
    ofs = (long) sc->bgrn[blk] * SC_GRAN;
    if ( sc->next > sc->peak ) sc->peak = sc->next;

    sc->slot[face].tag  = sc->gen * 4 + mip;
    sc->slot[face].stag = stag;
    sc_lru_touch( sc, blk );

    /* aim it at the bytes just claimed, ready for the builder to write */
    *aim_ofs = ofs;
    if ( !uglSetView( dc, ofs ) ) return 0;

    return dc;
}

short sc_held( SurfCache far *sc, short face )
{
    if ( !sc->ok ) return -1;
    if ( sc->slot[face].blk < 0 ) return -1;
    if ( (sc->slot[face].tag / 4) != sc->gen ) return -1;
    return sc->slot[face].tag & 3;
}

void sc_stats( SurfCache far *sc, CacheStats *s )
{
    /* Same reasoning as sc_ready: the overlay draws on a run whose cache
       never allocated, and zeroes are the honest reading there. */
    if ( !sc ) { memset( s, 0, sizeof(*s) ); return; }
    s->hits    = sc->hits;
    s->builds  = sc->builds;
    s->bpeak   = sc->bpeak;
    s->made    = sc->made;
    s->live    = sc->live;
    s->evict   = sc->evict;
    s->flushes = sc->flushes;
    s->peak    = sc->peak;
    s->total_builds = sc->tbuilds;
    s->dlit    = sc->dlit;
}

short sc_frame_end( SurfCache far *sc )
{
    short built = sc->builds;
    if ( sc->builds > sc->bpeak ) sc->bpeak = sc->builds;
    sc->hits   = 0;
    sc->builds = 0;
    return built;
}

short sc_ready( SurfCache far *sc )
{
    /* NULL is a real caller state, not a contract violation: main marks
       "sc_init FAILED" and carries on so a map too big for the cache
       still draws, just unlit. It used to dereference straight through
       and take the program with it -- on e1m1, only once an unrelated
       memory change let the run get this far. */
    if ( !sc ) return 0;
    return sc->ok;
}

void sc_note_build( SurfCache far *sc )
{
    sc->builds++;
    sc->tbuilds++;
}

void sc_note_dlit( SurfCache far *sc )
{
    sc->dlit++;
}

/*
 * name: sc_selftest
 * desc: Proves the pool behaves: sizes round up to the class the
 *       filler needs, a recycled DC comes back rather than a new one,
 *       distinct faces get distinct surfaces, a flush retires every
 *       slot, and bytes written to a cached DC read back -- then the
 *       LRU itself (reuse happens, a HIT changes who gets evicted,
 *       eviction takes exactly one surface), the buddy allocator's
 *       merge and split, and finally that a light-style change forces
 *       a rebuild even when the mip and generation still match.
 *
 *       10 faces (indices 0, 1, 2, 5 and 9 are used below) is the
 *       throwaway world this runs against -- never the caller's.
 */
static short sc_selftest_run( SurfCache far *sc )
{
    PDC d0, d1, d2;
    short gen0, made0;
    unsigned char wr[32], rd[32];
    long ofs0, live0, flush0, next0;
    long aim;
    short i;

    if ( !sc->ok ) return -1;

    sc_reset( sc, 10 );

    /* 224 rounds to 256, 112 to 128, 20 to 32 */
    if ( sc_shift( 224 ) != 8 ) return -2;
    if ( sc_shift( 112 ) != 7 ) return -3;
    if ( sc_shift( 20 )  != 5 ) return -4;
    if ( sc_shift( 16 )  != 4 ) return -5;

    /* 224x224 pads to 256x256 = 64K, four pages: it must be refused */
    if ( sc_alloc( sc, 9, 0, 224, 224, 224, 224, 0, 10, &aim ) != 0 ) return -6;
    /* 112x112 pads to 128x128 = 16,384, exactly one page: it must not be */
    d0 = sc_alloc( sc, 0, 0, 112, 112, 112, 112, 0, 10, &aim );
    d1 = sc_alloc( sc, 1, 0, 112, 96,  112, 96,  0, 10, &aim );
    if ( d0 == 0 ) return -7;
    if ( d1 == 0 ) return -8;
    /* both round to 128x128, so they share a view and differ only in
       where it points -- the whole point of the store */
    if ( d0 != d1 ) return -18;
    if ( sc->slot[0].blk == sc->slot[1].blk ) return -21;
    if ( sc->hnd == 0 ) return -22;

    /* and the floor it implies: 224 needs mip 1, 112 does not */
    if ( sc_mipfloor( 224, 224 ) != 1 ) return -19;
    if ( sc_mipfloor( 112, 112 ) != 0 ) return -20;

    if ( sc_find( sc, 0, 0, 112, 112, 0, &aim ) != d0 ) return -9;
    if ( sc_find( sc, 1, 0, 112, 96,  0, &aim ) != d1 ) return -10;
    if ( sc_find( sc, 1, 1, 112, 96,  0, &aim ) != 0 )  return -11;

    /* a write into the last row of the largest class, the 16K page edge */
    for ( i = 0; i < 32; i++ ) { wr[i] = (unsigned char) ((i * 7 + 3) & 255); rd[i] = 0; }
    uglRowWrite( d0, 0, 127, 32, UGL_8BIT, wr );
    uglRowRead( d0, 0, 127, 32, UGL_8BIT, rd );
    for ( i = 0; i < 32; i++ ) if ( rd[i] != wr[i] ) return -12;

    /* a flush must retire the slots and hand the DCs back, not make more */
    gen0  = sc->gen;
    made0 = sc->made;
    sc_flush( sc, 10 );
    if ( sc->gen == gen0 ) return -13;
    if ( sc_find( sc, 0, 0, 112, 112, 0, &aim ) != 0 ) return -14;

    /* a flush rewinds the store and makes no new view */
    d2 = sc_alloc( sc, 5, 0, 112, 112, 112, 112, 0, 10, &aim );
    if ( d2 != d0 ) return -15;
    if ( sc->made != made0 ) return -16;
    if ( sc->slot[5].blk < 0 ) return -23;
    if ( sc->bgrn[ sc->slot[5].blk ] != 0 ) return -33;

    /*
     * ---- the LRU itself ------------------------------------------
     * Everything above would pass just as well with the bump-and-flush
     * this replaced, so prove the part that is actually new: that
     * reuse happens, that a HIT changes who gets evicted, and that
     * eviction takes exactly one surface rather than the whole store.
     */
    sc_reset( sc, 10 );

    /* fill one class: three faces, three distinct blocks */
    d0 = sc_alloc( sc, 0, 0, 112, 112, 112, 112, 0, 10, &aim );
    d1 = sc_alloc( sc, 1, 0, 112, 112, 112, 112, 0, 10, &aim );
    d2 = sc_alloc( sc, 2, 0, 112, 112, 112, 112, 0, 10, &aim );
    if ( d0 == 0 || d1 == 0 || d2 == 0 ) return -24;
    if ( sc->bcnt != 3 ) return (short) -(2000 + sc->bcnt);
    if ( sc->slot[0].blk < 0 ) return -2999;
    if ( sc->slot[0].blk == sc->slot[1].blk ) return -25;
    if ( sc->slot[1].blk == sc->slot[2].blk ) return -26;

    /* face 0 is the oldest, so touching it must make face 1 the victim */
    if ( sc_find( sc, 0, 0, 112, 112, 0, &aim ) == 0 ) return -27;
    if ( sc->lhead[ sc->slot[0].cls ] < 0 ) return -28;
    if ( sc->bown[ sc->lhead[ sc->slot[0].cls ] ] != 1 )
        return (short) -(4000 + sc->bown[ sc->lhead[ sc->slot[0].cls ] ]);

    /* rebuilding the SAME face at a new mip must reuse its own block,
       not take a second one -- this is the leak the old allocator had */
    ofs0   = sc->slot[0].blk;
    live0  = sc->live;
    flush0 = sc->flushes;
    if ( sc_alloc( sc, 0, 1, 56, 56, 112, 112, 0, 10, &aim ) == 0 ) return -29;
    if ( sc->slot[0].blk != ofs0 ) return -30;
    if ( sc->live != live0 ) return -31;

    /* and a mip change must not have cost a flush */
    if ( sc->flushes != flush0 ) return -32;

    /*
     * ---- buddy merge ------------------------------------------------
     * Two 16x16 blocks are order 0 and land at granules 0 and 1 --
     * buddies, since 0 XOR 1 is 2^0. Growing both faces frees both,
     * and the second free must merge them into one order-1 block.
     */
    sc_reset( sc, 10 );
    if ( sc_alloc( sc, 0, 0, 16, 16, 16, 16, 0, 10, &aim ) == 0 ) return -40;
    if ( sc_alloc( sc, 1, 0, 16, 16, 16, 16, 0, 10, &aim ) == 0 ) return -41;
    /* grow both: each takes a new order-2 block and hands its order-0 back */
    if ( sc_alloc( sc, 0, 0, 32, 32, 32, 32, 0, 10, &aim ) == 0 ) return -42;
    if ( sc_alloc( sc, 1, 0, 32, 32, 32, 32, 0, 10, &aim ) == 0 ) return -43;

    next0 = sc->next;
    /* 32x16 is 512 bytes, order 1: only the MERGED pair can serve it */
    if ( sc_alloc( sc, 2, 0, 32, 16, 32, 16, 0, 10, &aim ) == 0 ) return -44;
    if ( sc->next != next0 ) return -45;

    /*
     * ---- buddy split --------------------------------------------
     * A freed order-2 block must be halved to serve an order-0
     * request rather than the store being grown again.
     */
    sc_reset( sc, 10 );
    if ( sc_alloc( sc, 0, 0, 32, 32, 32, 32, 0, 10, &aim ) == 0 ) return -46;
    if ( sc_alloc( sc, 0, 0, 64, 64, 64, 64, 0, 10, &aim ) == 0 ) return -47;
    next0 = sc->next;
    if ( sc_alloc( sc, 1, 0, 16, 16, 16, 16, 0, 10, &aim ) == 0 ) return -48;
    if ( sc->next != next0 ) return -49;

    /*
     * ---- stag: a light-style change must force a rebuild ---------
     * Everything above passes whether or not sc_find even looks at
     * stag, so this is the one block that proves it does. A tag match
     * (same gen, same mip) must still MISS if the style epoch moved
     * on -- that is the entire mechanism animated lightmaps rely on.
     */
    sc_reset( sc, 10 );
    if ( sc_alloc( sc, 0, 0, 112, 112, 112, 112, 5, 10, &aim ) == 0 ) return -50;
    if ( sc_find( sc, 0, 0, 112, 112, 5, &aim ) == 0 ) return -51;
    if ( sc_find( sc, 0, 0, 112, 112, 6, &aim ) != 0 ) return -52;

    /* rebuilding at the new stag must overwrite the slot's stag, not
       just its tag -- a second style change has to miss again too */
    if ( sc_alloc( sc, 0, 0, 112, 112, 112, 112, 6, 10, &aim ) == 0 ) return -53;
    if ( sc_find( sc, 0, 0, 112, 112, 5, &aim ) != 0 ) return -54;
    if ( sc_find( sc, 0, 0, 112, 112, 6, &aim ) == 0 ) return -55;

    sc_reset( sc, 10 );
    return 1;
}

short sc_selftest( void )
{
    SurfCache far *sc;
    short face_count = 10;
    short result;

    sc = (SurfCache far *) memAlloc( (long) sizeof(SurfCache) );
    if ( !sc ) return -1;

    if ( !sc_init( sc, face_count ) ) {
        farfree( (void far *) sc );
        return -1;
    }

    result = sc_selftest_run( sc );

    sc_shutdown( sc );
    farfree( (void far *) sc );
    return result;
}
