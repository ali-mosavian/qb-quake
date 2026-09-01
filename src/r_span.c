/*
 * r_span.c -- resolve one frame's already-projected polygons into a
 * global, non-overlapping span list the way Quake's r_edge.c does: one
 * edge list for the whole frame, swept scanline by scanline with a
 * sorted active edge list, instead of the per-polygon Z-buffered fill
 * the real raster path uses. A measurement, not a replacement
 * rasteriser -- nothing here draws a pixel.
 *
 * Called from d_poly.bas's per-face loop on exactly the polygons it is
 * already handing uGL: r_span_emit_poly per face, r_span_flush once at
 * the end of the frame. That split is what BASIC times, and the one a
 * real integration would keep.
 *
 * Three sorted structures, no sort call anywhere. Edges are bucketed by
 * starting row, counting sort. The active edge list is doubly linked,
 * sorted by x, and carried from row to row -- stepping an edge usually
 * leaves it in place, so the list is repaired by splicing where two
 * edges actually cross rather than rebuilt, which is the point of
 * linking it. The active poly set is sorted nearest-first: each
 * crossing toggles its polygon in or out, whoever is at the front
 * between two crossings is what shows there, and a span closes when the
 * front changes. That is the whole algorithm.
 *
 * Depth is the polygon's own emission index, not a number derived from
 * its vertices. r_walk.c recurses the far child first, so order_list is
 * back to front and d_poly hands polygons over in that order -- which
 * makes a later index strictly nearer, and makes the key an exact total
 * depth order for the world tree rather than an approximation of one.
 * It is Quake's surf->key, and it is the same order the painter's
 * algorithm in the real raster path already stakes correctness on.
 *
 * x is 16.16 fixed point, as Quake's fixed16_t is: a float compare here
 * is FLD/FCOMP/FSTSW/SAHF and a float-to-short a call to F_FTOL@, and
 * the per-crossing truncation is the hottest thing in the file. The
 * active list is likewise unpacked out of edges[] into near arrays as
 * an edge goes active, so no per-row loop loads a segment register or
 * multiplies by the Edge stride.
 */

#include "qcshared.h"

/* uGL's scanline filler, reached one span at a time. uglSpanBegin puts
   the polygon's texture, destination and gradients in place; uglSpanTP
   draws one span of it. Same far pascal shape sb_build.c already calls
   uglBuildSurf through. */
extern long pascal far uglSpanBegin(
    long texdc, long dstdc, short masked,
    float dudx, float dvdx, float dzdx
);
extern long pascal far uglSpanTP(
    short x, short wid, short y,
    float up, float vp, float zp
);
extern long pascal far uglDcSize( long dc, short sel );
extern short pascal far uglSetView( long dc, long ofs );

/*
 * The crossing walk, in assembly -- src/r_sweep.asm. Ours, not uGL's:
 * it touches no uGL structure, only this file's own arrays, which it
 * takes as near offsets because they all sit in DGROUP. It walks the
 * row and hands back the spans where the nearest polygon changed.
 *
 * Drawing stays here. A span is a far call into uGL whoever makes it,
 * so there is nothing to win by making it there, and keeping it out
 * means the assembly needs no symbol from this file and no callback.
 */
extern short pascal far r_sweep_row(
    short row, short scrw,
    unsigned nextp, unsigned up, unsigned polyp,
    short headi, short taili,
    unsigned outp, short outmax
);
extern long pascal far r_sweep_ovf( void );

#define SWEEP_OUT 64
static short sweep_out[SWEEP_OUT*3];

/*
 * Spans are recorded during the sweep and drawn afterwards, grouped by
 * the polygon they belong to -- Quake's surf->spans, and not an
 * optimisation on top of this architecture but part of it.
 *
 * The sweep visits spans in x order across a row, so consecutive spans
 * almost never share a polygon: measured, 538.8 of 539.1 spans changed
 * it, so uglSpanBegin re-established texture, window and gradients on
 * essentially every span. Grouping first takes that to one per polygon.
 *
 * Pushed at the head, so a polygon's spans come out in reverse. They are
 * non-overlapping by construction, so order within a polygon is free.
 */
#define MAX_SPANS 2048
static short far sp_row[MAX_SPANS];
static short far sp_x0[MAX_SPANS];
static short far sp_x1[MAX_SPANS];
static short far sp_next[MAX_SPANS];
static unsigned long draw_cyc;

/* rdtsc is 0f 31; bcc 3.1 predates the mnemonic. Same bytes and same
   register shuffle as mgl's own xsnd/sndint.c __snd_tsc. Clobbers only
   edx:eax, so a bracket is safe around any C statement below. */
static unsigned long near rdtsc_now( void )
{
    __asm push ebx
    __emit__( 0x0f, 0x31 );
    __asm {
        mov  ebx, eax
        shr  ebx, 16
        mov  dx, bx
        pop  ebx
    }
}

/* Bounds a counter and nothing else -- since the depth key became the
   emission index there is no per-polygon table to size. e1m7 draws
   more than 512 in a frame; dm3ish peaks near 105. */
/* 2x the 544 e1m7 peaks at. Sized by the gradient table below, which is
   40 bytes a polygon -- the counter alone would cost nothing. */
#define MAX_POLYS         1024
#define MAX_EDGES         3200
#define MAX_ROWS          240
#define MAX_ACTIVE_EDGES  256
#define MAX_ACTIVE_POLYS  96

/* Two slots past the pool are the list's head and tail. Their x is past
   anything real in both directions, so every walk below stops on a
   sentinel and needs no bounds test. */
#define AEL_HEAD          MAX_ACTIVE_EDGES
#define AEL_TAIL          (MAX_ACTIVE_EDGES+1)
#define AEL_SLOTS         (MAX_ACTIVE_EDGES+2)
#define U_MIN             (-2147483647L - 1L)
#define U_MAX             2147483647L

#define FIX_ONE           65536.0

/* 8192.0 is 0x46000000, so "magnitude at least 8192" is one integer
   compare on a float's high word, sign masked off, where two x87 ones
   would be FLD/FCOMP/FSTSW/SAHF twice. Per vertex of every face. */
#define HI_8192           0x4600

typedef struct {
    long  u;           /* 16.16 x at row y0's centre */
    long  u_step;
    short y0;          /* first active row (inclusive) */
    short y1;          /* first row no longer active (exclusive) */
    short poly;
} Edge;

/* far: medium model puts a static in DGROUP, which BASIC's local heap
   already shares -- 44K here linked with "stack plus data exceed 64K".
   These two earn near least: touched once per edge per FRAME. */
static Edge  far edges[MAX_EDGES];
static short edge_count;
static short far sorted_edge[MAX_EDGES];

static short poly_count;

/*
 * Per polygon: u/z, v/z and 1/z are each LINEAR in screen space -- which
 * is the whole reason this works -- so each is fitted once here from
 * three vertices instead of stepped down an edge. Evaluating one at a
 * span's own (x, y) is two multiplies and two adds, the one cost a
 * span-ordered caller pays that an edge walk does not.
 *
 * Held as the value at a reference vertex plus two gradients, and
 * evaluated ABOUT that vertex -- not as a*x + b*y + c. Near/far clipping
 * leaves a grazing-angle floor with vertices projecting to five figures,
 * and there c and a*x are both large and nearly cancel, so single
 * precision keeps almost no significant digits exactly where the polygon
 * is most foreshortened. Same arithmetic, three more floats, no
 * cancellation.
 *
 * far: 40 bytes a polygon is past what DGROUP has spare, and these are
 * read once per span, not per pixel.
 */
/* One declarator each: far does NOT distribute across a comma list here,
   and six of these silently landing in DGROUP is "stack plus data exceed
   64K" at link, nowhere near where it was written. */
static float far pg_ua[MAX_POLYS];
static float far pg_ub[MAX_POLYS];
static float far pg_u0[MAX_POLYS];
static float far pg_va[MAX_POLYS];
static float far pg_vb[MAX_POLYS];
static float far pg_v0[MAX_POLYS];
static float far pg_x0[MAX_POLYS];
static float far pg_y0[MAX_POLYS];
static float far pg_za[MAX_POLYS];
static float far pg_zb[MAX_POLYS];
static float far pg_z0[MAX_POLYS];
static long  far pg_tex[MAX_POLYS];
/*
 * Where that dc was aimed. The texture handles are not one dc per
 * texture -- there are about eight views, re-aimed per face with
 * uglSetView, which is what makes an atlas cost no conventional memory.
 * d_poly draws each face while its view still points at the right cell;
 * a sweep draws after the whole face loop has re-aimed it hundreds of
 * times, so the aim has to travel with the handle and be restored.
 */
static long  far pg_ofs[MAX_POLYS];
/* head of this polygon's span list, -1 = none. See MAX_SPANS above. */
static short far pg_spans[MAX_POLYS];

/* Drawing is off unless r_span_draw_to has been handed a destination:
   the prototype has always run alongside the real raster path, and
   drawing from both would put spans over polygons. */
static long  g_dst_dc;
static short g_draw;
static short g_begun;                   /* polygon uglSpanBegin last saw */

/* Per-polygon scratch: each vertex checked and given its row once --
   the edge loop below visits every vertex twice. */
static float vcx[32];
static float vcy[32];
static short vrow[32];

/* near: read in the per-row loops. */
static short row_count[MAX_ROWS+1];
static short row_offset[MAX_ROWS+1];

/* The active edge list: near parallel arrays linked through ael_next/
   ael_prev, sorted by u. A slot comes off ael_free when an edge goes
   active and goes back when it expires. */
static long  ael_u[AEL_SLOTS];
static long  ael_ustep[AEL_SLOTS];
static short ael_y1[AEL_SLOTS];
static short ael_poly[AEL_SLOTS];
static short ael_next[AEL_SLOTS];
static short ael_prev[AEL_SLOTS];
static short ael_free;
static short ael_cnt;

/* The active ("currently inside") polygon set, nearest first, which is
   descending index. Measured mean 1.6, peak 6 -- which is why
   toggle_active scans rather than indexing something. */
static short active_poly[MAX_ACTIVE_POLYS];
static short active_cnt;

static short span_count;

static short g_rows;
static short g_screen_w;

/* Bumped whenever a bound above would have been exceeded: the result is
   whatever fit, not corrupted, but no longer the whole frame's. */
static short r_span_overflow;

/*
 * resolved_pixels is every emitted span's width, whole run: each pixel
 * counted once. naive_pixels is what the real path shades, which is
 * every polygon over its whole width, world faces being Z.WRITE with no
 * Z.TEST. naive/resolved is the overdraw factor, and it is a property
 * of the map, not of this code -- 1.42 on dm3ish, higher on a real one.
 *
 * A polygon crosses a row exactly twice, so subtracting x where it goes
 * active and adding x where it goes inactive totals its width, over
 * every polygon, with one long add per crossing. The earlier form --
 * width times the active count, at every crossing -- was the same
 * number for a multiply.
 */
static long resolved_pixels;
static long naive_pixels;

/* Raw TSC cycles, whole run, for r_span_flush's four phases; together
   nearly all of pt_span_mean. These four and no finer -- a bracket
   inside the crossing loop cost 1.25ms of a 7.85ms sweep, a third of
   what it reported, so measure anything smaller by removing the work
   rather than timing it. Even these are ~300 rdtsc pairs a frame. */
static unsigned long bucket_cyc;
static unsigned long merge_cyc;
static unsigned long sweep_cyc;
static unsigned long step_cyc;

/* Whole-run counts, to size the loops: edges the frame produced, rows
   swept, crossings walked (one per active edge per row), spans out. */
static long  edges_total;
static long  rows_total;
static long  cross_total;
static long  spans_total;
/* How often the polygon changes between consecutive spans -- i.e. how
   many times uglSpanBegin re-establishes texture, window and gradients.
   Sweep order interleaves polygons, so this is the cost that bucketing
   spans per polygon would remove; the floor is one per polygon. */
static long  begins_total;

/* Which bound r_span_overflow is actually hitting, when it is. */
static short poly_peak;
static short edge_peak;
static short ael_peak;

/* Never stored -- drawn, or counted and dropped. This is the drawer the
   earlier comment said a real integration would have: the span goes to
   uGL's own scanline filler the moment the sweep closes it, so nothing
   needs bucketing by polygon or holding until the frame ends. */
static void near emit_span( short row, short x0, short x1, short poly )
{
    if ( x1 <= x0 ) return;
    resolved_pixels += (long) (x1 - x0);
    spans_total++;

    if ( !g_draw || pg_tex[poly] == 0L ) return;
    if ( span_count >= MAX_SPANS ) { r_span_overflow++; return; }

    sp_row[span_count]  = row;
    sp_x0[span_count]   = x0;
    sp_x1[span_count]   = x1;
    sp_next[span_count] = pg_spans[poly];
    pg_spans[poly]      = span_count;
    span_count++;
}

/* The drawing pass: one polygon at a time, so its texture, window and
   gradients are established once and every span of it reuses them. */
static void near draw_spans( void )
{
    short p, sp, x0, row;
    float fx, fy, zs;

    for ( p = 0; p < poly_count; p++ ) {
        sp = pg_spans[p];
        if ( sp < 0 || pg_tex[p] == 0L ) continue;

        uglSetView( pg_tex[p], pg_ofs[p] );
        uglSpanBegin( pg_tex[p], g_dst_dc, 0,
                      pg_ua[p], pg_va[p], pg_za[p] );
        begins_total++;

        while ( sp >= 0 ) {
            row = sp_row[sp];
            x0  = sp_x0[sp];

            /* pixel centre and half a texel -- see the note where the
               planes are fitted */
            fx = (float) x0  + (float) 0.5 - pg_x0[p];
            fy = (float) row + (float) 0.5 - pg_y0[p];
            zs = pg_z0[p] + pg_za[p]*fx + pg_zb[p]*fy;
            uglSpanTP( x0, sp_x1[sp] - x0, row,
                       pg_u0[p] + pg_ua[p]*fx + pg_ub[p]*fy
                           + (float) 0.5 * zs,
                       pg_v0[p] + pg_va[p]*fx + pg_vb[p]*fy
                           + (float) 0.5 * zs,
                       zs );
            sp = sp_next[sp];
        }
    }
}

/* The two screen-space gradients of u/z, v/z or 1/z. The value at the
   reference vertex is kept as it stands -- see the note by the table. */
static void near fit_plane(
    float f0, float f1, float f2,
    float dx1, float dy1, float dx2, float dy2,
    float inv_det,
    float far *a, float far *b
)
{
    float df1 = f1 - f0;
    float df2 = f2 - f0;
    *a = ( df1*dy2 - df2*dy1 ) * inv_det;
    *b = ( dx1*df2 - dx2*df1 ) * inv_det;
}

/* Removes poly from the active set if present and returns 1, inserts it
   in order and returns 0 if not. Its two edges on a row toggle it on then off, so the set's own
   contents say which case this is -- and because the set is sorted on
   the same key it is searched by, one scan answers both: it stops where
   poly belongs, which is also where poly would be if it were there. */
static short near toggle_active( short poly )
{
    short i = 0, j;

    while ( i < active_cnt && active_poly[i] > poly ) i++;

    if ( i < active_cnt && active_poly[i] == poly ) {
        for ( j = i; j+1 < active_cnt; j++ ) active_poly[j] = active_poly[j+1];
        active_cnt--;
        return 1;
    }

    if ( active_cnt >= MAX_ACTIVE_POLYS ) { r_span_overflow++; return 0; }

    for ( j = active_cnt; j > i; j-- ) active_poly[j] = active_poly[j-1];
    active_poly[i] = poly;
    active_cnt++;
    return 0;
}

/* Called once, from host_init: clears the accumulators so the first
   frame does not read whatever was in BSS at load. Every later frame is
   left ready by r_span_flush itself. */
void pascal far r_span_start_frame( void )
{
    edge_count = 0;
    poly_count = 0;
    r_span_overflow = 0;
    resolved_pixels = 0;
    naive_pixels = 0;
    bucket_cyc = 0;
    draw_cyc = 0;
    merge_cyc = 0;
    sweep_cyc = 0;
    step_cyc = 0;
    edges_total = 0;
    rows_total = 0;
    cross_total = 0;
    spans_total = 0;
    begins_total = 0;
    poly_peak = 0;
    edge_peak = 0;
    ael_peak = 0;
}

/* First row whose centre is at or past y -- ceil(), without libm. The
   row-centre convention is the rasteriser's own; plain round-to-nearest
   is wrong at half-integers and wrong-signed below zero. */
static short near ceil_row( float y )
{
    short i = (short) y;
    if ( (float) i < y ) i++;
    return i;
}

/* vx/vy are the same prj_x()/prj_y() scratch d_poly.bas fills for the
   real raster path. poly_cnt is clamped to 32 whatever is passed: that
   scratch is dim shared prj_x(32), and anything past it reads whatever
   happens to sit beyond the array. */
void pascal far r_span_emit_ptr( short poly_cnt, float far *vx, float far *vy,
                                 float far *vu, float far *vv, float far *vz,
                                 long texdc, long texofs );

/*
 * BASIC entry: unpacks the five array descriptors and hands off. d_faces.c
 * calls r_span_emit_ptr directly instead, because it already holds plain
 * far pointers and has no descriptors to build.
 */
void pascal far r_span_emit_poly(
    short poly_cnt,
    BASARRAY *vx_dsc,
    BASARRAY *vy_dsc,
    BASARRAY *vu_dsc,
    BASARRAY *vv_dsc,
    BASARRAY *vz_dsc,
    long texdc,
    long texofs
)
{
    r_span_emit_ptr( poly_cnt,
                     (float far *) vx_dsc->farptr, (float far *) vy_dsc->farptr,
                     (float far *) vu_dsc->farptr, (float far *) vv_dsc->farptr,
                     (float far *) vz_dsc->farptr, texdc, texofs );
}

void pascal far r_span_emit_ptr(
    short poly_cnt,
    float far *vx,
    float far *vy,
    float far *vu,
    float far *vv,
    float far *vz,
    long texdc,
    long texofs
)
{
    short far *xw = (short far *) vx;
    short far *yw = (short far *) vy;
    short p, i, i2, hw, ra, rb, y0i, y1i;
    float xlo, xhi, ylo, yhi, dxdy, xstart;
    Edge far *e;

    if ( poly_cnt > 32 ) poly_cnt = 32;

    if ( poly_count >= MAX_POLYS ) { r_span_overflow++; return; }
    p = poly_count;
    poly_count++;
    pg_spans[p] = -1;

    /*
     * The three planes, from the RAW vertices rather than the clamped
     * copies below: clamping moves a vertex without moving the u/v/z
     * that belongs at it, which would tilt the fit. A degenerate screen
     * triangle leaves pg_tex 0 and the polygon simply is not drawn.
     */
    pg_tex[p] = 0L;
    if ( poly_cnt >= 3 ) {
        /*
         * Not vertices 0, 1, 2. d_clip_z hands over clipped polygons
         * whose leading vertices are often very nearly collinear on
         * screen -- a wall at a grazing angle is the usual one -- and
         * fitting a plane through three of those is either garbage or,
         * past the determinant test below, a whole face silently not
         * drawn. So: the vertex farthest from the first, then the one
         * farthest off that line. Two linear scans, and the triangle
         * they pick is the best conditioned the polygon has.
         */
        short ia = 1, ib = 2;
        float x0  = vx[0], y0 = vy[0];
        float dx1, dy1, dx2, dy2, det, best, m;

        best = (float) -1.0;
        for ( i = 1; i < poly_cnt; i++ ) {
            float ex = vx[i] - x0, ey = vy[i] - y0;
            m = ex*ex + ey*ey;
            if ( m > best ) { best = m; ia = i; }
        }
        dx1 = vx[ia] - x0;
        dy1 = vy[ia] - y0;

        best = (float) -1.0;
        for ( i = 1; i < poly_cnt; i++ ) {
            float ex = vx[i] - x0, ey = vy[i] - y0;
            m = dx1*ey - ex*dy1;
            if ( m < (float) 0.0 ) m = -m;
            if ( m > best ) { best = m; ib = i; }
        }
        dx2 = vx[ib] - x0;
        dy2 = vy[ib] - y0;
        det = dx1*dy2 - dx2*dy1;

        if ( det > (float) 0.001 || det < (float) -0.001 ) {
            float inv = (float) 1.0 / det;
            /*
             * u and v arrive normalised over z, the way d_poly already
             * hands them to uglPolyTP, and the filler wants texels. Scale
             * the fitted plane once per polygon rather than the value
             * once per span -- six multiplies against two per span, and
             * the number has to be uGL's own or the two paths disagree
             * about where a texture starts.
             */
            float su = (float) uglDcSize( texdc, 0 );
            float sv = (float) uglDcSize( texdc, 1 );

            pg_x0[p] = x0;
            pg_y0[p] = y0;
            fit_plane( vu[0], vu[ia], vu[ib], dx1,dy1,dx2,dy2, inv,
                       &pg_ua[p], &pg_ub[p] );
            fit_plane( vv[0], vv[ia], vv[ib], dx1,dy1,dx2,dy2, inv,
                       &pg_va[p], &pg_vb[p] );
            fit_plane( vz[0], vz[ia], vz[ib], dx1,dy1,dx2,dy2, inv,
                       &pg_za[p], &pg_zb[p] );
            pg_u0[p] = vu[0];
            pg_v0[p] = vv[0];
            pg_z0[p] = vz[0];
            pg_ua[p] *= su;  pg_ub[p] *= su;  pg_u0[p] *= su;
            pg_va[p] *= sv;  pg_vb[p] *= sv;  pg_v0[p] *= sv;
            pg_tex[p] = texdc;
            pg_ofs[p] = texofs;
        }
    }
    if ( poly_count > poly_peak ) poly_peak = poly_count;

    /* Bring every vertex into range once, and give it its row. Only
       near/far clipping runs ahead of this, so a vertex past the near
       plane and off axis projects beyond 32767 and Borland's FIST folds
       it to -32768. Clamping vertices rather than what is derived from
       them is what leaves the edge loop with no clamps at all. */
    for ( i = 0; i < poly_cnt; i++ ) {
        hw = xw[2*i+1];
        vcx[i] = ( (hw & 0x7FFF) >= HI_8192 )
                     ? ( hw < 0 ? (float) -8192.0 : (float) 8192.0 )
                     : vx[i];

        hw = yw[2*i+1];
        vcy[i] = ( (hw & 0x7FFF) >= HI_8192 )
                     ? ( hw < 0 ? (float) -8192.0 : (float) 8192.0 )
                     : vy[i];

        ra = ceil_row( vcy[i] - (float) 0.5 );
        if ( ra < 0 ) ra = 0;
        if ( ra > MAX_ROWS ) ra = MAX_ROWS;
        vrow[i] = ra;
    }

    for ( i = 0; i < poly_cnt; i++ ) {
        i2 = i + 1;
        if ( i2 == poly_cnt ) i2 = 0;

        /* One compare for what was three tests: equal rows covers a
           horizontal edge, one inside a single row band, and one
           entirely off the top or bottom. */
        ra = vrow[i];
        rb = vrow[i2];
        if ( ra == rb ) continue;

        if ( edge_count >= MAX_EDGES ) { r_span_overflow++; continue; }

        if ( ra < rb ) {
            y0i = ra;  y1i = rb;
            ylo = vcy[i];   yhi = vcy[i2];
            xlo = vcx[i];   xhi = vcx[i2];
        } else {
            y0i = rb;  y1i = ra;
            ylo = vcy[i2];  yhi = vcy[i];
            xlo = vcx[i2];  xhi = vcx[i];
        }

        dxdy   = (xhi - xlo) / (yhi - ylo);
        xstart = xlo + dxdy * ( (float) y0i + (float) 0.5 - ylo );

        e = &edges[edge_count];

        /*
         * Neither needs clamping, given vertices inside 8192. Row y0i's
         * centre lies in [ylo, yhi) -- above ylo by ceil, below yhi
         * because y0i < y1i, and that survives clamping y0i up to 0 or
         * y1i down to MAX_ROWS -- so xstart is a convex combination of
         * xlo and xhi and cannot leave 8192 either. u_step is read only
         * on an edge alive two rows or more, the step walk expiring one
         * before it steps it, and two rows apart means yhi - ylo > 1,
         * so the slope is at most the 16384 x can span. 2^29 and 2^30.
         */
        e->u      = (long) ( xstart * (float) FIX_ONE );
        e->u_step = ( y1i - y0i > 1 ) ? (long) ( dxdy * (float) FIX_ONE ) : 0L;
        e->y0     = y0i;
        e->y1     = y1i;
        e->poly   = p;
        edge_count++;
        edges_total++;
    }
}

/* Bucket the edge list by starting row, sweep it into spans, and leave
   the accumulators clear for the next frame's emit calls. */
short pascal far r_span_flush( short screen_w, short screen_h )
{
    short row, k, i, j;
    short cur_poly, xk, e_poly, e, nxt, pv, cur, slot;
    short span_x_start;
    long  u;

    g_screen_w = screen_w;
    g_rows     = screen_h;
    if ( g_rows > MAX_ROWS ) { g_rows = MAX_ROWS; r_span_overflow++; }
    if ( edge_count > edge_peak ) edge_peak = edge_count;

    {
        unsigned long t0 = rdtsc_now();

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

        bucket_cyc += rdtsc_now() - t0;
    }

    span_count = 0;
    ael_cnt    = 0;
    ael_free   = 0;
    g_begun    = -1;
    for ( k = 0; k < MAX_ACTIVE_EDGES-1; k++ ) ael_next[k] = k + 1;
    ael_next[MAX_ACTIVE_EDGES-1] = -1;
    ael_u[AEL_HEAD]    = U_MIN;
    ael_u[AEL_TAIL]    = U_MAX;
    ael_next[AEL_HEAD] = AEL_TAIL;
    ael_prev[AEL_TAIL] = AEL_HEAD;

    for ( row = 0; row < g_rows; row++ ) {

        /* Splice in this row's new edges -- the one place edges[] is
           read during the sweep. cur carries over rather than restarting
           at the head: a row's edges arrive roughly in x order, so the
           forward walk usually costs nothing and the backward one
           rarely runs. Both stop on a sentinel, so an out-of-order
           group is slower, never wrong. */
        {
            unsigned long t0 = rdtsc_now();

            cur = ael_next[AEL_HEAD];
            for ( k = row_offset[row]; k < row_offset[row+1]; k++ ) {
                if ( ael_free < 0 ) { r_span_overflow++; continue; }
                i = sorted_edge[k];
                u = edges[i].u;
                while ( ael_u[cur] < u ) cur = ael_next[cur];
                while ( ael_u[ ael_prev[cur] ] >= u ) cur = ael_prev[cur];

                slot     = ael_free;
                ael_free = ael_next[ael_free];

                ael_u[slot]     = u;
                ael_ustep[slot] = edges[i].u_step;
                ael_y1[slot]    = edges[i].y1;
                ael_poly[slot]  = edges[i].poly;

                pv = ael_prev[cur];
                ael_prev[slot] = pv;
                ael_next[slot] = cur;
                ael_next[pv]   = slot;
                ael_prev[cur]  = slot;
                ael_cnt++;
            }

            merge_cyc += rdtsc_now() - t0;
        }

        rows_total++;
        cross_total += (long) ael_cnt;
        if ( ael_cnt > ael_peak ) ael_peak = ael_cnt;

        {
            unsigned long t0 = rdtsc_now();
            short ns, si2;

            /* The active set is per-row scratch and lives inside
               r_sweep_row, since nothing out here reads it. */
            ns = r_sweep_row( row, g_screen_w,
                              (unsigned) ael_next,
                              (unsigned) ael_u,
                              (unsigned) ael_poly,
                              AEL_HEAD, AEL_TAIL,
                              (unsigned) sweep_out, SWEEP_OUT );

            for ( si2 = 0; si2 < ns; si2++ )
                emit_span( row,
                           sweep_out[si2*3+0],
                           sweep_out[si2*3+1],
                           sweep_out[si2*3+2] );

            sweep_cyc += rdtsc_now() - t0;
        }

        /* Step, expire and repair in one walk. An edge that lands
           behind its predecessor is unhooked and pulled back; everything
           ahead of it is already stepped and in order, so this is an
           insertion sort done in splices -- one compare per edge, plus
           one walk per crossing that actually happened. */
        {
            unsigned long t0 = rdtsc_now();

            e = ael_next[AEL_HEAD];
            while ( e != AEL_TAIL ) {
                nxt = ael_next[e];
                pv  = ael_prev[e];

                if ( ael_y1[e] <= row + 1 ) {
                    ael_next[pv]  = nxt;
                    ael_prev[nxt] = pv;
                    ael_next[e]   = ael_free;
                    ael_free      = e;
                    ael_cnt--;
                } else {
                    u = ael_u[e] + ael_ustep[e];
                    ael_u[e] = u;
                    if ( u < ael_u[pv] ) {
                        ael_next[pv]  = nxt;
                        ael_prev[nxt] = pv;
                        do { pv = ael_prev[pv]; } while ( ael_u[pv] > u );
                        cur            = ael_next[pv];
                        ael_next[e]    = cur;
                        ael_prev[e]    = pv;
                        ael_prev[cur]  = e;
                        ael_next[pv]   = e;
                    }
                }
                e = nxt;
            }

            step_cyc += rdtsc_now() - t0;
        }
    }

    /* Everything resolved; now draw it, grouped. */
    {
        unsigned long t0 = rdtsc_now();
        if ( g_draw ) draw_spans();
        draw_cyc += rdtsc_now() - t0;
    }

    edge_count = 0;
    poly_count = 0;

    return span_count;
}

/* 0 means the counts and timings above are the whole frame's. */
short pascal far r_span_overflow_count( void ) { return r_span_overflow; }

/* Hand a destination and the sweep draws its spans into it; 0 and it
   goes back to counting only. Not a flag on flush: the caller has to
   stop drawing the same faces the other way round in the same frame. */
void pascal far r_span_draw_to( long dst_dc )
{
    g_dst_dc = dst_dc;
    g_draw   = ( dst_dc != 0L );
}

/* naive/resolved is the map's overdraw factor; resolved alone is also
   the check that a rewrite of the sweep still resolves the same
   picture, being the covered area and so order-independent. */
long pascal far r_span_resolved_pixels( void ) { return resolved_pixels; }
long pascal far r_span_naive_pixels( void ) { return naive_pixels; }

/* Raw TSC cycles; convert against this run's own sys_rdtsc_hz(). */
long pascal far r_span_bucket_cycles( void ) { return (long) bucket_cyc; }
long pascal far r_span_merge_cycles( void ) { return (long) merge_cyc; }
long pascal far r_span_sweep_cycles( void ) { return (long) sweep_cyc; }
long pascal far r_span_step_cycles( void ) { return (long) step_cyc; }
long pascal far r_span_edges_total( void ) { return edges_total; }
long pascal far r_span_rows_total( void ) { return rows_total; }
long pascal far r_span_cross_total( void ) { return cross_total; }
long pascal far r_span_spans_total( void ) { return spans_total; }
long pascal far r_span_begins_total( void ) { return begins_total; }
long pascal far r_span_draw_cycles( void ) { return (long) draw_cyc; }
short pascal far r_span_poly_peak( void ) { return poly_peak; }
short pascal far r_span_edge_peak( void ) { return edge_peak; }
short pascal far r_span_ael_peak( void ) { return ael_peak; }
