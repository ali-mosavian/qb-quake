#ifndef __INPUT_H__
#define __INPUT_H__

#include "qgl.h"     /* QSurf */

#include "renderer.h"
#include "hud.h"

/*
 * Input -- mouse, keyboard, and the screenshot counter that rides
 * along with the F5 key. Caller-owned, one instance for the run: kbdInit
 * registers an interrupt handler that writes into &input->keyboard for
 * as long as the program runs, so this can't be a short-lived local --
 * see in_init.
 */
typedef struct {
    MouseInf mouse;
    Keys   keyboard;
    short screenie;    /* screenshot counter -- scrn0.bmp, scrn1.bmp, ... */
} Input;

/*
 * name: in_init
 * desc: Mouse, keyboard and the one-second timer. h_video_dc is the
 *       video DC mouseInit clips the cursor to -- Video's, not Input's
 *       own, so it's a parameter rather than a field here.
 */
void in_init( Input *input, QSurf h_video_dc );

/*
 * name: in_handle_toggles
 * desc: The render-mode keys. Each waits for its own key to come back
 *       up, so one press is one toggle, not one per frame it's held.
 */
void in_handle_toggles( Input *input, Renderer *rdr, Camera *cam, Player *player, Hud far *hud );

/*
 * name: in_screenshot_key
 * desc: Writes scrnNN.bmp while F5 is held. scr_screenshot is
 *       screen.c's (screen.h) -- w/h are the DC's own size, Config's
 *       x_res/y_res once Config exists.
 */
void in_screenshot_key( Input *input, QSurf h_dst_dc, short w, short h );

#endif
