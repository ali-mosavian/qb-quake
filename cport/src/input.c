/*
 * input.c -- keyboard and mouse. C port of in_main.bas.
 *
 * in_init came from sys_init.bas in the original, the toggles from
 * r_main.bas where they sat beside the camera, and the screenshot key
 * from vid.bas, where it was being polled from inside the present
 * path -- in_main.bas is where all three ended up, and this is that
 * module's own slice of cport/.
 */

#include <stdio.h>
#include <stdlib.h>

#include "tmr.h"    /* tmrInit -- pascal convention; without this
                        prototype in scope bcc assumes cdecl for an
                        undeclared call and TLINK looks for the wrong
                        symbol name entirely (_tmrInit, not TMRINIT) */
#include "input.h"

/* screen.bas, not yet ported. */
#include "screen.h"

/* Fatal on failure, same as v_init_ugl (vid.c) -- sys_error (sys.bas)
   isn't ported yet, and nothing else can run without a mouse anyway. */
void in_init( Input *input, PDC h_video_dc )
{
    if ( !mouseInit( h_video_dc, &input->mouse ) ) {
        fprintf( stderr, "0x0006, Could not init mouse...\n" );
        exit( 1 );
    }

    kbdInit( &input->keyboard );
    tmrInit();
}

/*
 * True once per press, not once per frame: the key is read through a
 * pointer into the live KBD struct the keyboard ISR writes, so waiting
 * for it to clear here is what makes one press read as one toggle.
 */
static short in_keystroke( int *key_down )
{
    if ( !*key_down ) return 0;

    while ( *key_down ) { /* wait for the release */ }

    return 1;
}

void in_handle_toggles( Input *input, Renderer *rdr, Camera *cam, Player *player, Hud far *hud )
{
    KBD *k = &input->keyboard;

    if ( in_keystroke( &k->f1 ) ) rdr->use_mips = !rdr->use_mips;

    /* Perspective / wireframe only -- affine dropped with the fan path
       that was its only renderer (uglPolyTP has no affine equivalent). */
    if ( in_keystroke( &k->f2 ) ) rdr->rend_mode = ( rdr->rend_mode == 0 ) ? 2 : 0;

    if ( in_keystroke( &k->f3  ) ) cam->fps_view    = !cam->fps_view;
    if ( in_keystroke( &k->f12 ) ) hud->stats       = !hud->stats;
    if ( in_keystroke( &k->b   ) ) rdr->backface    = !rdr->backface;
    if ( in_keystroke( &k->l   ) ) rdr->lightmap    = !rdr->lightmap;
    if ( in_keystroke( &k->p   ) ) rdr->portal      = !rdr->portal;
    if ( in_keystroke( &k->o   ) ) hud->portal_wire = !hud->portal_wire;
    if ( in_keystroke( &k->f4  ) ) player->no_clip  = !player->no_clip;
}

/* F5, not S: S walks backwards. */
void in_screenshot_key( Input *input, PDC h_dst_dc, short w, short h )
{
    char name[16];

    if ( input->keyboard.f5 ) {
        sprintf( name, "scrn%d.bmp", input->screenie );
        scr_screenshot( name, h_dst_dc, w, h );
        input->screenie++;
    }
}
