/*
 * r_span.c -- prototype: resolve one frame's real, already-projected
 * polygons into a global, non-overlapping span list, the way Quake's
 * r_edge.c actually does it -- one global edge list for the whole
 * frame, swept scanline by scanline with a sorted active-edge list --
 * rather than the per-polygon Z-buffered fill this renderer's real
 * raster path uses. This is a measurement, not a replacement
 * rasteriser: nothing here draws a pixel.
 *
 * Two calls from BASIC, both from d_poly.bas's existing per-face loop
 * in d_draw_faces, on exactly the polygons that loop is already handing
 * to uGL:
 *
 *   r_span_emit_poly -- once per visible face, right where prj_x/prj_y/
 *   prj_w are already finalised. Converts that one polygon straight
 *   into edges and appends them to the frame's edge list; there is no
 *   stored per-frame vertex buffer; a polygon only ever needs its own
 *   vertices to become edges, so it happens at emit time rather than in
 *   a separate bulk pass over saved data.
 *
 *   r_span_flush -- once per frame, after the loop. Finishes the edge
 *   list (a counting sort by starting row -- see below) and sweeps it
 *   into the final span list.
 *
 * BASIC times each the same way it already times raster/build/aim in
 * that same loop: bracket with sys_rdtsc, accumulate. That is also why
 * the split is exactly emit/flush and not, say, three phases -- in a
 * real integration the emit side is the part that runs once per
 * polygon regardless, while resolving into spans (and eventually
 * drawing them) is the part that would end up interleaved one scanline
 * at a time rather than done as a separate pass, so those are the two
 * costs actually worth telling apart.
 *
 * Two sorted structures, both built to avoid an actual sort call:
 *
 *   - Edges are bucketed by their starting row with a counting sort
 *     (row_count/row_offset/sorted_edge below), not sorted by comparison
 *     -- rows are a small bounded integer range, so this is the same
 *     trick a radix sort uses for one digit, and it is O(edges + rows)
 *     rather than O(edges log edges).
 *
 *   - The active edge list is kept sorted by x with a plain insertion
 *     sort, on purpose: row to row it only changes by a few edges
 *     entering or leaving and everything else's x barely moves, which
 *     is exactly the case insertion sort is cheap on. This is the same
 *     coherence assumption Quake's own edge walker relies on.
 *
 *     CL.LIB's qsort was tried here instead, on the argument that
 *     MAX_ACTIVE_EDGES exists because a row CAN have well over a
 *     hundred edges active at once, and insertion sort's O(n^2) on
 *     whatever a busy row inserts unsorted looked like the reason
 *     pt_span_max spreads so far past pt_span_mean (41ms against a
 *     14ms mean, dm3ish campath). It hangs at runtime instead --
 *     reproduced twice, both the debug launch (stuck at a fixed
 *     BIOS-segment CS:EIP across repeated samples) and the plain -run
 *     harness (still burning CPU minutes past a normal ~20s bench).
 *     Most likely cause: qsort's own CL.LIB implementation expects C
 *     runtime state that a real C program's CRT0 startup sets up and
 *     that never runs here -- there is no C main(), no runtime init,
 *     just BASIC calling into a library function directly, the same
 *     reason this codebase avoids fopen/malloc generally. Not proven
 *     further than that, but reverting immediately once reproduced
 *     twice is the same rule "a real bug fixed with no change in
 *     symptom means the wrong cause" argues for in the other
 *     direction: two failures with one signature are enough to act on
 *     without a third. If this is revisited, it needs its own control
 *     build -- a trivial qsort call with no other change -- before
 *     trusting any conclusion about why.
 *
 * The occlusion resolution itself -- which polygon a given x range on a
 * given row actually shows -- falls out of a THIRD small sorted
 * structure, the active poly set: as the sweep crosses each edge, that
 * edge's polygon is toggled into or out of a list kept sorted by depth
 * (nearest first). Whichever polygon sits at the front of that list
 * between two consecutive crossings is the one visible there, and a
 * span closes and a new one opens whenever the front of the list
 * changes. That is the whole algorithm: no drawing, just bookkeeping.
 *
 * Depth is 1/z (BASIC's prj_w, larger meaning nearer -- the same
 * convention this renderer's own Z buffer already uses), one value per
 * polygon, its first vertex's: close enough to order by, and this
 * project's Z buffer already treats depth as interpolated per-vertex
 * rather than a single value per face.
 */

#include "qcshared.h"

#define MAX_POLYS         512
#define MAX_EDGES         3200
#define MAX_ROWS          240
#define MAX_ACTIVE_EDGES  256
#define MAX_ACTIVE_POLYS  96
#define MAX_SPANS         4096

typedef struct {
    float x;          /* current x -- advanced by dxdy as the sweep passes each row */
    float dxdy;
    short y0;          /* first active row (inclusive) */
    short y1;          /* first row no longer active (exclusive) */
    short poly;
} Edge;

/*
 * far, every one of them: medium model puts a plain static in DGROUP,
 * and BASIC's own local heap and string descriptors already live in
 * the same 64K -- the first build of this file linked with "stack plus
 * data exceed 64K" at roughly 44K of these arrays alone. far costs a
 * segment load per access, which is the right trade for a measurement
 * harness that is not on the frame's critical path.
 */
static Edge  far edges[MAX_EDGES];
static short edge_count;

static float far poly_depth_tbl[MAX_POLYS];
static short poly_count;

/* counting sort of edges[] by y0 -- see the file header */
static short far row_count[MAX_ROWS+1];
static short far row_offset[MAX_ROWS+1];
static short far sorted_edge[MAX_EDGES];

/* the active edge list for whichever row is currently being swept */
static short ael[MAX_ACTIVE_EDGES];
static short ael_cnt;

/* the active ("currently inside") polygon set, sorted nearest-first */
static short active_poly[MAX_ACTIVE_POLYS];
static float active_depth[MAX_ACTIVE_POLYS];
static short active_cnt;

static short far span_row[MAX_SPANS];
static short far span_x0[MAX_SPANS];
static short far span_x1[MAX_SPANS];
static short far span_poly[MAX_SPANS];
static short span_count;

static short g_rows;
static short g_screen_w;

/* Bumped whenever a static bound above would have been exceeded -- the
   result is still whatever fit, not corrupted, but is no longer the
   whole frame's real edge/span count. Read via r_span_overflow_count. */
static short r_span_overflow;

/*
 * Pixel-coverage totals, accumulated across the whole run (reset only
 * by r_span_start_frame, same lifetime as sc_built/sc_evict elsewhere
 * in this codebase) rather than per frame -- what we want out of these
 * is one ratio for the run, not a mean that would need g.ft.n threaded
 * in here too.
 *
 * naive_pixels is what the CURRENT renderer actually shades: d_poly.bas
 * sets world faces to Z.WRITE with no Z.TEST (confirmed by reading it,
 * not assumed), so every polygon that reaches the rasteriser pays the
 * full per-pixel cost across its own width, occluded or not. That is
 * exactly width * (how many polygons are active) summed over every
 * sub-interval the sweep already visits -- see the sweep's own comment.
 *
 * resolved_pixels is the zero-overdraw total: the sum of every emitted
 * span's width, each pixel counted at most once by construction.
 *
 * naive/resolved is the overdraw factor -- how many times an average
 * pixel is being shaded today versus once.
 */
static long naive_pixels;
static long resolved_pixels;

static void near emit_span( short row, short x0, short x1, short poly )
{
    if ( x1 <= x0 ) return;
    resolved_pixels += (long) (x1 - x0);
    if ( span_count < MAX_SPANS ) {
        span_row[span_count]  = row;
        span_x0[span_count]   = x0;
        span_x1[span_count]   = x1;
        span_poly[span_count] = poly;
        span_count++;
    } else {
        r_span_overflow++;
    }
}

/* Toggles poly's membership in the active set: removes it if present,
   inserts it sorted by depth (nearest first) if not. A polygon's two
   edges on a row always toggle it on then off, so which case applies
   is always unambiguous from the set's own current contents. */
static void near toggle_active( short poly, float depth )
{
    short i, j;

    for ( i = 0; i < active_cnt; i++ ) {
        if ( active_poly[i] == poly ) {
            for ( j = i; j+1 < active_cnt; j++ ) {
                active_poly[j]  = active_poly[j+1];
                active_depth[j] = active_depth[j+1];
            }
            active_cnt--;
            return;
        }
    }

    if ( active_cnt >= MAX_ACTIVE_POLYS ) { r_span_overflow++; return; }

    i = 0;
    while ( i < active_cnt && active_depth[i] >= depth ) i++;
    for ( j = active_cnt; j > i; j-- ) {
        active_poly[j]  = active_poly[j-1];
        active_depth[j] = active_depth[j-1];
    }
    active_poly[i]  = poly;
    active_depth[i] = depth;
    active_cnt++;
}

/* Called once, by main.bas's host_init, the same way r_walk_layout_ok
   and sb_layout_ok reset nothing but assert something -- this resets
   the per-frame accumulators so the very first frame does not see
   whatever was on the stack/BSS at load time. Every later frame is
   reset by r_span_flush itself, at the end, ready for the next one. */
void pascal far r_span_start_frame( void )
{
    edge_count = 0;
    poly_count = 0;
    r_span_overflow = 0;
    naive_pixels = 0;
    resolved_pixels = 0;
}

/* Row whose centre (row+0.5) is the first at or past y -- ceil(y-0.5)
   without pulling in a libm ceil() for one caller. Matches the same
   row-centre sampling convention the real rasteriser already samples
   prj_x/prj_y under, rather than the plain round-to-nearest an
   unadjusted (short)(y+0.5) gives (wrong at exact half-integers, and
   wrong direction entirely for negative y). */
static short near ceil_row( float y )
{
    short i = (short) y;
    if ( (float) i < y ) i++;
    return i;
}

/*
 * Emit: one polygon's own vertices become edges immediately, straight
 * into the frame's growing edge list -- see the file header for why
 * there is no separate stored-vertex buffer. vx/vy are the SAME
 * prj_x()/prj_y() scratch d_poly.bas already fills for the real raster
 * path; only the first poly_cnt elements are read -- clamped to 32
 * regardless of what is passed, since that scratch is declared
 * dim shared prj_x(32) in d_poly.bas and a poly_cnt past that would
 * read whatever happens to sit past the array's own end.
 */
void pascal far r_span_emit_poly(
    short poly_cnt,
    BASARRAY *vx_dsc,
    BASARRAY *vy_dsc,
    float depth
)
{
    float far *vx = (float far *) vx_dsc->farptr;
    float far *vy = (float far *) vy_dsc->farptr;
    short p, i, i2;
    float ya, yb, xa, xb, ylo, yhi, xlo, xhi, dxdy;
    short y0i, y1i;
    Edge far *e;

    if ( poly_cnt > 32 ) poly_cnt = 32;

    if ( poly_count >= MAX_POLYS ) { r_span_overflow++; return; }
    p = poly_count;
    poly_count++;
    poly_depth_tbl[p] = depth;

    for ( i = 0; i < poly_cnt; i++ ) {
        i2 = i + 1;
        if ( i2 == poly_cnt ) i2 = 0;

        ya = vy[i];
        yb = vy[i2];
        if ( ya == yb ) continue;

        xa = vx[i];
        xb = vx[i2];

        if ( ya < yb ) { ylo = ya; yhi = yb; xlo = xa; xhi = xb; }
        else           { ylo = yb; yhi = ya; xlo = xb; xhi = xa; }

        /*
         * Clamped before any cast, not after: only near/far clipping
         * runs before this (d_poly.bas's d_clip_z), so a vertex just
         * past the near plane and well off axis can project to a
         * magnitude past 32767, and a raw (short) of that is undefined
         * -- observed as Borland's FIST folding it to -32768, which
         * then survives as a bogus edge instead of getting dropped by
         * the y0i>=y1i check below. Clamped in world-projected pixels,
         * not screen pixels, since an off-screen edge crossing back
         * into a visible row still needs the right slope; 8192 is
         * generous against a 320-wide, 200-tall screen.
         */
        if ( ylo < (float) -8192.0 ) ylo = (float) -8192.0;
        if ( yhi > (float)  8192.0 ) yhi = (float)  8192.0;
        if ( xlo < (float) -8192.0 ) xlo = (float) -8192.0;
        if ( xlo > (float)  8192.0 ) xlo = (float)  8192.0;
        if ( xhi < (float) -8192.0 ) xhi = (float) -8192.0;
        if ( xhi > (float)  8192.0 ) xhi = (float)  8192.0;
        if ( ylo >= yhi ) continue;

        dxdy = (xhi - xlo) / (yhi - ylo);

        y0i = ceil_row( ylo - (float) 0.5 );
        y1i = ceil_row( yhi - (float) 0.5 );
        if ( y0i < 0 ) y0i = 0;
        if ( y1i > MAX_ROWS ) y1i = MAX_ROWS;
        if ( y0i >= y1i ) continue;

        if ( edge_count >= MAX_EDGES ) { r_span_overflow++; continue; }

        e = &edges[edge_count];
        e->dxdy = dxdy;
        e->x    = xlo + dxdy * ( (float) y0i + (float) 0.5 - ylo );
        e->y0   = y0i;
        e->y1   = y1i;
        e->poly = p;
        edge_count++;
    }
}

/*
 * Flush: finish the edge list (counting sort by starting row) and sweep
 * it into the final span list. Resets the accumulators at the end, so
 * the next frame's r_span_emit_poly calls start clean without a
 * separate reset call from BASIC.
 */
short pascal far r_span_flush( short screen_w, short screen_h )
{
    short row, k, w, i;
    short cur_poly, xk, e_poly;
    short span_x_start;
    short naive_x;

    g_screen_w = screen_w;
    g_rows     = screen_h;
    if ( g_rows > MAX_ROWS ) { g_rows = MAX_ROWS; r_span_overflow++; }

    /* Counting sort of edges[] by y0 into sorted_edge[]. */
    for ( row = 0; row <= g_rows; row++ ) row_count[row] = 0;
    for ( i = 0; i < edge_count; i++ ) {
        if ( edges[i].y0 < g_rows ) row_count[ edges[i].y0 ]++;
    }

    row_offset[0] = 0;
    for ( row = 0; row < g_rows; row++ )
        row_offset[row+1] = row_offset[row] + row_count[row];

    for ( row = 0; row < g_rows; row++ ) row_count[row] = row_offset[row];
    for ( i = 0; i < edge_count; i++ ) {
        row = edges[i].y0;
        if ( row >= g_rows ) continue;
        sorted_edge[ row_count[row] ] = i;
        row_count[row]++;
    }

    /* Sweep. */
    span_count = 0;
    ael_cnt    = 0;

    for ( row = 0; row < g_rows; row++ ) {

        /*
         * Reset every row, not once before the loop: the active set
         * describes "what is inside as of this row's own crossings so
         * far", walked fresh from x=0 each time. An edge still spanning
         * several rows stays in ael[] across all of them and re-crosses
         * on every one, so the set is correctly rebuilt from scratch --
         * leaving a stale entry here from the previous row (e.g. after
         * an overflow dropped its matching off-toggle) would poison
         * every row after it, not just the one that overflowed.
         */
        active_cnt = 0;

        for ( k = row_offset[row]; k < row_offset[row+1]; k++ ) {
            if ( ael_cnt < MAX_ACTIVE_EDGES ) ael[ael_cnt++] = sorted_edge[k];
            else r_span_overflow++;
        }

        w = 0;
        for ( k = 0; k < ael_cnt; k++ ) {
            if ( edges[ ael[k] ].y1 > row ) { ael[w] = ael[k]; w++; }
        }
        ael_cnt = w;

        for ( k = 1; k < ael_cnt; k++ ) {
            short t  = ael[k];
            float tx = edges[t].x;
            short j  = k - 1;
            while ( j >= 0 && edges[ ael[j] ].x > tx ) {
                ael[j+1] = ael[j];
                j--;
            }
            ael[j+1] = t;
        }

        cur_poly     = -1;
        span_x_start = 0;
        naive_x      = 0;

        for ( k = 0; k < ael_cnt; k++ ) {
            short new_poly;

            xk = (short) edges[ ael[k] ].x;
            if ( xk < 0 ) xk = 0;
            if ( xk > g_screen_w ) xk = g_screen_w;
            e_poly = edges[ ael[k] ].poly;

            /*
             * Every currently-active polygon would be fully shaded
             * across this sub-interval by the real (no-Z-test) raster
             * path, not just the nearest one -- so this adds width *
             * active_cnt, using the count as it stood BEFORE this
             * crossing's toggle, at every crossing, independent of
             * whether the span winner (cur_poly) changes here or not.
             */
            if ( xk > naive_x )
                naive_pixels += (long) (xk - naive_x) * (long) active_cnt;
            naive_x = xk;

            toggle_active( e_poly, poly_depth_tbl[e_poly] );

            /*
             * Close and reopen only when the FRONT of the active set
             * actually changes -- not at every crossing regardless.
             * Toggling a farther, already-hidden polygon in or out
             * behind the current winner must not fragment its span.
             */
            new_poly = ( active_cnt > 0 ) ? active_poly[0] : -1;
            if ( new_poly != cur_poly ) {
                if ( xk > span_x_start && cur_poly >= 0 )
                    emit_span( row, span_x_start, xk, cur_poly );
                cur_poly     = new_poly;
                span_x_start = xk;
            }
        }

        if ( cur_poly >= 0 && g_screen_w > span_x_start )
            emit_span( row, span_x_start, g_screen_w, cur_poly );

        for ( k = 0; k < ael_cnt; k++ )
            edges[ ael[k] ].x += edges[ ael[k] ].dxdy;
    }

    edge_count = 0;
    poly_count = 0;

    return span_count;
}

/* How many times a static bound above was hit this call -- 0 means the
   span count and both calls' timing just measured are the whole
   frame's, not a truncated piece of it. */
short pascal far r_span_overflow_count( void )
{
    return r_span_overflow;
}

/* Whole-run totals -- see their own comment by the two statics. Read
   together, naive/resolved is the overdraw factor: how many times an
   average pixel is being shaded by the real (no-Z-test) raster path
   today, against once. */
long pascal far r_span_naive_pixels( void )
{
    return naive_pixels;
}

long pascal far r_span_resolved_pixels( void )
{
    return resolved_pixels;
}
