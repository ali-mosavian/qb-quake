/*
 * h_frame.c -- one frame's simulation step and one frame's drawing.
 *
 * C port of the old h_frame.bas. host_advance's own accumulator logic
 * is real and self-contained; host_tick and host_render call out to
 * ent/camera/input/BSP-walk/HUD subsystems that are declared here
 * (matching the signatures they'll have once ported) but not yet
 * implemented anywhere -- this compiles today; it links once enough of
 * World's owners (r_bsp.bas, model.bas, ent.bas, pl_move.bas,
 * in_main.bas, screen.bas) exist in cport/ too.
 *
 * That's a deliberate order: writing the caller before the callees
 * exist is normal top-down design, and it fixes the target signatures
 * (World* instead of a dozen separate BASIC arrays) before any of
 * those modules get written against something that has to change
 * later.
 */

#include "qrcfg.h"
#include "h_frame.h"
#include "mdl_ai.h"
#include "weapons.h"
#include "d_poly.h"
#include "d_faces.h"
#include "ent.h"
#include "ent_move.h"
#include "item.h"
#include "d_alias.h"
#include "input.h"
#include "r_bsp.h"
#include "mod_tex.h"
#include "qgl.h"
#include "view.h"
#include "screen.h"
#include "sbar.h"
#include "gstate.h"
#include "mdl.h"
#include "snd.h"

/* q_scr.bi's HOST_DT#/HOST_MAXSTEPS. */
#define HOST_DT       0.0166666f
#define HOST_MAXSTEPS 5

/* q_draw.bi's DL_RADIUS#: Quake's own rocket dlight radius. */
#define DL_RADIUS 200.0f

#define QGL_Z_OFF 0

/*
 * name: host_advance
 * desc: Spends a frame's worth of real time on whole simulation steps.
 *
 *       The renderer's frame time varies with what is on screen.
 *       Feeding it straight to the physics made every result depend on
 *       the framerate: the same walk integrated in a few long steps at
 *       12 fps and many short ones at 45, and the two drifted apart
 *       because a long step overshoots a wall a short one stops
 *       against.
 *
 *       Every step is HOST_DT regardless, and the remainder carries.
 *       Physics sees a constant rate; only how many steps a frame runs
 *       varies.
 */
void host_advance( World *world, Player *player, Camera *cam, Renderer *rdr,
                    Input *input, Hud far *hud, LightStyles *ls, Fight *fight,
                    SysClock *sysclk,
                    HostClock *clock, PhaseTimes *pt, float real_dt,
                    short scr_x_res, short scr_y_res )
{
    short steps = 0;
#if QR_PROF
    float t0 = sys_now( sysclk );
#endif

    clock->accum += real_dt;

    while ( clock->accum >= HOST_DT && steps < HOST_MAXSTEPS ) {
        /* Stop ON the tick budget, not past it -- -ticks is tested
           once a frame, after this whole loop, so a slow frame that
           runs two or three steps would end the run at 902 rather
           than 900, with the camera wherever those extra steps
           carried it. Two runs of one binary then differ by most of a
           room, which reads exactly like a rendering bug and is not
           one. */
        if ( clock->bench_ticks > 0 && clock->ticks >= clock->bench_ticks ) {
            break;
        }
        host_tick( world, player, cam, rdr, input, hud, ls, fight, HOST_DT, scr_x_res, scr_y_res );
        clock->accum -= HOST_DT;
        clock->ticks++;
        steps++;
    }

    /* Still behind after the cap: give up on the backlog rather than
       carry it into the next frame, where it would only grow. */
    if ( clock->accum > HOST_DT ) clock->accum = 0.0f;

#if QR_PROF
    if ( pt->n > 0 ) {
        float dt = sys_now( sysclk ) - t0;
        pt->tick_sum += dt;
        if ( dt > pt->tick_max ) pt->tick_max = dt;
    }
#endif
}

/*
 * name: host_tick
 * desc: One simulation step. Everything that changes the world in
 *       response to time or input happens here, and nothing here
 *       draws.
 *
 *       dt is a parameter rather than a global read so the step is
 *       explicit at the call site: this is the one number that
 *       decides how far the world moves, and a caller can pass a
 *       different one -- a fixed step, a halved step for a sub-tick --
 *       without the routine knowing or caring.
 */
void host_tick( World *world, Player *player, Camera *cam, Renderer *rdr,
                 Input *input, Hud far *hud, LightStyles *ls, Fight *fight,
                 float dt, short scr_x_res, short scr_y_res )
{
    /* fire is mouse 1 or ctrl, as it has always been; mouse 1 also
       walks forward, which is the original's binding too. Read once:
       outside GS_PLAY it is what starts the next thing rather than
       what shoots. */
    short fire = (short) ( input->mouse.left || input->keyboard.k[KEY_CTRL] );

    /* what the player asked for */
    in_handle_toggles( input, rdr, cam, player, hud );

    /* and what the world does about it: camera, and the physics under it */
    v_update_camera( cam, player, world, input, fight, rdr, dt, scr_x_res, scr_y_res );

    /* and anything the world does to the player as a result of moving */
    ent_check_teleport( player, world, scr_x_res );

    /* movers, after the player has moved and before anything is drawn.
       Doors before triggers, because a button's target is a door and a
       door fired this tick should start moving on it. */
    ent_move_plats( world, player, dt );
    ent_move_doors( world, player, fight, rdr, dt );
    ent_move_trigs( world, player, cam, fight, rdr, dt, scr_x_res, scr_y_res );
    ent_move_trains( world, player, dt );

    /* and what the player picked up on the way. After the movers: a
       plat can carry an item's floor out from under the player. */
    pl_items_touch( world, player, fight, rdr );

    /* the monsters, after the player has moved: FindTarget sees where
       they are now, not where they were at the top of the tick */
    if ( fight->state == GS_PLAY ) mdl_tick( world, player, fight, rdr );

    /* and the fight: what the player is holding, what they fired, the
       traps a trigger armed this tick, and everything already in the
       air. The shot goes after the monsters' think so it hits them
       where this frame drew them. A dead player fires nothing, but
       what is already in the air keeps flying. */
    if ( fight->state == GS_PLAY ) {
        pl_select_weapon( input, fight );
        if ( fire ) pl_fire( world, player, cam, fight, rdr );
    }
    host_view_load( world, fight->weapon );
    pl_traps_tick( world, player, fight, rdr );
    pl_spikes_tick( world, player, fight, rdr, dt );

    /* dying, coming back, and the level's end */
    host_state( world, player, cam, fight, rdr, fire, scr_x_res );

    /* where each mover ended up, so the draw order can place it */
    ent_place_models( world );

    /* map time, which drives every texture animation */
    rdr->anim_time += dt;

    /* light styles: fixed 10 Hz off the same clock, not framerate */
    ls_animate( ls, rdr->anim_time );

    /* the test dynamic light, following the player */
    rdr->dlight.pos.x = player->pos.x;
    rdr->dlight.pos.y = player->pos.y;
    rdr->dlight.pos.z = player->pos.z;
    rdr->dlight.radius = DL_RADIUS;
}

/*
 * name: host_render
 * desc: One frame's drawing. Reads the world, changes none of it --
 *       the counterpart to host_tick, which changes it and draws none
 *       of it.
 */
void host_render( World *world, Renderer *rdr, Camera *cam, Player *player,
                   SurfCache far *sc, LightStyles *ls,
                   Hud far *hud, Fight *fight, PhaseTimes *pt, SysClock *sysclk,
                   QSurf h_dst_dc, Mat4 *mtx_prj, float xresh, float yresh,
                   float z_near, float z_far,
                   Vec3 *cam_up, QSurf z_dc, short comp, short no_draw,
                   short x_res, short y_res )
{
    Mat4 mtx_mdl, mtx_fin;
    Vec3 cam_pos_b;
    DrawParams dp;
    DiskPlane frustum[6];
#if QR_PROF
    float t0, dt;

    t0 = sys_now( sysclk );
#endif
    qglM4LookAt( &mtx_mdl, &cam->pos, &cam->look_at, cam_up );
    qglM4Conc( &mtx_fin, &mtx_mdl, mtx_prj );
    r_set_frustum( frustum, &mtx_fin );

    /*
     * Birdseye stuff. Deliberate, and it looks like a bug: the frustum
     * above was taken from the PLAYER camera, and the view matrix is
     * now rebuilt from a fixed overhead one. Flying above the level
     * while the culling still answers to the player's view is the
     * point of the mode -- you get to watch what the PVS and the
     * frustum actually throw away. Do not "fix" it by moving
     * r_set_frustum below this block.
     */
    if ( !cam->fps_view ) {
        cam_pos_b.x = 351.0f;
        cam_pos_b.y = 2119.0f;
        cam_pos_b.z = -552.0f;

        cam->look_at.x = cam_pos_b.x + 1.991367e-8f;
        cam->look_at.y = cam_pos_b.y - 1.0f;
        cam->look_at.z = cam_pos_b.z + 1.570986e-2f;
    } else {
        cam_pos_b = cam->pos;
    }

    qglM4LookAt( &mtx_mdl, &cam_pos_b, &cam->look_at, cam_up );
    qglM4Conc( &mtx_fin, &mtx_mdl, mtx_prj );

    /* Walk BSP tree */
    {
#if QR_PROF
        float tw = sys_now( sysclk );
#endif
        r_draw_world( world, rdr, frustum, 0, &cam->pos, &mtx_fin,
                       xresh, yresh, z_near );
#if QR_PROF
        if ( pt->n > 0 ) pt->walk_sum += sys_now( sysclk ) - tw;
        rdr->ord_sum += rdr->ord_count;
#endif
    }

    /* Cull ends here -- both exits from this function after this
       point (-nodraw, and the normal one at the bottom) pass through
       it, so timing it once here covers both. */
#if QR_PROF
    if ( pt->n > 0 ) {
        dt = sys_now( sysclk ) - t0;
        pt->cull_sum += dt;
        if ( dt > pt->cull_max ) pt->cull_max = dt;
    }
#endif

    /* Clear to the far plane before the frame. Depth is 1/z and
       larger is nearer, so zero is infinitely distant and the first
       surface to cover a pixel always wins. */
    /* The DESTINATION surface, not the depth surface: qglSfZClear
       follows surf->zsf to find the buffer, and a depth surface's own
       zsf is null -- so passing z_dc here cleared nothing at all and
       returned quietly. The buffer then held whatever its allocation
       left, every QGL_Z_TEST face failed against it for the life of
       the run, and the world still looked right because QGL_Z_SET
       writes without testing. Brush entities are the only thing that
       tests, and they were invisible: no doors, no lifts. */
    if ( z_dc != 0 ) qglSfZClear( h_dst_dc, 0 );

    /* -nodraw stops HERE: the walk above has run and filled the draw
       order, so everything node paging touches has happened. What is
       skipped is fill, which paging does not affect. */
    if ( no_draw ) return;

    dp.h_dst_dc    = h_dst_dc;
    dp.tex_ofs_ptr = world_tex_ofs_ptr( world );
    dp.turb_ptr    = (long) (void far *) d_turb_table();
    dp.xresh       = xresh;
    dp.yresh       = yresh;
    dp.z_near      = z_near;
    dp.z_far       = z_far;
    dp.anim_time   = rdr->anim_time;
    dp.dl_x        = rdr->dlight.pos.x;
    dp.dl_y        = rdr->dlight.pos.y;
    dp.dl_z        = rdr->dlight.pos.z;
    dp.dl_radius   = rdr->dlight.radius;
    dp.frame_stamp = rdr->frame_stamp;
    dp.ord_count   = (short) rdr->ord_count;
    /* Config's own use_lm toggle (common.bas, not yet ported) isn't
       here yet -- gated on whether the lightmap atlas actually loaded
       instead of a settable flag, which is the conservative default:
       "off" is never reachable until the map genuinely has no data. */
    dp.use_lm      = (short) ( world->light_atlas != 0 );
    dp.lightmap    = rdr->lightmap;
    dp.backface    = rdr->backface;
    dp.rend_mode   = rdr->rend_mode;
    dp.use_mips    = rdr->use_mips;
    dp.z_avail     = (short) ( z_dc != 0 );
    dp.x_res       = x_res;
    dp.y_res       = y_res;
#if QR_PROF
    dp.prof        = (short) ( pt->n > 0 );
    t0 = sys_now( sysclk );
#else
    dp.prof        = 0;
#endif
    d_draw_faces( world, rdr, sc, ls, &dp, &mtx_fin, &cam->pos, sysclk );

    rdr->polys = (short) ( rdr->polys + dp.polys );
    rdr->tris  = (short) ( rdr->tris + dp.tris );

#if QR_PROF
    if ( pt->n > 0 ) {
        pt->build_sum  += dp.build_us  / 1000000.0f;
        pt->raster_sum += dp.raster_us / 1000000.0f;

        dt = sys_now( sysclk ) - t0;
        pt->draw_sum += dt;
        if ( dt > pt->draw_max ) pt->draw_max = dt;
    }
#endif

    /* The pickups, depth tested against the world that is already
       there. Before the outlines, which are the same depth state. */
#if QR_PROF
    t0 = sys_now( sysclk );
#endif
    d_draw_items( world, rdr, player, frustum, &mtx_fin,
                   xresh, yresh, z_near, h_dst_dc );
    rdr->mdl_drawn = d_draw_models( world, rdr, frustum, &mtx_fin,
                                     xresh, yresh, z_near, h_dst_dc );
    d_draw_spikes( fight, &mtx_fin, xresh, yresh, z_near, h_dst_dc );
    /* and the weapon in hand, LAST and with depth off inside
       d_draw_view: it is not in the world and nothing may hide it */
    rdr->mdl_drawn = (short) ( rdr->mdl_drawn +
        d_draw_view( world, rdr, cam, player, fight, &mtx_fin,
                      xresh, yresh, z_near, h_dst_dc ) );

    /* Portal outlines, while the depth test is still on, so a portal
       behind a wall is hidden by it. Drawn after depth goes off they
       show through everything, and a view full of portals you cannot
       see buries the few you are actually looking through. */
    if ( hud->portal_wire ) r_portal_outline( world, rdr, h_dst_dc, &mtx_fin,
                                               xresh, yresh, z_near );

#if QR_PROF
    if ( pt->n > 0 ) {
        dt = sys_now( sysclk ) - t0;
        pt->alias_sum += dt;
        if ( dt > pt->alias_max ) pt->alias_max = dt;
    }
#endif

    /* leave depth off for the overlay, which is 2D and would
       otherwise test itself against the scene it is drawn on top of */
    if ( z_dc != 0 ) qglSfZMode( h_dst_dc, QGL_Z_OFF );

#if QR_PROF
    t0 = sys_now( sysclk );
#endif
    /* Under -comp the host loop draws this onto the composite after
       the scale, at the mode's own resolution. */
    if ( !comp ) {
        /* Quake's own bar first; the stats overlay may cover its edge */
        scr_sbar_draw( fight, h_dst_dc, x_res, y_res );
        scr_draw_hud( world, rdr, cam, player, sc, hud, h_dst_dc, x_res, y_res );
        scr_draw_msg( hud, world, fight, rdr, h_dst_dc, x_res, y_res );
    }

#if QR_PROF
    if ( pt->n > 0 ) {
        dt = sys_now( sysclk ) - t0;
        pt->hud_sum += dt;
        if ( dt > pt->hud_max ) pt->hud_max = dt;
    }
#endif
}
