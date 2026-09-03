#ifndef __SC_H__
#define __SC_H__

#include "ugl.h"   /* PDC */

/*
 * sc.h -- the surface cache: where a face's texture and its lightmap,
 * already combined, wait to be drawn. C port of d_surf.bas's sc_*
 * slice (see sc.c's own header for the pool's shape and why).
 *
 * SurfCache is heap-sized, not stack/DGROUP-sized -- its five block
 * tables alone are 10 KB (SC_NBLK entries x 5 arrays x 2 bytes), and
 * medium model's DGROUP is 64 KB shared with the stack and every other
 * near global. Its owner allocates it with memAlloc (mgl's dos.h, the
 * standard far heap, not a MEM/EMS uGL store -- this is bookkeeping,
 * not surface bytes) and every function here takes SurfCache far*,
 * not SurfCache* -- the one struct in cport/ that has to be far,
 * because it's the one struct big enough that near addressing (a
 * DGROUP offset) couldn't reach all of it if it were DGROUP-resident
 * in the first place.
 */

#define SC_MINSH  4    /* 16, the smallest class */
#define SC_MAXSH  8    /* 256 on one axis, if the other stays small */
#define SC_MAXSUM 14   /* 2^a * 2^b <= 16384: one EMS page, all a single
                           rdAccess brings in */
#define SC_NCLS   25   /* (SC_MAXSH-SC_MINSH+1) squared */

#define SC_NBLK   1024   /* max resident surfaces -- a hard bound, unlike
                             the bump allocator this replaced */
#define SC_GRAN   256    /* smallest class, 16x16: the offset unit */

#define SC_MINORD 8    /* log2(SC_GRAN) */
#define SC_NORD   7    /* SC_MAXSUM - SC_MINORD + 1 */

#define SC_PGBYTES 16384L   /* one EMS page: the widest bps allowed */
#define SC_PAGES   256      /* the max ANY EMS DC can be -- ems_New packs
                                a scanline's logical page into one byte;
                                a 257th wraps and aliases page 0 */
#define SC_STORE   4194304L /* 256 * 16384 */

/* bspfile.bi's CacheSlot -- one per face, not per surface: which block
   (if any) a face currently owns, and what content it holds. */
typedef struct {
    short blk;    /* index into the block table, -1 for none */
    short tag;    /* generation * 4 + mip the CONTENT holds */
    short cls;    /* size class of the block, fixed per face */
    short stag;   /* the face's light style epoch the CONTENT holds --
                      see ls_epoch (ls.h) */
} CacheSlot;

/* bspfile.bi's CacheStats -- sc_stats' own snapshot, one crossing
   instead of nine separate counter reads. */
typedef struct {
    short hits;          /* per FRAME -- a build costs milliseconds, so
                             what hitches is how many land in one frame */
    short builds;
    short bpeak;          /* the worst frame seen */
    short made;           /* slots (views) created at init */
    long  live;           /* blocks currently resident */
    long  evict;          /* blocks thrown out over the run */
    long  flushes;        /* whole-cache flushes over the run */
    long  peak;           /* high-water bytes in the cache DC */
    long  total_builds;   /* builds over the whole run */
    long  dlit;           /* of those, how many a dynamic light reached */
} CacheStats;

typedef struct {
    short     ok;      /* whether there is a surface cache at all --
                           false if EMS isn't there or the store DC
                           couldn't be made */
    short     gen;      /* bumped on every flush; a stale tag from a
                            prior generation is always a miss */

    PDC       hnd;      /* the DC owning every surface's bytes -- 0 if
                            the store hasn't been claimed yet */
    long      next;      /* bump pointer within it */
    long      cap;       /* how big it is */

    CacheSlot far *slot; /* one per face -- far-allocated in sc_init to
                             world->face_count entries */

    PDC       desc[SC_NCLS];   /* one view DC per size class, made on
                                   demand and re-aimed per surface; 0 =
                                   not made yet */

    /* The block table. One entry per surface actually resident, not
       per face. Offsets are kept in SC_GRAN granules so they fit a
       short: SC_GRAN is the smallest class, so every block is a whole
       number of them, and SC_STORE/SC_GRAN is 16,384, inside int16. */
    short far *bgrn;   /* block offset / SC_GRAN -- SC_NBLK entries */
    short far *bord;   /* size order: 2^(o+SC_MINORD) bytes */
    short far *bown;   /* owning face, -1 if none */
    short far *bprev;  /* the class's LRU chain */
    short far *bnext;
    short     bcnt;     /* blocks made so far */
    short     rfree;    /* recycled block records, via bnext */

    short lhead[SC_NORD];  /* per-order LRU of owned blocks, -1 empty.
                               Head is least recently used. */
    short ltail[SC_NORD];
    short fhead[SC_NORD];  /* per-order free blocks, via bnext */

    /* Where sc_find/sc_alloc last aimed the class view -- now returned
       to the caller explicitly (both take a trailing long *aim_ofs)
       instead of being read back later through a separate accessor;
       the old sc_view_ofs() read a `dim shared sc_aim_ofs` no caller
       had to be handed, which is exactly the hidden-channel shape
       AGENTS.md's "no hidden side effects" rule rules out. */

    short made, hits, builds, bpeak;
    long  live, evict, flushes, peak, tbuilds, dlit;
} SurfCache;

/*
 * name: sc_init
 * desc: Allocates sc's own bookkeeping (far heap: the block tables and
 *       one CacheSlot per face) and empties the pool. The store DC
 *       itself is claimed lazily, on first use (sc_store_open) -- see
 *       its own header for why. Returns 0 if the far heap couldn't
 *       supply the bookkeeping arrays (a hard failure, unlike EMS
 *       being absent, which just leaves sc->ok false and every call
 *       a harmless no-op).
 */
short sc_init( SurfCache far *sc, short face_count );

/* Drops every slot without giving up the DCs, for when the map changes
   and the face numbering with it. */
void  sc_reset( SurfCache far *sc, short face_count );

/* Frees sc's far-heap bookkeeping and deletes every DC and view the
   pool made. sc itself is not freed -- its own storage is the
   caller's, matching every other cport/ context struct. */
void  sc_shutdown( SurfCache far *sc );

/* Every cached surface becomes a miss and every DC goes back to its
   class. The DCs themselves are kept -- they cost EMS, not
   correctness, and making them again is the expensive part. */
void  sc_flush( SurfCache far *sc, short face_count );

/* Finest mip at which a face's surface still fits a single EMS page. */
short sc_mipfloor( short extw, short exth );

/* Smallest power-of-two shift that covers v, clamped to the classes
   the filler can address -- d_faces.c rounds a surface's own sw/sh up
   to its class size the same way, to size the DC it builds into. */
short sc_shift( short v );

/* The DC holding this face's surface, or 0 if it has to be built. A
   mip other than the cached one, or a light-style change, counts as a
   miss. On a hit, *aim_ofs is where the class view now points -- the
   caller needs this to draw the right surface, since one view serves
   every surface of a size class. */
PDC   sc_find( SurfCache far *sc, short face, short mip, short w, short h, short stag, long *aim_ofs );

/* A DC big enough for w by h, remembered against face. Returns 0 if
   the surface is larger than the filler can address or EMS is out.
   *aim_ofs is where the class view now points, ready for the builder
   to write. fw/fh (the face's floor-mip extents) are kept in the
   signature though this sizes at the mip being drawn now, not the
   floor -- a future shrink-on-demand would want them, and the caller
   already has them. face_count is only for the backstop path (every
   size class exhausted -- should be unreachable): it has to flush the
   WHOLE cache then, and a flush needs to know how many slots exist. */
PDC   sc_alloc( SurfCache far *sc, short face, short mip, short w, short h, short fw, short fh,
                short stag, short face_count, long *aim_ofs );

/* Which mip this face already has resident, or -1 for none. */
short sc_held( SurfCache far *sc, short face );

/* Fills a CacheStats with the current counters. */
void  sc_stats( SurfCache far *sc, CacheStats *s );

/* Closes the frame's counters and returns how many builds landed in
   it. The peak is kept BEFORE the reset, so a hitch is one bad frame
   rather than smoothed into a run average. */
short sc_frame_end( SurfCache far *sc );

/* Whether there is a surface cache at all. */
short sc_ready( SurfCache far *sc );

void  sc_note_build( SurfCache far *sc );
void  sc_note_dlit( SurfCache far *sc );

/*
 * name: sc_selftest
 * desc: Proves the pool behaves against a throwaway SurfCache of its
 *       own (never the caller's) -- see sc.c's own header on
 *       sc_selftest for the checks. Returns 1 on success, a negative
 *       code naming which check failed. Requires EMS; returns -1
 *       immediately if there isn't any (matching the old BASIC's own
 *       sc_ok gate).
 */
short sc_selftest( void );

#endif
