#ifndef __MDL_AI_H__
#define __MDL_AI_H__

#include "world.h"
#include "renderer.h"
#include "pl_move.h"
#include "fight.h"

/*
 * mdl_ai.h -- id's own monster AI (ai.qc, sv_move.c, soldier.qc and the
 * rest), plus the own-goal wander stock Quake has no state for: a
 * walkmonster with no path_corner target sets pausetime 99999999 and
 * never leaves stand. Constants are id's, not approximated.
 *
 * NOT here: the three attacks that spawn a projectile -- the ogre's
 * grenade, the zombie's gib and the wizard's spike -- which want the
 * Spike array the weapons subsystem owns. Those monsters still enter
 * the attack state and play its frames; nothing leaves them yet.
 */

/* MdlEnt.state */
#define MDL_ST_STAND   0
#define MDL_ST_RUN     1
#define MDL_ST_DEAD    2      /* the death frames once, then a corpse */
#define MDL_ST_PAIN    3      /* the flinch a hit that does not kill plays */
#define MDL_ST_ATTACK  4      /* the knight's sword, charging */
#define MDL_ST_LEAP    5      /* the dog in the air, on its velocity */

#define MDL_HEALTH      30    /* monster_army's */
#define MDL_PELLETS     4     /* army_fire: FireBullets(4, '0.1 0.1 0') */
#define MDL_PELLET_DMG  4
#define MDL_SPREAD      0.1f
#define MDL_AIM_LAG     0.2f  /* aimed 0.2 s behind the player's velocity */
#define MDL_ATK_MELEE   0.9f  /* CheckAttack's chance per think, by range */
#define MDL_ATK_NEAR    0.4f
#define MDL_ATK_NEAR_MELEE 0.2f
#define MDL_ATK_MID     0.05f
#define MDL_HALF        16.0f /* monster_army's setsize */
#define MDL_ZLO         (-24.0f)
#define MDL_ZHI         40.0f
#define MDL_FLASH       0.12f /* seconds the muzzle flash shows */
#define MDL_YAW_SPEED   20.0f /* walkmonster_start_go's yaw_speed */
#define MDL_RANGE_MELEE 120.0f
#define MDL_RANGE_NEAR  500.0f
#define MDL_RANGE_MID   1000.0f  /* past this is RANGE_FAR, never noticed */
#define MDL_VIEW_OFS    25.0f
#define MDL_STEPSIZE    18.0f

#define KNIGHT_HEALTH      75
#define KNIGHT_MELEE_RANGE 60.0f
#define KNIGHT_MELEE_DMG   3.0f
#define KNIGHT_ATK_FIRST   5     /* the frames that strike, 0-based */
#define KNIGHT_ATK_LAST    7

#define DOG_HEALTH      25
#define DOG_BITE_RANGE  100.0f
#define DOG_BITE_DMG    8.0f
#define DOG_BITE_RATE   0.8f
#define DOG_LEAP_SPEED  300.0f   /* dog_leap2: v_forward * 300 + '0 0 200' */
#define DOG_LEAP_UP     200.0f
#define DOG_LEAP_MIN    80.0f    /* CheckDogJump's level range */
#define DOG_LEAP_MAX    150.0f
#define DOG_LEAP_DMG    10.0f    /* Dog_JumpTouch: 10 + 10 * random */

#define OGRE_HEALTH     200
#define OGRE_SAW_RANGE  100.0f
#define OGRE_SAW_DMG    4.0f
#define OGRE_SWING      1.4f     /* a swing's 14 frames */

#define DEMON_HEALTH     300
#define DEMON_CLAW_RANGE 100.0f
#define DEMON_CLAW_BASE  10
#define DEMON_CLAW_DMG   5.0f
#define DEMON_CLAW_A     4       /* the frames that strike, 0-based */
#define DEMON_CLAW_B     10
#define DEMON_LEAP_SPEED 600.0f
#define DEMON_LEAP_UP    250.0f
#define DEMON_LEAP_MIN   100.0f
#define DEMON_LEAP_MAX   200.0f
#define DEMON_LEAP_TOUCH 400.0f  /* Demon_JumpTouch bites past this speed */
#define DEMON_LEAP_DMG   40.0f   /* 40 + 10 * random */

#define ZOMBIE_HEALTH    60
#define ZOMBIE_ATK_NEAR  0.4f
#define ZOMBIE_ATK_MID   0.1f

#define WIZARD_HEALTH     80
#define WIZARD_FLY_LO     30.0f  /* held 30..40 above the player, 8 a step */
#define WIZARD_FLY_HI     40.0f
#define WIZARD_FLY_STEP   8.0f
#define WIZARD_FLY_DIST   16.0f  /* wiz_run's ai_run(16) */
#define WIZARD_ATK_NEAR   0.6f
#define WIZARD_ATK_MID    0.2f
#define WIZARD_ATK_WAIT   2.0f

#define SHAMBLER_HEALTH     600
#define SHAMBLER_SMASH_DMG  40.0f
#define SHAMBLER_SMASH      1.2f
#define SHAMBLER_BOLT_RANGE 600.0f
#define SHAMBLER_BOLT_DMG   10
#define SHAMBLER_BOLT_UP    40.0f
#define SHAMBLER_BOLT_AIM   16.0f
#define SHAMBLER_BOLT_A     5     /* 0-based magic frames */
#define SHAMBLER_BOLT_B     8
#define SHAMBLER_BOLT_C     9
#define SHAMBLER_ATK_WAIT   2.0f  /* + 2 * random */

/* The wander, which is this port's own and not id's. */
#define MDL_WANDER_MIN      64.0f
#define MDL_WANDER_MAX      256.0f
#define MDL_WANDER_ARRIVE   24.0f
#define MDL_WANDER_MAXTICKS 100    /* give up after 10 s of think-ticks */
#define MDL_PATROL_STEP     2.0f   /* ai_walk's stride: army_walk's average */
#define MDL_STAND_MIN       1.0f
#define MDL_STAND_MAX       4.0f

/*
 * name: mdl_spawn
 * desc: walkmonster_start_go on one monster: health by kind, the first
 *       patrol corner if it has one, and droptofloor.
 */
void mdl_spawn( World *world, MdlEnt far *ent );

/*
 * name: mdl_think
 * desc: One 10 Hz think. can_chase gates the FindTarget call alone --
 *       a monster without it still wanders on its own goals.
 */
void mdl_think( World *world, Player *player, Fight *fight, Renderer *rdr,
                 MdlEnt far *ent, MdlState *m, short can_chase );

/*
 * name: mdl_tick
 * desc: mdl_think over every monster the map spawned, and nothing when
 *       -noai is on.
 */
void mdl_tick( World *world, Player *player, Fight *fight, Renderer *rdr );

/*
 * name: mdl_ai_stats
 * desc: how many monsters are hunting, and how many have left their
 *       spawn by more than 32 units.
 */
void mdl_ai_stats( World *world, short *hunting, short *moved );

/*
 * name: pl_damage
 * desc: T_Damage on the player: the pentagram, then the armor's share,
 *       then the health.
 */
void pl_damage( Fight *fight, Renderer *rdr, short dmg );

#endif
