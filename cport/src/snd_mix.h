#ifndef __SND_MIX_H__
#define __SND_MIX_H__

#include "bsptypes.h"

/*
 * snd_mix.h -- S_PaintChannels for one 8-bit mono ring. snd.c is the
 * layer above: this owns the channels and the paint and knows nothing
 * about files, the card or the game.
 */

/* an (offset, length) into the sample stream, sndtab.raw's own record */
typedef struct { long ofs, len; } SndRec;

/*
 * name: snd_mix_setup
 * desc: hnd is the samples' EMS handle, ring dsp.asm's DMA buffer,
 *       scratch its spare block and scratch_bytes how much of it there
 *       is -- -1 when that is short, which is a real failure and not a
 *       rounding: the channels once ran 304 bytes past dsp.asm's 1792
 *       and the map hung in the allocator instead. Starts every
 *       recorded ambient on its own looping channel.
 */
short snd_mix_setup( short hnd, unsigned char far *ring, void far *scratch,
                      SndRec far *tab, short count, short scratch_bytes );

/* S_StartSound's channel pick: a free one, else the one with least
   left to play. vol 1..255; the channel, or -1. */
short snd_mix_start( short id, short vol );

/* an ambient point, before the card is up. Returns -1 when full. */
short snd_mix_ambient( short id, short vol, BspVec3 *org );

short snd_mix_loops( void );

/*
 * name: snd_mix_frame
 * desc: pos is qglDspPos now, adv the samples the frame's wall time is
 *       worth (which tells one wrap of the ring from two), ear the
 *       player. Paints from where it stopped to a quarter second past
 *       the DMA -- ALWAYS, whether or not a channel is playing: the
 *       ring is a loop, and a stretch left unpainted is played again.
 *       Returns the underruns so far.
 */
short snd_mix_frame( short pos, long adv, BspVec3 *ear );

#endif
