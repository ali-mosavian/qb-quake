#ifndef __R_BSP_H__
#define __R_BSP_H__

#include "renderer.h"
#include "world.h"
#include "bsptypes.h"

/*
 * r_bsp.bas -- BSP traversal and visibility. r_point_leaf/r_leaf_contents
 * are real now (r_bsp.c); ent.c's ent_point_leaf and pl_move.c's
 * pl_point_contents were written against this signature before either
 * existed, since it's the eventual World*-taking shape r_bsp.bas would
 * need regardless of when it got ported -- see AGENTS.md's "no globals"
 * rule (the old BASIC r_leaf_contents read a `dim shared` leaves()
 * array implicitly instead of taking one).
 */
float r_plane_dist( BspVec3 *p, Plane far *pl );
short r_point_leaf( BspVec3 *p, World *world );
short r_leaf_contents( short leaf_nr, World *world );
float r_cam_plane_dist( Vec3 *pt, Plane far *pl );
short r_node_side( short node_idx, Vec3 *pt, World *world );
/* Every frustum plane still worth testing. The walk starts here and
   r_cull_box hands each subtree the narrower mask its own box earned. */
#define CLIP_ALL 0x3f

/* -1 culled; otherwise the mask the children should be tested with
   (0 = the box is wholly inside, no plane left to cross). */
short r_cull_box( PackedBounds far *bbox, DiskPlane far *frustum, short mask );
void  r_set_frustum( DiskPlane far *frustum, Mat4 *mtx );

/*
 * name: r_mark_leaves
 * desc: Finds the leaf campos is in and, if it's a different leaf than
 *       last frame, decompresses that leaf's PVS entry into rdr->pvsb
 *       (one entry per world leaf: -1 visible, 0 not).
 */
void  r_mark_leaves( World *world, Renderer *rdr, short nodenr, Vec3 *campos );

/*
 * name: r_draw_world
 * desc: One frame's BSP walk: advances the frame stamp, extracts the
 *       PVS for the camera's leaf, then walks the tree recording which
 *       faces are visible (rdr->pflag) and the back-to-front node order
 *       (rdr->ord) the rasteriser follows.
 */
void  r_draw_world( World *world, Renderer *rdr, DiskPlane far *frustum,
                     short model, Vec3 *campos, Mat4 *mtx_fin,
                     float xresh, float yresh, float z_near );

/* Outline every portal of every leaf still visible after the flood --
   r_portal.c's r_portal_draw, wrapped with World's/Renderer's own
   portal store and pvs_now. */
void  r_portal_outline( World *world, Renderer *rdr, QSurf dc, Mat4 *mtx_fin,
                         float xresh, float yresh, float z_near );

/* Builds world->leaves: leaf_count entries from assets.zip's own
   already-narrowed leaves.pag (fatal if it won't load). */
void r_load_leaves( World *world );

/* Builds world->lfc (the marksurface list) from lump_bytes, the raw
   .bsp's own lface lump size -- the file's own byte count sizes the
   read; nothing here needs a derived count. */
void r_load_lfaces( World *world, long lump_bytes );

/* Builds world->pt_idx/pt_ref from mkportals.py's own portalidx.bld/
   portalref.bld. Two lumps because the ref count isn't in the bsp and
   can't be derived from it: the index is one short per leaf (a count
   this project already has) plus one, and its LAST entry IS the ref
   count -- so loading the index is what sizes the refs. */
void r_load_portals( World *world, Renderer *rdr, long leaf_count );

/*
 * name: r_alloc_scratch
 * desc: memAllocs rdr's four per-map-sized working arrays -- pflag
 *       (face_count), ord (node_count), pvsb/pvs_now (leaf_count).
 *       BASIC's own r_alloc_pvs sized only pvsb; ord/pflag were
 *       main.bas's own REDIMs and pvs_now was r_load_portals's, all
 *       three real arrays with nowhere else to be allocated from now
 *       that they're Renderer fields rather than loose COMMON arrays.
 */
void r_alloc_scratch( Renderer *rdr, short face_count, short node_count, short leaf_count );

/*
 * name: r_build_parents
 * desc: Fills rdr->nd_parent from the node tree. Call once, after the
 *       nodes are loaded and before the first frame.
 */
void r_build_parents( World *world, Renderer *rdr );

#endif
