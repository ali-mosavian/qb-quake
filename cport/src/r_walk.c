/*
 * r_walk.c -- the recursive BSP walk. C port of r_bsp.bas's
 * r_recursive_world_node.
 *
 * Its own translation unit for the same reason the BASIC-linked
 * build's src/r_walk.c already was: the hottest recursion in the
 * renderer wants a tight, purpose-built call frame, not r_bsp.c's
 * struct-heavy per-call setup. Unlike that version (which unpacked
 * BASARRAY descriptors into a hand-rolled WalkCtx once per top-level
 * call, specifically to avoid re-deriving eight far pointers at every
 * recursive level), World* and Renderer* already ARE the two pointers
 * that own everything the walk touches -- there's nothing left to
 * unpack, so the recursion just carries them straight through.
 */

#include "r_bsp.h"
#include "r_walk.h"

/* r_bsp.c's own -- declared here, not in a header, since this is the
   only caller (same reasoning the original module gave for keeping it
   out of a shared .bi). */
extern void r_emit_entities( World *world, Renderer *rdr, DiskPlane far *frustum,
                              short nodenr, u3dVector3f *campos, short ign );

void r_recursive_world_node( World *world, Renderer *rdr, DiskPlane far *frustum,
                              short nodenr, u3dVector3f *campos, short ign )
{
    short side, i, frst, last, leafnr;

    if ( nodenr & 0x8000 ) {
        leafnr = ~nodenr;
        if ( (ign || rdr->pvsb[leafnr]) &&
             r_cull_box( &world->leaves[leafnr].bound, frustum ) ) {
            frst = world->leaves[leafnr].lface_id;
            last = frst + world->leaves[leafnr].lface_num;
            for ( i = frst; i < last; i++ )
                rdr->pflag[ world->lfc[i] ] = rdr->frame_stamp;

            if ( rdr->ent_left )
                r_emit_entities( world, rdr, frustum, nodenr, campos, ign );

            rdr->drw_leafs++;
        } else {
            rdr->cul_leafs++;
        }
        return;
    }

    if ( !r_cull_box( &world->nodes[nodenr].bound, frustum ) ) return;

    side = ( r_cam_plane_dist( campos, &world->planes[ world->nodes[nodenr].plane_id ] ) >= 0.0f );

    if ( side ) {
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child1, campos, ign );
        if ( rdr->ent_left )
            r_emit_entities( world, rdr, frustum, nodenr, campos, ign );
        rdr->ord[ rdr->ord_count++ ] = nodenr;
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child0, campos, ign );
    } else {
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child0, campos, ign );
        if ( rdr->ent_left )
            r_emit_entities( world, rdr, frustum, nodenr, campos, ign );
        rdr->ord[ rdr->ord_count++ ] = nodenr;
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child1, campos, ign );
    }
}
