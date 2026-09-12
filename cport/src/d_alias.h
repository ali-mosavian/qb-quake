#ifndef __D_ALIAS_H__
#define __D_ALIAS_H__

#include "world.h"
#include "renderer.h"
#include "qgltypes.h"
#include "pl_move.h"   /* Player */

/*
 * d_alias.h -- the things that are not world geometry: for now the
 * pickups, as flat boxes. The alias models themselves (d_mdl.bas) are
 * not ported.
 */

/*
 * name: d_draw_items
 * desc: Every pickup still there, spinning and bobbing on the same
 *       clock as the liquids. Depth-tested, so a box behind a wall is
 *       behind it -- nothing orders these against the world walk.
 *       Returns the quads drawn.
 */
short d_draw_items( World *world, Renderer *rdr, Player *player,
                     DiskPlane far *frustum, Mat4 *mtx_fin,
                     float xresh, float yresh, float z_near, QSurf dst );

/*
 * name: d_draw_models
 * desc: Every monster the map spawned, on the frame it is holding.
 *       Depth tested, like the pickups. Returns the triangles handed
 *       to the rasteriser.
 */
short d_draw_models( World *world, Renderer *rdr, DiskPlane far *frustum,
                      Mat4 *mtx_fin, float xresh, float yresh, float z_near,
                      QSurf dst );

#endif
