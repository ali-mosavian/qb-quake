/*
 * pl_move.c -- player physics: collision, gravity, sliding, stairs.
 * C port of pl_move.bas, minus pl_trace/pl_hull_check/pl_hull_contents
 * (pl_trace.c, already its own translation unit both there and here).
 *
 * COORDINATE SPACE. This module works in BSP space, where Z is up. The
 * renderer works in Y-up: pl_move is the one place the two meet --
 * pl_init and pl_move's own tail both do the swap, and nothing else in
 * this file touches a Y-up value.
 */

#include <math.h>
#include <stdlib.h>

#include "pl_move.h"
#include "snd.h"
#include "mdl_ai.h"   /* pl_damage -- the landing costs five */
#include "pl_trace.h"
#include "r_bsp.h"
#include "assets.h"

/*
 * name: pl_point_contents
 * desc: What is at a point, from hull 0 -- the render tree, not the
 *       collision hulls. The collision hulls are built for a box to
 *       move through and carry only EMPTY and SOLID; water and lava
 *       exist only as leaf contents in hull 0.
 */
short pl_point_contents( BspVec3 *p, World *world )
{
    short leaf_nr = r_point_leaf( p, world );
    return r_leaf_contents( leaf_nr, world );
}

/*
 * name: pl_water_level
 * desc: How deep the player is: 0 dry, 1 feet wet, 2 waist, 3 eyes
 *       under. Three samples up the body, which is what lets wading
 *       feel different from swimming.
 */
static void pl_water_level( Player *player, World *world )
{
    BspVec3 p;
    short c;

    player->water_level = 0;
    player->water_type  = CONTENTS_EMPTY;

    p = player->pos;
    p.z = player->pos.z - PL_FEET + 1.0f;
    c = pl_point_contents( &p, world );

    if ( c > CONTENTS_WATER ) return;   /* EMPTY or SOLID: dry */

    player->water_type  = c;
    player->water_level = 1;

    p.z = player->pos.z;
    if ( pl_point_contents( &p, world ) <= CONTENTS_WATER ) {
        player->water_level = 2;

        p.z = player->pos.z + PL_EYE;
        if ( pl_point_contents( &p, world ) <= CONTENTS_WATER ) player->water_level = 3;
    }
}

/*
 * name: pl_clip_velocity
 * desc: Removes the component of v that points into the plane, which
 *       is what turns a head-on stop into a slide along the wall.
 */
static void pl_clip_velocity( BspVec3 *v, BspVec3 *norm )
{
    float backoff = v->x*norm->x + v->y*norm->y + v->z*norm->z;

    v->x -= norm->x*backoff;
    v->y -= norm->y*backoff;
    v->z -= norm->z*backoff;

    if ( (float) fabs( v->x ) < PL_STOP_EPS ) v->x = 0.0f;
    if ( (float) fabs( v->y ) < PL_STOP_EPS ) v->y = 0.0f;
    if ( (float) fabs( v->z ) < PL_STOP_EPS ) v->z = 0.0f;
}

/*
 * name: pl_slide_move
 * desc: Moves org along vel for dt, sliding along whatever it hits.
 *       Four attempts: each impact clips the velocity into the surface
 *       and the remaining time is retried, so an inside corner
 *       resolves in two bumps and a dead end stops.
 */
static void pl_slide_move( World *world, BspVec3 *org, BspVec3 *vel, float dt, TraceResult *tr )
{
    short bump;
    float time_left = dt;
    BspVec3 fin;

    for ( bump = 0; bump < 4; bump++ ) {
        if ( vel->x == 0.0f && vel->y == 0.0f && vel->z == 0.0f ) break;

        fin.x = org->x + vel->x*time_left;
        fin.y = org->y + vel->y*time_left;
        fin.z = org->z + vel->z*time_left;

        pl_trace( world, org, &fin, tr );

        /* Started inside solid. Refusing to move is the safe answer:
           moving would push further in, and Quake's unstick logic is
           not here. */
        if ( tr->all_solid ) {
            vel->z = 0.0f;
            return;
        }

        if ( tr->frac > 0.0f ) *org = tr->end_pos;

        if ( tr->frac == 1.0f ) break;

        time_left -= time_left*tr->frac;

        pl_clip_velocity( vel, &tr->norm );
    }
}

/*
 * name: pl_step_move
 * desc: The same move, but if it is blocked by something short
 *       enough, climb it. Try the move from PL_STEP higher, then drop
 *       back down: if the result lands on walkable ground, the
 *       obstacle was a stair and the higher path is kept. Ported from
 *       sv_phys.c's SV_WalkMove.
 *
 *       Without this the player is stopped by every step and every
 *       doorframe lip, because a 16 unit stair and a wall are the same
 *       thing to a trace.
 */
static void pl_step_move( World *world, Player *player, BspVec3 *org, BspVec3 *vel, float dt, TraceResult *tr )
{
    BspVec3 flat_pos, flat_vel;
    BspVec3 up_pos, down_pos;
    BspVec3 step_vel;
    float old_vel_z;

    /* the ordinary slide, kept in case the step attempt is worse */
    flat_pos = *org;
    flat_vel = *vel;
    pl_slide_move( world, &flat_pos, &flat_vel, dt, tr );

    /*
     * Nothing to step over: the flat move's velocity came out exactly
     * as it went in, so nothing clipped it against a plane anywhere
     * along the way. Matches SV_WalkMove's own gate (it only tries
     * stepping when FlyMove reports it was blocked), and checking
     * velocity rather than tr->frac matters here: pl_slide_move can
     * clip against a riser on its first bump and then finish the
     * REMAINING distance unobstructed on a later bump, leaving
     * tr->frac at 1.0 even though the move was blocked. As a side
     * effect this also stops the probe below from zeroing a swim
     * stroke's vertical velocity when there was nothing to climb at
     * all.
     */
    if ( flat_vel.x == vel->x && flat_vel.y == vel->y && flat_vel.z == vel->z ) {
        *org = flat_pos;
        *vel = flat_vel;
        return;
    }

    /*
     * Ground, or water. Standing on something is the usual reason to
     * be able to climb a step, but swimming sets on_ground false, and
     * refusing to step then means every stair and ledge in a pool
     * stops the player dead. Matches SV_WalkMove's own gate: don't
     * stair up while jumping, but any wetness at all is enough to
     * allow it.
     */
    if ( !player->on_ground && player->water_level == 0 ) {
        *org = flat_pos;
        *vel = flat_vel;
        return;
    }

    old_vel_z = vel->z;

    /* lift, then move forward with the vertical component held at
       zero -- the step height stands in for it, so falling speed
       should not also carry the probe forward at the raised height */
    up_pos = *org;
    up_pos.z += PL_STEP;
    pl_trace( world, org, &up_pos, tr );

    if ( tr->all_solid ) {
        *org = flat_pos;
        *vel = flat_vel;
        return;
    }
    up_pos = tr->end_pos;

    step_vel   = *vel;
    step_vel.z = 0.0f;
    pl_slide_move( world, &up_pos, &step_vel, dt, tr );

    /* drop back down, extended by however far the original fall speed
       would have carried this tick */
    down_pos   = up_pos;
    down_pos.z = down_pos.z - PL_STEP + old_vel_z*dt;
    pl_trace( world, &up_pos, &down_pos, tr );

    /*
     * Keep the stepped path only if it lands on walkable ground. A
     * slope too steep to climb, or open air past the edge, fails this
     * -- tr->norm is left at (0,0,0) by pl_trace when nothing is hit,
     * which is not > PL_GROUND_NRM either -- and falls back to the
     * flat move.
     */
    if ( tr->norm.z > PL_GROUND_NRM ) {
        *org = tr->end_pos;
        *vel = step_vel;
    } else {
        *org = flat_pos;
        *vel = flat_vel;
    }
}

/*
 * name: pl_gravity
 * desc: Ground test and fall. A surface counts as ground only if it
 *       is more floor than wall, which is what PL_GROUND_NRM measures
 *       -- otherwise the player would stand on vertical surfaces.
 *
 *       Gravity is suppressed by ANY water contact, not just being
 *       fully submerged -- Quake's SV_CheckWater gates SV_AddGravity
 *       on waterlevel being nonzero at all. Sinking is pl_water_move's
 *       job at water_level>=2, folded into its own accel/friction
 *       rather than a separate force; at water_level=1 (feet only)
 *       there is neither fall nor sink.
 */
/* PlayerPostThink's landing: a splash in water, else a thud past 300
   down, a grunt and five points past 650. */
static void pl_land( Player *player, Fight *fight, Renderer *rdr )
{
    if ( player->vel.z > PL_LAND_SOFT || fight->health <= 0 ) return;
    if ( player->water_level > 0 && player->water_type == CONTENTS_WATER ) {
        snd_self( player, CHAN_BODY, SND_H2OJUMP );
        return;
    }
    if ( player->vel.z > PL_LAND_HARD ) { snd_self( player, CHAN_VOICE, SND_LAND ); return; }
    snd_self( player, CHAN_VOICE, SND_LAND2 );
    pl_damage( player, fight, rdr, 5 );
}

/* client.qc's WaterMove: breath and drowning, the gasp on surfacing,
   slime and lava's bites, and the splash in and out. */
static void pl_water_check( Player *player, Fight *fight, Renderer *rdr, float dt )
{
    float now = rdr->anim_time;
    short d;

    if ( player->no_clip || fight->health <= 0 ) return;
    if ( now < fight->suit_until ) fight->air_used = 0.0f;   /* CheckPowerups: the suit breathes */

    if ( player->water_level != 3 ) {
        if ( fight->air_used > PL_AIR )           snd_self( player, CHAN_VOICE, SND_GASP1 + 1 );
        else if ( fight->air_used > PL_AIR_GASP ) snd_self( player, CHAN_VOICE, SND_GASP1 );
        fight->air_used = 0.0f;
        fight->drown_dmg = 0;
    } else {
        fight->air_used += dt;
        if ( fight->air_used > PL_AIR && now >= fight->pain_at ) {
            d = (short) ( ( fight->drown_dmg ? fight->drown_dmg : 2 ) + 2 );
            if ( d > 15 ) d = 10;
            fight->drown_dmg = d;
            pl_damage( player, fight, rdr, d );
            fight->pain_at = now + 1.0f;
        }
    }

    if ( player->water_level == 0 ) {
        if ( fight->in_water ) snd_self( player, CHAN_BODY, SND_OUTWATER );
        fight->in_water = 0;
        return;
    }
    if ( player->water_type == CONTENTS_LAVA && now >= fight->dmg_at ) {
        fight->dmg_at = now + ( now < fight->suit_until ? 1.0f : 0.2f );
        pl_damage( player, fight, rdr, (short) ( 10 * player->water_level ) );
    } else if ( player->water_type == CONTENTS_SLIME && now >= fight->dmg_at &&
                now >= fight->suit_until ) {
        fight->dmg_at = now + 1.0f;
        pl_damage( player, fight, rdr, (short) ( 4 * player->water_level ) );
    }
    if ( fight->in_water ) return;
    switch ( player->water_type ) {
    case CONTENTS_LAVA:  snd_self( player, CHAN_BODY, SND_INLAVA ); break;
    case CONTENTS_WATER: snd_self( player, CHAN_BODY, SND_INH2O );  break;
    case CONTENTS_SLIME: snd_self( player, CHAN_BODY, SND_SLIME );  break;
    }
    fight->in_water = 1;
    fight->dmg_at = 0.0f;       /* id's order: the entry bites twice */
}

static void pl_gravity( World *world, Player *player, Fight *fight,
                         Renderer *rdr, float dt, TraceResult *tr )
{
    BspVec3 below = player->pos;
    below.z -= 1.0f;

    pl_trace( world, &player->pos, &below, tr );

    if ( tr->frac < 1.0f && tr->norm.z > PL_GROUND_NRM ) {
        if ( !player->on_ground ) pl_land( player, fight, rdr );
        player->on_ground = 1;
        if ( player->vel.z < 0.0f ) player->vel.z = 0.0f;
    } else {
        player->on_ground = 0;
        if ( player->water_level == 0 ) player->vel.z -= PL_FALLACC*dt;
    }
}

/*
 * name: pl_ground_friction
 * desc: Ground friction, horizontal only. Ported from sv_user.c's
 *       SV_UserFriction.
 *
 *       The PL_STOPSPEED floor is what makes a near-stop actually
 *       stop: the decay is proportional to speed, so without a floor
 *       it approaches zero without ever reaching it. Quake's own
 *       edge-friction bonus (extra drag with a dropoff underfoot)
 *       costs a second trace per tick -- ported anyway, since it's the
 *       one part of SV_UserFriction that changes the numbers that
 *       matter: acceleration, top speed, and how fast the player
 *       stops.
 */
static void pl_ground_friction( World *world, BspVec3 *org, BspVec3 *vel, float dt, TraceResult *tr )
{
    float speed, speed_floor, newspeed;
    float fric;
    BspVec3 edge_a, edge_b;

    speed = (float) sqrt( vel->x*vel->x + vel->y*vel->y );
    if ( speed == 0.0f ) return;

    /*
     * Edge friction. Probe one player-width ahead along the way we
     * are travelling, from the feet down 34 units: if nothing is
     * under it the leading edge overhangs a drop, and friction
     * doubles. That is what stops you sliding off a ledge, and it is
     * the one part of SV_UserFriction that costs a trace.
     */
    edge_a.x = org->x + vel->x/speed*PL_EDGE_FWD;
    edge_a.y = org->y + vel->y/speed*PL_EDGE_FWD;
    edge_a.z = org->z - PL_FEET;
    edge_b.x = edge_a.x;
    edge_b.y = edge_a.y;
    edge_b.z = edge_a.z - PL_EDGE_DROP;

    pl_trace( world, &edge_a, &edge_b, tr );

    fric = PL_FRICTION;
    if ( tr->frac == 1.0f ) fric = PL_FRICTION * PL_EDGEFRIC;

    speed_floor = speed;
    if ( speed_floor < PL_STOPSPEED ) speed_floor = PL_STOPSPEED;

    newspeed = speed - dt*speed_floor*fric;
    if ( newspeed < 0.0f ) newspeed = 0.0f;
    newspeed = newspeed / speed;

    /* All THREE components, as SV_UserFriction does: the speed is
       measured from x and y, but the scaling is applied to z as well. */
    vel->x *= newspeed;
    vel->y *= newspeed;
    vel->z *= newspeed;
}

/*
 * name: pl_ground_accel
 * desc: Ground acceleration towards wishdir at wishspeed. Ported from
 *       sv_user.c's SV_Accelerate: the gain is proportional to how far
 *       current speed along wishdir is from wishspeed, so it tapers
 *       off approaching top speed rather than adding a flat amount
 *       every tick.
 */
static void pl_ground_accel( BspVec3 *vel, BspVec3 *wishdir, float wishspeed, float dt )
{
    float currentspeed, addspeed, accelspeed;

    currentspeed = vel->x*wishdir->x + vel->y*wishdir->y;

    addspeed = wishspeed - currentspeed;
    if ( addspeed <= 0.0f ) return;

    accelspeed = PL_ACCELERATE * wishspeed * dt;
    if ( accelspeed > addspeed ) accelspeed = addspeed;

    vel->x += accelspeed*wishdir->x;
    vel->y += accelspeed*wishdir->y;
}

/*
 * name: pl_air_accel
 * desc: The airborne counterpart of pl_ground_accel. Ported from
 *       sv_user.c's SV_AirAccelerate, quirk and all: addspeed is
 *       capped at PL_AIRSPEEDCAP (30), but accelspeed is scaled by the
 *       UNCAPPED wishspeed, not by wishspd. That mismatch is what lets
 *       air strafing gain more speed per tick than the 30 cap alone
 *       suggests -- it's Quake's own arithmetic, not a bug to tidy up
 *       here.
 */
static void pl_air_accel( BspVec3 *vel, BspVec3 *wishdir, float wishspeed, float dt )
{
    float wishspd, currentspeed;
    float addspeed, accelspeed;

    wishspd = wishspeed;
    if ( wishspd > PL_AIRSPEEDCAP ) wishspd = PL_AIRSPEEDCAP;

    currentspeed = vel->x*wishdir->x + vel->y*wishdir->y;

    addspeed = wishspd - currentspeed;
    if ( addspeed <= 0.0f ) return;

    accelspeed = PL_ACCELERATE * wishspeed * dt;
    if ( accelspeed > addspeed ) accelspeed = addspeed;

    vel->x += accelspeed*wishdir->x;
    vel->y += accelspeed*wishdir->y;
}

/*
 * name: pl_water_move
 * desc: Swimming: horizontal wishdir from the same input as ground
 *       movement, plus a drift towards the bottom when nothing is
 *       pressed. Ported from sv_user.c's SV_WaterMove.
 *
 *       Friction and acceleration both act on the FULL three-axis
 *       speed here, unlike ground movement's horizontal-only friction
 *       -- swimming drags vertical motion down too, which is what
 *       makes a dive glide to a stop rather than coast forever.
 *
 *       STRUCTURAL NOTE: real Quake's wishvel comes from AngleVectors
 *       on the full view angle, so looking up or down tilts the swim
 *       direction. dir_x/dir_y here are already flattened to the
 *       horizontal look, and no pitch reaches this module -- ported
 *       exactly as the BASIC left it, not extended.
 */
static void pl_water_move( BspVec3 *vel, float fwd, float strafe, float dir_x, float dir_y, float dt )
{
    BspVec3 wishvel, wishdir;
    float wishspeed, wishlen, scale;
    float speed, newspeed;
    float addspeed, accelspeed;

    wishvel.x = dir_x*fwd*PL_FWDSPEED - dir_y*strafe*PL_FWDSPEED;
    wishvel.y = dir_y*fwd*PL_FWDSPEED + dir_x*strafe*PL_FWDSPEED;

    if ( fwd == 0.0f && strafe == 0.0f ) wishvel.z = -PL_WATERSINK;
    else                                 wishvel.z = 0.0f;

    wishspeed = (float) sqrt( wishvel.x*wishvel.x + wishvel.y*wishvel.y + wishvel.z*wishvel.z );
    if ( wishspeed > PL_MAXSPEED ) {
        scale = PL_MAXSPEED / wishspeed;
        wishvel.x *= scale;
        wishvel.y *= scale;
        wishvel.z *= scale;
        wishspeed = PL_MAXSPEED;
    }
    wishlen   = wishspeed;
    wishspeed = wishspeed * PL_WATERSCALE;

    /* water friction: the full 3D speed, not just horizontal */
    speed = (float) sqrt( vel->x*vel->x + vel->y*vel->y + vel->z*vel->z );
    if ( speed > 0.0f ) {
        newspeed = speed - dt*speed*PL_FRICTION;
        if ( newspeed < 0.0f ) newspeed = 0.0f;
        vel->x *= newspeed/speed;
        vel->y *= newspeed/speed;
        vel->z *= newspeed/speed;
    } else {
        newspeed = 0.0f;
    }

    if ( wishspeed == 0.0f ) return;
    addspeed = wishspeed - newspeed;
    if ( addspeed <= 0.0f ) return;

    wishdir.x = wishvel.x / wishlen;
    wishdir.y = wishvel.y / wishlen;
    wishdir.z = wishvel.z / wishlen;

    accelspeed = PL_ACCELERATE * wishspeed * dt;
    if ( accelspeed > addspeed ) accelspeed = addspeed;

    vel->x += accelspeed*wishdir.x;
    vel->y += accelspeed*wishdir.y;
    vel->z += accelspeed*wishdir.z;
}

/*
 * name: pl_init
 * desc: Seeds the player from a spawn point. The height does NOT come
 *       from PL_EYE-adjusting the camera's own eye height: an
 *       info_player_start's origin IS the player's own origin, the
 *       same thing player->pos holds, and the eye goes PL_EYE ABOVE it
 *       (pl_move does that on the way out). Taking PL_EYE off here
 *       would put the player under the spawn -- open air on some maps,
 *       inside the floor on others, where every direction traces solid
 *       and it can't move at all.
 */
void pl_init( Player *player, Camera *cam, BspVec3 *start_override )
{
    if ( start_override ) {
        player->pos = *start_override;
    } else {
        player->pos.x = cam->pos.x;
        player->pos.y = cam->pos.z;
        player->pos.z = cam->pos.y;
    }

    player->vel.x = 0.0f;
    player->vel.y = 0.0f;
    player->vel.z = 0.0f;

    player->on_ground = 0;
}

/*
 * name: pl_move
 * desc: One tick of player physics: accelerate along the look
 *       direction, apply friction and gravity, move with collision,
 *       then put the eye where the camera can use it.
 */
void pl_move( World *world, Player *player, Camera *cam, Fight *fight,
              Renderer *rdr, float fwd, float strafe, float dir_x, float dir_y,
              short jump, float dt )
{
    TraceResult tr;
    BspVec3 wishvel, wishdir;
    float wishspeed;

    /*
     * dir_x/dir_y is the horizontal look direction in BSP space,
     * passed in rather than read from cam->look_at: that vector is a
     * direction for part of v_update_camera and an absolute point for
     * the rest, and depending on which half of the routine called
     * this would be a trap.
     *
     * player->water_level here is last tick's value -- pl_water_level
     * below refreshes it for pl_gravity and for the NEXT tick's read
     * of this same branch, exactly the one-tick lag SV_ClientThink has
     * against SV_CheckWater: friction and accel run before the server
     * re-checks where the player ended up wet.
     */
    if ( player->water_level >= 2 ) {
        pl_water_move( &player->vel, fwd, strafe, dir_x, dir_y, dt );
    } else {
        wishvel.x = dir_x*fwd*PL_FWDSPEED - dir_y*strafe*PL_FWDSPEED;
        wishvel.y = dir_y*fwd*PL_FWDSPEED + dir_x*strafe*PL_FWDSPEED;

        wishspeed = (float) sqrt( wishvel.x*wishvel.x + wishvel.y*wishvel.y );
        if ( wishspeed > 0.0f ) {
            wishdir.x = wishvel.x / wishspeed;
            wishdir.y = wishvel.y / wishspeed;
        } else {
            wishdir.x = 0.0f;
            wishdir.y = 0.0f;
        }
        if ( wishspeed > PL_MAXSPEED ) wishspeed = PL_MAXSPEED;

        if ( player->on_ground ) {
            pl_ground_friction( world, &player->pos, &player->vel, dt, &tr );
            pl_ground_accel( &player->vel, &wishdir, wishspeed, dt );
        } else {
            pl_air_accel( &player->vel, &wishdir, wishspeed, dt );
        }
    }

    pl_water_level( player, world );
    pl_water_check( player, fight, rdr, dt );

    pl_gravity( world, player, fight, rdr, dt, &tr );

    /*
     * Jump. After pl_gravity, which is what decides whether there is
     * any ground -- doing it before would read last frame's answer and
     * allow a second jump in mid-air. Swimming and jumping share the
     * key but not the effect: at waterlevel>=2 it's a swim stroke,
     * keyed on liquid type, every tick the key is held rather than a
     * one-shot launch. Ported from QuakeWorld's pmove.c JumpButton.
     *
     * The velocity is SET rather than added, so holding the key gives
     * one jump or one stroke instead of accumulating thrust.
     */
    if ( player->water_level >= 2 ) {
        if ( jump ) {
            switch ( player->water_type ) {
            case CONTENTS_SLIME: player->vel.z = PL_SWIM_SLIME; break;
            case CONTENTS_WATER: player->vel.z = PL_SWIM_WATER; break;
            default:              player->vel.z = PL_SWIM_LAVA; break;
            }
            player->on_ground = 0;
            if ( rdr->anim_time >= fight->swim_at ) {
                fight->swim_at = rdr->anim_time + 1.0f;
                snd_self( player, CHAN_BODY, (short) ( SND_SWIM1 + ( rand() & 1 ) ) );
            }
        }
    } else if ( jump && player->on_ground ) {
        player->vel.z     = PL_JUMP;
        player->on_ground = 0;
        snd_self( player, CHAN_BODY, SND_JUMP );
    }

    /*
     * A per-axis safety clamp, not a speed cap -- Quake's
     * SV_CheckVelocity against sv_maxvelocity. The real ceiling on
     * walking/swimming speed is wishspeed inside pl_ground_accel/
     * pl_air_accel/pl_water_move; this only stops a runaway (e.g. a
     * bad trace) from producing a velocity the next frame's move can't
     * recover from.
     */
    if ( player->vel.x >  PL_MAXVEL ) player->vel.x =  PL_MAXVEL;
    if ( player->vel.x < -PL_MAXVEL ) player->vel.x = -PL_MAXVEL;
    if ( player->vel.y >  PL_MAXVEL ) player->vel.y =  PL_MAXVEL;
    if ( player->vel.y < -PL_MAXVEL ) player->vel.y = -PL_MAXVEL;
    if ( player->vel.z >  PL_MAXVEL ) player->vel.z =  PL_MAXVEL;
    if ( player->vel.z < -PL_MAXVEL ) player->vel.z = -PL_MAXVEL;

    pl_step_move( world, player, &player->pos, &player->vel, dt, &tr );

    if ( player->pos.z > player->peak_z ) player->peak_z = player->pos.z;

    /* Hand the eye back to the renderer, converting Z-up to Y-up.
       This is the only place the two spaces meet. */
    cam->pos.x = player->pos.x;
    cam->pos.y = player->pos.z + PL_EYE;
    cam->pos.z = player->pos.y;
}

void pl_load_hulls( World *world, short clip_count )
{
    world->clip = (ClipNode far *) asset_load( "clip.pag",
                                                (long) clip_count * sizeof(ClipNode) );
}
