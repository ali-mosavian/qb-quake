#ifndef __SND_MIX_H__
#define __SND_MIX_H__

#include "bsptypes.h"

/*
 * snd_mix.h -- S_PaintChannels for one 8-bit mono ring. snd.c is the
 * layer above: this owns the channels and the paint and knows nothing
 * about files, the card or the game.
 */

/* an (offset, length, loop) into the sample stream, sndtab.raw's own
   record. The offset is in SAMPLES and lands on a block; the length is
   the wav's own, so the silence a block's tail is padded with never
   plays. loop is where a looping sound rejoins, -1 for one that plays
   once. */
typedef struct { long ofs, len; short loop; } SndRec;

/* the entity whose sounds are never spatialised and never stolen by
   another's: cl.viewentity */
#define SND_ENT_PLAYER 1

/*
 * name: snd_mix_setup
 * desc: hnd is the samples' EMS handle, ring dsp.asm's DMA buffer,
 *       scratch its spare block and scratch_bytes how much of it there
 *       is -- -1 when that is short, which is a real failure and not a
 *       rounding: the channels once ran 304 bytes past dsp.asm's 1792
 *       and the map hung in the allocator instead. dec is snddec.raw,
 *       512 bytes of it, the codec's whole contract. water and sky are
 *       the leaves' two ambient loops. Starts every recorded static.
 */
short snd_mix_setup( short hnd, unsigned char far *ring, void far *scratch,
                      SndRec far *tab, short count, short scratch_bytes,
                      signed char far *dec, short water, short sky );

/* S_StartSound: a channel of ent's own chan (not 0) is replaced, else a
   free one or the one with least left, never the player's for another
   entity's sound. vol 1..255, attn ATTN_*, org where it starts, ear the
   listener. A sound silent from there takes nothing. The channel, or -1. */
short snd_mix_start( short id, short vol, short ent, short chan, short attn,
                      BspVec3 *org, BspVec3 *ear );

/* room for n static points, before any snd_mix_ambient */
short snd_mix_statics( short n );

/* S_StaticSound, before the card is up: a point playing id at vol. Every
   point of one sound shares one looping channel, its volume the points'
   sum -- Quake's combine, and what lets 71 torches play on eight
   channels. -1 when full. */
short snd_mix_ambient( short id, short vol, BspVec3 *org );

/* static points playing, and the channels they share */
short snd_mix_loops( void );
short snd_mix_voices( void );

/* times an entity's looping sound rejoined its loop */
short snd_mix_wraps( void );

/* the sounds on the dynamic channels now, up to 8, and how many */
short snd_mix_live( short *ids );

/* the water (0) or sky (1) ambient's volume now */
short snd_mix_leaf_vol( short i );

/* Every sound in the table decoded through the paint's own fetch and
   summed, table order, the duplicates twice: the only headless view of
   what the card is handed, since a decode that reads the wrong nibble
   or the wrong page still fills the ring and every counter stays
   right. -sndsum prints it; test-sndcodec.sh has mksnd.py's own answer. */
unsigned long snd_mix_sum( void );

/*
 * name: snd_mix_frame
 * desc: pos is qglDspPos now, adv the samples the frame's wall time is
 *       worth (which tells one wrap of the ring from two), ear the
 *       listener and amb the ambient levels of the leaf it is in, water
 *       in the high nibble and sky in the low. Re-places every channel,
 *       then paints from where it stopped to a quarter second past the
 *       DMA -- ALWAYS, whether or not a channel is playing: the ring is a
 *       loop, and a stretch left unpainted is played again. Returns the
 *       underruns so far.
 */
short snd_mix_frame( short pos, long adv, BspVec3 *ear, unsigned char amb );

#endif
