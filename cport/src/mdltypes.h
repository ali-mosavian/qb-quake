#ifndef __MDLTYPES_H__
#define __MDLTYPES_H__

#include "bsptypes.h"

/*
 * mdltypes.h -- MdlState and MdlEnt alone, so world.h can hold them
 * without including mdl.h, which includes world.h. Everything else
 * about a model is mdl.h's.
 */
#define MDL_MAXV      236        /* the dog's, the largest that fits */
#define MDL_TRI_BYTES 18
#define MDL_KINDS     8

/* the view weapons, in the order host_view_load and d_draw_view index
   them -- v_shot, v_shot2, v_nail, v_rock, v_nail2, v_rock2 */
#define PL_VIEW_SHOT   0
#define PL_VIEW_SSG    1
#define PL_VIEW_NAIL   2
#define PL_VIEW_GL     3
#define PL_VIEW_SNG    4
#define PL_VIEW_RL     5
#define PL_VIEW_N      6

/* MDL_KIND_*, mkassets.py's own numbering */
#define MDL_KIND_ARMY     0
#define MDL_KIND_KNIGHT   1
#define MDL_KIND_DOG      2
#define MDL_KIND_OGRE     3
#define MDL_KIND_DEMON    4
#define MDL_KIND_ZOMBIE   5
#define MDL_KIND_WIZARD   6
#define MDL_KIND_SHAMBLER 7

/* mkmdl.py's .geo header, 48 bytes. Read whole and picked apart, so
   the field order here is the file's. */
typedef struct {
    long  magic;
    short ntri, nvert, nframe;
    short skin_w, skin_h;
    BspVec3 scale;              /* vertex byte -> model unit */
    BspVec3 origin;
    short nstand, nrun, ndeath, npain, natk;
} MdlHead;

#define REC_MDLHEAD 48
typedef char rec_mdlhead_ok[ sizeof(MdlHead) == REC_MDLHEAD ? 1 : -1 ];

/* One loaded model, shared by every monster of its kind. */
typedef struct {
    short   loaded;
    short   ntri, nvert, nframe;
    QSurf   skin;
    short   vtx_hnd;            /* qglGemAlloc: page 0 vertices, page 1 triangles */
    BspVec3 scale, origin;
    float   radius, zlo, zhi;   /* the box any frame at any yaw fits in */
    short   nstand, nrun, ndeath, npain, natk;
} MdlState;

/* One spawned monster: everything mdl_think owns, separate from the
   MdlState a whole kind shares. BSP space, Z up, like Player.pos, so it
   can be handed to pl_trace with no copy. */
typedef struct {
    BspVec3 pos;
    float   yaw;                /* Quake's own, CCW from +x -- not mirrored */
    float   ideal_yaw;          /* what change_yaw turns towards */
    short   kind;
    short   state;              /* MDL_ST_* */
    short   anim_frame;         /* within the set state selects */
    float   next_think;         /* anim_time of the next 10 Hz think */
    BspVec3 goal;               /* the wander or patrol destination */
    float   stand_until;        /* anim_time to leave STAND on */
    short   wander_ticks;       /* think-ticks spent on this goal */
    short   health;
    short   hunting;            /* has seen the player */
    float   next_attack;
    float   flash_until;        /* the volley's muzzle flash, until then */
    float   pain_finished;      /* no new flinch before this */
    BspVec3 spawn;
    BspVec3 vel;                /* a leaper's, MOVETYPE_STEP off the ground */
    short   leapt;              /* this leap has landed its damage */
    short   patrol, corner;     /* the map's path_corner, and the one bound for */
    float   idle_at;            /* the next roll for an idle sound */
    short   water;              /* SV_CheckWaterTransition's: 1 in a liquid,
                                   -1 out, 0 before its first look */
} MdlEnt;


#endif
