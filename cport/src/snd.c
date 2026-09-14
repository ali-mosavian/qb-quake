/*
 * snd.c -- see snd.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "snd.h"
#include "snd_mix.h"
#include "r_bsp.h"
#include "assets.h"
#include "qgl.h"

#define SND_RATE       11025
#define SND_PAGE       16384L
#define PAGE_SLOT      2
#define SND_DTAB       512L      /* snddec.raw: 32 scales x 16 codes */

static short snd_on      = 0;
static short snd_hnd     = 0;
static short snd_started = 0;
static short snd_under   = 0;
static unsigned char snd_seen[(SND_COUNT + 7) / 8];

void snd_init( short off )
{
    SndRec far *tab;
    unsigned char far *raw;
    unsigned char far *dec;
    long  remain, want, n;
    short fh, pg, pgseg, count;

    snd_on = 0;
    if ( off ) return;
    if ( !asset_has( "snd.bsc" ) || !asset_has( "sndtab.raw" ) || !asset_has( "snddec.raw" ) ) {
        fprintf( stderr, "no sounds in the container -- rebuild its assets with the PAK\n" );
        return;
    }
    if ( !qglDspInit( SND_RATE ) ) return;   /* no card: play nothing, run on */

    /* the table first: its count has to agree with snd.h's SND_*,
       which are indices into it. A table from another mksnd.py run
       would play the wrong sound for every id and say nothing. */
    raw = asset_load_whole( "sndtab.raw", &n );
    count = *(short far *) raw;
    if ( count != SND_COUNT || n < 2 + (long) count * sizeof(SndRec) ) {
        fprintf( stderr, "sndtab.raw has %d sounds, snd.h says %d\n", (int) count, SND_COUNT );
        qglMemFree( (long) raw );
        qglDspShutdown();
        return;
    }
    tab = (SndRec far *) ( raw + 2 );
    dec = asset_load( "snddec.raw", SND_DTAB );

    /* and the samples, straight into EMS a page at a time: 1.2M of
       bsc4/32n, which is why they are not in the far heap */
    fh = asset_seek( "snd.bsc", &remain );
    snd_hnd = qglGemAlloc( remain );
    if ( !snd_hnd ) {
        fprintf( stderr, "snd.bsc: no EMS for %ld bytes\n", remain );
        qglMemFree( (long) dec );
        qglMemFree( (long) raw );
        qglDspShutdown();
        return;
    }
    for ( pg = 0; remain > 0; pg++ ) {
        pgseg = qglGemMap( snd_hnd, pg, PAGE_SLOT );
        if ( !pgseg ) { fprintf( stderr, "snd.bsc: page %d would not map\n", (int) pg ); exit( 1 ); }
        want = remain > SND_PAGE ? SND_PAGE : remain;
        if ( qglFileRead( fh, (long) pgseg << 16, want ) != want ) {
            fprintf( stderr, "snd.bsc: short read\n" ); exit( 1 );
        }
        remain -= want;
    }

    if ( snd_mix_setup( snd_hnd, (unsigned char far *) qglDspBuf(),
                        (void far *) qglDspScratch(), tab, count,
                        qglDspScratchBytes(), (signed char far *) dec,
                        SND_WATER, SND_WIND ) < 0 ) {
        fprintf( stderr, "dsp.asm's scratch is short of the mixer's table and channels\n" );
        qglMemFree( (long) dec );
        qglMemFree( (long) raw );
        qglGemFree( snd_hnd );
        qglDspShutdown();
        return;
    }
    qglMemFree( (long) dec );
    qglMemFree( (long) raw );
    snd_on = -1;
}

/* Every sound decoded and summed, the run's own answer to what mksnd.py
   put in the container -- 0 with the card or the flag off. */
unsigned long snd_sum( void )
{
    return snd_on ? snd_mix_sum() : 0L;
}

/* Recorded whatever the card does, and unguarded on purpose: this runs
   while the map loads, before snd_init has been anywhere near a Sound
   Blaster, and an ambient nobody ever starts costs its record. */
void snd_statics( short n )
{
    snd_mix_statics( n );
}

void snd_ambient( short id, short vol, BspVec3 *org )
{
    snd_mix_ambient( id, vol, org );
}

void snd_start( Player *player, short ent, short chan, short id, BspVec3 *org, short attn )
{
    if ( !snd_on ) return;
    if ( snd_mix_start( id, 255, ent, chan, attn, org, &player->pos ) < 0 ) return;
    snd_started++;
    snd_seen[id >> 3] |= (unsigned char) ( 1 << ( id & 7 ) );
}

void snd_frame( World *world, Player *player, float dt )
{
    BspVec3 eye;

    if ( !snd_on ) return;
    eye = player->pos;
    eye.z += PL_EYE;
    snd_under = snd_mix_frame( qglDspPos(), (long) ( dt * SND_RATE ), &player->pos,
                               world->leaves[ r_point_leaf( &eye, world ) ].amb );
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

void snd_report( char *buf )
{
    short ids[8], i, n = snd_mix_live( ids );

    strcpy( buf, "snd seen=" );
    for ( i = 0; i < (short) sizeof(snd_seen); i++ )
        sprintf( buf + strlen( buf ), "%02X", (int) snd_seen[i] );
    strcat( buf, " live=" );
    for ( i = 0; i < n; i++ )
        sprintf( buf + strlen( buf ), i ? ",%d" : "%d", (int) ids[i] );
    sprintf( buf + strlen( buf ), " wraps=%d water=%d sky=%d voices=%d",
             (int) snd_mix_wraps(), (int) snd_mix_leaf_vol( 0 ),
             (int) snd_mix_leaf_vol( 1 ), (int) snd_mix_voices() );
}
