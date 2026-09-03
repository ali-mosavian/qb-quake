#ifndef __VIEW_H__
#define __VIEW_H__

#include "renderer.h"
#include "world.h"
#include "input.h"

/*
 * view.h -- where the camera is and where it looks. C port of
 * view.bas's freelook half only: v_update_camera's scripted-bezier
 * playback (cam_mode 1, recording mode 2) reads Config fields
 * (cam_mode/cam_path/cam_interp/cam_script) that don't exist yet --
 * common.bas isn't ported -- and are a separate feature (an offline
 * .cam file format, bezier interpolation) from what draws a frame.
 * Deliberately not ported; freelook (the default mode) is.
 *
 * x_res/y_res are Config's own scr_x_res/scr_y_res, threaded as
 * parameters for the same reason.
 */

/*
 * name: v_update_camera
 * desc: Advances the camera for one frame: mouse position becomes a
 *       look direction, WASD/mouse-buttons become fwd/strafe, and
 *       pl_move (or, noclip, a straight fly) turns those into a new
 *       player and camera position.
 */
void v_update_camera( Camera *cam, Player *player, World *world, Input *input,
                       float dt, short x_res, short y_res );

#endif
