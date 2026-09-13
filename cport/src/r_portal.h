#ifndef __R_PORTAL_H__
/* The flood's own static tables bound what it can answer for, so
   r_load_portals refuses a map past either -- one fact, one place. */
#define PT_MAX_LEAVES 1024
#define PT_MAX_REFS   4096   /* dm3ish has 1566, e1m7 about the same */

#define __R_PORTAL_H__

#include "renderer.h"
#include "world.h"

/*
 * r_portal.c -- narrow the PVS to what is visible from HERE, not from
 * anywhere in the camera's leaf. See r_portal.c's own header for the
 * flood-fill algorithm; this is the World-/Renderer-taking adaptation
 * of the BASIC-linked build's own src/r_portal.c, same mechanical
 * change pl_trace.c and r_walk.c already got (BASARRAY descriptors ->
 * struct fields).
 */

/* A portal entry as mkportals.py writes it: neighbour leaf, then the
   portal's world-space bounding box as mins[3], maxs[3]. BSP space,
   Z-up. Shared with r_bsp.c's r_load_portals, which sizes the read by
   it -- the one fact both the loader and the reader need to agree on. */
#define PT_REF_SHORTS 7

/*
 * name: r_portal_mark
 * desc: Narrows rdr->pvsb into rdr->pvs_now, keeping only leaves the
 *       flood actually reached from campos through world->pt_idx/
 *       pt_ref. Returns the number of leaves cleared, or a negative
 *       code if the flood couldn't run (bad leaf count, work budget
 *       exceeded) -- in which case pvs_now is untouched and the
 *       caller falls back to using pvsb unchanged, which is always
 *       correct, just unnarrowed.
 */
short r_portal_mark( World *world, Renderer *rdr, Mat4 *m, short cam_leaf, short visleafs,
                      float xresh, float yresh, float z_near );

/*
 * name: r_portal_draw
 * desc: Draws the wireframe box of every portal the flood actually
 *       went through this frame, for every leaf still in rdr->pvs_now.
 */
void  r_portal_draw( QSurf dc, Mat4 *m, short visleafs, float xresh, float yresh, float z_near,
                      long clr, World *world, Renderer *rdr );

/* Flood totals for the whole run: leaves popped, portal boxes
   projected, rectangles pushed. bench.txt reports them. */
void r_portal_stats( long *pops, long *projs, long *pushes );

#endif
