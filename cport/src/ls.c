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

/* world.qc's worldspawn; 32..62 are the switchable lights', "m" until
   a light turns one off. */
#define LS_WORLD 12
static const char *ls_world[LS_WORLD] = {
    "m",
    "mmnmmommommnonmmonqnmmo",
    "abcdefghijklmnopqrstuvwxyzyxwvutsrqponmlkjihgfedcba",
    "mmmmmaaaaammmmmaaaaaabcdefgabcdefg",
    "mamamamamama",
    "jklmnopqrstuvwxyzyxwvutsrqponmlkj",
    "nmonqnmomnmomomno",
    "mmmaaaabcdefgmmmmaaaammmaamm",
    "mmmaaammmaaammmabcdefaaaammmmabcdefmmmaaaa",
    "aaaaaaaazzzzzzzz",
    "mmamammmmammamamaaamammma",
    "abcdefghijklmnopqrrqponmlkjihgfedcba"
};

void ls_init( LightStyles *ls )
{
    short i;

    for ( i = 0; i <= LS_MAXSTYLE; i++ ) {
        ls->tab[i].pattern = i < LS_WORLD ? ls_world[i] : "m";
        ls->tab[i].length = (short) strlen( ls->tab[i].pattern );
        ls->tab[i].frame  = 0;
        ls->tab[i].value  = i < LS_WORLD ? ls_lchar( ls->tab[i].pattern[0] ) : LS_UNSET;
        ls->tab[i].epoch  = 0;
    }
    ls->tab[63].pattern = "a";
    ls->tab[63].value   = ls_lchar( 'a' );

    ls->last = 0.0f;
}

void ls_switch( LightStyles *ls, short style, short on )
{
    LightStyleEntry *e;
    short v = ls_lchar( (char) ( on ? 'm' : 'a' ) );

    if ( style < 0 || style > LS_MAXSTYLE ) return;
    e = &ls->tab[style];
    e->pattern = on ? "m" : "a";
    e->length  = 1;
    e->frame   = 0;
    if ( e->value == v ) return;
    e->value = v;
    e->epoch++;
    if ( e->epoch > 32000 ) e->epoch = 1;
}

void ls_hold( LightStyles *ls )
{
    short i;

    for ( i = 0; i <= LS_MAXSTYLE; i++ ) ls_switch( ls, i, 1 );
}

short ls_face_style( short s01, short s23, short k )
{
    unsigned short w = (unsigned short) ( k < 2 ? s01 : s23 );
    return (short) ( ( ( k & 1 ) ? w >> 8 : w ) & 255 );
}

short ls_face_styles( short s01, short s23 )
{
    short n = 0;
    while ( n < 4 && ls_face_style( s01, s23, n ) != 255 ) n++;
    return n;
}

short ls_face_epoch( LightStyles *ls, short s01, short s23 )
{
    long e = 0;
    short k, n = ls_face_styles( s01, s23 );

    for ( k = 0; k < n; k++ ) e += ls_epoch( ls, ls_face_style( s01, s23, k ) );
    return (short) ( e % 32000L );
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

/*
 * name: ls_selftest
 * desc: Proves the animation loop, not any real map: a synthetic
 *       2-char pattern must toggle value and bump epoch exactly once
 *       per change, a steady style must never bump, and steps must
 *       accumulate correctly across an uneven call pattern (two short
 *       ticks the same as one that covers both) -- neither map on
 *       hand has a non-neutral style, so this is what actually
 *       exercises ls_scale_byte too.
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
    ls.tab[30].pattern = "az";
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
    ls.tab[31].pattern = "az";
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

    /* a style nothing sets is id's 256, not 'm'; world.qc's start where
       their patterns do; and the hold puts every one at 'm' */
    ls_init( &ls );
    if ( ls.tab[20].value != LS_UNSET ) return -12;
    if ( ls.tab[2].value != ls_lchar( 'a' ) ) return -13;
    ls_hold( &ls );
    if ( ls.tab[2].value != LS_NEUTRAL || ls.tab[20].value != LS_NEUTRAL ) return -14;
    ls_animate( &ls, 5.0f );
    if ( ls.tab[2].value != LS_NEUTRAL ) return -15;

    return 1;
}
