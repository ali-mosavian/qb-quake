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

typedef struct _BASARRAY {
    void  far *farptr;
    short next_dsc;
    short next_dsc_size;
    char  dimensions;
    char  type_storage;
    short adjs_offset;
    short element_len;
    short last_dim_elemts;
    short last_dim_first;
} BASARRAY;

typedef struct { short x, y, z; } Vec3i;
typedef struct { Vec3i min, max; } Bounds;
typedef struct { float x, y, z; } Vec3f;

typedef struct {
    short plane_id;
    short child0;
    short child1;
    short lface_id;
    short lface_num;
    Bounds bound;
} Node;

typedef struct {
    short cont;
    long  vis_list;
    Bounds bound;
    short lface_id;
    short lface_num;
} Leaf;

typedef struct { Vec3f norm; float dist; short ptype; } Plane;
typedef struct { Vec3f norm; float dist; long  ptype; } DiskPlane;

/*
 * VisState's own fields, verified against src/q_vis.bi's declared order:
 * frame_stamp(int) ord_count(long) drw_leafs(int) cul_leafs(int)
 * ent_left(int) no_ents(int) bad_order(int) -- all scalars, no padding,
 * so this is a direct transcription, not a guess.
 *
 * Game.vis's own OFFSET is not something to hand-derive: Game carries
 * five nested structs (World, Env, PlayerState, CamState, RenderState)
 * before vis, and getting any one of their sizes wrong silently
 * corrupts whichever field lands on the wrong address. Measured instead,
 * via varptr(g.vis) - varptr(g) in a throwaway BASIC probe: 5022. main.bas
 * asserts this at startup (see r_walk_layout_ok) so a future field added
 * ahead of vis fails loud at run time instead of silently drifting.
 */
typedef struct {
    short frame_stamp;
    long  ord_count;
    short drw_leafs;
    short cul_leafs;
    short ent_left;
    short no_ents;
    short bad_order;
} VisState;

#define GAME_VIS_OFFSET 5022

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
   src/bspfile.bi's own DiskVertex exactly (x,y,z as single). */
typedef struct { float x, y, z; } DiskVertex;

/* Transcribed from r_bsp.bas's r_cull_box, not reimagined: same 8-way
   branch on the frustum plane's normal sign to pick the box's near
   corner, same y/z swap copying from bbox (BSP, z-up) into near_point
   (renderer, y-up) -- near_point.y = bbox micro.z, near_point.z = bbox
   corner.y, matching r_cam_plane_dist's own swap below. bbox.min/max are
   Vec3i; the assignment into a float DiskVertex is BASIC's own implicit
   int-to-single conversion, so this does the cast explicitly instead of
   leaving it for the compiler to decide silently. */
static int near r_cull_box_c( Bounds far *bbox, DiskPlane far *frustum )
{
    DiskVertex near_point;
    float dp;
    int i;

    for ( i = 0; i < 6; i++ ) {
        if ( frustum[i].norm.x > 0.0 ) {
            if ( frustum[i].norm.y > 0.0 ) {
                if ( frustum[i].norm.z > 0.0 ) {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->max.y;
                }
            } else {
                if ( frustum[i].norm.z > 0.0 ) {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->max.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->max.z;
                    near_point.z = (float) bbox->max.y;
                }
            }
        } else {
            if ( frustum[i].norm.y > 0.0 ) {
                if ( frustum[i].norm.z > 0.0 ) {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->max.y;
                }
            } else {
                if ( frustum[i].norm.z > 0.0 ) {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->max.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->max.z;
                    near_point.z = (float) bbox->max.y;
                }
            }
        }

        dp = frustum[i].norm.x * near_point.x + frustum[i].norm.y * near_point.y +
             frustum[i].norm.z * near_point.z;

        if ( (dp + frustum[i].dist) > 0 ) return 0;
    }

    return -1;
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
} WalkCtx;

static void near r_walk_rec( WalkCtx *ctx, int nodenr )
{
    Node      far *nds  = ctx->nds;
    Leaf      far *lef  = ctx->lef;
    Plane     far *pln  = ctx->pln;
    DiskPlane far *fru  = ctx->fru;
    short     far *lfc  = ctx->lfc;
    short     far *pvsb = ctx->pvsb;
    short     far *pflag = ctx->pflag;
    short     far *ord  = ctx->ord;
    VisState  far *vis  = ctx->vis;
    short ign_tmp;

    int side, i, frst, last, leafnr;

    if ( nodenr & 0x8000 ) {
        leafnr = ~nodenr;
        if ( (ctx->ign || pvsb[leafnr]) &&
             r_cull_box_c( &lef[leafnr].bound, fru ) ) {
            frst = lef[leafnr].lface_id;
            last = frst + lef[leafnr].lface_num;
            for ( i = frst; i < last; i++ )
                pflag[ lfc[i] ] = vis->frame_stamp;

            if ( vis->ent_left ) {
                ign_tmp = ctx->ign;
                r_emit_entities( ctx->g, nodenr, ctx->model_count, &ctx->cpos,
                                  &ign_tmp, ctx->models, ctx->brush,
                                  ctx->nodes_dsc, ctx->planes_dsc,
                                  ctx->pvsb_dsc, ctx->pflag_dsc, ctx->ord_dsc,
                                  ctx->fru_dsc );
            }

            vis->drw_leafs++;
        } else {
            vis->cul_leafs++;
        }
        return;
    }

    if ( !r_cull_box_c( &nds[nodenr].bound, fru ) ) return;

    side = ( r_cam_plane_dist_c( &ctx->cpos, &pln[ nds[nodenr].plane_id ] ) >= 0.0 );

    if ( side ) {
        r_walk_rec( ctx, nds[nodenr].child1 );
        if ( vis->ent_left ) {
            ign_tmp = ctx->ign;
            r_emit_entities( ctx->g, nodenr, ctx->model_count, &ctx->cpos,
                              &ign_tmp, ctx->models, ctx->brush,
                              ctx->nodes_dsc, ctx->planes_dsc,
                              ctx->pvsb_dsc, ctx->pflag_dsc, ctx->ord_dsc,
                              ctx->fru_dsc );
        }
        ord[ vis->ord_count++ ] = nodenr;
        r_walk_rec( ctx, nds[nodenr].child0 );
    } else {
        r_walk_rec( ctx, nds[nodenr].child0 );
        if ( vis->ent_left ) {
            ign_tmp = ctx->ign;
            r_emit_entities( ctx->g, nodenr, ctx->model_count, &ctx->cpos,
                              &ign_tmp, ctx->models, ctx->brush,
                              ctx->nodes_dsc, ctx->planes_dsc,
                              ctx->pvsb_dsc, ctx->pflag_dsc, ctx->ord_dsc,
                              ctx->fru_dsc );
        }
        ord[ vis->ord_count++ ] = nodenr;
        r_walk_rec( ctx, nds[nodenr].child1 );
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

    r_walk_rec( &ctx, nodenr );
}

/* Called once at startup (see main.bas) with off = varptr(g.vis)-varptr(g):
   fails loud if a field ever gets added ahead of vis in Game, instead of
   silently corrupting whichever VisState field the wrong offset lands on. */
int pascal far r_walk_layout_ok( long off )
{
    return ( off == GAME_VIS_OFFSET );
}
