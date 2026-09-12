/*
 * sbar.c -- see sbar.h. Sbar_DrawNormal, minus the keys and the sigil:
 * the cell band is 512 wide and full.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sbar.h"
#include "qgl.h"
#include "assets.h"
#include "pl_move.h"    /* PL_ARMOR2_TYPE lives with the player's kit */

static QSurf sbar_work, sbar_view;
/* what the composed band already shows: a repaint is a per-pixel loop
   over 21 cells and is skipped while every number is the same */
static short sbar_health = -1, sbar_shells, sbar_face, sbar_armor, sbar_weapon;

void scr_sbar_load( void )
{
    short h, y, i;
    long  bytes;

    sbar_work = qglSfNew( SBARC_EMS_W, SBARC_EMS_H, QGL_SURF_EMS );
    if ( !sbar_work ) { fprintf( stderr, "0x3003, no memory for the status bar\n" ); exit( 1 ); }
    sbar_view = qglSfViewNew( sbar_work, SBARC_W, SBARC_H, SBARC_EMS_W );
    if ( !sbar_view ) { fprintf( stderr, "0x3007, no view for the status bar\n" ); exit( 1 ); }
    if ( !qglSfViewAim( sbar_view, (long) SBARC_WORK_Y * SBARC_EMS_W ) ) {
        fprintf( stderr, "0x3008, the status bar view would not aim\n" );
        exit( 1 );
    }

    /* Read straight into the rows: qglSfWrRow hands out a mapped EMS
       window and the file layer's read takes any far address, so no
       staging buffer is needed. The handle is shared and sequential,
       which is why each member is read through before the next. */
    h = asset_seek( "sbar.raw", &bytes );
    if ( bytes < (long) SBARC_W * SBARC_H ) {
        fprintf( stderr, "0x3004, sbar.raw is %ld bytes, wanted %ld\n",
                 bytes, (long) SBARC_W * SBARC_H );
        exit( 1 );
    }
    for ( y = 0; y < SBARC_H; y++ )
        qglFileRead( h, qglSfWrRow( sbar_work, y ), (long) SBARC_W );

    h = asset_seek( "sbnum.raw", &bytes );
    if ( bytes < (long) SBARC_CELLS * SBARC_CELL * SBARC_CELL ) {
        fprintf( stderr, "0x3006, sbnum.raw is %ld bytes, wanted %ld\n",
                 bytes, (long) SBARC_CELLS * SBARC_CELL * SBARC_CELL );
        exit( 1 );
    }
    for ( i = 0; i < SBARC_CELLS; i++ )
        for ( y = 0; y < SBARC_CELL; y++ )
            qglFileRead( h, qglSfWrRow( sbar_work, (short) ( SBARC_CELL_Y + y ) ) + i * SBARC_CELL,
                          (long) SBARC_CELL );
}

/* A cell's opaque pixels over the working bar at column x. The read row
   and the write row are two mapped windows at once, which is what
   qglSfRdRow and qglSfWrRow are for -- one call each way per row. */
static void scr_sbar_cell( short idx, short x )
{
    unsigned char far *src, far *dst;
    short y, k;

    for ( y = 0; y < SBARC_CELL; y++ ) {
        src = (unsigned char far *) qglSfRdRow( sbar_work, (short) ( SBARC_CELL_Y + y ) ) + idx * SBARC_CELL;
        dst = (unsigned char far *) qglSfWrRow( sbar_work, (short) ( SBARC_WORK_Y + y ) ) + x;
        for ( k = 0; k < SBARC_CELL; k++ )
            if ( src[k] != 255 ) dst[k] = src[k];
    }
}

/* Sbar_DrawNum: three digits, right aligned, from column x. */
static void scr_sbar_num( short x, short v )
{
    char t[8];
    short n, i;

    sprintf( t, "%d", (int) v );
    n = (short) strlen( t );
    if ( n > 3 ) n = 3;
    x = (short) ( x + ( 3 - n ) * SBARC_CELL );
    for ( i = 0; i < n; i++ )
        scr_sbar_cell( (short) ( t[i] - '0' ), (short) ( x + i * SBARC_CELL ) );
}

/*
 * Sbar_DrawNormal: the armor icon at 0 and its count at 24 while any is
 * worn -- Quake draws a 0 there too, which would move every reference
 * -- the face at 112, health at 136, the ammo icon at 224 and its count
 * at 248.
 */
static void scr_sbar_paint( Fight *fight )
{
    short hp, sh, f, ar, icon, y;

    hp = fight->health;
    if ( hp < 0 ) hp = 0;
    /* currentammo: what the weapon in hand fires */
    sh = fight->shells; icon = SBARC_ICON;
    if ( fight->weapon == PL_IT_NAILGUN || fight->weapon == PL_IT_SNG ) {
        sh = fight->nails; icon = SBARC_NAILS;
    }
    if ( fight->weapon == PL_IT_GL || fight->weapon == PL_IT_RL ) {
        sh = fight->rockets; icon = SBARC_ROCKETS;
    }
    ar = fight->armor;
    f = (short) ( hp / 20 );
    if ( f > 4 ) f = 4;

    if ( hp == sbar_health && sh == sbar_shells && f == sbar_face &&
         ar == sbar_armor && fight->weapon == sbar_weapon ) return;
    sbar_health = hp; sbar_shells = sh; sbar_face = f;
    sbar_armor = ar; sbar_weapon = fight->weapon;

    for ( y = 0; y < SBARC_H; y++ )
        qglMemCopy( qglSfWrRow( sbar_work, (short) ( SBARC_WORK_Y + y ) ),
                     qglSfRdRow( sbar_work, y ), (long) SBARC_W );

    if ( ar > 0 ) {
        scr_sbar_cell( (short) ( SBARC_ARMOR + ( fight->armor_type >= PL_ARMOR2_TYPE ) ), 0 );
        scr_sbar_num( 24, ar );
    }
    scr_sbar_cell( (short) ( SBARC_FACE + ( 4 - f ) ), 112 );
    scr_sbar_num( 136, hp );
    scr_sbar_cell( icon, 224 );
    scr_sbar_num( 248, sh );
}

void scr_sbar_draw( Fight *fight, QSurf dst, short w, short h )
{
    short bh;

    scr_sbar_paint( fight );
    bh = (short) ( (long) SBARC_H * w / SBARC_W );
    qglDrBlitScl( dst, 0, (short) ( h - bh ), w, bh, sbar_view );
}
