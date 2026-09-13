/*
 * r_bsp.c -- BSP traversal and visibility. C port of r_bsp.bas, minus
 * r_recursive_world_node (r_walk.c, its own translation unit both in
 * the BASIC-linked build and here, for the same reason: the recursive
 * hot path wants a tight, purpose-built call frame, not this file's
 * struct-heavy per-call setup) and minus the loading functions
 * (r_load_lfaces/r_alloc_pvs/r_load_leaves/r_load_portals -- deferred
 * alongside model.bas's own binary I/O, matching ent.bas's and
 * pl_move.bas's own loaders).
 *
 * Decompresses the PVS for the camera's leaf, walks the tree front to
 * back culling against the frustum, and records the draw order the
 * rasteriser follows. Quake splits it the same way: r_bsp.c decides
 * what is seen, the d_ side draws it.
 */

#include <math.h>
#include "qgl.h"
#include <stdio.h>
#include <stdlib.h>
#include <mem.h>    /* _fmemcpy/_fmemset -- the per-frame walk bitmaps */

#include "r_bsp.h"
#include "r_walk.h"
#include "r_portal.h"
#include "assets.h"

/* Takes a RENDERER point: Y-up there, Z-up in the BSP, so y pairs with
   norm.z. Single, not double: returning double moved two edge-on faces
   onto the other side of their plane in the original BASIC. */
float r_plane_dist( BspVec3 *p, Plane far *pl )
{
    return p->x*pl->norm.x + p->y*pl->norm.y + p->z*pl->norm.z - pl->dist;
}

/* The leaf holding p, walking hull 0. Bit 15 marks a leaf; ~ is its index. */
short r_point_leaf( BspVec3 *p, World *world )
{
    short nodenr = 0;

    while ( !(nodenr & 0x8000) ) {
        Node far *n = &world->nodes[nodenr];
        if ( r_plane_dist( p, &world->planes[n->plane_id] ) >= 0.0f )
            nodenr = n->child0;
        else
            nodenr = n->child1;
    }

    return ~nodenr;
}

/* pl_move's point test walks the node tree itself and needs exactly
   this at the end of it, which is not reason enough for the whole
   leaves array to be shared beyond World. */
short r_leaf_contents( short leaf_nr, World *world )
{
    return world->leaves[leaf_nr].cont;
}

float r_cam_plane_dist( Vec3 *pt, Plane far *pl )
{
    return pt->x*pl->norm.x + pt->y*pl->norm.z + pt->z*pl->norm.y - pl->dist;
}

/* Which side of a node's splitting plane a point falls on: -1 front, 0 behind. */
short r_node_side( short node_idx, Vec3 *pt, World *world )
{
    Node far *n = &world->nodes[node_idx];
    if ( r_cam_plane_dist( pt, &world->planes[n->plane_id] ) > 0.0f ) return -1;
    return 0;
}

/* r_bsp.bas's r_cull_box with Quake's clip flags (R_RecursiveWorldNode):
   mask holds the frustum planes the box may still cross. The near corner
   outside a plane rejects the box, -1; the far corner inside it too means
   every box below this one is inside, so that plane leaves the mask the
   children get -- a child's box lies in its parent's, so a dropped test
   could only have passed. The box arrives packed, a byte a coordinate,
   and the y/z swap is r_cam_plane_dist's: renderer y is bsp z. */
short r_cull_box( PackedBounds far *bbox, DiskPlane far *frustum, short mask )
{
    BspVec3 n, f;
    float lo[3], hi[3], dp;
    short i;

    if ( !mask ) return 0;

    lo[0] = (float) bbox->q[0] * BOUND_Q + BOUND_BASE;
    lo[1] = (float) bbox->q[2] * BOUND_Q + BOUND_BASE;
    lo[2] = (float) bbox->q[1] * BOUND_Q + BOUND_BASE;
    hi[0] = (float) bbox->q[3] * BOUND_Q + BOUND_BASE;
    hi[1] = (float) bbox->q[5] * BOUND_Q + BOUND_BASE;
    hi[2] = (float) bbox->q[4] * BOUND_Q + BOUND_BASE;

    for ( i = 0; i < 6; i++ ) {
        if ( !( mask & ( 1 << i ) ) ) continue;

        if ( frustum[i].norm.x > 0.0f ) { n.x = lo[0]; f.x = hi[0]; } else { n.x = hi[0]; f.x = lo[0]; }
        if ( frustum[i].norm.y > 0.0f ) { n.y = lo[1]; f.y = hi[1]; } else { n.y = hi[1]; f.y = lo[1]; }
        if ( frustum[i].norm.z > 0.0f ) { n.z = lo[2]; f.z = hi[2]; } else { n.z = hi[2]; f.z = lo[2]; }

        dp = frustum[i].norm.x*n.x + frustum[i].norm.y*n.y + frustum[i].norm.z*n.z;
        if ( (dp + frustum[i].dist) > 0.0f ) return -1;

        dp = frustum[i].norm.x*f.x + frustum[i].norm.y*f.y + frustum[i].norm.z*f.z;
        if ( (dp + frustum[i].dist) <= 0.0f ) mask &= ~( 1 << i );
    }

    return mask;
}

/* Six planes off the concatenated view*projection matrix (Gribb/Hartmann),
   normalized so r_cull_box's distances are in real units. */
void r_set_frustum( DiskPlane far *frustum, Mat4 *mtx )
{
    short i;
    float d;

    frustum[0].norm.x = -(mtx->m14 + mtx->m11);   /* left */
    frustum[0].norm.y = -(mtx->m24 + mtx->m21);
    frustum[0].norm.z = -(mtx->m34 + mtx->m31);
    frustum[0].dist    = -(mtx->m44 + mtx->m41);

    frustum[1].norm.x = -(mtx->m14 - mtx->m11);   /* right */
    frustum[1].norm.y = -(mtx->m24 - mtx->m21);
    frustum[1].norm.z = -(mtx->m34 - mtx->m31);
    frustum[1].dist    = -(mtx->m44 - mtx->m41);

    frustum[2].norm.x = -(mtx->m14 - mtx->m12);   /* top */
    frustum[2].norm.y = -(mtx->m24 - mtx->m22);
    frustum[2].norm.z = -(mtx->m34 - mtx->m32);
    frustum[2].dist    = -(mtx->m44 - mtx->m42);

    frustum[3].norm.x = -(mtx->m14 + mtx->m12);   /* bottom */
    frustum[3].norm.y = -(mtx->m24 + mtx->m22);
    frustum[3].norm.z = -(mtx->m34 + mtx->m32);
    frustum[3].dist    = -(mtx->m44 + mtx->m42);

    frustum[4].norm.x = -(mtx->m14 + mtx->m13);   /* near */
    frustum[4].norm.y = -(mtx->m24 + mtx->m23);
    frustum[4].norm.z = -(mtx->m34 + mtx->m33);
    frustum[4].dist    = -(mtx->m44 + mtx->m43);

    frustum[5].norm.x = -(mtx->m14 - mtx->m13);   /* far */
    frustum[5].norm.y = -(mtx->m24 - mtx->m23);
    frustum[5].norm.z = -(mtx->m34 - mtx->m33);
    frustum[5].dist    = -(mtx->m44 - mtx->m43);

    for ( i = 0; i < 6; i++ ) {
        d = 1.0f / (float) sqrt( frustum[i].norm.x*frustum[i].norm.x +
                                  frustum[i].norm.y*frustum[i].norm.y +
                                  frustum[i].norm.z*frustum[i].norm.z );
        frustum[i].norm.x *= d;
        frustum[i].norm.y *= d;
        frustum[i].norm.z *= d;
        frustum[i].dist   *= d;
    }
}

/*
 * name: r_mark_leaves
 * desc: Finds the leaf campos is in; if it's the same leaf as last
 *       frame, does nothing more -- the visible set only changes when
 *       the camera changes leaf, and the camera spends most frames in
 *       one. Otherwise decompresses that leaf's PVS entry (run-length
 *       coded: a zero byte is a marker plus a repeat count, any other
 *       byte is eight leaves' worth of bits) into rdr->pvsb.
 *
 *       world->pvs_data + v replaces the original's DEF SEG/PEEK pair
 *       (v was the lump offset, DEF SEG the segment reconstructed from
 *       a packed long) with a plain far pointer -- same address, no
 *       segment arithmetic to get wrong.
 */
/* Any leaf below nodenr in pvsb? One post-order pass, no parent
   pointers needed, run only when pvsb is rebuilt. pvs_now is a SUBSET of
   pvsb (r_portal_mark only ever clears bits), so a node this pass leaves
   unmarked can hold nothing the flood would have kept either -- and the
   leaf still gets its own pvs_now test on the way past. */
static short r_mark_sub( World *world, Renderer *rdr, short nodenr )
{
    short any;

    if ( nodenr & 0x8000 ) {
        if ( !rdr->pvsb[ (short) ~nodenr ] ) return 0;
        rdr->vis_leaves++;
        return 1;
    }
    any = r_mark_sub( world, rdr, world->nodes[nodenr].child0 );
    if ( r_mark_sub( world, rdr, world->nodes[nodenr].child1 ) ) any = 1;
    if ( any ) {
        rdr->vis_sub[nodenr >> 3] |= (unsigned char) ( 1 << (nodenr & 7) );
        rdr->vis_nodes++;
    }
    return any;
}

static void r_mark_subtrees( World *world, Renderer *rdr, short head, short all )
{
    short nb = (short) ( ( world->node_count + 7 ) / 8 ), i;

    for ( i = 0; i < nb; i++ ) rdr->vis_sub[i] = all ? 0xFF : 0;
    rdr->vis_leaves = rdr->vis_nodes = 0;
    if ( all ) {
        rdr->vis_leaves = world->leaf_count;
        rdr->vis_nodes  = world->node_count;
        return;
    }
    r_mark_sub( world, rdr, head );
}

/*
 * name: r_build_parents
 * desc: A node's parent, once at load. The walk needs to mark the path
 *       from the root down to each brush entity's insertion node, and
 *       there is no way up the tree without this.
 */
void r_build_parents( World *world, Renderer *rdr )
{
    short i, c;

    for ( i = 0; i < world->node_count; i++ ) rdr->nd_parent[i] = -1;
    for ( i = 0; i < world->leaf_count; i++ ) rdr->lf_parent[i] = -1;
    for ( i = 0; i < world->node_count; i++ ) {
        c = world->nodes[i].child0;
        if ( c & 0x8000 ) rdr->lf_parent[ (short) ~c ] = i; else rdr->nd_parent[c] = i;
        c = world->nodes[i].child1;
        if ( c & 0x8000 ) rdr->lf_parent[ (short) ~c ] = i; else rdr->nd_parent[c] = i;
    }
}

void r_mark_leaves( World *world, Renderer *rdr, short nodenr, Vec3 *campos )
{
    unsigned char far *v;
    short leafnr, l, j, byte, bit, head = 0;

    head = nodenr;              /* the root of the walk, before the descent */
    while ( !(nodenr & 0x8000) ) {
        if ( r_node_side( nodenr, campos, world ) )
            nodenr = world->nodes[nodenr].child0;
        else
            nodenr = world->nodes[nodenr].child1;
    }

    rdr->dbg_camleaf = ~nodenr;
    if ( nodenr == rdr->pvs_leaf ) return;
    rdr->pvs_leaf = nodenr;

    leafnr = ~nodenr;
    if ( world->leaves[leafnr].vis_list == -2 ) {
        fprintf( stderr, "Leaf has no pvs data.\n" );
        exit( 1 );
    }

    if ( world->leaves[leafnr].vis_list == -1 ) {
        /* no visibility restriction: draw from everywhere */
        for ( l = 0; l < world->leaf_count; l++ ) rdr->pvsb[l] = -1;
        r_mark_subtrees( world, rdr, head, 1 );
        return;
    }

    v = world->pvs_data + world->leaves[leafnr].vis_list;

    l = 1;
    while ( l < world->leaf_count ) {
        if ( *v == 0 ) {
            j = l;
            l += 8 * (short) v[1];
            if ( l > world->leaf_count ) l = world->leaf_count;
            for ( ; j < l; j++ ) rdr->pvsb[j] = 0;
            v++;    /* one here, one below: a zero run is marker plus
                        count, both consumed */
        } else {
            byte = *v;
            for ( bit = 0; bit < 8; bit++ ) {
                /* a run can carry past the last leaf */
                if ( l >= world->leaf_count ) break;
                rdr->pvsb[l] = ( byte & (1 << bit) ) ? 1 : 0;
                l++;
            }
        }
        v++;
    }

    r_mark_subtrees( world, rdr, head, 0 );
}

/*
 * name: r_emit_entities
 * desc: Draws every brush entity whose place in the order (ent_find_node,
 *       ent.c) is this node. Called from the walk (r_walk.c) at the one
 *       moment everything further away has been emitted and nothing
 *       nearer has -- the whole of what makes a painter's algorithm work.
 *
 *       ign gates re-entrance: while nonzero, this is already inside
 *       another entity's own submodel walk, and emitting a THIRD level
 *       of entities from there would not terminate against rdr->ent_left
 *       correctly, so it's skipped.
 */
void r_emit_entities( World *world, Renderer *rdr, DiskPlane far *frustum,
                       short nodenr, Vec3 *campos, short ign )
{
    short m;

    if ( ign || rdr->bad_order || rdr->no_ents ) return;

    for ( m = 1; m < world->model_count; m++ ) {
        if ( world->brush[m].draw && world->brush[m].node == nodenr ) {
            rdr->ent_left--;
            r_recursive_world_node( world, rdr, frustum, (short) world->models[m].head_node0, campos, 1, CLIP_ALL );
        }
    }
}

/*
 * name: r_draw_world
 * desc: One frame's BSP walk: advances the frame stamp, extracts the
 *       PVS for the camera's leaf (narrowed by the portals if enabled),
 *       counts how many brush entities are still owed a place in the
 *       draw order, then walks the tree.
 */
void r_draw_world( World *world, Renderer *rdr, DiskPlane far *frustum,
                    short model, Vec3 *campos, Mat4 *mtx_fin,
                    float xresh, float yresh, float z_near )
{
    short i;

    rdr->ord_count  = 0;
    rdr->cul_leafs  = 0;
    rdr->drw_leafs  = 0;

    _fmemset( rdr->pflag, 0, (unsigned) ( ( world->face_count + 7 ) / 8 ) );

    r_mark_leaves( world, rdr, (short) world->models[model].head_node0, campos );

    /*
     * Narrow the PVS to what the portals actually reach from this eye.
     * The PVS answers a question about the LEAF -- visible from
     * anywhere in it, looking anywhere -- so it can't tell a doorway
     * behind you from one in front of you. This has to run every
     * frame, because the answer moves when you turn: exactly what
     * r_mark_leaves caches away.
     */
    rdr->pt_culled = 0;
    if ( rdr->portal ) {
        /* Real half-extents and near plane, not the zeros this used to
           pass "until Config exists": r_portal_mark projects each
           portal rect to screen with them, so at 0,0,0 the projection
           is degenerate and the flood is answering a different
           question than the one the HUD reports. */
        rdr->pt_culled = r_portal_mark( world, rdr, mtx_fin, rdr->dbg_camleaf,
                                         (short) (world->leaf_count - 1),
                                         xresh, yresh, z_near );
    }
    if ( rdr->pt_culled < 0 || !rdr->portal ) {
        /* bailed, or switched off: use the PVS exactly as it stands */
        for ( i = 0; i < world->leaf_count; i++ ) rdr->pvs_now[i] = rdr->pvsb[i];
    }

    /* How many brush entities the walk still has to place. Once it's
       zero the per-node test in r_walk.c costs a compare, not a call. */
    rdr->ent_left = 0;
    for ( i = 1; i < world->model_count; i++ )
        if ( world->brush[i].draw ) rdr->ent_left++;

    /* Where the entities are, and what the walk may prune.
     *
     * ent_nd/ent_lf are one bit per node and leaf: the walk emits only
     * where a bit is set instead of rescanning every submodel at every
     * node it visits.
     *
     * vis_walk is the PVS's subtrees PLUS the root-to-node path of each
     * entity. An entity is placed at the deepest node its box does not
     * straddle and drawn with the PVS ignored -- its own leaves are not
     * in it, a lift sitting in its solid shaft -- so that node is
     * routinely one vis_sub leaves unmarked, and pruning it loses the
     * entity entirely. */
    {   short nb = (short) ( ( world->node_count + 7 ) / 8 );
        short lb = (short) ( ( world->leaf_count + 7 ) / 8 );
        short n;

        _fmemset( rdr->ent_nd, 0, (unsigned) nb );
        _fmemset( rdr->ent_lf, 0, (unsigned) lb );
        if ( !rdr->no_subvis ) _fmemcpy( rdr->vis_walk, rdr->vis_sub, (unsigned) nb );

        if ( rdr->ent_left && !rdr->no_ents ) {
            for ( i = 1; i < world->model_count; i++ ) {
                if ( !world->brush[i].draw ) continue;
                n = world->brush[i].node;
                if ( n == ENT_NODE_DIRTY ) continue;   /* ent_place_models has not run */
                if ( n & 0x8000 ) {
                    short lf = (short) ~n;
                    rdr->ent_lf[lf >> 3] |= (unsigned char) ( 1 << (lf & 7) );
                    n = rdr->lf_parent[lf];
                } else {
                    rdr->ent_nd[n >> 3] |= (unsigned char) ( 1 << (n & 7) );
                }
                if ( rdr->no_subvis ) continue;
                for ( ; n >= 0; n = rdr->nd_parent[n] )
                    rdr->vis_walk[n >> 3] |= (unsigned char) ( 1 << (n & 7) );
            }
        }
    }

    r_recursive_world_node( world, rdr, frustum, (short) world->models[model].head_node0, campos, 0, CLIP_ALL );

    /* -badorder reproduces what this used to do: every brush entity
       appended once the world is finished, so all of them draw in
       front of it. Kept so the fix (insertion at ent_find_node's own
       place) can be shown against, not just asserted. */
    if ( rdr->bad_order && !rdr->no_ents ) {
        for ( i = 1; i < world->model_count; i++ ) {
            if ( world->brush[i].draw ) {
                r_recursive_world_node( world, rdr, frustum, (short) world->models[i].head_node0, campos, 1, CLIP_ALL );
            }
        }
    }
}

/*
 * name: r_portal_outline
 * desc: Outline every portal of every leaf still visible after the
 *       flood. Lives here because the portal store and pvs_now are
 *       World's/Renderer's now, not passed around as loose arrays --
 *       BASIC couldn't hand an array back to a caller, which is the
 *       only reason the original needed this wrapper at all; kept
 *       anyway since h_frame.c already calls it as r_bsp.bas's own
 *       entry point.
 */
void r_portal_outline( World *world, Renderer *rdr, QSurf dc, Mat4 *mtx_fin,
                        float xresh, float yresh, float z_near )
{
    r_portal_draw( dc, mtx_fin, (short) (world->leaf_count - 1),
                   xresh, yresh, z_near, 251, world, rdr );
}

void r_load_leaves( World *world )
{
    world->leaves = (Leaf far *) asset_load( "leaves.pag",
                                              (long) world->leaf_count * sizeof(Leaf) );
}

void r_load_lfaces( World *world, long lump_bytes )
{
    world->lfc = (short far *) asset_load( "lface.bld", lump_bytes );
}

void r_load_portals( World *world, Renderer *rdr, long leaf_count )
{
    long nrefs;

    world->pt_idx = 0;
    world->pt_ref = 0;

    /* Nothing is loaded that the flood cannot use. r_portal_mark
       refuses a map past its own static tables on its first line, so
       on e1m1 -- 1,531 leaves against PT_MAX_LEAVES, 6,624 refs
       against PT_MAX_REFS -- the table was 95,800 bytes of
       conventional memory backing a pass that returned -2 every frame
       for the life of the run, and sc_init then died 28 KB short and
       the map drew unlit. The BASIC build never had this: its
       r_load_portals bailed because 6,624 x 7 x 2 is past a BASIC
       array's 64K, and the port's far pointers quietly removed the
       accident that was protecting it. */
    if ( !rdr->portal ) return;
    if ( leaf_count <= 0 || leaf_count - 1 >= PT_MAX_LEAVES ) return;

    world->pt_idx = (short far *) asset_load( "portalidx.bld",
                                               (leaf_count + 1) * (long) sizeof(short) );

    nrefs = world->pt_idx[leaf_count];
    if ( nrefs <= 0 || nrefs > PT_MAX_REFS ) {
        qglMemFree( (long) world->pt_idx );
        world->pt_idx = 0;
        return;
    }

    world->pt_ref = (short far *) asset_load( "portalref.bld",
                                               nrefs * (long) PT_REF_SHORTS * sizeof(short) );
}

void r_alloc_scratch( Renderer *rdr, short face_count, short node_count, short leaf_count )
{
    rdr->vis_sub   = (unsigned char far *) qglMemAlloc( ( (long) node_count + 7 ) / 8 );
    rdr->vis_walk  = (unsigned char far *) qglMemAlloc( ( (long) node_count + 7 ) / 8 );
    rdr->nd_parent = (short far *) qglMemAlloc( (long) node_count * sizeof(short) );
    rdr->lf_parent = (short far *) qglMemAlloc( (long) leaf_count * sizeof(short) );
    rdr->ent_nd    = (unsigned char far *) qglMemAlloc( ( (long) node_count + 7 ) / 8 );
    rdr->ent_lf    = (unsigned char far *) qglMemAlloc( ( (long) leaf_count + 7 ) / 8 );
    rdr->pflag   = (unsigned char far *) qglMemAlloc( ( (long) face_count + 7 ) / 8 );
    rdr->ord     = (short far *) qglMemAlloc( (long) node_count * sizeof(short) );
    rdr->pvsb    = (short far *) qglMemAlloc( (long) leaf_count * sizeof(short) );
    rdr->pvs_now = (short far *) qglMemAlloc( (long) leaf_count * sizeof(short) );

    if ( !rdr->vis_sub || !rdr->vis_walk || !rdr->nd_parent || !rdr->lf_parent || !rdr->ent_nd || !rdr->ent_lf || !rdr->pflag || !rdr->ord || !rdr->pvsb || !rdr->pvs_now ) {
        fprintf( stderr, "r_alloc_scratch: out of memory\n" );
        exit( 1 );
    }
}
