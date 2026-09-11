/*
 * pl_trace.c -- drop-in C replacement for pl_trace, pl_hull_check and
 * pl_hull_contents (src/pl_move.bas).
 *
 * Cleaner than r_walk.c/sb_build.c: pl_trace is the only external entry
 * point (pl_hull_check/pl_hull_contents are called only from within this
 * trio in the original BASIC too, so they never need to be externally
 * callable here either -- pure static near helpers, no reentrancy
 * concerns to design around). No g as Game, so no offset to measure or
 * assert. No calls to any other BASIC function at all -- everything is
 * arithmetic plus direct array/UDT field access, so none of r_walk.c's
 * "does this other function's byref-UDT parameter survive a foreign
 * call" question applies anywhere in this file.
 *
 * start/fin/tr arrive as plain (non-SEG) byref UDTs from pl_trace's four
 * BASIC callers (pl_slide_move, pl_step_move x2, pl_gravity) -- the same
 * shape r_walk.c's cpos parameter had, which worked correctly as a near
 * pointer under -mm. Same assumption here, verified the same way: build
 * it, then compare px/py/pz/vz/onground against the original build under
 * -walk/-jump (already-established ground truth for this exact code),
 * not by inspecting disassembly.
 */

#include "qcshared.h"

#define CONTENTS_SOLID (-2)
#define PL_CLIP_EPS ((float) 0.03125)

/* Transcribed from pl_move.bas's pl_hull_contents: walk the hull from
   node, front or back per which side of the plane p falls on, until a
   leaf (node < 0) is reached. */
static short near pl_hull_contents_c( short node, Vec3 far *p, ClipNode far *clip, Plane far *planes )
{
    short pid;
    float d;

    while ( node >= 0 ) {
        pid = clip[node].plane_num;
        d = p->x * planes[pid].norm.x + p->y * planes[pid].norm.y +
            p->z * planes[pid].norm.z - planes[pid].dist;
        if ( d >= 0.0 ) node = clip[node].front;
        else            node = clip[node].back;
    }

    return node;
}

/* Transcribed from pl_move.bas's pl_hull_check, not reimagined: same
   epsilon-backed split at the plane crossing, same near-half-first
   order (an earlier hit wins), same re-read of clip[node] AFTER the
   near-half recursion returns rather than a cached copy from before it
   (the original's own comment: "the recursion above moved the window;
   map before reading again" -- clip[node] here is a fresh array index
   each time, never hoisted into a local, so this falls out for free). */
static short near pl_hull_check_c(
    short node, float p1f, float p2f,
    Vec3 far *p1, Vec3 far *p2,
    TraceResult *tr,
    ClipNode far *clip, Plane far *planes
)
{
    short pid, side, other;
    float t1, t2, frac, midf;
    Vec3 midp;

    if ( node < 0 ) {
        tr->all_solid = ( node == CONTENTS_SOLID ) ? 1 : 0;
        return 1;
    }

    pid = clip[node].plane_num;
    t1 = p1->x * planes[pid].norm.x + p1->y * planes[pid].norm.y +
         p1->z * planes[pid].norm.z - planes[pid].dist;
    t2 = p2->x * planes[pid].norm.x + p2->y * planes[pid].norm.y +
         p2->z * planes[pid].norm.z - planes[pid].dist;

    if ( t1 >= 0.0 && t2 >= 0.0 )
        return pl_hull_check_c( clip[node].front, p1f, p2f, p1, p2, tr, clip, planes );
    if ( t1 < 0.0 && t2 < 0.0 )
        return pl_hull_check_c( clip[node].back, p1f, p2f, p1, p2, tr, clip, planes );

    if ( t1 < 0.0 ) {
        frac = (t1 + PL_CLIP_EPS) / (t1 - t2);
        side = 1;
    } else {
        frac = (t1 - PL_CLIP_EPS) / (t1 - t2);
        side = 0;
    }
    if ( frac < 0.0 ) frac = 0.0;
    if ( frac > 1.0 ) frac = 1.0;

    midf   = p1f + (p2f - p1f) * frac;
    midp.x = p1->x + (p2->x - p1->x) * frac;
    midp.y = p1->y + (p2->y - p1->y) * frac;
    midp.z = p1->z + (p2->z - p1->z) * frac;

    if ( side == 0 ) {
        if ( !pl_hull_check_c( clip[node].front, p1f, midf, p1, &midp, tr, clip, planes ) )
            return 0;
        other = clip[node].back;
    } else {
        if ( !pl_hull_check_c( clip[node].back, p1f, midf, p1, &midp, tr, clip, planes ) )
            return 0;
        other = clip[node].front;
    }

    if ( pl_hull_contents_c( other, &midp, clip, planes ) != CONTENTS_SOLID )
        return pl_hull_check_c( other, midf, p2f, &midp, p2, tr, clip, planes );

    if ( tr->all_solid ) {
        tr->start_solid = 1;
        return 0;
    }

    if ( tr->frac > midf ) {
        tr->frac    = midf;
        tr->end_pos = midp;
        if ( side == 1 ) {
            tr->norm.x = -planes[pid].norm.x;
            tr->norm.y = -planes[pid].norm.y;
            tr->norm.z = -planes[pid].norm.z;
        } else {
            tr->norm.x = planes[pid].norm.x;
            tr->norm.y = planes[pid].norm.y;
            tr->norm.z = planes[pid].norm.z;
        }
    }

    return 0;
}

/* SOLID_BBOX entities -- the exploding boxes -- as pl_boxes_sync sets
   them. Every trace sweeps the live ones after the hulls, each grown by
   the player's hull-1 box, since a trace here is a point through hull 1:
   the same Minkowski sum the clipnodes carry for the world. */
#define PL_BOXES 8
typedef struct { float mins[3], maxs[3]; short on; } SolidBox;
static SolidBox near pl_box[PL_BOXES] = { 0 };

void pascal far pl_box_solid( short i, Vec3 *mins, Vec3 *maxs, short on )
{
    if ( i < 0 || i >= PL_BOXES ) return;
    pl_box[i].mins[0] = mins->x; pl_box[i].mins[1] = mins->y; pl_box[i].mins[2] = mins->z;
    pl_box[i].maxs[0] = maxs->x; pl_box[i].maxs[1] = maxs->y; pl_box[i].maxs[2] = maxs->z;
    pl_box[i].on = on;
}

/* The slab test: the segment against the grown box, an earlier hit than
   tr->frac taking it, backed off PL_CLIP_EPS as the hull walk does. A
   start inside is start_solid, as SV_ClipMoveToEntity reports it. */
static void near pl_box_sweep( Vec3 *s, Vec3 *f, SolidBox *b, TraceResult *tr )
{
    static float grow_lo[3] = { (float) 16.0, (float) 16.0, (float) 32.0 };
    static float grow_hi[3] = { (float) 16.0, (float) 16.0, (float) 24.0 };
    float sp[3], fp[3], t0 = (float) 0.0, t1 = (float) 1.0, d, ta, tb, tmp;
    short ax, hit_ax = -1, sign, hs = 0;

    sp[0] = s->x; sp[1] = s->y; sp[2] = s->z;
    fp[0] = f->x; fp[1] = f->y; fp[2] = f->z;
    for ( ax = 0; ax < 3; ax++ ) {
        d  = fp[ax] - sp[ax];
        ta = b->mins[ax] - grow_lo[ax] - sp[ax];
        tb = b->maxs[ax] + grow_hi[ax] - sp[ax];
        if ( d == (float) 0.0 ) {
            if ( ta > (float) 0.0 || tb < (float) 0.0 ) return;
            continue;
        }
        ta /= d; tb /= d; sign = -1;
        if ( ta > tb ) { tmp = ta; ta = tb; tb = tmp; sign = 1; }
        if ( ta > t0 ) { t0 = ta; hit_ax = ax; hs = sign; }
        if ( tb < t1 ) t1 = tb;
        if ( t0 > t1 ) return;
    }
    if ( hit_ax < 0 ) {
        tr->start_solid = tr->all_solid = 1;
        tr->frac = (float) 0.0;
        return;
    }
    if ( t0 >= tr->frac ) return;
    d = fp[hit_ax] - sp[hit_ax];
    if ( d < (float) 0.0 ) d = -d;
    t0 -= PL_CLIP_EPS / d;
    if ( t0 < (float) 0.0 ) t0 = (float) 0.0;
    tr->frac = t0;
    tr->norm.x = tr->norm.y = tr->norm.z = (float) 0.0;
    if ( hit_ax == 0 ) tr->norm.x = (float) hs;
    else if ( hit_ax == 1 ) tr->norm.y = (float) hs;
    else tr->norm.z = (float) hs;
}

/* The only external entry point -- pl_slide_move, pl_step_move (x2) and
   pl_gravity all call this unchanged. */
void pascal far pl_trace(
    Vec3 *start,
    Vec3 *fin,
    TraceResult *tr,
    short model_count,
    BASARRAY *models_dsc,
    BASARRAY *brush_dsc,
    BASARRAY *clip_dsc,
    BASARRAY *planes_dsc
)
{
    Submodel   far *models = (Submodel   far *) models_dsc->farptr;
    BrushModel far *brush  = (BrushModel far *) brush_dsc->farptr;
    ClipNode   far *clip   = (ClipNode   far *) clip_dsc->farptr;
    Plane      far *planes = (Plane      far *) planes_dsc->farptr;

    short i, dummy, any_solid;
    Vec3 s2, f2;

    tr->frac        = (float) 1.0;
    tr->end_pos     = *fin;
    tr->norm.x      = (float) 0.0;
    tr->norm.y      = (float) 0.0;
    tr->norm.z      = (float) 0.0;
    tr->start_solid = 0;

    tr->all_solid = 1;
    dummy = pl_hull_check_c( (short) models[0].head_node1, (float) 0.0, (float) 1.0, start, fin, tr, clip, planes );
    any_solid = tr->all_solid;

    for ( i = 1; i < model_count; i++ ) {
        if ( brush[i].solid ) {
            s2 = *start;
            f2 = *fin;
            s2.x -= brush[i].ofs.x; s2.y -= brush[i].ofs.y; s2.z -= brush[i].ofs.z;
            f2.x -= brush[i].ofs.x; f2.y -= brush[i].ofs.y; f2.z -= brush[i].ofs.z;

            tr->all_solid = 1;
            dummy = pl_hull_check_c( (short) models[i].head_node1, (float) 0.0, (float) 1.0, &s2, &f2, tr, clip, planes );
            if ( tr->all_solid ) any_solid = 1;
        }
    }

    tr->all_solid = any_solid;

    for ( i = 0; i < PL_BOXES; i++ )
        if ( pl_box[i].on ) pl_box_sweep( start, fin, &pl_box[i], tr );

    if ( tr->frac < (float) 1.0 ) {
        tr->end_pos.x = start->x + (fin->x - start->x) * tr->frac;
        tr->end_pos.y = start->y + (fin->y - start->y) * tr->frac;
        tr->end_pos.z = start->z + (fin->z - start->z) * tr->frac;
    }
}
