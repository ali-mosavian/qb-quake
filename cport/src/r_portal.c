/*
 * r_portal.c -- narrow the PVS to what is visible from HERE, not from
 * anywhere in this leaf.
 *
 * The PVS answers a question about a LEAF: what can be seen from any point
 * in it, looking any direction. Standing still and turning around does not
 * change it, which is why r_mark_leaves can cache it until the camera
 * crosses a leaf boundary. That is also its weakness -- in a map of rooms
 * joined by doorways it keeps every room the current one can see through
 * any opening, whether or not that opening is in front of you.
 *
 * This floods outward from the camera's leaf instead, through the portals
 * mkportals.py rebuilt, carrying a screen rectangle that shrinks at every
 * opening it passes through. A leaf survives only if some chain of portals
 * still leaves a non-empty rectangle. Measured offline on dm3ish over eight
 * viewpoints: 1362 faces under PVS-and-frustum against 761 through portals.
 *
 * It REFINES the PVS rather than replacing it -- a leaf is kept only if the
 * PVS had it AND the flood reached it -- so it can never mark something the
 * PVS did not, and a bug here shows up as geometry vanishing rather than as
 * something subtler.
 *
 * Runs every frame, unlike the PVS it narrows: the answer depends on where
 * you are looking, so there is no leaf-crossing to cache on.
 *
 * World-/Renderer-taking adaptation of the BASIC-linked build's own
 * src/r_portal.c -- same mechanical change pl_trace.c and r_walk.c
 * already got. m stays a raw float* internally (not Mat4*): both
 * r_ptproj.asm and the flat-index math below (m[0]..m[15]) already
 * treated a byref Mat4 as 16 contiguous floats, row-major, which is
 * exactly u3d.h's own layout (m11..m14, m21..m24, ...) -- the public
 * header takes Mat4* for type safety at the call site and this file
 * casts once, at the top of r_portal_mark.
 */

#include "r_portal.h"

/*
 * Sized for real mode, where these statics are the whole cost of the file:
 * 1024 leaves is dm3ish's 313 and e1m7's 281 with room, and the tables
 * below come to about 13K. A per-leaf history of several rectangles would
 * be tighter but costs that many times more -- 4096 leaves by six rects of
 * four floats is 393K, which is not a thing that fits anywhere here.
 */
#define PT_MAX_STACK  1024   /* frontier depth */
#define PT_MAX_WORK   8192   /* total pushes before giving up on the frame */

/* PT_REF_SHORTS -- r_portal.h now, shared with r_bsp.c's r_load_portals */

typedef struct { float x0, y0, x1, y1; } Rect;

/*
 * One rectangle per leaf, the UNION of everything it has been reached with,
 * and a leaf is only re-expanded when a new rectangle is not already inside
 * that union. Shorts, not floats: a stored rectangle has always been clipped
 * against the screen, so it fits.
 *
 * The union is the approximation this file makes. Keeping every rectangle
 * separately would be exact; a union can contain a rectangle that no single
 * visit actually covered, and then a leaf reachable only through that gap is
 * missed. That direction is unsafe -- it culls something visible -- so it is
 * checked by rendering: with portals on the picture must be identical to
 * with them off, and anything the union wrongly swallowed shows up as
 * geometry that disappears.
 */
static short far seen[PT_MAX_LEAVES][4];
static short far reached[PT_MAX_LEAVES];

/* Which portal refs the flood actually went through this frame. qglDrLine
   carries no z and so cannot be depth-tested, which is the obvious way to
   hide a portal behind a wall and is not available; this is better anyway.
   A portal the flood traversed is one visibility genuinely came through,
   which is the thing worth looking at -- every portal of every surviving
   leaf includes the ones behind you and the ones you cannot see. */
static char far used[PT_MAX_REFS];

static short far stk_leaf[PT_MAX_STACK];
static short far stk_rect[PT_MAX_STACK][4];

static short culled_frame;

/* Run totals for bench.txt. The flood's cost is pops x the refs on each
   popped leaf, and a leaf is popped once per rectangle that widens its
   union -- so neither figure is bounded by the leaf count and neither
   can be estimated from the map. Counted, not reasoned about. */
static long pt_pops, pt_projs, pt_pushes;

void r_portal_stats( long *pops, long *projs, long *pushes )
{
    *pops = pt_pops; *projs = pt_projs; *pushes = pt_pushes;
}

/*
 * A portal's box projected to a screen rectangle -- src/r_ptproj.asm.
 * bcc -Ox never hoists a far pointer's segment out of a loop: the C
 * version reloaded ES thirteen times per corner for two parameters
 * that never move across the whole function. See r_ptproj.asm's own
 * header for the rest, including why vx/vy are computed lazily and
 * 1/vw replaces two divides with one.
 */
extern short pascal far r_ptproj(
    short far *bb, float *m,
    float xresh, float yresh, float z_near,
    Rect *outp
);

/* r_rclip -- also r_ptproj.asm now: 93 instructions in bcc's own -S
 * output, 6 FWAIT with nothing to wait on under DOSBox's dynamic core,
 * and 6 redundant reloads of outp's pointer through a register that
 * cannot itself address memory. Same math, same result. */
extern short pascal far r_rclip( Rect *a, Rect *b, Rect *outp );

/*
 * Narrow rdr->pvsb to the leaves this eye can actually see through
 * portals, into rdr->pvs_now.
 *
 * Returns the number of leaves cleared, or a negative code if the
 * flood ran past its work budget or the map's leaf count is out of
 * range -- in which case pvs_now is left untouched, and the caller
 * (r_draw_world) falls back to using pvsb unchanged, which is always
 * correct, just unnarrowed.
 */
short r_portal_mark( World *world, Renderer *rdr, Mat4 *mtx, short cam_leaf, short visleafs,
                      float xresh, float yresh, float z_near )
{
    float *m = (float *) mtx;
    short far *index = world->pt_idx;
    short far *refs  = world->pt_ref;
    short far *pvsb  = rdr->pvsb;
    short far *outb  = rdr->pvs_now;
    Rect screen, rect, pr, sub;
    short sp = 0, i, k, li, nb, first, last, nrefs;
    long work = 0;

    culled_frame = 0;
    /* No adjacency loaded -- r_load_portals never ran, or the map has
       none. Without this the flood indexes off a null far pointer,
       reads the interrupt vector table as a portal index, and finds
       leaf ranges thousands of entries wide: 4.75 million projections a
       frame, 2.38 seconds of a 2.39 second frame, and 28 leaves culled
       on the strength of it. It did not fault and it did not look
       broken; it looked slow. */
    if ( !index || !refs ) return -5;
    if ( visleafs <= 0 || visleafs >= PT_MAX_LEAVES ) return -2;
    if ( cam_leaf < 0 || cam_leaf > visleafs ) return -3;

    for ( i = 0; i <= visleafs; i++ ) reached[i] = 0;
    nrefs = index[visleafs + 1];
    if ( nrefs > PT_MAX_REFS ) nrefs = PT_MAX_REFS;
    for ( i = 0; i < nrefs; i++ ) used[i] = 0;

    screen.x0 = 0.0f; screen.y0 = 0.0f;
    screen.x1 = xresh * 2.0f; screen.y1 = yresh * 2.0f;

    reached[cam_leaf] = 1;
    seen[cam_leaf][0] = 0;
    seen[cam_leaf][1] = 0;
    seen[cam_leaf][2] = (short) screen.x1;
    seen[cam_leaf][3] = (short) screen.y1;
    stk_leaf[0] = cam_leaf;
    stk_rect[0][0] = 0;
    stk_rect[0][1] = 0;
    stk_rect[0][2] = (short) screen.x1;
    stk_rect[0][3] = (short) screen.y1;
    sp = 1;

    while ( sp > 0 ) {
        sp--;
        li = stk_leaf[sp];
        rect.x0 = stk_rect[sp][0]; rect.y0 = stk_rect[sp][1];
        rect.x1 = stk_rect[sp][2]; rect.y1 = stk_rect[sp][3];

        pt_pops++;
        first = index[li];
        last  = index[li + 1];
        for ( k = first; k < last; k++ ) {
            short far *e = refs + (long) k * PT_REF_SHORTS;
            nb = e[0];
            if ( nb < 0 || nb > visleafs ) continue;

            pt_projs++;
            if ( !r_ptproj( e + 1, m, xresh, yresh, z_near, &pr ) ) continue;
            if ( !r_rclip( &pr, &rect, &sub ) ) continue;

            /* Nothing new if the union this leaf has been reached with
               already contains it. Otherwise widen the union and expand. */
            if ( reached[nb] &&
                 seen[nb][0] <= (short) sub.x0 && seen[nb][1] <= (short) sub.y0 &&
                 seen[nb][2] >= (short) sub.x1 && seen[nb][3] >= (short) sub.y1 )
                continue;

            if ( !reached[nb] ) {
                reached[nb] = 1;
                seen[nb][0] = (short) sub.x0; seen[nb][1] = (short) sub.y0;
                seen[nb][2] = (short) sub.x1; seen[nb][3] = (short) sub.y1;
            } else {
                if ( (short) sub.x0 < seen[nb][0] ) seen[nb][0] = (short) sub.x0;
                if ( (short) sub.y0 < seen[nb][1] ) seen[nb][1] = (short) sub.y0;
                if ( (short) sub.x1 > seen[nb][2] ) seen[nb][2] = (short) sub.x1;
                if ( (short) sub.y1 > seen[nb][3] ) seen[nb][3] = (short) sub.y1;
            }

            if ( sp >= PT_MAX_STACK ) return -4;
            pt_pushes++;
            if ( ++work >= PT_MAX_WORK ) return -1;
            if ( k < PT_MAX_REFS ) used[k] = 1;
            stk_leaf[sp] = nb;
            stk_rect[sp][0] = (short) sub.x0; stk_rect[sp][1] = (short) sub.y0;
            stk_rect[sp][2] = (short) sub.x1; stk_rect[sp][3] = (short) sub.y1;
            sp++;
        }
    }

    /* The PVS narrowed by the flood, written where the walk reads it --
       pvsb itself must not be touched, r_mark_leaves rebuilds it only when
       the camera changes leaf and a bit cleared there stays cleared. */
    outb[0] = 0;
    for ( i = 1; i <= visleafs; i++ ) {
        if ( !pvsb[i] ) {
            outb[i] = 0;
        } else if ( reached[i] ) {
            outb[i] = pvsb[i];
        } else {
            outb[i] = 0;
            culled_frame++;
        }
    }
    return culled_frame;
}

/*
 * Draw every portal of every leaf the flood reached, as the wireframe of its
 * bounding box -- which for a planar portal on an axis-aligned plane is the
 * portal rectangle itself, and for anything else is the box that bounds it.
 *
 * The box is what the flood actually tests, so this shows the geometry the
 * culling is reasoning about rather than an idealised version of it: a portal
 * that looks far larger than the opening it represents is exactly why a leaf
 * beyond it survived.
 *
 * Drawn into the render target, not the composite -- these are world-space
 * lines and belong in the view, scaled with it.
 */
void r_portal_draw( QSurf dc, Mat4 *mtx, short visleafs, float xresh, float yresh, float z_near,
                     long clr, World *world, Renderer *rdr )
{
    static short edge[12][2] = {
        {0,1},{1,3},{3,2},{2,0},   /* the two faces normal to z */
        {4,5},{5,7},{7,6},{6,4},
        {0,4},{1,5},{2,6},{3,7}    /* and the struts between them */
    };
    float *m = (float *) mtx;
    short far *index = world->pt_idx;
    short far *refs  = world->pt_ref;
    short far *vis   = rdr->pvs_now;
    short sx[8], sy[8], ok[8];
    short li, k, i, c, nb, first, last, infront;
    float lox, loy, hix, hiy;

    if ( visleafs <= 0 || visleafs >= PT_MAX_LEAVES ) return;

    for ( li = 1; li <= visleafs; li++ ) {
        if ( !vis[li] ) continue;
        first = index[li];
        last  = index[li + 1];

        for ( k = first; k < last; k++ ) {
            short far *bb = refs + (long) k * PT_REF_SHORTS + 1;
            nb = refs[ (long) k * PT_REF_SHORTS ];

            /* Only the ones visibility actually came through this frame. */
            if ( k >= PT_MAX_REFS || !used[k] ) continue;

            lox = 1e30f; loy = 1e30f; hix = -1e30f; hiy = -1e30f;
            infront = 0;

            for ( i = 0; i < 8; i++ ) {
                float bx = (float) bb[ (i & 1) ? 3 : 0 ];
                float bz = (float) bb[ (i & 2) ? 4 : 1 ];
                float by = (float) bb[ (i & 4) ? 5 : 2 ];
                float vx, vy, vw, fx, fy;

                vx = bx*m[0] + by*m[4] + bz*m[ 8] + m[12];
                vy = bx*m[1] + by*m[5] + bz*m[ 9] + m[13];
                vw = bx*m[3] + by*m[7] + bz*m[11] + m[15];

                if ( vw < z_near ) { ok[i] = 0; continue; }
                infront++;
                fx = xresh + vx / vw * xresh;
                fy = yresh - vy / vw * yresh;
                if ( fx < lox ) lox = fx;
                if ( fx > hix ) hix = fx;
                if ( fy < loy ) loy = fy;
                if ( fy > hiy ) hiy = fy;

                /* Clamped before the cast, not after: a corner just past the
                   near plane projects past a short, and Borland's FIST folds
                   that to -32768 -- a line to the wrong side of the screen.
                   Same trap r_span.c documents. */
                if ( fx < -4096.0f ) fx = -4096.0f;
                if ( fx >  4096.0f ) fx =  4096.0f;
                if ( fy < -4096.0f ) fy = -4096.0f;
                if ( fy >  4096.0f ) fy =  4096.0f;
                sx[i] = (short) fx;
                sy[i] = (short) fy;
                ok[i] = 1;
            }

            /* Only the ones actually on screen. Every portal of every leaf
               the flood kept includes the ones behind you and the ones off
               to the side, and drawing those buries the few you are looking
               through -- which are the only ones that explain anything. */
            if ( !infront ) continue;
            if ( hix < 0.0f || hiy < 0.0f ||
                 lox > xresh * 2.0f || loy > yresh * 2.0f ) continue;

            for ( c = 0; c < 12; c++ ) {
                short a = edge[c][0], b = edge[c][1];
                if ( ok[a] && ok[b] )
                    qglDrLine( dc, sx[a], sy[a], sx[b], sy[b], clr );
            }
        }
    }
}
