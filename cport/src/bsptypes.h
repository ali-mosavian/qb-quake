#ifndef __BSPTYPES_H__
#define __BSPTYPES_H__

#include "renderer.h"   /* Vec3 */

/* BSP-domain types -- qb-qrender's own, not mgl's (mgl has no notion
   of a map). Mirror the old bspfile.bi/q_ent.bi field-for-field; the
   main project's qcshared.h carries the same shapes for its own C
   modules, kept separate here since this project no longer shares a
   struct layout with anything BASIC reads. */

/* q_pl.bi's contents codes -- straight off a leaf/clipnode child index.
   A negative child is not a node number but one of these. */
#define CONTENTS_EMPTY (-1)
#define CONTENTS_SOLID (-2)
#define CONTENTS_WATER (-3)
#define CONTENTS_SLIME (-4)
#define CONTENTS_LAVA  (-5)
#define CONTENTS_SKY   (-6)

/* bspfile.bi's Vec3i -- same axes as Vec3, quantized to a short. Node/
   Leaf bounds are stored this way on disk; NOT a premature-optimization
   choice made here, so it stays Vec3i rather than the Vec3 this file
   originally (and wrongly) gave it before anything actually read a
   bound -- see r_cull_box's own int-to-single conversion below, which
   only makes sense against a genuinely integer Bounds. */
typedef struct { short x, y, z; } Vec3i;

typedef struct { Vec3i min, max; } Bounds;

typedef struct {
    short plane_id;
    short child0;
    short child1;
    short lface_id;
    short lface_num;
    Bounds bound;
} Node;

typedef struct {
    Vec3  norm;
    float dist;
    short ptype;
} Plane;

/* bspfile.bi's DiskPlane -- the frustum's own plane record. Same shape
   as Plane except ptype is long, not short; r_set_frustum computes six
   of these from the view matrix, so there's no on-disk instance to
   confuse it with. */
typedef struct {
    Vec3  norm;
    float dist;
    long  ptype;
} DiskPlane;

/* bspfile.bi's Leaf. vis_list is an offset into World's pvs_data blob,
   -1 for "no visibility restriction" (draw from everywhere) and -2 for
   "no pvs data at all" (r_mark_leaves treats that as a load-time
   error). cont is one of the CONTENTS_ codes above. */
typedef struct {
    short  cont;
    long   vis_list;
    Bounds bound;
    short  lface_id;
    short  lface_num;
} Leaf;

typedef struct {
    Vec3 mins, maxs, origin;
    long head_node0, head_node1, head_node2, head_node3;
    long vis_leafs, first_face, num_faces;
} Submodel;

/* bspfile.bi's Face. geom_row/geom_ofs locate the face's fetched
   geometry record (d_poly's own gv_buf scratch, not World's -- it's
   filled per face by the caller, model.bas isn't ported yet either). */
typedef struct {
    short plane_id;
    short side;
    short geom_row;
    short geom_ofs;
    short tex_info_id;
} Face;

/* bspfile.bi's TexInfo. vecs/vect are FIXED-size embedded arrays (dim
   x(3) inside a BASIC TYPE), not the dynamic kind that cannot be a UDT
   member -- a plain C array field mirrors this correctly. */
typedef struct {
    float vecs[4];
    float vect[4];
    short mip_tex;
} TexInfo;

/* bspfile.bi's MipTex. wdth/hght are already 1/origW, 1/origH -- see
   sb_build.c's own note on why. */
typedef struct {
    float wdth;
    float hght;
    short lnext;
    short liquid;
    short anim_base;
    short anim_count;
} MipTex;

/* q_map.bi's BrushModel -- per-submodel draw/solid/vertical-offset
   state, one entry per Submodel, index 0 is the world and always
   draw=solid=true, zofs=0. */
typedef struct {
    short draw;
    short solid;
    float zofs;
    short node;      /* ent_find_node's answer: where this submodel
                         belongs in the world's back-to-front order */
} BrushModel;

/* bspfile.bi's ClipNode -- the pre-expanded collision hulls. A negative
   front/back is not a node index but a CONTENTS_ code. */
typedef struct {
    short plane_num;
    short front;
    short back;
} ClipNode;

/* q_ent.bi's Teleporter. */
typedef struct {
    Vec3  mins, maxs;
    Vec3  dest;
    float yaw;
} Teleporter;

/* q_ent.bi's PlatEnt. ENT_PLAT_DOWN=0, ENT_PLAT_UP=1. */
#define ENT_PLAT_DOWN 0
#define ENT_PLAT_UP   1
typedef struct {
    short model;
    float travel;
    float speed;
    short state;
    Vec3  mins, maxs;
} PlatEnt;

#endif
