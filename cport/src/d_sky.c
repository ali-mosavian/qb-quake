/*
 * d_sky.c -- WinQuake's sky (r_sky.c, d_sky.c). A sky texture is a back
 * layer and a front one, 128 square each; the front drifts over the back
 * at iskyspeed and the composed sky pans at iskyspeed2. mkassets splits
 * and shades the layers; index 0 in the front one is clear.
 */

#include <mem.h>

#include "qgl.h"
#include "d_sky.h"
#include "assets.h"
#include "qglsurf.h"

#define SKY_SIZE   128
#define SKY_MASK   127
#define SKY_SPEED  8.0f         /* iskyspeed */
#define SKY_SPEED2 2.0f         /* iskyspeed2 */
#define SKY_CYCLE  512.0f       /* R_SetSkyFrame: SKYSIZE * 8/2 * 2/2, both repeat */

/* Two reads held together: nothing holds these slots between faces. */
#define SKY_SLOT_BACK  2
#define SKY_SLOT_FRONT 3

static float sky_time( float t )
{
    return t - (float) (long) ( t / SKY_CYCLE ) * SKY_CYCLE;
}

void d_sky_init( World *world )
{
    world->sky_layers = 0;
    world->sky_dc     = 0;
    world->sky_shift  = -1;
    if ( !asset_has( "sky.raw" ) ) return;

    world->sky_layers = qgl_surf_from_member( "sky.raw", SKY_SIZE, QGL_SURF_EMS, 0 );
    if ( !world->sky_layers ) return;
    world->sky_dc = (QSurf) qglSfNew( SKY_SIZE, SKY_SIZE, QGL_SURF_EMS );
}

float d_sky_pan( float time )
{
    return sky_time( time ) * SKY_SPEED2;
}

void d_sky_make( World *world, float time )
{
    unsigned char row[SKY_SIZE];
    unsigned char far *front, far *back, far *out;
    long  layers = (long) (void far *) world->sky_layers;
    short shift, y, x;

    if ( !world->sky_dc ) return;
    shift = (short) ( (long) ( sky_time( time ) * SKY_SPEED ) & SKY_MASK );
    if ( shift == world->sky_shift ) return;
    world->sky_shift = shift;

    for ( y = 0; y < SKY_SIZE; y++ ) {
        front = (unsigned char far *) qglSfAccessRdEx( layers, SKY_SIZE + ( ( y + shift ) & SKY_MASK ),
                                                       SKY_SLOT_FRONT );
        _fmemcpy( row, front + shift, SKY_SIZE - shift );
        _fmemcpy( row + SKY_SIZE - shift, front, shift );
        back = (unsigned char far *) qglSfAccessRdEx( layers, y, SKY_SLOT_BACK );
        out  = (unsigned char far *) qglSfWrRow( (long) (void far *) world->sky_dc, y );
        for ( x = 0; x < SKY_SIZE; x++ ) out[x] = row[x] ? row[x] : back[x];
    }
}
