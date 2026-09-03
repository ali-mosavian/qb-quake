/*
 * ls.c -- light styles. C port of d_surf.bas's ls_* slice.
 */

#include <math.h>
#include <string.h>

#include "ls.h"

/* One pattern character to an intensity, Quake's own mapping: 'a' is
   0, 'z' is the brightest, everything else (including the pattern's
   null terminator, standing in for BASIC's empty-string case) clamps
   to 'm'. */
static short ls_lchar( char c )
{
    short v;

    if ( c == '\0' ) return ( 'm' - 'a' ) * 10;

    v = c - 'a';
    if ( v < 0 || v > 25 ) v = 'm' - 'a';
    return v * 10;
}

void ls_init( LightStyles *ls )
{
    short i;

    for ( i = 0; i <= LS_MAXSTYLE; i++ ) {
        strcpy( ls->tab[i].pattern, "m" );
        ls->tab[i].length = 1;
        ls->tab[i].frame  = 0;
        ls->tab[i].value  = ls_lchar( 'm' );
        ls->tab[i].epoch  = 0;
    }

    strcpy( ls->tab[1].pattern, "mmnmmommommnonmmonqnmmo" );
    ls->tab[1].length = 23;
    strcpy( ls->tab[10].pattern, "mmamammmmammamamaaamammma" );
    ls->tab[10].length = 25;

    ls->last = 0.0f;
}

void ls_animate( LightStyles *ls, float anim_time )
{
    short i, steps, nf, nv;

    steps = (short) ( (long) (anim_time * LS_RATE) - (long) (ls->last * LS_RATE) );
    if ( steps <= 0 ) return;
    ls->last = anim_time;

    for ( i = 0; i <= LS_MAXSTYLE; i++ ) {
        if ( ls->tab[i].length > 1 ) {
            nf = (short) ( (ls->tab[i].frame + steps) % ls->tab[i].length );
            ls->tab[i].frame = nf;
            nv = ls_lchar( ls->tab[i].pattern[nf] );
            if ( nv != ls->tab[i].value ) {
                ls->tab[i].value = nv;
                ls->tab[i].epoch++;
                if ( ls->tab[i].epoch > 32000 ) ls->tab[i].epoch = 1;
            }
        }
    }
}

short ls_epoch( LightStyles *ls, short style )
{
    if ( style < 0 || style > LS_MAXSTYLE ) style = 0;
    return ls->tab[style].epoch;
}

short ls_value( LightStyles *ls, short style )
{
    if ( style < 0 || style > LS_MAXSTYLE ) style = 0;
    return ls->tab[style].value;
}

short ls_scale_byte( short raw, short sval )
{
    long v = (long) raw * sval / LS_NEUTRAL;
    if ( v > 255 ) v = 255;
    if ( v < 0 )   v = 0;
    return (short) v;
}

short ls_add_dlight( short raw, float pdist, float ts, float tt, float radius )
{
    float d = (float) sqrt( pdist*pdist + ts*ts + tt*tt );
    float contrib = radius - d;
    long v;
    if ( contrib < 0.0f ) contrib = 0.0f;
    v = raw + (long) ( contrib + 0.5f );   /* clng() rounds; contrib is
                                               never negative here */
    if ( v > 255 ) v = 255;
    return (short) v;
}

/*
 * name: ls_selftest
 * desc: Proves the animation loop, not any real map: a synthetic
 *       2-char pattern must toggle value and bump epoch exactly once
 *       per change, a steady style must never bump, and steps must
 *       accumulate correctly across an uneven call pattern (two short
 *       ticks the same as one that covers both) -- neither map on
 *       hand has a non-neutral style, so this is what actually
 *       exercises ls_scale_byte/ls_add_dlight too.
 */
short ls_selftest( void )
{
    LightStyles ls;
    short e0;

    ls_init( &ls );

    /* style 0 is steady: many ticks, no bump */
    e0 = ls.tab[0].epoch;
    ls_animate( &ls, 0.05f );
    ls_animate( &ls, 1.05f );
    ls_animate( &ls, 2.05f );
    if ( ls.tab[0].epoch != e0 ) return -1;

    /* a synthetic 2-char pattern, 'a' then 'z': one step must flip the
       value and bump the epoch exactly once */
    strcpy( ls.tab[30].pattern, "az" );
    ls.tab[30].length = 2;
    ls.tab[30].frame  = 0;
    ls.tab[30].value  = ls_lchar( 'a' );
    ls.tab[30].epoch  = 0;
    ls.last = 0.0f;

    ls_animate( &ls, 0.1f );   /* one 10 Hz step: frame 0 -> 1, 'a' -> 'z' */
    if ( ls.tab[30].value != ls_lchar( 'z' ) ) return -2;
    if ( ls.tab[30].epoch != 1 ) return -3;

    ls_animate( &ls, 0.15f );  /* under 0.1s more: no new step, no bump */
    if ( ls.tab[30].epoch != 1 ) return -4;

    ls_animate( &ls, 0.2f );   /* the step lands: frame 1 -> 0, 'z' -> 'a' */
    if ( ls.tab[30].value != ls_lchar( 'a' ) ) return -5;
    if ( ls.tab[30].epoch != 2 ) return -6;

    /* two ticks that together cross a step boundary must land the same
       as one tick that crosses it directly -- steps come from elapsed
       TIME, not call count */
    strcpy( ls.tab[31].pattern, "az" );
    ls.tab[31].length = 2;
    ls.tab[31].frame  = 0;
    ls.tab[31].value  = ls_lchar( 'a' );
    ls.tab[31].epoch  = 0;
    ls.last = 0.0f;
    ls.tab[30].frame = 0; ls.tab[30].value = ls_lchar( 'a' ); ls.tab[30].epoch = 0;
    ls_animate( &ls, 0.04f );
    ls_animate( &ls, 0.11f );  /* crosses 0.1 here, one step total */
    if ( ls.tab[30].epoch != 1 ) return -7;

    /* ls_scale_byte: the one thing neither map on hand ever exercises
       for real, so it has to prove itself here instead. */
    if ( ls_scale_byte( 200, LS_NEUTRAL ) != 200 ) return -8;       /* neutral passes through */
    if ( ls_scale_byte( 200, LS_NEUTRAL / 2 ) != 100 ) return -9;   /* half neutral halves it */
    if ( ls_scale_byte( 200, LS_NEUTRAL * 2 ) != 255 ) return -10;  /* clamps, doesn't wrap */
    if ( ls_scale_byte( 200, 0 ) != 0 ) return -11;                 /* off goes fully dark */

    /* ls_add_dlight: the other thing neither map exercises for real. */
    if ( ls_add_dlight( 0, 0.0f, 0.0f, 0.0f, 200.0f ) != 200 ) return -12;   /* dead centre: full radius */
    if ( ls_add_dlight( 50, 200.0f, 0.0f, 0.0f, 200.0f ) != 50 ) return -13; /* exactly at edge: nothing added */
    if ( ls_add_dlight( 50, 300.0f, 0.0f, 0.0f, 200.0f ) != 50 ) return -14; /* past edge: still nothing, never negative */
    /* the three components combine by distance, not summed separately --
       a 3-4-5 triangle, so this is exact, not an approximation */
    if ( ls_add_dlight( 0, 0.0f, 3.0f, 4.0f, 10.0f ) != 5 ) return -15;
    if ( ls_add_dlight( 200, 0.0f, 0.0f, 0.0f, 200.0f ) != 255 ) return -16; /* clamps, doesn't wrap */

    return 1;
}
