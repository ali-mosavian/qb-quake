#ifndef __FIGHT_H__
#define __FIGHT_H__

/*
 * Fight -- q_pl.bi's PlayerCombat, the part of it the movers read.
 * Keys gate a door, secrets are counted by a trigger, and the
 * centerprint is what a trigger or a door says. Grows as the rest of
 * the game layer lands; nothing here is map data, so it lives beside
 * the Player rather than in World.
 */
#define PL_IT_KEY1 1
#define PL_IT_KEY2 2

#define ENT_MSG_TIME 2.0f     /* scr_centertime */
#define ENT_MSG_LEN  40       /* one line of the overlay's font */

typedef struct {
    long  items;              /* PL_IT_* bits: the keys held */
    short secrets;
    short worldtype;          /* worldspawn's: which key names and sounds */
    float gravity;            /* world.qc's sv_gravity for this map */
    char  msg[ENT_MSG_LEN + 1];
    float msg_until;          /* anim_time the centerprint clears at */
} Fight;

#endif
