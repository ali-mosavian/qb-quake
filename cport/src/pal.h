#ifndef __PAL_H__
#define __PAL_H__

#include "qgl.h"

/*
 * pal -- the palette this program installed, and lookups against it.
 *
 * mgl answered both by asking the hardware: uglPalGet read the DAC back
 * and uglPalBestFit matched against what it returned. The DAC holds six
 * bits a channel, so that round trip handed 0..63 values to a search
 * whose targets are 0..255 -- every HUD colour was matched against a
 * palette four times darker than the one the lookup meant. Keeping the
 * 8-bit palette we installed costs 768 bytes and removes the round trip
 * along with the error.
 */
void     pal_install( PalRgb far *p );
PalRgb far *pal_current( void );
short    pal_bestfit( short r, short g, short b );

#endif
