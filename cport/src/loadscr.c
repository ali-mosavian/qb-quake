/*
 * loadscr.c -- see loadscr.h. C port of screen.bas's scr_load_* family,
 * minus the decorative chrome (see the header for what and why).
 */

#include <stdio.h>
#include <string.h>
#include <mem.h>     /* _fmemset */

#include "loadscr.h"
#include "screen.h"   /* draw_string */
#include "qgl.h"
#include "pal.h"

/* screen.bas's own names, same offsets into the ramps above. */
#define C_PANEL    (LP_STN0 + 6)    /* the sunken well the bar sits in */
#define C_EDGE     (LP_STN0 + 2)
#define C_EDGEHI   (LP_STN0 + 26)
#define C_TROUGH   (LP_STN0 + 1)
#define C_BACK     (LP_STN0 + 3)
#define C_PLATE    (LP_BRZ0 + 9)
#define C_PLATEHI  (LP_BRZ0 + 22)
#define C_PLATELO  (LP_BRZ0 + 2)
#define C_ACCHI    (LP_ACC0 + 29)
#define C_TEXT     (LP_NEU0 + 13)
#define C_TEXTDIM  (LP_NEU0 + 7)

/* Panel geometry, screen.bas's constants. 320x200 numbers: the caller
   passes the real mode size and this centres against it, so a mode
   other than 13h still lands sensibly. */
#define PAN_W      196
#define PAN_H      48
#define BAR_INSET  10
#define BAR_H      12

static short pan_x, pan_y;   /* set by ld_begin, read by the drawing below */

/*
 * name: ld_palette
 * desc: Four warm ramps into the low half of the palette. Ported from
 *       scr_load_palette: stone goes much darker than feels right on a
 *       monitor because Quake's own menu is nearly black except where a
 *       light falls, and red leads green leads blue at every step,
 *       which is what keeps it grimy brown instead of a cold grey.
 */
static void ld_palette( void )
{
    PalRgb far *pal;
    short i;
    float f;

    pal = (PalRgb far *) qglMemAlloc( 256L * (long) sizeof(PalRgb) );

    if ( !pal ) return;   /* no palette is survivable; a failed load is not */
    _fmemset( pal, 0, 256 * sizeof(PalRgb) );

    for ( i = 0; i < LP_STNN; i++ ) {
        f = (float) i / (float)( LP_STNN - 1 );
        pal[LP_STN0+i].red   = (char)(  6 + f *  62 );
        pal[LP_STN0+i].green = (char)(  5 + f *  46 );
        pal[LP_STN0+i].blue  = (char)(  4 + f *  34 );
    }
    for ( i = 0; i < LP_BRZN; i++ ) {
        f = (float) i / (float)( LP_BRZN - 1 );
        pal[LP_BRZ0+i].red   = (char)( 34 + f * 148 );
        pal[LP_BRZ0+i].green = (char)( 23 + f * 104 );
        pal[LP_BRZ0+i].blue  = (char)( 12 + f *  50 );
    }
    for ( i = 0; i < LP_ACCN; i++ ) {
        f = (float) i / (float)( LP_ACCN - 1 );
        pal[LP_ACC0+i].red   = (char)( 62 + f * 193 );
        pal[LP_ACC0+i].green = (char)( 20 + f * 188 );
        pal[LP_ACC0+i].blue  = (char)(  6 + f * 118 );
    }
    for ( i = 0; i < LP_NEUN; i++ ) {
        f = (float) i / (float)( LP_NEUN - 1 );
        pal[LP_NEU0+i].red   = (char)( 30 + f * 132 );
        pal[LP_NEU0+i].green = (char)( 28 + f * 124 );
        pal[LP_NEU0+i].blue  = (char)( 26 + f * 112 );
    }

    pal_install( (PalRgb far *) pal );
    qglMemFree( (long) pal );
}

/* A pressed-metal edge: light on top and left, dark on bottom and
   right, and the pair swapped when something is meant to look sunken.
   That one trick is most of what makes the original read as Quake. */
static void ld_bevel( QSurf dc, short x, short y, short w, short h,
                       long hi, long lo )
{
    qglDrHline( dc, x, y, x + w, hi );
    qglDrVline( dc, x, y, y + h, hi );
    qglDrHline( dc, x, y + h, x + w, lo );
    qglDrVline( dc, x + w, y, y + h, lo );
}

/*
 * name: ld_bar
 * desc: Sunken trough, then an amber fill shaded across its height --
 *       brightest just under the top edge, falling away below, one
 *       HLine per row. The trough is repainted every tick rather than
 *       once: the fill only grows here, but redrawing costs nothing at
 *       load time and a stale tail is worse than the redraw.
 */
static void ld_bar( QSurf dc, short x, short y, short w, short h, float pct )
{
    short fill, i, k;

    if ( pct < 0.0f )   pct = 0.0f;
    if ( pct > 100.0f ) pct = 100.0f;
    fill = (short)( ( (long) w * (long) pct ) / 100L );

    qglDrFill( dc, x, y, x + w, y + h, C_TROUGH );
    ld_bevel( dc, x, y, w, h, C_EDGE, C_EDGEHI );

    if ( fill < 1 ) return;

    for ( i = 1; i < h; i++ ) {
        k = (short)( LP_ACC0 + LP_ACCN - 1 - ( ( i * ( LP_ACCN - 4 ) ) / h ) );
        qglDrHline( dc, x + 1, y + i, x + fill, k );
    }
    qglDrHline( dc, x + 1, y + 1, x + fill, C_ACCHI );
}

static void ld_redraw( LoadScreen *ld, QSurf dc, Hud far *hud )
{
    char pct[8];

    ld_bar( dc, (short)( pan_x + BAR_INSET ), (short)( pan_y + 20 ),
             (short)( PAN_W - 2 * BAR_INSET ), BAR_H, ld->pct );

    sprintf( pct, "%d%%", (int) ld->pct );
    qglDrFill( dc, (short)( pan_x + PAN_W - 34 ), (short)( pan_y + 7 ),
                  (short)( pan_x + PAN_W - 8 ),  (short)( pan_y + 14 ), C_PANEL );
    draw_string_r( hud, dc, (short)( pan_x + PAN_W - 10 ),
                    (short)( pan_y + 8 ), pct, C_TEXT );
}

void ld_begin( LoadScreen *ld, QSurf dc, Hud far *hud, short steps,
                short w, short h )
{
    ld->pct   = 0.0f;
    ld->steps = ( steps > 0 ) ? steps : 1;
    ld->done  = 0;

    pan_x = (short)( ( w - PAN_W ) / 2 );
    pan_y = (short)( ( h - PAN_H ) / 2 + 24 );   /* low, as the original has it */

    ld_palette();

    qglDrFill( dc, 0, 0, (short)( w - 1 ), (short)( h - 1 ), C_BACK );

    /* the raised plate, then the sunken well inside it */
    qglDrFill( dc, pan_x, pan_y, (short)( pan_x + PAN_W ), (short)( pan_y + PAN_H ),
              C_PLATE );
    ld_bevel( dc, pan_x, pan_y, PAN_W, PAN_H, C_PLATEHI, C_PLATELO );
    qglDrFill( dc, (short)( pan_x + 6 ), (short)( pan_y + 5 ),
                  (short)( pan_x + PAN_W - 6 ), (short)( pan_y + PAN_H - 6 ),
              C_PANEL );
    ld_bevel( dc, (short)( pan_x + 6 ), (short)( pan_y + 5 ),
               (short)( PAN_W - 12 ), (short)( PAN_H - 11 ), C_EDGE, C_EDGEHI );

    ld_stage( ld, dc, hud, "starting up" );
}

void ld_stage( LoadScreen *ld, QSurf dc, Hud far *hud, char *what )
{
    qglDrFill( dc, (short)( pan_x + 9 ), (short)( pan_y + 7 ),
                  (short)( pan_x + PAN_W - 36 ), (short)( pan_y + 14 ), C_PANEL );
    draw_string( hud, dc, (short)( pan_x + 10 ), (short)( pan_y + 8 ),
                  what, C_TEXTDIM );
    ld_redraw( ld, dc, hud );
}

void ld_step( LoadScreen *ld, QSurf dc, Hud far *hud )
{
    ld->done++;
    ld->pct = ( 100.0f * (float) ld->done ) / (float) ld->steps;
    ld_redraw( ld, dc, hud );
}
