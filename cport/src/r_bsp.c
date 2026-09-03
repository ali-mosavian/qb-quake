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
#include <stdio.h>
#include <stdlib.h>

#include "r_bsp.h"
#include "r_walk.h"
#include "r_portal.h"
#include "assets.h"
#include "dos.h"    /* memAlloc, for r_alloc_scratch */

/* Takes a RENDERER point: Y-up there, Z-up in the BSP, so y pairs with
   norm.z. Single, not double: returning double moved two edge-on faces
   onto the other side of their plane in the original BASIC. */
float r_plane_dist( Vec3 *p, Plane far *pl )
{
    return p->x*pl->norm.x + p->y*pl->norm.y + p->z*pl->norm.z - pl->dist;
}

/* The leaf holding p, walking hull 0. Bit 15 marks a leaf; ~ is its index. */
short r_point_leaf( Vec3 *p, World *world )
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

float r_cam_plane_dist( u3dVector3f *pt, Plane far *pl )
{
    return pt->x*pl->norm.x + pt->y*pl->norm.z + pt->z*pl->norm.y - pl->dist;
}

/* Which side of a node's splitting plane a point falls on: -1 front, 0 behind. */
short r_node_side( short node_idx, u3dVector3f *pt, World *world )
{
    Node far *n = &world->nodes[node_idx];
    if ( r_cam_plane_dist( pt, &world->planes[n->plane_id] ) > 0.0f ) return -1;
    return 0;
}

/* Same 8-way branch on the frustum plane's normal sign to pick the
   box's near corner, same y/z swap copying from bbox (BSP, z-up) into
   near_point (renderer, y-up). bbox.min/max are Vec3i; the assignment
   into a float Vec3 is BASIC's own implicit int-to-single conversion,
   done explicitly here instead. */
short r_cull_box( Bounds far *bbox, DiskPlane far *frustum )
{
    Vec3 near_point;
    float dp;
    short i;

    for ( i = 0; i < 6; i++ ) {
        if ( frustum[i].norm.x > 0.0f ) {
            if ( frustum[i].norm.y > 0.0f ) {
                if ( frustum[i].norm.z > 0.0f ) {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->min.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->max.y;
                }
            } else {
                if ( frustum[i].norm.z > 0.0f ) {
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
            if ( frustum[i].norm.y > 0.0f ) {
                if ( frustum[i].norm.z > 0.0f ) {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->min.y;
                } else {
                    near_point.x = (float) bbox->max.x;
                    near_point.y = (float) bbox->min.z;
                    near_point.z = (float) bbox->max.y;
                }
            } else {
                if ( frustum[i].norm.z > 0.0f ) {
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

        dp = frustum[i].norm.x*near_point.x + frustum[i].norm.y*near_point.y +
             frustum[i].norm.z*near_point.z;

        if ( (dp + frustum[i].dist) > 0.0f ) return 0;
    }

    return -1;
}

/* Six planes off the concatenated view*projection matrix (Gribb/Hartmann),
   normalized so r_cull_box's distances are in real units. */
void r_set_frustum( DiskPlane far *frustum, u3dMtrx *mtx )
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
void r_mark_leaves( World *world, Renderer *rdr, short nodenr, u3dVector3f *campos )
{
    unsigned char far *v;
    short leafnr, l, j, byte, bit;

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
                       short nodenr, u3dVector3f *campos, short ign )
{
    short m;

    if ( ign || rdr->bad_order || rdr->no_ents ) return;

    for ( m = 1; m < world->model_count; m++ ) {
        if ( world->brush[m].draw && world->brush[m].node == nodenr ) {
            rdr->ent_left--;
            r_recursive_world_node( world, rdr, frustum, (short) world->models[m].head_node0, campos, 1 );
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
                    short model, u3dVector3f *campos, u3dMtrx *mtx_fin )
{
    short i;

    rdr->ord_count  = 0;
    rdr->cul_leafs  = 0;
    rdr->drw_leafs  = 0;

    /* Advance the frame stamp instead of clearing every face flag every
       frame -- comparing against the stamp is the same test, run once
       per 32,767 frames instead of every one. QuickBASIC traps integer
       overflow at run time rather than wrapping, hence the check
       before the increment; short wraps silently in C, but the check
       is kept anyway since it's what makes the reset visible. */
    if ( rdr->frame_stamp == 32767 ) {
        for ( i = 0; i < world->face_count; i++ ) rdr->pflag[i] = 0;
        rdr->frame_stamp = 0;
    }
    rdr->frame_stamp++;

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
        /* xresh/yresh/z_near are Env's -- 0 here until Config exists to
           carry x_res/y_res/z_near down to this call. */
        rdr->pt_culled = r_portal_mark( world, rdr, mtx_fin, rdr->dbg_camleaf,
                                         (short) (world->leaf_count - 1),
                                         0.0f, 0.0f, 0.0f );
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

    r_recursive_world_node( world, rdr, frustum, (short) world->models[model].head_node0, campos, 0 );

    /* -badorder reproduces what this used to do: every brush entity
       appended once the world is finished, so all of them draw in
       front of it. Kept so the fix (insertion at ent_find_node's own
       place) can be shown against, not just asserted. */
    if ( rdr->bad_order && !rdr->no_ents ) {
        for ( i = 1; i < world->model_count; i++ ) {
            if ( world->brush[i].draw ) {
                r_recursive_world_node( world, rdr, frustum, (short) world->models[i].head_node0, campos, 1 );
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
void r_portal_outline( World *world, Renderer *rdr, PDC dc, u3dMtrx *mtx_fin )
{
    /* xresh/yresh/z_near are Env's -- 0 here until Config exists. */
    r_portal_draw( dc, mtx_fin, (short) (world->leaf_count - 1),
                   0.0f, 0.0f, 0.0f, 251, world, rdr );
}

void r_load_leaves( World *world )
{
    world->leaves = (Leaf far *) asset_load( "assets.zip::leaves.pag",
                                              (long) world->leaf_count * sizeof(Leaf) );
}

void r_load_lfaces( World *world, long lump_bytes )
{
    world->lfc = (short far *) asset_load( "assets.zip::lface.bld", lump_bytes );
}

void r_load_portals( World *world, long leaf_count )
{
    long nrefs;

    world->pt_idx = (short far *) asset_load( "assets.zip::portalidx.bld",
                                               (leaf_count + 1) * (long) sizeof(short) );

    nrefs = world->pt_idx[leaf_count];
    if ( nrefs <= 0 ) { world->pt_ref = 0; return; }

    world->pt_ref = (short far *) asset_load( "assets.zip::portalref.bld",
                                               nrefs * (long) PT_REF_SHORTS * sizeof(short) );
}

void r_alloc_scratch( Renderer *rdr, short face_count, short node_count, short leaf_count )
{
    rdr->pflag   = (short far *) memAlloc( (long) face_count * sizeof(short) );
    rdr->ord     = (short far *) memAlloc( (long) node_count * sizeof(short) );
    rdr->pvsb    = (short far *) memAlloc( (long) leaf_count * sizeof(short) );
    rdr->pvs_now = (short far *) memAlloc( (long) leaf_count * sizeof(short) );

    if ( !rdr->pflag || !rdr->ord || !rdr->pvsb || !rdr->pvs_now ) {
        fprintf( stderr, "r_alloc_scratch: out of memory\n" );
        exit( 1 );
    }
}
