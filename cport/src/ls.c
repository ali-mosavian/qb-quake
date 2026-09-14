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
    e->value   = v;
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

long ls_face_key( LightStyles *ls, short s01, short s23 )
{
    long key = 0, place = 1;
    short k, v, n = ls_face_styles( s01, s23 );

    for ( k = 0; k < n; k++ ) {
        v = ls_value( ls, ls_face_style( s01, s23, k ) );
        key += place * LS_KEY_DIGIT( v );
        place *= 27;
    }
    return key;
}

void ls_animate( LightStyles *ls, float anim_time )
{
    short i, steps, nf;

    steps = (short) ( (long) (anim_time * LS_RATE) - (long) (ls->last * LS_RATE) );
    if ( steps <= 0 ) return;
    ls->last = anim_time;

    for ( i = 0; i <= LS_MAXSTYLE; i++ ) {
        if ( ls->tab[i].length > 1 ) {
            nf = (short) ( (ls->tab[i].frame + steps) % ls->tab[i].length );
            ls->tab[i].frame = nf;
            ls->tab[i].value = ls_lchar( ls->tab[i].pattern[nf] );
        }
    }
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
 *       2-char pattern must step once per 10 Hz tick, a steady style
 *       must never move, steps must accumulate across an uneven call
 *       pattern, and the face key must tell every value of every style
 *       apart.
 */
short ls_selftest( void )
{
    LightStyles ls;
    long k0;

    ls_init( &ls );

    /* style 0 is steady: many ticks, no change */
    ls_animate( &ls, 0.05f );
    ls_animate( &ls, 1.05f );
    ls_animate( &ls, 2.05f );
    if ( ls.tab[0].value != LS_NEUTRAL ) return -1;

    /* a synthetic 2-char pattern, 'a' then 'z': one step flips it */
    ls.tab[30].pattern = "az";
    ls.tab[30].length = 2;
    ls.tab[30].frame  = 0;
    ls.tab[30].value  = ls_lchar( 'a' );
    ls.last = 0.0f;

    ls_animate( &ls, 0.1f );   /* one 10 Hz step: frame 0 -> 1, 'a' -> 'z' */
    if ( ls.tab[30].value != ls_lchar( 'z' ) ) return -2;
    if ( ls.tab[30].frame != 1 ) return -3;

    ls_animate( &ls, 0.15f );  /* under 0.1s more: no new step */
    if ( ls.tab[30].frame != 1 ) return -4;

    ls_animate( &ls, 0.2f );   /* the step lands: frame 1 -> 0, 'z' -> 'a' */
    if ( ls.tab[30].value != ls_lchar( 'a' ) ) return -5;
    if ( ls.tab[30].frame != 0 ) return -6;

    /* two ticks that together cross a step boundary must land the same
       as one tick that crosses it directly -- steps come from elapsed
       TIME, not call count */
    ls.last = 0.0f;
    ls.tab[30].frame = 0; ls.tab[30].value = ls_lchar( 'a' );
    ls_animate( &ls, 0.04f );
    ls_animate( &ls, 0.11f );  /* crosses 0.1 here, one step total */
    if ( ls.tab[30].frame != 1 ) return -7;

    /* the key: four styles, 0 10 20 21, where 20 and 21 are unset. Only
       the fourth moving must still move it -- that digit is 26 * 27^3,
       past a short -- and 'm' against 'n' must differ in any place */
    ls_init( &ls );
    k0 = ls_face_key( &ls, 0 | ( 10 << 8 ), 20 | ( 21 << 8 ) );
    if ( k0 != 12L + 27L * 12L + 729L * 26L + 19683L * 26L ) return -16;
    ls_switch( &ls, 21, 0 );
    if ( ls_face_key( &ls, 0 | ( 10 << 8 ), 20 | ( 21 << 8 ) ) == k0 ) return -17;
    ls.tab[10].value = ls_lchar( 'n' );
    if ( ls_face_key( &ls, 0 | ( 10 << 8 ), 255 | ( 255 << 8 ) ) != 12L + 27L * 13L ) return -18;

    /* the inline key agrees with the call on every one-style face,
       the no-style one, and style 10 at 'a', 'm' and unset */
    {
        short st, s01, s23 = -1, pass;
        for ( pass = 0; pass < 3; pass++ ) {
            ls.tab[10].value = pass == 0 ? ls_lchar( 'a' ) : pass == 1 ? ls_lchar( 'm' ) : LS_UNSET;
            for ( st = 0; st <= 255; st++ ) {
                s01 = (short) ( st | 0xFF00 );
                if ( LS_FACE_KEY( &ls, s01, s23 ) != ls_face_key( &ls, s01, s23 ) ) return -19;
            }
        }
        s01 = 0 | ( 10 << 8 );
        if ( LS_FACE_KEY( &ls, s01, s23 ) != ls_face_key( &ls, s01, s23 ) ) return -20;
    }

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
