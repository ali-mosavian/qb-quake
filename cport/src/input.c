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
#include "qgl.h"
#include <stdlib.h>

#include "input.h"

/* screen.bas, not yet ported. */
#include "screen.h"

/* Fatal on failure, same as v_init_ugl (vid.c) -- sys_error (sys.bas)
   isn't ported yet, and nothing else can run without a mouse anyway. */
void in_init( Input *input, QSurf h_video_dc )
{
    /* qgl clips the cursor to a rectangle rather than to a surface, so
       the mode's own size is read off the video surface and handed over
       -- qglSfSize answers the size, where mgl's uglDcSize answered one
       less and every caller added it back. */
    if ( !qglMouseInit( &input->mouse,
                        (short) ( qglSfSize( h_video_dc, 0 ) - 1 ),
                        (short) ( qglSfSize( h_video_dc, 1 ) - 1 ) ) ) {
        fprintf( stderr, "0x0006, Could not init mouse...\n" );
        exit( 1 );
    }

    qglKbdInit( &input->keyboard );
    qglTmrInit( 1000 );   /* 1 ms; sys_time_init measures what arrives */
}

/*
 * True once per press, not once per frame: the key is read through a
 * pointer into the live Keys struct the keyboard ISR writes, so waiting
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
    Keys *k = &input->keyboard;

    if ( in_keystroke( &k->k[KEY_F1] ) ) rdr->use_mips = !rdr->use_mips;

    /* Perspective / wireframe only -- affine dropped with the fan path
       that was its only renderer (uglPolyTP has no affine equivalent). */
    if ( in_keystroke( &k->k[KEY_F2] ) ) rdr->rend_mode = ( rdr->rend_mode == 0 ) ? 2 : 0;

    if ( in_keystroke( &k->k[KEY_F3] ) ) cam->fps_view    = !cam->fps_view;
    if ( in_keystroke( &k->k[KEY_F12] ) ) hud->stats       = !hud->stats;
    if ( in_keystroke( &k->k[KEY_B] ) ) rdr->backface    = !rdr->backface;
    if ( in_keystroke( &k->k[KEY_L] ) ) rdr->lightmap    = !rdr->lightmap;
    if ( in_keystroke( &k->k[KEY_P] ) ) rdr->portal      = !rdr->portal;
    if ( in_keystroke( &k->k[KEY_O] ) ) hud->portal_wire = !hud->portal_wire;
    if ( in_keystroke( &k->k[KEY_F4] ) ) player->no_clip  = !player->no_clip;
}

/* F5, not S: S walks backwards. */
void in_screenshot_key( Input *input, QSurf h_dst_dc, short w, short h )
{
    char name[16];

    if ( input->keyboard.k[KEY_F5] ) {
        sprintf( name, "scrn%d.bmp", input->screenie );
        scr_screenshot( name, h_dst_dc, w, h );
        input->screenie++;
    }
}
