/*
 * qcshared.h -- struct definitions shared across qrender's own C modules
 * (r_walk.c, sb_build.c, pl_trace.c), mirroring the BASIC UDTs each one
 * interoperates with (mostly src/bspfile.bi, plus q_pl.bi, q_vis.bi and
 * q_draw.bi as noted). Kept as a hand-maintained mirror of a handful of
 * types, not a generated twin of those headers -- if a mirrored BASIC
 * type's fields change, this file has to change with it by hand.
 *
 * Vec3 vs Vec3f: same three-float layout, but NOT the same type on
 * purpose. Vec3 mirrors BASIC's own Vec3 (BSP space, Z-up); Vec3f
 * mirrors u3dVector3f (renderer space, Y-up). Collapsing them into one
 * type would compile and run identically right up until a Y-up value
 * got passed somewhere a Z-up one was expected, or the reverse -- the
 * exact class of bug this codebase's own notes describe paying for more
 * than once. Match whichever BASIC type the field you're mirroring
 * actually is, not whichever C struct happens to have the same shape.
 */

#ifndef __QC_SHARED_H__
#define __QC_SHARED_H__

/* BASIC's own array-parameter descriptor (mgl's bas.h has the same
   struct under the same name). Every array parameter to an external
   procedure arrives as a near pointer to one of these; farptr is the
   far pointer to the actual data, which can live anywhere regardless of
   the descriptor's own near address. */
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

/* bspfile.bi's Vec3 -- BSP space, Z-up. */
typedef struct { float x, y, z; } Vec3;

/* bspfile.bi's Vec3i -- same axes as Vec3, quantized to a short. */
typedef struct { short x, y, z; } Vec3i;

/* u3d.bi's u3dVector3f -- renderer space, Y-up. See the file header for
   why this stays a distinct type from Vec3 rather than an alias. */
typedef struct { float x, y, z; } Vec3f;

/* bspfile.bi's Bounds. */
typedef struct { Vec3i min, max; } Bounds;

/* bspfile.bi's Plane -- the map's own runtime plane record. */
typedef struct { Vec3 norm; float dist; short ptype; } Plane;

/* bspfile.bi's DiskPlane -- the frustum's plane record (long ptype, not
   short; otherwise the same shape as Plane). */
typedef struct { Vec3 norm; float dist; long ptype; } DiskPlane;

/* bspfile.bi's Node. */
typedef struct {
    short plane_id;
    short child0;
    short child1;
    short lface_id;
    short lface_num;
    Bounds bound;
} Node;

/* bspfile.bi's Leaf. */
typedef struct {
    short cont;
    long  vis_list;
    Bounds bound;
    short lface_id;
    short lface_num;
} Leaf;

/* bspfile.bi's ClipNode. */
typedef struct {
    short plane_num;
    short front;
    short back;
} ClipNode;

/* bspfile.bi's Submodel. */
typedef struct {
    Vec3 mins, maxs, origin;
    long head_node0, head_node1, head_node2, head_node3;
    long vis_leafs, first_face, num_faces;
} Submodel;

/* bspfile.bi's BrushModel. */
typedef struct {
    short draw;
    short solid;
    float zofs;
    short node;
} BrushModel;

/* bspfile.bi's Face. */
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

/* bspfile.bi's MipTex. */
typedef struct {
    float wdth;
    float hght;
    short lnext;
    short liquid;
    short anim_base;
    short anim_count;
} MipTex;

/* bspfile.bi's SurfBuild -- the parameter block uglBuildSurf reads back
   out of a packed far pointer, not a BASIC-to-C call parameter itself. */
typedef struct {
    long  lmptr;
    long  lm_stride;
    long  cmap_ptr;
    long  au0;
    long  av0;
    long  du;
    long  dv;
    short sw;
    short sh;
    short lmw;
    short lmh;
    short shft;
    short msk;
} SurfBuild;

/* q_pl.bi's TraceResult. */
typedef struct {
    float frac;
    Vec3  end_pos;
    Vec3  norm;
    short all_solid;
    short start_solid;
} TraceResult;

/* q_draw.bi's DynLight -- BSP space, Z-up, hence Vec3 not Vec3f. */
typedef struct { Vec3 pos; float radius; } DynLight;

/* q_vis.bi's VisState -- frame_stamp(int) ord_count(long) drw_leafs(int)
   cul_leafs(int) ent_left(int) no_ents(int) bad_order(int), all scalars,
   no padding: a direct transcription of the declared field order. */
typedef struct {
    short frame_stamp;
    long  ord_count;
    short drw_leafs;
    short cul_leafs;
    short ent_left;
    short no_ents;
    short bad_order;
} VisState;

#endif /* __QC_SHARED_H__ */
