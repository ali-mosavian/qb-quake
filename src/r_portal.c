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
 */

#include "qcshared.h"

/*
 * Sized for real mode, where these statics are the whole cost of the file:
 * 1024 leaves is dm3ish's 313 and e1m7's 281 with room, and the tables
 * below come to about 13K. A per-leaf history of several rectangles would
 * be tighter but costs that many times more -- 4096 leaves by six rects of
 * four floats is 393K, which is not a thing that fits anywhere here.
 */
#define PT_MAX_LEAVES 1024
#define PT_MAX_STACK  1024   /* frontier depth */
#define PT_MAX_WORK   8192   /* total pushes before giving up on the frame */

/* A portal entry as mkportals.py writes it: neighbour leaf, then the
   portal's world-space bounding box as mins[3], maxs[3]. BSP space, Z-up. */
#define PT_REF_SHORTS 7

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

static short far stk_leaf[PT_MAX_STACK];
static short far stk_rect[PT_MAX_STACK][4];

static long culled_run;
static short culled_frame;
static short gave_up;

/*
 * A portal's box projected to a screen rectangle.
 *
 * Returns 0 when the box is entirely behind the near plane, and the whole
 * screen when it straddles it. Straddling is where a projection stops being
 * bounded -- one corner just past the near plane throws the rectangle out to
 * infinity -- and the honest conservative answer is "could be anywhere",
 * which costs cull rate and cannot cost correctness. It also means this
 * needs no clipper at all.
 */
static int near project_box( short far *bb, float far *m,
                              float xresh, float yresh, float z_near,
                              Rect *out )
{
    float x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
    int i, behind = 0, infront = 0;

    for ( i = 0; i < 8; i++ ) {
        /* BSP is Z-up and the matrix wants the renderer's Y-up, the same
           swap d_faces makes building a face: renderer y is bsp z. */
        float bx = (float) bb[ (i & 1) ? 3 : 0 ];
        float bz = (float) bb[ (i & 2) ? 4 : 1 ];
        float by = (float) bb[ (i & 4) ? 5 : 2 ];
        float vx, vy, vw, sx, sy;

        /* Row-vector times a 4x4 with w = 1, matching d_faces.c. */
        vx = bx*m[0] + by*m[4] + bz*m[ 8] + m[12];
        vy = bx*m[1] + by*m[5] + bz*m[ 9] + m[13];
        vw = bx*m[3] + by*m[7] + bz*m[11] + m[15];

        if ( vw < z_near ) { behind++; continue; }
        infront++;

        sx = xresh + vx / vw * xresh;
        sy = yresh - vy / vw * yresh;
        if ( sx < x0 ) x0 = sx;
        if ( sx > x1 ) x1 = sx;
        if ( sy < y0 ) y0 = sy;
        if ( sy > y1 ) y1 = sy;
    }

    if ( !infront ) return 0;
    if ( behind ) {
        out->x0 = -1e6; out->y0 = -1e6;
        out->x1 =  1e6; out->y1 =  1e6;
        return 1;
    }
    out->x0 = x0; out->y0 = y0; out->x1 = x1; out->y1 = y1;
    return 1;
}

static int near rect_clip( Rect *a, Rect *b, Rect *out )
{
    out->x0 = a->x0 > b->x0 ? a->x0 : b->x0;
    out->y0 = a->y0 > b->y0 ? a->y0 : b->y0;
    out->x1 = a->x1 < b->x1 ? a->x1 : b->x1;
    out->y1 = a->y1 < b->y1 ? a->y1 : b->y1;
    return ( out->x1 > out->x0 && out->y1 > out->y0 );
}

/*
 * Narrow pvsb to the leaves this eye can actually see through portals.
 *
 * Returns the number of leaves cleared, or -1 if the flood ran past its work
 * budget -- in which case pvsb is left exactly as the PVS produced it, which
 * is today's behaviour and always correct.
 */
short pascal far r_portal_mark(
    float     *m,
    short      cam_leaf,
    short      visleafs,
    float      xresh,
    float      yresh,
    float      z_near,
    BASARRAY  *a_index,
    BASARRAY  *a_refs,
    BASARRAY  *a_pvsb,
    BASARRAY  *a_out
)
{
    short far *index = (short far *) a_index->farptr;
    short far *refs  = (short far *) a_refs->farptr;
    short far *pvsb  = (short far *) a_pvsb->farptr;
    short far *outb  = (short far *) a_out->farptr;
    Rect screen, rect, pr, sub;
    short sp = 0, i, k, li, nb, first, last;
    long work = 0;

    gave_up = 0;
    culled_frame = 0;
    if ( visleafs <= 0 || visleafs >= PT_MAX_LEAVES ) return -2;
    if ( cam_leaf < 0 || cam_leaf > visleafs ) return -3;

    for ( i = 0; i <= visleafs; i++ ) reached[i] = 0;

    screen.x0 = 0.0; screen.y0 = 0.0;
    screen.x1 = xresh * 2.0; screen.y1 = yresh * 2.0;

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

        first = index[li];
        last  = index[li + 1];
        for ( k = first; k < last; k++ ) {
            short far *e = refs + (long) k * PT_REF_SHORTS;
            nb = e[0];
            if ( nb < 0 || nb > visleafs ) continue;

            if ( !project_box( e + 1, m, xresh, yresh, z_near, &pr ) ) continue;
            if ( !rect_clip( &pr, &rect, &sub ) ) continue;

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

            if ( sp >= PT_MAX_STACK ) { gave_up = 1; return -4; }
            if ( ++work >= PT_MAX_WORK ) { gave_up = 1; return -1; }
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
    culled_run += culled_frame;
    return culled_frame;
}

long pascal far r_portal_culled( void )
{
    return culled_run;
}

short pascal far r_portal_culled_frame( void )
{
    return culled_frame;
}
