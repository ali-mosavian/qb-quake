#ifndef __H_FRAME_H__
#define __H_FRAME_H__

#include "renderer.h"
#include "fight.h"
#include "world.h"
#include "input.h"
#include "hud.h"
#include "ls.h"
#include "sc.h"
#include "sys_time.h"

/* host_advance's own state: the accumulator and tick counter used to
   turn variable real frame time into a constant-rate simulation.
   Explicit and passed in, not static -- a caller owns this, the same
   way it owns Renderer/Camera/Player. */
typedef struct {
    float accum;
    long  ticks;
    long  bench_ticks;    /* -ticks N; 0 = unbounded */
} HostClock;

void host_advance( World *world, Player *player, Camera *cam, Renderer *rdr,
                    Input *input, Hud far *hud, LightStyles *ls, Fight *fight,
                    SysClock *sysclk,
                    HostClock *clock, PhaseTimes *pt, float real_dt,
                    short scr_x_res, short scr_y_res );

void host_tick( World *world, Player *player, Camera *cam, Renderer *rdr,
                 Input *input, Hud far *hud, LightStyles *ls, Fight *fight,
                 float dt, short scr_x_res, short scr_y_res );

/* z_near/z_far: Config's own (common.bas, not yet ported) -- passed in
   rather than hardcoded here, matching every other per-run setting
   this port threads explicitly instead of reaching for a global. hud
   supplies portal_wire (the outline toggle) and, via scr_draw_hud,
   every stats-panel field. */
void host_render( World *world, Renderer *rdr, Camera *cam, Player *player,
                   SurfCache far *sc, LightStyles *ls,
                   Hud far *hud, Fight *fight, PhaseTimes *pt, SysClock *sysclk,
                   QSurf h_dst_dc, Mat4 *mtx_prj, float xresh, float yresh,
                   float z_near, float z_far,
                   Vec3 *cam_up, QSurf z_dc, short comp, short no_draw,
                   short x_res, short y_res );

#endif
