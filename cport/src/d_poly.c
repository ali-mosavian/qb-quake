/*
 * d_poly.c -- the turbulence table. C port of the old d_poly.bas.
 *
 * That module had already been reduced to just this by the time the
 * BASIC-hosted transitional port reached it: d_draw_faces itself moved
 * to a C module a session ago, and nothing called d_poly.bas's own
 * d_clip_z after that -- confirmed by grep across the whole BASIC tree
 * before it was dropped rather than ported.
 */

#include "d_poly.h"

/* Quake's rocket-trail turbulence is 8 texels of a 64-wide texture;
   this table works in the normalised units the draw loop uses, so the
   amplitude is that ratio. */
#define TURB_AMP 0.125

/* Takes and returns double, matching the original BASIC evaluation:
   i * (2.0*3.14159265/256.0) was double precision (unsuffixed BASIC
   literals default to double), narrowed to single only at the store
   into a single-precision array. FSIN is a plain 8087+ instruction;
   this project already assumes the FPU is there, so no libm needed. */
static double fsin( double rad )
{
    double result;
    __asm {
        fld   rad
        fsin
        fstp  result
    }
    return result;
}

static float turb_sin[256];

void d_init_turb( void )
{
    short i;
    for ( i = 0; i < 256; i++ ) {
        turb_sin[i] = (float) ( TURB_AMP * fsin( (double) i * (2.0 * 3.14159265 / 256.0) ) );
    }
}

float far *d_turb_table( void )
{
    return turb_sin;
}
