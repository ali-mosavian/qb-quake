/*
 * scr_pal.c -- the damage and bonus flash's palette, in one call.
 *
 * screen.bas's scr_pal_shift blended 768 bytes a frame for as long as a
 * flash faded, each one an asc() and a chr$() string assignment: ~2 ms
 * of every frame the player was being hit. Same arithmetic, same order.
 */

typedef struct { unsigned char r, g, b; } PalRgb;

/* BASIC's CINT for 0..255: nearest, a tie to the even neighbour. */
static unsigned char near pal_cint( float x )
{
    long i;
    float d;

    if ( x <= 0.0f ) return 0;
    if ( x >= 255.0f ) return 255;
    i = (long) x;
    d = x - (float) i;
    if ( d > 0.5f || ( d == 0.5f && ( i & 1 ) ) ) i++;
    return (unsigned char) i;
}

void pascal far scr_pal_blend( PalRgb far *src, PalRgb far *dst, float dmg, float bonus )
{
    float r, g, b, a;
    short i;

    for ( i = 0; i < 256; i++ ) {
        r = (float) src[i].r;
        g = (float) src[i].g;
        b = (float) src[i].b;
        a = dmg / 255.0f;
        r = r + ( 255.0f - r ) * a; g = g - g * a; b = b - b * a;
        a = bonus / 255.0f;
        r = r + ( 215.0f - r ) * a; g = g + ( 186.0f - g ) * a; b = b + ( 69.0f - b ) * a;
        dst[i].r = pal_cint( r );
        dst[i].g = pal_cint( g );
        dst[i].b = pal_cint( b );
    }
}
