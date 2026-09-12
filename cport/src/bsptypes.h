#ifndef __BSPTYPES_H__
#define __BSPTYPES_H__

#include "renderer.h"   /* BspVec3 */

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

/* bspfile.bi's PackedBounds -- a node or leaf box in six bytes, min xyz
   then max xyz, each (v - BOUND_BASE) / BOUND_Q with the min rounded
   down and the max up. A box therefore only ever grows, so r_cull_box
   culls less than it might, never more. mkassets.py's bound_bytes is
   the other half of this and the two must change together. */
typedef struct { unsigned char q[6]; } PackedBounds;
#define BOUND_Q    32.0f
#define BOUND_BASE (-4096.0f)

typedef struct {
    short plane_id;
    short child0;
    short child1;
    short lface_id;
    short lface_num;
    PackedBounds bound;
} Node;

typedef struct {
    BspVec3  norm;
    float dist;
} Plane;

/* bspfile.bi's DiskPlane -- the frustum's own plane record. Same shape
   as Plane except ptype is long, not short; r_set_frustum computes six
   of these from the view matrix, so there's no on-disk instance to
   confuse it with. */
typedef struct {
    BspVec3  norm;
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
    PackedBounds bound;
    short  lface_id;
    short  lface_num;
} Leaf;

/* bspfile.bi's Submodel -- 32 bytes, not the BSP's own 64. mkassets
   keeps the box and the two hulls the renderer and the player trace
   use, and narrows the rest away; origin, hulls 2 and 3 and vis_leafs
   have no reader here. */
typedef struct {
    BspVec3 mins, maxs;
    short head_node0, head_node1, first_face, num_faces;
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

/* q_map.bi's BrushModel -- per-submodel draw/solid/offset state, one
   entry per Submodel, index 0 is the world and always draw=solid=true,
   ofs zero. The offset is all three axes because a door slides along
   whichever one its movedir names; a plat uses ofs.z alone. */
typedef struct {
    short draw;
    short solid;
    BspVec3 ofs;
    short node;      /* ent_find_node's answer: where this submodel
                         belongs in the world's back-to-front order, or
                         ENT_NODE_DIRTY once the brush has moved */
} BrushModel;

/* A brush that moved since it was placed. Leaf 32767, which no map has
   -- -1 would be leaf 0, the answer for a box in solid. */
#define ENT_NODE_DIRTY ((short)0x8000)

/* bspfile.bi's ClipNode -- the pre-expanded collision hulls. A negative
   front/back is not a node index but a CONTENTS_ code. */
typedef struct {
    short plane_num;
    short front;
    short back;
} ClipNode;

/* The record sizes mkassets.py writes. A struct that drifts from its
   file is a "short read" several load marks after the structure that
   actually changed, so it is caught here instead: a mismatch is a
   negative array bound and the build stops on this line.
   cport/tools/test-records.sh reads these same numbers and checks the
   assets against them, which is the other half of the same fact. */
#define REC_PLANE     16
#define REC_NODE      16
#define REC_LEAF      16
#define REC_FACE      10
#define REC_CLIPNODE   6
#define REC_SUBMODEL  32
#define REC_TEXINFO   34

typedef char rec_plane_ok   [ sizeof(Plane)    == REC_PLANE    ? 1 : -1 ];
typedef char rec_node_ok    [ sizeof(Node)     == REC_NODE     ? 1 : -1 ];
typedef char rec_leaf_ok    [ sizeof(Leaf)     == REC_LEAF     ? 1 : -1 ];
typedef char rec_face_ok    [ sizeof(Face)     == REC_FACE     ? 1 : -1 ];
typedef char rec_clip_ok    [ sizeof(ClipNode) == REC_CLIPNODE ? 1 : -1 ];
typedef char rec_submodel_ok[ sizeof(Submodel) == REC_SUBMODEL ? 1 : -1 ];
typedef char rec_texinfo_ok [ sizeof(TexInfo)  == REC_TEXINFO  ? 1 : -1 ];

/* q_ent.bi's Teleporter. */
typedef struct {
    BspVec3  mins, maxs;
    BspVec3  dest;
    float yaw;
} Teleporter;

/* q_ent.bi's PlatEnt. A func_train shares the array: same brush, same
   speed, a different state machine. */
#define ENT_PLAT_DOWN  0
#define ENT_PLAT_UP    1
#define ENT_TRAIN_IDLE 2        /* a targeted train, before its trigger */
#define ENT_TRAIN_WAIT 3        /* at a corner for wait_left */
#define ENT_TRAIN_MOVE 4
#define ENT_PLAT_KIND_PLAT  0
#define ENT_PLAT_KIND_TRAIN 1
typedef struct {
    short model;
    float travel;
    float speed;
    short state;
    BspVec3  mins, maxs;
    short kind;
    short targeted;      /* a train's name id; 0 starts by itself */
    short first;         /* its first path_corner */
    short corner;        /* the one it is at, or bound for */
    float wait_left;
} PlatEnt;

/* q_ent.bi's ItemEnt: a pickup where the map put it, dropped to the
   floor at load. Single player, so taken is taken. */
typedef struct {
    short   kind;
    short   amount;      /* healamount, or the ammo, or a powerup's seconds */
    short   target;      /* fired when taken */
    short   crate;       /* CrateModel index, or -1: a flat box */
    BspVec3 pos;         /* BSP space, on the floor */
    short   gone;
} ItemEnt;

/* q_ent.bi's PathCorner. nxt -1 stays. */
typedef struct {
    BspVec3 org;
    float   wait;
    short   nxt;
} PathCorner;

/* q_ent.bi's DoorEnt -- doors.qc. A touch anywhere in the field sends
   every door of its linked group to the open end, where it holds and
   comes back; a touch while closing sends it out again. A secret door
   goes in two legs with a pause between, and comes home the same way. */
#define ENT_DOOR_SHUT       0
#define ENT_DOOR_OPENING    1
#define ENT_DOOR_OPEN       2
#define ENT_DOOR_CLOSING    3
#define ENT_DOOR_OUT1       4   /* a secret door's first leg, to ofs_mid */
#define ENT_DOOR_PAUSE_OUT  5
#define ENT_DOOR_PAUSE_BACK 6
#define ENT_DOOR_BACK2      7
#define ENT_DOOR_PAUSE   1.0f
#define ENT_DOOR_FIELD  60.0f   /* spawn_field grows the touch box this
                                   much in x and y ... */
#define ENT_DOOR_FIELDZ  8.0f   /* ... and this much in z */
#define ENT_TOUCH_SLACK  2.0f   /* a brush is touched from this close */
typedef struct {
    short   model;
    BspVec3 ofs_shut, ofs_open;
    BspVec3 ofs_mid;     /* a secret door's corner */
    float   speed, hold, hold_left, pause_left;
    short   state, secret, shoot;
    short   link;        /* lowest door index of its linked group */
    short   nolink, targeted, snd;
    short   key;         /* 1 silver, 2 gold */
    float   say_at;      /* door_touch's attack_finished: the refusal
                            is said two seconds apart, not every tick */
    BspVec3 mins, maxs;  /* the touch field */
    short   msg;
} DoorEnt;

/* q_ent.bi's TrigEnt -- triggers.qc and buttons.qc. All four kinds do
   one thing, fire a target, so they share an array. */
#define ENT_TRIG_ONCE     0
#define ENT_TRIG_MULTI    1
#define ENT_TRIG_COUNTER  2
#define ENT_TRIG_BUTTON   3
#define ENT_TRIG_EXIT     4     /* trigger_changelevel */
#define ENT_TRIG_SHOOT    5     /* a trigger with health: a pellet fires it */
#define ENT_TRIG_SECRET   6
#define ENT_TRIG_SHOOTER  7     /* trap_spikeshooter */
#define ENT_TRIG_RELAY    8
#define ENT_TRIG_BOSS     9     /* Chthon, unseen */
#define ENT_TRIG_BOLT    10     /* event_lightning */
#define ENT_TRIG_FIREBALL 11
#define ENT_TRIG_READY 0
#define ENT_TRIG_GOING 1        /* a button on its way in */
#define ENT_TRIG_HELD  2        /* pressed, or waiting to re-arm */
#define ENT_TRIG_BACK  3        /* a button on its way out */
#define ENT_TRIG_DONE  4
#define ENT_TRIG_ARMED 5        /* a shooter used this tick */
typedef struct {
    short   model, kind, target, name, kill;
    short   state, left, count;
    float   wait, wait_left, speed;
    BspVec3 ofs_out;     /* a button's pressed offset */
    short   snd;
    BspVec3 mins, maxs;  /* the volume, or the button's brush */
    short   msg;
    float   delay, delay_left;
} TrigEnt;

#endif
