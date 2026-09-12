#ifndef __SND_H__
#define __SND_H__

#include "bsptypes.h"
#include "pl_move.h"

/*
 * snd.h -- the sound layer: Quake's snd_dma.c without the stereo.
 *
 * qglDspInit starts a Sound Blaster playing a 4096-byte ring in
 * auto-init DMA; snd.raw, mksnd.py's concatenation of the game's wavs,
 * goes into one EMS handle a page at a time; snd_mix.c paints eight
 * channels plus the map's ambients into the ring ahead of where the
 * DMA is, once a frame. The card never stops: a frame with nothing
 * playing still paints, silence being 128 and not zero, because the
 * ring is a loop and what is not repainted is played again.
 */

/* the sounds, in tools/mksnd.py's SOUNDS order -- q_pl.bi's own
   numbering, and sndtab.raw's. SND_MON + kind * 4 is a monster's
   four for kinds 0..4, SND_MON2 + (kind - 5) * 4 for the rest. */
#define SND_COUNT       100
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
#define SND_PAIN1       14    /* three of them */
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
#define SND_TRAIN       76    /* plats/train1 the stop, train2 the move */
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

/*
 * name: snd_init
 * desc: The card, snd.raw into EMS, and the mixer over dsp.asm's ring.
 *       Quiet and harmless on a machine with no card, on -nosound, or
 *       with no sounds in the container: every call below then returns
 *       at once.
 */
void snd_init( short off );

/*
 * name: snd_ambient
 * desc: ambientsound: recorded at map load, before the card is up,
 *       started with it and looped for good. The mixer re-places it
 *       from the player every frame.
 */
void snd_ambient( short id, short vol, BspVec3 *org );

/*
 * name: snd_play
 * desc: S_StartSound with SND_Spatialize, mono: full volume less the
 *       distance's share of a thousand units, taken once, where the
 *       sound began.
 */
void snd_play( Player *player, short id, BspVec3 *org );

/*
 * name: snd_frame
 * desc: Once a frame, between the tick and the render -- nothing holds
 *       an EMS window then and the mixer takes PAGE_SLOT. dt is the
 *       frame's real time: it tells one wrap of the ring from two.
 */
void snd_frame( Player *player, float dt );

void snd_shutdown( void );

/* for bench.txt: sounds started, ambients looping, and the frames that
   found the DMA past what had been painted */
void snd_stats( short *started, short *loops, short *under );

#endif
