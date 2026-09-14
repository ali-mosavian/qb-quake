#ifndef __RENDERER_H__
#define __RENDERER_H__

#include "qgl.h"

/* BspVec3 is BSP space, Z-up; Vec3 -- qgl's own three-float record,
   declared in qgltypes.h -- is renderer space, Y-up, and is used
   directly everywhere renderer space is meant. Two types on purpose:
   same layout, but collapsing them compiles and runs identically right
   up until a Y-up value is passed where a Z-up one was expected. This
   codebase's notes describe paying for exactly that more than once,
   and collapsing them is precisely what a blanket rename off mgl's
   u3dVector3f does if it is not watched. */
typedef struct { float x, y, z; } BspVec3;

/* Which leaves an entity's box samples, and the box it was sampled for.
   d_mdl_visible descends the tree from the root at nine points to ask
   whether any lands in a visible leaf, and on e1m1 that is 62 levels
   nine times per entity -- 13,007 node visits a frame for 36 entities,
   against 540 for the entire world walk. The leaves depend only on the
   box, not on the PVS, so they are found once and the per-frame test
   becomes nine array reads. A pickup never moves at all; a monster
   moves at its 10 Hz think and re-fills this when it does. */
typedef struct {
    BspVec3 at;              /* the origin these were found for */
    float   r, zlo, zhi;     /* and the extent around it */
    short   lf[9];
    short   ok;
} LeafCache;

/* cl_dlights' dlight_t, in BSP space. Live while die >= anim_time and
   radius > 0. */
#define DL_MAX 32
typedef struct {
    BspVec3 origin;
    float   radius, die, decay, minlight;
    short   key;
} DynLight;

/* Renderer -- per-frame toggles and counters. Quake's own name for
   this role; owns what d_draw_faces reads and what host_tick/
   host_render update every frame. Narrower than the old BASIC
   RenderState: fields no C module reads yet (portal, the counters
   scr_count_frame alone touches) aren't here until something needs
   them -- there's no BASIC layout to mirror any more, so there's no
   reason to carry fields nothing reads. */
typedef struct {
    short backface;
    short use_mips;
    short lightmap;
    short rend_mode;      /* 0 perspective, 1 affine, 2 wireframe */
    short portal;         /* portal-adjacency PVS narrowing toggle */
    short polys;
    short tris;
    float anim_time;
    DynLight dlights[DL_MAX];
    short dl_tick;            /* dl_stag's clock */
    unsigned short dl_seed;   /* the flicker's LCG */
    short no_dlight;          /* -nodlight */
    short no_styles;          /* -nostyles: the light styles hold still */

    /* q_vis.bi's VisState -- folded in here per the port plan's own
       architecture table (Renderer replaces RenderState *and*
       VisState). frame_stamp/ord_count/drw_leafs/cul_leafs/ent_left/
       pt_culled/no_ents/bad_order are the counters r_draw_world resets
       and the walk (r_walk.c) updates every frame. pflag/ord/pvsb/
       pvs_now are the working scratch the walk writes into -- sized
       once at map-load time (to face_count/node_count/leaf_count),
       not reallocated per frame, but not raw map data either, so they
       live here rather than in World. */
    short no_subvis;      /* -nosubvis: the skip below off, for the A/B */
    short no_lcache;      /* -nolcache: the entity leaf caches off, likewise */
    unsigned char far *vis_sub;   /* a bit a node: is any leaf below it in
                            pvsb? Rebuilt with pvsb -- only when the
                            camera changes leaf -- which is Quake's
                            node->visframe test. */
    unsigned char far *vis_walk;  /* what the walk actually reads: vis_sub
                            plus the root-to-node path of every brush
                            entity due to be emitted. An entity's own
                            leaves are NOT in the world PVS (a lift sits
                            in its solid shaft), so pruning by vis_sub
                            alone loses the node it is placed at and the
                            entity never draws. Rebuilt every frame. */
    short far *nd_parent;         /* a node's parent, -1 at the root; the
                            only way to walk up to mark that path */
    short far *lf_parent;         /* and a leaf's, because ent_find_node
                            stops at a LEAF whenever the box straddles no
                            plane all the way down -- r_emit_entities is
                            called from the leaf branch too */
    unsigned char far *ent_nd;    /* a bit where some brush entity is placed, */
    unsigned char far *ent_lf;    /* nodes and leaves. r_emit_entities used to
                            rescan every submodel at every visited node --
                            nodes x models compares a frame, and on e1m1
                            that was most of the cull. Rebuilt with
                            vis_walk. */
    unsigned char far *pflag; /* one BIT a face, cleared every frame --
                              a short each was 11,032 bytes on e1m1 for
                              a yes/no, and the frame stamp it held only
                              existed to avoid clearing them. 690 bytes
                              of _fmemset is cheaper than the 11K it
                              saved us clearing.
                              when the walk marks a face visible */
    short far *ord;       /* draw order: internal node indices, far to
                              near, written by the walk */
    short far *pvsb;      /* this frame's leaf -> visible bit, rebuilt
                              by r_mark_leaves only when the camera
                              changes leaf */
    short far *pvs_now;   /* pvsb narrowed to what the portals actually
                              reach from this eye -- r_portal.c, not yet
                              ported; unused until it is */

    short frame_stamp;    /* stamped into pflag for visible faces */
    long  ord_count;      /* entries written to ord */
    short drw_leafs;      /* leaves the walk kept this frame, and */
    short cul_leafs;      /* threw away; both on the stats panel */
    short vis_leaves;     /* leaves with pvsb set, and nodes the mark set: */
    short vis_nodes;      /* the two numbers the subtree skip turns on */
    long  mk_faces;       /* pflag writes: faces some visible leaf marked */
    long  ord_sum;        /* nodes the draw order carried */
    LeafCache far *item_lc;  /* d_mdl_visible's nine leaves per pickup and */
    LeafCache far *mdl_lc;   /* per monster; see its own note */
    long  dv_calls;       /* d_mdl_visible: entries, the ones the frustum */
    long  dv_fout;        /* threw out, the tree descents the rest cost */
    long  dv_desc;        /* and the ones that came back visible */
    long  dv_vis;
    long  nd_seen;        /* nodes and leaves the walk reached, summed over */
    long  lf_seen;        /* the run: what a cull cost divides by */
    short ent_left;       /* brush entities the walk has yet to emit,
                              counted down so the per-node test costs a
                              compare, not a call, once they're placed */
    short pt_culled;      /* leaves the portal flood removed from the
                              PVS this frame, or -1 when it gave up */
    short no_ents;        /* -noents */
    short no_items;       /* -noitems */
    short no_mdl;         /* -nomdl */
    short no_view;        /* -noview: no weapon in hand, for a reference frame */
    short no_ai;          /* -noai: the monsters stand where they spawned */
    short mdl_drawn;      /* monster triangles submitted this frame */
    short bad_order;      /* -badorder */

    /* r_mark_leaves's own memory, not reset by r_draw_world: the
       visible set only changes when the camera changes leaf, so these
       carry across frames on purpose. pvs_leaf starts at 0 same as a
       fresh BASIC integer would -- leaf 0 never occurs as a camera
       leaf (it's the outside-the-world solid leaf), so the first
       frame always decompresses. */
    short pvs_leaf;
    short dbg_camleaf;    /* the leaf the camera resolved into --
                              checks the one assumption PVS rests on */
} Renderer;

/* Camera -- eye and look direction. */
typedef struct {
    Vec3 pos;
    Vec3 look_at;
    short fps_view;        /* false = the fixed overhead view */
    float start_angle;     /* spawn yaw, seeds the mouse position (the
                               same trick teleporting uses -- the camera
                               reads its angle from the mouse, so the
                               mouse is what has to move) */
} Camera;

/* Player -- physics state. no_clip stops ent_check_teleport testing an
   already-noclipping player against trigger volumes, matching the old
   PlayerState field the same check reads.
   Caller-owned and caller-zeroed, matching q_pl.bi's PlayerState: pl_init
   sets pos/vel/on_ground, exactly as the old pl_init did, and nothing
   here sets peak_z/water_level/water_type -- they start at whatever the
   struct held (zero, for a fresh one), same as the BASIC's implicit
   struct-zero of a fresh Game. */
typedef struct {
    BspVec3  pos;
    BspVec3  vel;
    short no_clip;
    short on_ground;
    float peak_z;         /* highest z reached, so -jump is checkable */
    short water_level;    /* 0 dry, 1 feet, 2 waist, 3 eyes under */
    short water_type;     /* CONTENTS_WATER, _SLIME or _LAVA */
} Player;

/* PhaseTimes -- where a frame's time goes. The phases are disjoint and
   frame_sum is the whole frame measured at its own boundaries, so
   bench.txt can print what they do NOT account for (pt_other_mean)
   instead of leaving a reader to assume they account for everything:
   every pass this port has added -- the alias models, the mixer, the
   present -- was invisible here until it was bracketed, and an
   unbracketed pass reads as zero rather than as missing.
   build and raster are INSIDE draw, counted by d_faces itself. */
typedef struct {
    float tick_sum, tick_max;
    float cull_sum, cull_max;
    float walk_sum;               /* r_draw_world alone, inside cull */
    float draw_sum, draw_max;
    float alias_sum, alias_max;   /* the models, items, spikes and the gun */
    float hud_sum,  hud_max;
    float sound_sum;
    float present_sum;            /* the scale, the overlay on it, the blit */
    float frame_sum, frame_max;
    float build_sum;
    float raster_sum;
    long  n;               /* frames profiled; 0 until the warm-up is past,
                              which is also every site's "armed" test */
} PhaseTimes;

/* DrawParams -- everything d_draw_faces (d_faces.c, not yet moved into
   cport/) reads out of a frame, gathered once so the per-face loop
   never has to know Renderer/Camera/Env's layout. Mirrors the old
   q_draw.bi DrawParams field-for-field for the "in" half; the "out"
   half (polys/tris/the sc_find diagnostics) is d_faces.c's own to
   fill.

   No span_draw: the original's -spandraw path (r_span.c) is a
   prototype measurement rasteriser, gated behind a flag, that draws
   nothing unless asked and calls into nothing else this port needs --
   d_faces.c's own real per-face loop (uglPolyTP) never touches it.
   Not ported; a deliberate scope cut, not an oversight. */
typedef struct {
    QSurf   h_dst_dc;
    long  tex_ofs_ptr;
    long  turb_ptr;
    float xresh, yresh;
    float z_near, z_far;
    float anim_time;
    short frame_stamp;
    short ord_count;
    short use_lm;
    short lightmap;
    short backface;
    short rend_mode;
    short use_mips;
    short z_avail;      /* a depth buffer exists this frame -- host_z_on's
                            old (z_dc <> 0) test, done once by the caller
                            rather than read through a function */
    short x_res, y_res;
    short prof;
    /* out */
    short polys;
    short tris;
    long  build_us;      /* microseconds spent in sb_build */
    long  raster_us;     /* microseconds in the uglPolyTP call */
    short lm_want;       /* faces that asked for a surface */
    short lm_fallback;   /* ...and did not get one */
    long  k_mip;         /* sums of the sc_find key inputs, this frame */
    long  k_sw;
    long  k_sh;
    long  k_stag;
    long  k_v0;
    long  k_lm;
    long  k_hdr;         /* faces whose record has a lightmap */
    long  k_ext;         /* ...and non-zero extents */
    long  k_n;           /* sc_find calls */
} DrawParams;

#endif
