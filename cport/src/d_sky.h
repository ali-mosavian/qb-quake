#ifndef D_SKY_H
#define D_SKY_H

#include "world.h"

#define SKY_SPAN  378.0f            /* 6 * (SKYSIZE/2 - 1): texels a unit of direction */
#define SKY_RECIP ( 1.0f / 128.0f )

/* sky.raw's two layers and the surface they compose into, or nothing:
   a map with no sky draws its sky faces as walls. */
void  d_sky_init( World *world );

/* R_MakeSky: the front layer at its shift over the back, when the shift
   has moved since the last compose. */
void  d_sky_make( World *world, float time );

/* the whole sky's pan, texels, D_Sky_uv_To_st's skytime*skyspeed2 */
float d_sky_pan( float time );

#endif
