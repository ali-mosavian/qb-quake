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
                              short nodenr, Vec3 *campos, short ign );

void r_recursive_world_node( World *world, Renderer *rdr, DiskPlane far *frustum,
                              short nodenr, Vec3 *campos, short ign, short mask )
{
    short side, i, frst, last, leafnr;

    if ( nodenr & 0x8000 ) {
        leafnr = ~nodenr;
        /* pvs_now, NOT pvsb. pvsb is the raw PVS for the camera's leaf,
           rebuilt only when the leaf changes; pvs_now is that set after
           r_portal_mark narrows it to what the portals actually reach
           from this eye, rebuilt every frame. The BASIC passed
           pvs_now() into this routine's own pvsb() PARAMETER
           (r_bsp.bas:439), so once the arrays became struct fields the
           name here matched the wrong one: portal culling built the
           narrowed set, reported pt_culled to the HUD, and the walk
           then ignored it. The tell was the HUD itself -- "leaves
           portal-cut" moved while polys did not. */
        if ( (ign || rdr->pvs_now[leafnr]) &&
             r_cull_box( &world->leaves[leafnr].bound, frustum, mask ) >= 0 ) {
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

    mask = r_cull_box( &world->nodes[nodenr].bound, frustum, mask );
    if ( mask < 0 ) return;

    side = ( r_cam_plane_dist( campos, &world->planes[ world->nodes[nodenr].plane_id ] ) >= 0.0f );

    if ( side ) {
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child1, campos, ign, mask );
        if ( rdr->ent_left )
            r_emit_entities( world, rdr, frustum, nodenr, campos, ign );
        rdr->ord[ rdr->ord_count++ ] = nodenr;
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child0, campos, ign, mask );
    } else {
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child0, campos, ign, mask );
        if ( rdr->ent_left )
            r_emit_entities( world, rdr, frustum, nodenr, campos, ign );
        rdr->ord[ rdr->ord_count++ ] = nodenr;
        r_recursive_world_node( world, rdr, frustum, world->nodes[nodenr].child1, campos, ign, mask );
    }
}
