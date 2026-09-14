#ifndef __SND_H__
#define __SND_H__

#include "bsptypes.h"
#include "pl_move.h"
#include "snd_mix.h"    /* SND_ENT_PLAYER */

/*
 * snd.h -- the sound layer: Quake's snd_dma.c without the stereo.
 *
 * qglDspInit starts a Sound Blaster playing a 4096-byte ring in
 * auto-init DMA; snd.bsc, mksnd.py's concatenation of the game's wavs
 * as bsc4/32n, goes into one EMS handle a page at a time and
 * snddec.raw is the table it is decoded through; snd_mix.c paints its
 * channels into the ring ahead of where the DMA is, once a frame. The
 * card never stops: a frame with nothing playing still paints, silence
 * being 128 and not zero, because the ring is a loop and what is not
 * repainted is played again.
 */

/* the sounds, in tools/mksnd.py's SOUNDS order -- q_pl.bi's own
   numbering, and sndtab.raw's. SND_MON + kind * 4 is a monster's
   four for kinds 0..4, SND_MON2 + (kind - 5) * 4 for the rest. */
#define SND_COUNT       165
#define SND_SHOTGUN     0
#define SND_SSG         1
#define SND_NAIL        2
#define SND_BOOM        3
#define SND_HEALTH      4
#define SND_HEALTH_ROT  5
#define SND_HEALTH_MEGA 6
#define SND_ARMOR       7
#define SND_WEAPON      8
#define SND_AMMO        9
#define SND_QUAD        10
#define SND_SUIT        11
#define SND_SECRET      12
#define SND_TALK        13
#define SND_PAIN1       14    /* three of them, and SND_PAIN4's three */
#define SND_DEATH       17
#define SND_JUMP        18
#define SND_LAND        19
#define SND_LAND2       20
#define SND_SLIME       21
#define SND_BURN1       22    /* two */
#define SND_MON         24
#define SND_DOOR        44    /* doors.qc's 1..4: stop, move */
#define SND_SECRET1     52    /* func_door_secret's noise1..3 */
#define SND_BUTTON      61    /* func_button's 0..3 */
#define SND_KEY         67    /* a key taken: medieval, rune */
#define SND_KEYTRY      69    /* a key door refused then opened; rune is +2 */
#define SND_TRAIN       76    /* plats/train2 the stop, train1 the move */
#define SND_SPIKE2      78    /* trap_spikeshooter */
#define SND_DJUMP       79    /* the demon's leap */
#define SND_GRENADE     80    /* the ogre's grenade thrown, and bounced */
#define SND_BOUNCE      81
#define SND_MON2        82    /* the zombie's and the wizard's four, kinds 5 up */
#define SND_ROCKET      94    /* weapons/sgun1 */
#define SND_SHAM_MELEE  95
#define SND_SHAM_SMACK  96
#define SND_SHAM_BOOM   97
#define SND_PENT        98
#define SND_PENT_HIT    99
#define SND_WATER       100   /* the leaves' ambients */
#define SND_WIND        101
#define SND_PLAT        102   /* func_plat's sounds 1, 2: move, stop */
#define SND_TELE        106   /* play_teleport's five */
#define SND_TRIGGER     111
#define SND_H2OHIT      112
#define SND_FIRE        113   /* FireAmbient */
#define SND_FLUORO      114
#define SND_SPARK       115
#define SND_PAIN4       116
#define SND_DEATH2      119   /* four */
#define SND_H2ODEATH    123
#define SND_DROWN1      124   /* two */
#define SND_GASP1       126   /* two */
#define SND_INH2O       128
#define SND_INLAVA      129
#define SND_OUTWATER    130
#define SND_H2OJUMP     131
#define SND_UDEATH      132
#define SND_GIB         133
#define SND_QUAD_END    134
#define SND_SUIT_END    135
#define SND_PENT_END    136
#define SND_QUAD_SHOT   137
#define SND_RIC1        138   /* three */
#define SND_TINK        141
#define SND_SWIM1       142   /* two */
#define SND_ARMY_IDLE   144
#define SND_ARMY_PAIN2  145
#define SND_KNIGHT_IDLE 146
#define SND_SWORD2      147
#define SND_DOG_IDLE    148
#define SND_OGRE_IDLE   149
#define SND_OGRE_IDLE2  150
#define SND_OGRE_DRAG   151
#define SND_DEMON_IDLE  152
#define SND_Z_IDLE1     153
#define SND_Z_HIT       154
#define SND_Z_MISS      155
#define SND_Z_FALL      156
#define SND_Z_PAIN1     157
#define SND_WIZ_IDLE1   158   /* two */
#define SND_WIZ_HIT     160
#define SND_SHAM_IDLE   161
#define SND_SHAM_MELEE2 162
#define SND_BOSS_OUT    163
#define SND_BOSS_SIGHT  164

/* sound()'s attenuations and entity channels, id's numbers */
#define ATTN_NONE   0
#define ATTN_NORM   1
#define ATTN_IDLE   2
#define ATTN_STATIC 3
#define CHAN_AUTO   0
#define CHAN_WEAPON 1
#define CHAN_VOICE  2
#define CHAN_ITEM   3
#define CHAN_BODY   4

/* entity numbers for the channels: the player, a monster by its index,
   a brush by its submodel */
#define SND_ENT_MON   1024
#define SND_ENT_BRUSH 256

/*
 * name: snd_init
 * desc: The card, snd.bsc into EMS, and the mixer over dsp.asm's ring.
 *       Quiet and harmless on a machine with no card, on -nosound, or
 *       with no sounds in the container: every call below then returns
 *       at once.
 */
void snd_init( short off );

/* room for the map's n static points, before the first snd_ambient */
void snd_statics( short n );

/*
 * name: snd_ambient
 * desc: ambientsound: recorded at map load, before the card is up,
 *       started with it and looped for good. The mixer re-places it
 *       from the player every frame.
 */
void snd_ambient( short id, short vol, BspVec3 *org );

/*
 * name: snd_start
 * desc: sound(): id from ent's chan at org, full volume less the
 *       distance's share of a thousand units over attn. A new sound on
 *       an entity's channel (not CHAN_AUTO) ends the one there, which is
 *       how a mover's stop ends its looping move.
 */
void snd_start( Player *player, short ent, short chan, short id, BspVec3 *org, short attn );

#define snd_play( player, id, org ) snd_start( player, 0, CHAN_AUTO, id, org, ATTN_NORM )
#define snd_self( player, chan, id ) \
    snd_start( player, SND_ENT_PLAYER, chan, id, &(player)->pos, ATTN_NORM )

/*
 * name: snd_frame
 * desc: Once a frame, between the tick and the render -- nothing holds
 *       an EMS window then and the mixer takes PAGE_SLOT. dt is the
 *       frame's real time: it tells one wrap of the ring from two, and
 *       fades the ambients of the leaf the eye is in.
 */
void snd_frame( World *world, Player *player, float dt );

void snd_shutdown( void );

/* -sndsum's: every sound decoded through the mixer's own fetch and
   summed. See snd_mix.h. */
unsigned long snd_sum( void );

/* for bench.txt: sounds started, ambients looping, and the frames that
   found the DMA past what had been painted */
void snd_stats( short *started, short *loops, short *under );

/* the run's sound record, one line: every id started as a bitmap in hex,
   the ids on the dynamic channels now, loop wraps, the leaf ambients'
   volumes and the statics */
void snd_report( char *buf );

#endif
