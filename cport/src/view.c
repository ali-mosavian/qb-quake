/*
 * view.c -- see view.h. C port of view.bas's freelook path.
 */

#include <math.h>
#include "qgl.h"

#include "view.h"
#include "pl_move.h"   /* PL_NOCLIP/PL_EYE */

#define PI 3.14159f

void v_update_camera( Camera *cam, Player *player, World *world, Input *input,
                       Fight *fight,
                       float dt, short x_res, short y_res )
{
    int   tmx, tmy;
    float theta, phi;
    float fwd, strafe;
    float dir_x, dir_y, dir_l;
    short jump;

    /* Screen coordinates throughout: the mouse spans the MODE, not
       the view, so a smaller view must not shrink the look range. */
    if ( input->mouse.x < 1 )          qglMousePos( x_res - 4, input->mouse.y );
    if ( input->mouse.x > x_res - 3 )  qglMousePos( 1, input->mouse.y );
    if ( input->mouse.y < 0 )          qglMousePos( input->mouse.x, 0 );
    if ( input->mouse.y > y_res )      qglMousePos( input->mouse.x, y_res - 1 );

    tmx = input->mouse.x + 1;
    tmy = input->mouse.y + 2;

    theta = 2.0f * PI * (float)( (x_res - 1) - tmx ) / (float) x_res;
    phi   = PI * (float) tmy / (float) y_res;

    cam->look_at.x = (float)( cos( theta ) * sin( phi ) );
    cam->look_at.y = (float) cos( phi );
    cam->look_at.z = (float)( sin( theta ) * sin( phi ) );

    /* Forward and back on the mouse buttons, as well as WASD -- both
       have always driven this program's movement. Pressing both of
       an opposing pair cancels, which falls out of the sum, and
       holding W with the left button does not double the speed
       because pl_move clamps to PL_MAXSPEED. */
    fwd    = 0.0f;
    strafe = 0.0f;
    if ( input->keyboard.k[KEY_W] )     fwd    += 1.0f;
    if ( input->keyboard.k[KEY_S] )     fwd    -= 1.0f;
    if ( input->keyboard.k[KEY_A] )     strafe += 1.0f;
    if ( input->keyboard.k[KEY_D] )     strafe -= 1.0f;
    if ( input->mouse.left )     fwd    += 1.0f;
    if ( input->mouse.right )    fwd    -= 1.0f;

    if ( player->no_clip ) {
        /* the intermission holds still: the tally's camera is the
           map's, not one the player can fly out of */
        if ( fight->state == GS_EXIT ) fwd = 0.0f;

        /* Per second, not per frame -- this used to advance a flat 3
           units every frame, flying at whatever speed the framerate
           happened to give it. */
        cam->pos.x += cam->look_at.x * PL_NOCLIP * fwd * dt;
        cam->pos.y += cam->look_at.y * PL_NOCLIP * fwd * dt;
        cam->pos.z += cam->look_at.z * PL_NOCLIP * fwd * dt;

        /* Keep the player in step with the free camera, so switching
           back to walking carries on from here rather than snapping
           to wherever physics was last left. */
        player->pos.x = cam->pos.x;
        player->pos.y = cam->pos.z;
        player->pos.z = cam->pos.y - PL_EYE;
        player->vel.x = 0.0f;
        player->vel.y = 0.0f;
        player->vel.z = 0.0f;
    } else {
        /* cam->look_at is still a direction here; it becomes an
           absolute point only at the bottom of this function. Only
           its horizontal part steers walking, renormalised so that
           looking at the floor does not slow the player down. */
        dir_x = cam->look_at.x;
        dir_y = cam->look_at.z;   /* renderer z is bsp y */
        dir_l = (float) sqrt( dir_x*dir_x + dir_y*dir_y );
        if ( dir_l > 0.001f ) {
            dir_x /= dir_l;
            dir_y /= dir_l;
        } else {
            dir_x = 1.0f;
            dir_y = 0.0f;
        }

        jump = 0;
        if ( input->keyboard.k[KEY_SPCBAR] ) jump = -1;

        pl_move( world, player, cam, fwd, strafe, dir_x, dir_y, jump, dt );
    }

    cam->look_at.x += cam->pos.x;
    cam->look_at.y += cam->pos.y;
    cam->look_at.z += cam->pos.z;
}
