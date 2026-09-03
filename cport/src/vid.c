/*
 * vid.c -- video mode, back buffer and page flip.
 *
 * C port of the old vid.bas, for the standalone (no-BASIC-runtime)
 * renderer. Earlier drafts of this file lived in src/vid.c, glued into
 * the still-BASIC-linked build via measured offsets into a live Game
 * struct -- abandoned once the project moved to a full rewrite with
 * its own build, since there's no Game to reach into any more and no
 * BASIC caller to hand a status code back to.
 */

#include "video.h"
#include "uglpatch.h"
#include "dos.h"
#include <stdio.h>
#include <stdlib.h>

/* ugl.bi: UGL.MEM% = 0*DCTSIZE, UGL.EMS% = 2*DCTSIZE, DCTSIZE% = 64. */
#define UGL_DC_MEM 0
#define UGL_DC_EMS 128

/*
 * name: v_init_ugl
 * desc: Brings uGL up. Fatal on failure -- nothing else can run
 *       without it, so there is no useful status to hand back.
 */
void v_init_ugl( void )
{
    if ( uglInit() == 0 ) {
        fprintf( stderr, "0x0000, Could not init UGL...\n" );
        exit( 1 );
    }
}

/*
 * name: v_init
 * desc: Opens the video mode, allocates the backbuffer (and -comp's
 *       composite buffer) and paints the border once. v owns the
 *       result: h_video_dc/h_comp_dc/h_back_bdc are written back into
 *       it, matching the caller's own expectation of what "init"
 *       leaves behind. Fatal on failure, same reasoning as
 *       v_init_ugl -- nothing downstream can run without a mode.
 */
void v_init( Video *v, long pal )
{
    short pages = v->use_paging ? v->pages : 1;

    v->h_video_dc = uglSetVideoDC( v->c_fmt, v->scr_x_res, v->scr_y_res, pages );
    if ( v->h_video_dc == 0 ) {
        fprintf( stderr, "0x0001, Could not set video mode...\n" );
        exit( 1 );
    }

    if ( !v->use_paging ) {
        v->h_back_bdc = uglNew( UGL_DC_MEM, v->c_fmt, v->x_res, v->y_res );
        if ( v->h_back_bdc == 0 ) {
            fprintf( stderr, "0x0002, Could not create a backbuffer...\n" );
            exit( 1 );
        }

        if ( v->comp ) {
            /* MEM not EMS: v_present's uglPutScl holds this as its
               destination window for the whole scaled blit, every
               frame -- an EMS window competes with the surface
               cache/texture atlas for the same small page-frame pool,
               and losing that race mid-blit is what corrupted state
               under live mouse-driven movement (never seen on an
               untouched view, which barely touches the pool). */
            v->h_comp_dc = uglNew( UGL_DC_MEM, v->c_fmt, v->scr_x_res, v->scr_y_res );
            if ( v->h_comp_dc == 0 ) {
                fprintf( stderr, "0x0003, Could not create the composite buffer...\n" );
                exit( 1 );
            }
        }
    }

    uglRectF( v->h_video_dc, 0, 0, v->scr_x_res - 1, v->scr_y_res - 1, 0L );

    /* uglPalSet/memFree both declare their far-pointer-shaped parameter
       with a real pointer type (RGB far *, void far *) -- pal here is
       already an encoded far pointer, carried as a plain long the same
       way every DC handle is, so both just need the matching cast. */
    uglPalSet( 0, 256, (RGB far *) pal );
    memFree( (void far *) pal );
}

/*
 * name: v_present
 * desc: Page flip or backbuffer blit, once per frame at the end of it.
 *       Returns the next work page; v itself never changes.
 */
short v_present( Video *v, PDC h_dst_dc, short page )
{
    if ( !v->use_paging ) {
        PDC target = v->comp ? v->h_comp_dc : v->h_video_dc;
        uglPutScl( target, v->view_x, v->view_y,
                   (float) v->view_scale, (float) v->view_scale, v->h_back_bdc );
        return page;
    }

    uglSetVisPage( page );
    page = (short) ( (page + 1) % v->pages );
    uglSetWrkPage( page );
    return page;
}
