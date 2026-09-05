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
            s2.z -= brush[i].zofs;
            f2.z -= brush[i].zofs;

            tr->all_solid = 1;
            dummy = pl_hull_check_c( (short) models[i].head_node1, (float) 0.0, (float) 1.0, &s2, &f2, tr, clip, planes );
            if ( tr->all_solid ) any_solid = 1;
        }
    }

    tr->all_solid = any_solid;

    if ( tr->frac < (float) 1.0 ) {
        tr->end_pos.x = start->x + (fin->x - start->x) * tr->frac;
        tr->end_pos.y = start->y + (fin->y - start->y) * tr->frac;
        tr->end_pos.z = start->z + (fin->z - start->z) * tr->frac;
    }
}
