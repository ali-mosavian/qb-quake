/*
 * r_walk.c -- drop-in C replacement for r_recursive_world_node.
 *
 * Compiled medium model (-mm): data pointers are NEAR by default, matching
 * how BASIC passes array parameters to an external procedure -- each is a
 * near offset (in DGROUP) to a BASARRAY descriptor, not a far pointer to
 * one. The descriptor's own farptr field IS far: the descriptor is small
 * and lives in DGROUP, but the array data it names can be anywhere.
 *
 * r_cull_box and r_cam_plane_dist are reimplemented here rather than
 * called back into BASIC. Their BASIC declares pass bbox/pt/pl as plain
 * (non-SEG) byref UDTs -- and "seg vtx as TriType" in ugl.bi's own
 * uglTriTP is what actually forces a raw far pointer for a C callee.
 * Without SEG, BASIC uses its own internal byref convention for a
 * BASIC-to-BASIC call, which a foreign pascal-convention C function has
 * no reliable way to reproduce -- confirmed the hard way: declaring
 * those parameters far hung the walk outright, and near read whatever
 * happened to be in DS at the pushed offset instead of the real bounds,
 * culling everything. Both are pure math with no BASIC-side state, so
 * porting them removes the cross-call, and the mismatch, entirely.
 *
 * r_emit_entities stays an external call -- it is rare (only brush
 * entities in view reach it) and does real BASIC-side bookkeeping
 * (g.vis.ent_left, the entity's own submodel walk) that is not worth
 * duplicating here.
 *
 * External signature matches the original BASIC sub exactly, parameter
 * for parameter -- r_draw_world, r_emit_entities and the -badorder path
 * all call this unchanged. r_emit_entities's own reentrant call into this
 * same entry point works automatically: each call is a fresh invocation
 * on the real hardware stack, no shared mutable state to corrupt across
 * the reentry, which is exactly the property a hand-rolled explicit
 * stack (tried and reverted in BASIC) could not get for free.
 *
 * The entry point unpacks every descriptor's farptr ONCE, then hands off
 * to r_walk_rec -- static (this file only) and near (called only from
 * here, in the same segment) -- for the actual recursion. That split is
 * the whole point: the recursive calls only ever push one far pointer
 * (nodenr fits in it, see WalkCtx) instead of re-deriving eight far
 * pointers from their descriptors at every node.
 */

#include "qcshared.h"

/*
 * Game.vis's own OFFSET is not something to hand-derive: Game carries
 * five nested structs (World, Env, PlayerState, CamState, RenderState)
 * before vis, and getting any one of their sizes wrong silently
 * corrupts whichever field lands on the wrong address. Measured instead,
 * via varptr(g.vis) - varptr(g): main.bas asserts it at startup (see
 * r_walk_layout_ok) so a field added ahead of vis fails loud at run time
 * instead of silently drifting, and the failure prints the offset it
 * measured -- which is the new number to put here.
 */
#define GAME_VIS_OFFSET 4988

/* e1m6 has 107 submodels; a map with more drawn than this asks at every
   node, as the walk always did. On the stack: DGROUP is string space. */
#define ENT_NODES_MAX 128

/* ign here is BASIC's own "ign as integer" -- no byval in the original
   declare, so it is BYREF: r_emit_entities sets it true, walks the
   entity's own submodel tree, then sets it back false before returning
   (see its own comment on why that would not terminate otherwise).
   Passing our own local's address is exactly what the recursive BASIC
   version did implicitly, since ITS "ign" parameter was byval too, and
   this makes the same copy-in/copy-out explicit. campos stays a plain
   (near) byref UDT, matching how the original recursive BASIC version's
   own call to r_emit_entities compiled -- see the file header for why
   this is a guess for the rare/untested entity path rather than
   something verified as directly as r_cull_box/r_cam_plane_dist were. */
extern void pascal far r_emit_entities(
    void  *g,
    short  nodenr,
    long   model_count,
    Vec3f *campos,
    short *ign,
    BASARRAY *models,
    BASARRAY *brush,
    BASARRAY *nodes,
    BASARRAY *planes,
    BASARRAY *pvsb,
    BASARRAY *pflag,
    BASARRAY *ord,
    BASARRAY *fru
);

/* DiskVertex: single-precision scratch r_cull_box_c projects bbox's
   integer corners into before dotting with a frustum plane -- matches
   src/bspfile.bi's own DiskVertex exactly (x,y,z as single). Local to
   this file: nothing else needs it. */
typedef struct { float x, y, z; } DiskVertex;

/* r_bsp.bas's r_cull_box with Quake's clip flags (R_RecursiveWorldNode):
   mask holds the frustum planes the box may still cross. The near corner
   outside a plane rejects the box, -1; the far corner inside it too means
   every box below this one is inside, so the plane leaves the mask its
   children get. A child's box lies in its parent's, so a dropped test
   could only have passed. The box comes packed, a byte a coordinate, and
   the y/z swap is r_cam_plane_dist's: renderer y is bsp z. */
#define CLIP_ALL 0x3f

static int near r_cull_box_c( PackedBounds far *bbox, DiskPlane far *frustum, int mask )
{
    DiskVertex n, f;
    float lo[3], hi[3], dp;
    int i;

    if ( !mask ) return 0;
    lo[0] = (float) bbox->q[0] * BOUND_Q + BOUND_BASE;
    lo[1] = (float) bbox->q[2] * BOUND_Q + BOUND_BASE;
    lo[2] = (float) bbox->q[1] * BOUND_Q + BOUND_BASE;
    hi[0] = (float) bbox->q[3] * BOUND_Q + BOUND_BASE;
    hi[1] = (float) bbox->q[5] * BOUND_Q + BOUND_BASE;
    hi[2] = (float) bbox->q[4] * BOUND_Q + BOUND_BASE;

    for ( i = 0; i < 6; i++ ) {
        if ( !( mask & ( 1 << i ) ) ) continue;
        if ( frustum[i].norm.x > 0.0 ) { n.x = lo[0]; f.x = hi[0]; } else { n.x = hi[0]; f.x = lo[0]; }
        if ( frustum[i].norm.y > 0.0 ) { n.y = lo[1]; f.y = hi[1]; } else { n.y = hi[1]; f.y = lo[1]; }
        if ( frustum[i].norm.z > 0.0 ) { n.z = lo[2]; f.z = hi[2]; } else { n.z = hi[2]; f.z = lo[2]; }
        dp = frustum[i].norm.x * n.x + frustum[i].norm.y * n.y + frustum[i].norm.z * n.z;
        if ( (dp + frustum[i].dist) > 0 ) return -1;
        dp = frustum[i].norm.x * f.x + frustum[i].norm.y * f.y + frustum[i].norm.z * f.z;
        if ( (dp + frustum[i].dist) <= 0 ) mask &= ~( 1 << i );
    }
    return mask;
}

/* Transcribed from r_bsp.bas's r_cam_plane_dist: same y/z swap dotting a
   renderer-space (y-up) point against a BSP-space (z-up) plane normal. */
static float near r_cam_plane_dist_c( Vec3f far *pt, Plane far *pl )
{
    return pt->x * pl->norm.x + pt->y * pl->norm.z + pt->z * pl->norm.y - pl->dist;
}

/* Bundles everything the recursion needs so a call only ever pushes ONE
   far pointer plus nodenr, instead of re-pushing every invariant at every
   level -- see the file header. Built once per top-level call, in
   r_recursive_world_node, from the real BASARRAY descriptors. */
typedef struct {
    Node      far *nds;
    Leaf      far *lef;
    Plane     far *pln;
    DiskPlane far *fru;
    short     far *lfc;
    short     far *pvsb;
    short     far *pflag;
    short     far *ord;
    VisState  far *vis;
    Vec3f          cpos;
    short          ign;
    /* r_emit_entities still wants the descriptor for its own fru()
       parameter -- an array parameter, unlike bbox/pt/pl above. */
    BASARRAY      *fru_dsc;
    /* passed straight through to r_emit_entities, untouched here */
    void          *g;
    long           model_count;
    BASARRAY      *models;
    BASARRAY      *brush;
    BASARRAY      *nodes_dsc;
    BASARRAY      *planes_dsc;
    BASARRAY      *pvsb_dsc;
    BASARRAY      *pflag_dsc;
    BASARRAY      *ord_dsc;
    /* the nodes drawn brush models sit at, ascending; -1 when there are
       more models than room, and every node asks */
    short         *ent_node;
    short          ent_n;
} WalkCtx;

/* A leaf's faces marked and its entities emitted, in a frame of its own:
   the recursion below carries no locals but the node array and the side,
   about 24 bytes a level, where the nine far pointers it used to copy
   made 70 -- and e1m3 is 85 deep, which ran BASIC's 8K stack out into
   DGROUP and came back as "runtime error 9" from a procedure entry. */
/* r_emit_entities is BASIC and loops over every model, so it is asked
   only at a node some drawn model sits at -- not, as it was, at every
   node visited while any entity was unplaced, which on a map of doors
   is every node. */
static int near r_walk_has_ent( WalkCtx *ctx, int nodenr )
{
    int lo = 0, hi = ctx->ent_n - 1, mid;

    if ( ctx->ent_n < 0 ) return 1;
    while ( lo <= hi ) {
        mid = ( lo + hi ) >> 1;
        if ( ctx->ent_node[mid] == nodenr ) return 1;
        if ( ctx->ent_node[mid] < nodenr ) lo = mid + 1; else hi = mid - 1;
    }
    return 0;
}

static void near r_walk_emit( WalkCtx *ctx, int nodenr )
{
    short ign_tmp = ctx->ign;

    if ( ctx->ign || !r_walk_has_ent( ctx, nodenr ) ) return;

    r_emit_entities( ctx->g, nodenr, ctx->model_count, &ctx->cpos,
                      &ign_tmp, ctx->models, ctx->brush,
                      ctx->nodes_dsc, ctx->planes_dsc,
                      ctx->pvsb_dsc, ctx->pflag_dsc, ctx->ord_dsc,
                      ctx->fru_dsc );
}

static void near r_walk_leaf( WalkCtx *ctx, int nodenr, int mask )
{
    Leaf      far *lef   = ctx->lef;
    short     far *lfc   = ctx->lfc;
    short     far *pflag = ctx->pflag;
    int i, frst, last, leafnr;

    leafnr = ~nodenr;
    if ( (ctx->ign || ctx->pvsb[leafnr]) &&
         r_cull_box_c( &lef[leafnr].bound, ctx->fru, mask ) >= 0 ) {
        frst = lef[leafnr].lface_id;
        last = frst + lef[leafnr].lface_num;
        for ( i = frst; i < last; i++ )
            pflag[ lfc[i] >> 4 ] |= (short) ( 1 << ( lfc[i] & 15 ) );

        if ( ctx->vis->ent_left ) r_walk_emit( ctx, nodenr );

        ctx->vis->drw_leafs++;
    } else {
        ctx->vis->cul_leafs++;
    }
}

static void near r_walk_rec( WalkCtx *ctx, int nodenr, int mask )
{
    Node far *nds = ctx->nds;
    int side;

    if ( nodenr & 0x8000 ) {
        r_walk_leaf( ctx, nodenr, mask );
        return;
    }

    mask = r_cull_box_c( &nds[nodenr].bound, ctx->fru, mask );
    if ( mask < 0 ) return;

    side = ( r_cam_plane_dist_c( &ctx->cpos, &ctx->pln[ nds[nodenr].plane_id ] ) >= 0.0 );

    if ( side ) {
        r_walk_rec( ctx, nds[nodenr].child1, mask );
        if ( ctx->vis->ent_left ) r_walk_emit( ctx, nodenr );
        ctx->ord[ ctx->vis->ord_count++ ] = nodenr;
        r_walk_rec( ctx, nds[nodenr].child0, mask );
    } else {
        r_walk_rec( ctx, nds[nodenr].child0, mask );
        if ( ctx->vis->ent_left ) r_walk_emit( ctx, nodenr );
        ctx->ord[ ctx->vis->ord_count++ ] = nodenr;
        r_walk_rec( ctx, nds[nodenr].child1, mask );
    }
}

void pascal far r_recursive_world_node(
    void  *g,
    short  nodenr,
    long   model_count,
    BASARRAY *models,
    BASARRAY *brush,
    Vec3f *cpos,
    short  ign,
    BASARRAY *nds_dsc,
    BASARRAY *pln_dsc,
    BASARRAY *lef_dsc,
    BASARRAY *lfc_dsc,
    BASARRAY *pvsb_dsc,
    BASARRAY *pflag_dsc,
    BASARRAY *ord_dsc,
    BASARRAY *fru_dsc
)
{
    WalkCtx ctx;
    short ent_node[ENT_NODES_MAX];
    BrushModel far *bm = (BrushModel far *) brush->farptr;
    short m, k, v;

    ctx.nds   = (Node      far *) nds_dsc->farptr;
    ctx.lef   = (Leaf      far *) lef_dsc->farptr;
    ctx.pln   = (Plane     far *) pln_dsc->farptr;
    ctx.fru   = (DiskPlane far *) fru_dsc->farptr;
    ctx.lfc   = (short     far *) lfc_dsc->farptr;
    ctx.pvsb  = (short     far *) pvsb_dsc->farptr;
    ctx.pflag = (short     far *) pflag_dsc->farptr;
    ctx.ord   = (short     far *) ord_dsc->farptr;
    ctx.vis   = (VisState  far *) ( (char far *) g + GAME_VIS_OFFSET );
    ctx.cpos  = *cpos;
    ctx.ign   = ign;
    ctx.fru_dsc = fru_dsc;

    ctx.g           = g;
    ctx.model_count = model_count;
    ctx.models      = models;
    ctx.brush       = brush;
    ctx.nodes_dsc   = nds_dsc;
    ctx.planes_dsc  = pln_dsc;
    ctx.pvsb_dsc    = pvsb_dsc;
    ctx.pflag_dsc   = pflag_dsc;
    ctx.ord_dsc     = ord_dsc;

    ctx.ent_node = ent_node;
    ctx.ent_n    = 0;
    for ( m = 1; m < (short) model_count && !ign; m++ ) {
        if ( !bm[m].draw ) continue;
        if ( ctx.ent_n == ENT_NODES_MAX ) { ctx.ent_n = -1; break; }
        v = bm[m].node;
        for ( k = ctx.ent_n++; k > 0 && ent_node[k - 1] > v; k-- ) ent_node[k] = ent_node[k - 1];
        ent_node[k] = v;
    }

    r_walk_rec( &ctx, nodenr, CLIP_ALL );
}

/* Called once at startup (see main.bas) with off = varptr(g.vis)-varptr(g):
   fails loud if a field ever gets added ahead of vis in Game, instead of
   silently corrupting whichever VisState field the wrong offset lands on. */
/* every face bit off, at the top of the frame: 16 a word, so the
   episode maps cost 350 words here and 700 bytes of far heap, where the
   frame stamp this replaced cost two bytes a face for the whole map */
void pascal far r_pflag_clear( BASARRAY *pflag_dsc, short nwords )
{
    short far *p = (short far *) pflag_dsc->farptr;
    short i;

    for ( i = 0; i < nwords; i++ ) p[i] = 0;
}

int pascal far r_walk_layout_ok( long off )
{
    return ( off == GAME_VIS_OFFSET );
}
