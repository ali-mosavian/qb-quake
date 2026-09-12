#ifndef __FIGHT_H__
#define __FIGHT_H__

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
} Fight;

#endif
