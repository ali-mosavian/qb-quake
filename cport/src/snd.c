/*
 * snd.c -- see snd.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "snd.h"
#include "snd_mix.h"
#include "assets.h"
#include "qgl.h"

#define SND_RATE       11025
#define SND_CLIP_DIST  1000.0f   /* sound_nominal_clip_dist, ATTN_NORM */
#define SND_PAGE       16384L
#define PAGE_SLOT      2

static short snd_on      = 0;
static short snd_hnd     = 0;
static short snd_started = 0;
static short snd_under   = 0;

void snd_init( short off )
{
    SndRec far *tab;
    unsigned char far *raw;
    long  remain, want, n;
    short fh, pg, pgseg, count;

    snd_on = 0;
    if ( off ) return;
    if ( !asset_has( "snd.raw" ) || !asset_has( "sndtab.raw" ) ) {
        fprintf( stderr, "no sounds in the container -- rebuild its assets with the PAK\n" );
        return;
    }
    if ( !qglDspInit( SND_RATE ) ) return;   /* no card: play nothing, run on */

    /* the table first: its count has to agree with snd.h's SND_*,
       which are indices into it. A table from another mksnd.py run
       would play the wrong sound for every id and say nothing. */
    raw = asset_load_whole( "sndtab.raw", &n );
    count = *(short far *) raw;
    if ( count != SND_COUNT ) {
        fprintf( stderr, "sndtab.raw has %d sounds, snd.h says %d\n", (int) count, SND_COUNT );
        qglMemFree( (long) raw );
        qglDspShutdown();
        return;
    }
    tab = (SndRec far *) ( raw + 2 );

    /* and the samples, straight into EMS a page at a time: 1.3 MB of
       them, which is why they are not in the far heap */
    fh = asset_seek( "snd.raw", &remain );
    snd_hnd = qglGemAlloc( remain );
    if ( !snd_hnd ) {
        fprintf( stderr, "snd.raw: no EMS for %ld bytes\n", remain );
        qglMemFree( (long) raw );
        qglDspShutdown();
        return;
    }
    for ( pg = 0; remain > 0; pg++ ) {
        pgseg = qglGemMap( snd_hnd, pg, PAGE_SLOT );
        if ( !pgseg ) { fprintf( stderr, "snd.raw: page %d would not map\n", (int) pg ); exit( 1 ); }
        want = remain > SND_PAGE ? SND_PAGE : remain;
        if ( qglFileRead( fh, (long) pgseg << 16, want ) != want ) {
            fprintf( stderr, "snd.raw: short read\n" ); exit( 1 );
        }
        remain -= want;
    }

    if ( snd_mix_setup( snd_hnd, (unsigned char far *) qglDspBuf(),
                        (void far *) qglDspScratch(), tab, count,
                        qglDspScratchBytes() ) < 0 ) {
        fprintf( stderr, "dsp.asm's scratch is short of the mixer's table and channels\n" );
        qglMemFree( (long) raw );
        qglGemFree( snd_hnd );
        qglDspShutdown();
        return;
    }
    qglMemFree( (long) raw );
    snd_on = -1;
}

/* Recorded whatever the card does, and unguarded on purpose: this runs
   while the map loads, before snd_init has been anywhere near a Sound
   Blaster, and an ambient nobody ever starts costs its record. */
void snd_ambient( short id, short vol, BspVec3 *org )
{
    snd_mix_ambient( id, vol, org );
}

void snd_play( Player *player, short id, BspVec3 *org )
{
    float dx, dy, dz;
    short vol;

    if ( !snd_on ) return;
    dx = org->x - player->pos.x;
    dy = org->y - player->pos.y;
    dz = org->z - player->pos.z;
    vol = (short) ( 255.0f * ( 1.0f - (float) sqrt( dx*dx + dy*dy + dz*dz ) / SND_CLIP_DIST ) );
    if ( vol <= 0 ) return;
    if ( snd_mix_start( id, vol ) >= 0 ) snd_started++;
}

void snd_frame( Player *player, float dt )
{
    if ( !snd_on ) return;
    snd_under = snd_mix_frame( qglDspPos(), (long) ( dt * SND_RATE ), &player->pos );
}

void snd_shutdown( void )
{
    if ( !snd_on ) return;
    snd_on = 0;
    qglDspShutdown();
    qglGemFree( snd_hnd );
}

void snd_stats( short *started, short *loops, short *under )
{
    *started = snd_started;
    *loops   = snd_mix_loops();
    *under   = snd_under;
}
