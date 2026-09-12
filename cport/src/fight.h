#ifndef __FIGHT_H__
#define __FIGHT_H__

#include "bsptypes.h"   /* BspVec3 -- a Spike's own */

/*
 * Fight -- q_pl.bi's PlayerCombat, the part of it this port has reached.
 * Keys gate a door, secrets are counted by a trigger, the centerprint is
 * what a trigger or a door says, and the rest is what a pickup fills.
 * Grows as the rest of the game layer lands; nothing here is map data,
 * so it lives beside the Player rather than in World.
 */
/* q_pl.bi's own values, not renumbered: the keys are 8 and 16 because
   the three weapons the shareware game starts with take 1, 2 and 4. */
#define PL_IT_SHOTGUN 1
#define PL_IT_SSG     2
#define PL_IT_NAILGUN 4
#define PL_IT_KEY1    8       /* the silver key: this map's, never carried */
#define PL_IT_KEY2    16      /* and the gold */
#define PL_IT_GL      32
#define PL_IT_SNG     64
#define PL_IT_RL      128

#define PL_HEALTH       100
#define PL_HEALTH_MEGA  250   /* T_Heal ignoring the cap stops here */
#define PL_ROT_DELAY    5.0f  /* item_megahealth_rot: then a point a second */
#define PL_SHELLS       25    /* Quake's starting shells */
#define PL_SHELLS_MAX   100
#define PL_NAILS_CAP    200
#define PL_ROCKETS_CAP  100
#define PL_ARMOR1_TYPE  0.3f  /* armor_touch: green, and yellow */
#define PL_ARMOR2_TYPE  0.6f
#define PL_BONUS_SHIFT  50.0f /* the pickup flash, fading 100/s */

/* The guns, q_pl.bi's own numbers: the shotgun's six pellets of four
   at 0.04, the super shotgun's fourteen at 0.14 by 0.08 for two
   shells, the nailgun's nine a nail at 1000. */
#define PL_PELLETS      6
#define PL_PELLET_DMG   4
#define PL_SPREAD       0.04f
#define PL_FIRE_RATE    0.5f     /* the shotgun's attack_finished */
#define PL_SSG_RATE     0.7f
#define PL_SSG_PELLETS  14
#define PL_SSG_SPREAD_X 0.14f
#define PL_SSG_SPREAD_Y 0.08f
#define PL_QUAD_MUL     4

#define PL_NG_RATE      0.2f
#define PL_NG_SPEED     1000.0f
#define PL_NG_DMG       9
#define PL_SNG_DMG      18
#define PL_NG_OX        4.0f     /* the muzzle, alternating either side */
#define PL_NG_UP        16.0f
#define PL_NG_LIFE      6.0f

#define PL_GL_RATE      0.6f
#define PL_GL_SPEED     600.0f
#define PL_GL_UP        200.0f
#define PL_GL_FUSE      2.5f
#define PL_GL_DMG       120.0f

#define PL_RL_RATE      0.8f
#define PL_RL_SPEED     1000.0f
#define PL_RL_HIT       100      /* the direct hit: 100 + 20 * random */
#define PL_RL_HIT_RND   20
#define PL_RL_DMG       120.0f   /* and the blast where it stopped */
#define PL_RL_LIFE      5.0f

#define PL_BOUNCE       1.5f     /* MOVETYPE_BOUNCE's ClipVelocity overbounce */
#define PL_NAILS_MAX    24       /* in flight at once */
#define PL_FIREBALL_DMG 20       /* fire_touch */

/* One projectile: a nail, a grenade, a rocket, a trap's spike, an
   ogre's grenade, a zombie's gib or a lava ball. The flags say which,
   and pl_nail_free clears them all -- a nail handed a spent grenade's
   slot bounced and blew up before it did. */
typedef struct {
    BspVec3 pos, vel;
    short   alive;
    float   die_at;
    short   hostile;      /* bites the player, not the monsters */
    short   dmg;
    short   grenade;      /* gravity, a bounce, a fuse and a blast */
    short   gib;          /* a zombie's: bites where it lands, no blast */
    short   rocket;       /* straight, the blast where it stops */
    short   toss;         /* a hostile one under gravity: the lava ball */
} Spike;

#define ENT_MSG_TIME 2.0f     /* scr_centertime */
#define ENT_MSG_LEN  40       /* one line of the overlay's font */

typedef struct {
    long  items;              /* PL_IT_* bits: the weapons owned and the keys */
    short secrets;
    short worldtype;          /* worldspawn's: which key names and sounds */
    float gravity;            /* world.qc's sv_gravity for this map */
    char  msg[ENT_MSG_LEN + 1];
    float msg_until;          /* anim_time the centerprint clears at */

    short health;
    short armor;
    float armor_type;         /* armortype: the share of a hit it takes, 0 none */
    short weapon;             /* the one in hand, a PL_IT_* bit */
    short shells, nails, rockets;
    float rot_at;             /* megahealth: the next point over 100 rots then */
    float quad_until;         /* super_damage_finished */
    float suit_until;         /* radsuit_finished */
    float pent_until;         /* invincible_finished */
    float bonus_pct;          /* the pickup flash, 50, fading 100/s */
    float show_hostile;       /* W_Attack: time + 1, monsters notice a shot
                                 from behind until then -- nothing sets it
                                 until the player has a weapon */
    short leaps;              /* dogs and demons that left the ground */
    short kills, deaths, booms;
    float next_fire;          /* attack_finished */
    float fire_at;            /* when the last shot left, for the view model */
    float flash_until;        /* the muzzle flash shows until then */
    short nail_side;          /* the nailgun alternates its muzzle */
    Spike nail[PL_NAILS_MAX];
} Fight;

/* The header carries only the struct and its constants; every routine
   that acts on it is declared in weapons.h, which can see World and
   Player. */

#endif
