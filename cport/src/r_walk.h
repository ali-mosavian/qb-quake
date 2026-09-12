#ifndef __R_WALK_H__
#define __R_WALK_H__

#include "renderer.h"
#include "world.h"
#include "bsptypes.h"

/*
 * name: r_recursive_world_node
 * desc: Walks the tree front-to-back from nodenr, culling against
 *       frustum (r_set_frustum's own output -- built by the caller,
 *       not stored on Renderer, since nothing else needs it to
 *       outlive one call to r_draw_world) and PVS (rdr->pvsb),
 *       stamping every visible face in rdr->pflag and appending every
 *       visited internal node to rdr->ord. ign, while true, skips the
 *       PVS test and lets the frustum decide alone -- set by
 *       r_emit_entities while walking a brush entity's own submodel
 *       tree, since a lift's leaves are never in the world's PVS (the
 *       PVS answers where the CAMERA can see from; a door is not part
 *       of that). mask is the frustum planes this subtree may still
 *       cross -- CLIP_ALL from a fresh walk, r_cull_box's own answer
 *       from a parent node.
 */
void r_recursive_world_node( World *world, Renderer *rdr, DiskPlane far *frustum,
                              short nodenr, Vec3 *campos, short ign, short mask );

#endif
