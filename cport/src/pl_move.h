#ifndef __PL_MOVE_H__
#define __PL_MOVE_H__

#include "renderer.h"
#include "world.h"

/*
 * q_pl.bi's constants. Player-physics-specific (contrast bsptypes.h's
 * CONTENTS_ codes, which are a general BSP fact, not this module's
 * own) -- ent.c also reads PL_FEET, so this header, not a local
 * #define in either .c, is the one place it's declared.
 */
#define PLAYER_HULL    1

#define PL_FALLACC     800.0f    /* units/s^2, Quake's sv_gravity */
#define PL_MAXVEL      2000.0f   /* a per-axis safety clamp, Quake's sv_maxvelocity */
#define PL_STOP_EPS    0.1f
#define PL_CLIP_EPS    0.03125f  /* 1/32, Quake's DIST_EPSILON */
#define PL_STEP        18.0f     /* tallest stair the player walks up, Quake's STEPSIZE */
#define PL_EYE         22.0f     /* eye above the hull origin */
#define PL_TELE_LIFT   27.0f     /* what a teleport destination adds above its own origin */
#define PL_GROUND_NRM  0.7f      /* cos of the steepest walkable slope */
#define PL_ACCELERATE  10.0f     /* Quake's sv_accelerate */
#define PL_AIRSPEEDCAP 30.0f     /* SV_AirAccelerate's hardcoded wishspeed cap */
#define PL_FRICTION    4.0f      /* Quake's sv_friction, ground and water alike */
#define PL_STOPSPEED   100.0f    /* Quake's sv_stopspeed */
#define PL_MAXSPEED    320.0f
#define PL_FWDSPEED    200.0f    /* Quake's cl_forwardspeed -- the walk, no +speed */
#define PL_EDGEFRIC    2.0f      /* sv_edgefriction: doubles over a drop */
#define PL_EDGE_FWD    16.0f
#define PL_EDGE_DROP   34.0f
#define PL_JUMP        270.0f
#define PL_NOCLIP      200.0f    /* noclip fly speed, units/s */
#define PL_WATERSINK   60.0f     /* downward drift in water with no input */
#define PL_SWIM_WATER  100.0f    /* JumpButton's velocity.z by liquid */
#define PL_SWIM_SLIME  80.0f
#define PL_SWIM_LAVA   50.0f
#define PL_WATERSCALE  0.7f      /* SV_WaterMove's wishspeed *= 0.7 */
#define PL_FEET        24.0f     /* player box: origin sits this far above the feet */
#define PL_HALF        16.0f     /* and half its width; what a pellet hits */
#define PL_ZLO         (-24.0f)
#define PL_ZHI         32.0f
#define PL_SHOT_RANGE  2048.0f   /* how far a bullet is traced */

/* q_pl.bi's TraceResult -- the result of sweeping the player hull from
   one point to another. frac is how far it got, 0..1; norm is the
   plane it stopped against. */
typedef struct {
    float frac;
    BspVec3  end_pos;
    BspVec3  norm;
    short all_solid;      /* the whole sweep was inside solid */
    short start_solid;    /* it began inside solid */
} TraceResult;

/*
 * name: pl_point_contents
 * desc: The leaf contents at a point, walked in hull 0 -- the render
 *       tree, not the clipnodes, which carry only EMPTY and SOLID.
 */
short pl_point_contents( BspVec3 *p, World *world );

/*
 * name: pl_init
 * desc: Seeds the player from a spawn point. start_override, when not
 *       NULL, is used as-is (Config's `-at` override, once Config
 *       exists); otherwise the spawn comes from the camera's own
 *       position, Y-up swapped back to pl.pos's Z-up -- the ELSE branch
 *       of the old pl_init, the only one reachable today since cport/
 *       has no Config yet to carry start_set/start_x/y/z.
 */
void pl_init( Player *player, Camera *cam, BspVec3 *start_override );

/*
 * name: pl_move
 * desc: One tick of player physics: accelerate along the look
 *       direction, apply friction and gravity, move with collision,
 *       then put the eye where the camera can use it. fwd/strafe are
 *       -1, 0 or 1.
 */
void pl_move( World *world, Player *player, Camera *cam,
              float fwd, float strafe, float dir_x, float dir_y,
              short jump, float dt );

/* Builds world->clip: clip_count entries from assets.zip's own
   already-narrowed clip.pag (fatal if it won't load). pl_move owns
   the hulls -- it's the only reader -- so it makes the store itself;
   the loader (mod.c) passes only the count. */
void pl_load_hulls( World *world, short clip_count );

#endif
