/*
 * mdl_ai.c -- the monsters' own tick: ai.qc and sv_move.c, ported as
 * they stand. Movement distance and displayed frame are one state --
 * while army_runN is on screen, ai_run(N)'s distance is what moves that
 * think -- so the animation always matches what the monster is doing.
 *
 * The "path finding" is SV_NewChaseDir's eight compass points. There is
 * no graph and no search, because id shipped none.
 */

#include <math.h>
#include <stdlib.h>

#include "mdl_ai.h"
#include "mdl.h"
#include "pl_trace.h"
#include "ent.h"

#define DEG2RAD 0.017453293f

/* ai_run(N)'s own per-frame distances, straight out of each .qc. */
static short army_run_dist[8]     = { 11, 15, 10, 10, 8, 15, 10, 8 };
static short knight_run_dist[8]   = { 16, 20, 13, 7, 16, 20, 14, 6 };
static short knight_atk_dist[10]  = { 0, 7, 4, 0, 3, 4, 1, 3, 1, 5 };
static short dog_run_dist[12]     = { 16, 32, 32, 20, 64, 32, 16, 32, 32, 20, 64, 32 };
static short ogre_run_dist[8]     = { 9, 12, 8, 22, 16, 4, 13, 24 };
static short demon_run_dist[6]    = { 20, 15, 36, 20, 15, 36 };
static short demon_atk_dist[15]   = { 4, 0, 0, 1, 2, 1, 6, 8, 4, 2, 0, 5, 8, 4, 4 };
static short zombie_run_dist[8]   = { 1, 1, 0, 1, 2, 3, 4, 4 };
static short shambler_run_dist[6] = { 20, 24, 20, 20, 24, 20 };

/* BASIC's RND: [0,1). The AI reads it for chances and for the compass
   coin-flips, and nothing here depends on the sequence matching the
   BASIC branch's -- only on the distribution. */
static float mdl_rnd( void )
{
    return (float) rand() / ( (float) RAND_MAX + 1.0f );
}

static float mdl_anglemod( float v )
{
    while ( v >= 360.0f ) v -= 360.0f;
    while ( v < 0.0f )    v += 360.0f;
    return v;
}

/* PF_vectoyaw, including its (int) truncation toward zero. */
static float mdl_vectoyaw( float dx, float dy )
{
    float yaw;

    if ( dx == 0.0f && dy == 0.0f ) return 0.0f;
    yaw = (float) ( atan2( dy, dx ) * 57.29577951 );
    yaw = (float) (long) yaw;
    if ( yaw < 0.0f ) yaw += 360.0f;
    return yaw;
}

/* PF_changeyaw: up to MDL_YAW_SPEED degrees per think. */
static void mdl_change_yaw( MdlEnt far *ent )
{
    float cur = mdl_anglemod( ent->yaw ), ideal = ent->ideal_yaw, mv;

    if ( cur == ideal ) return;
    mv = ideal - cur;
    if ( ideal > cur ) { if ( mv >=  180.0f ) mv -= 360.0f; }
    else               { if ( mv <= -180.0f ) mv += 360.0f; }

    if ( mv > 0.0f ) { if ( mv >  MDL_YAW_SPEED ) mv =  MDL_YAW_SPEED; }
    else             { if ( mv < -MDL_YAW_SPEED ) mv = -MDL_YAW_SPEED; }

    ent->yaw = mdl_anglemod( cur + mv );
}

void pl_damage( Fight *fight, Renderer *rdr, short dmg )
{
    short save;

    /* T_Damage: nothing gets through the pentagram */
    if ( rdr->anim_time < fight->pent_until ) return;

    /* the armor takes ceil(type * damage), and its last point takes the
       type with it */
    save = (short) -(long) ( -fight->armor_type * dmg );
    if ( save >= fight->armor ) { save = fight->armor; fight->armor_type = 0.0f; }
    fight->armor  = (short) ( fight->armor - save );
    fight->health = (short) ( fight->health - ( dmg - save ) );
}

/* One axis of the ray-box test: narrows tn..tf to the slab. */
static short mdl_slab( float lo, float hi, float o, float d,
                        float *tn, float *tf )
{
    float t0, t1, sw;

    if ( fabs( d ) < 0.0001 ) return ( o >= lo && o <= hi ) ? -1 : 0;
    t0 = ( lo - o ) / d;
    t1 = ( hi - o ) / d;
    if ( t0 > t1 ) { sw = t0; t0 = t1; t1 = sw; }
    if ( t0 > *tn ) *tn = t0;
    if ( t1 < *tf ) *tf = t1;
    return (short) ( *tn <= *tf );
}

/* Where a ray from org along dir enters the box, or -1. */
static float pl_ray_box( BspVec3 *mins, BspVec3 *maxs, BspVec3 *org,
                          BspVec3 *dir, float maxt )
{
    float tn = 0.0f, tf = maxt;

    if ( !mdl_slab( mins->x, maxs->x, org->x, dir->x, &tn, &tf ) ) return -1.0f;
    if ( !mdl_slab( mins->y, maxs->y, org->y, dir->y, &tn, &tf ) ) return -1.0f;
    if ( !mdl_slab( mins->z, maxs->z, org->z, dir->z, &tn, &tf ) ) return -1.0f;
    return tn;
}

static float mdl_ray_player( BspVec3 *pl, BspVec3 *org, BspVec3 *dir, float maxt )
{
    BspVec3 mins, maxs;

    mins.x = pl->x - PL_HALF; maxs.x = pl->x + PL_HALF;
    mins.y = pl->y - PL_HALF; maxs.y = pl->y + PL_HALF;
    mins.z = pl->z + PL_ZLO;  maxs.z = pl->z + PL_ZHI;
    return pl_ray_box( &mins, &maxs, org, dir, maxt );
}

/* FireBullets' pellet: dir + crandom*spread*right + crandom*spread*up. */
static void pl_spread_dir( BspVec3 *dir, float sx, float sy, BspVec3 *out )
{
    float rx = dir->y, ry = -dir->x, rl;
    float ux, uy, uz, a, b;

    rl = (float) sqrt( rx*rx + ry*ry );
    if ( rl < 0.001f ) { rx = 1.0f; ry = 0.0f; rl = 1.0f; }
    rx /= rl; ry /= rl;
    ux =  ry * dir->z;
    uy = -rx * dir->z;
    uz =  rx * dir->y - ry * dir->x;
    a = ( 2.0f * mdl_rnd() - 1.0f ) * sx;
    b = ( 2.0f * mdl_rnd() - 1.0f ) * sy;
    out->x = dir->x + a * rx + b * ux;
    out->y = dir->y + a * ry + b * uy;
    out->z = dir->z + b * uz;
}

/* SV_movestep's FL_FLY case: a straight trace, held 30..40 above the
   player while hunting. */
static short mdl_flystep( World *world, Player *player, MdlEnt far *ent,
                           float dx, float dy )
{
    BspVec3 start, fin;
    TraceResult tr;
    float dz;
    short try_n;

    for ( try_n = 0; try_n < 2; try_n++ ) {
        start = ent->pos;
        fin.x = ent->pos.x + dx; fin.y = ent->pos.y + dy; fin.z = ent->pos.z;
        if ( try_n == 0 && ent->hunting ) {
            dz = ent->pos.z - player->pos.z;
            if ( dz > WIZARD_FLY_HI ) fin.z -= WIZARD_FLY_STEP;
            if ( dz < WIZARD_FLY_LO ) fin.z += WIZARD_FLY_STEP;
        }
        pl_trace( world, &start, &fin, &tr );
        if ( tr.frac >= 1.0f && !tr.start_solid && !tr.all_solid ) {
            ent->pos = tr.end_pos;
            return -1;
        }
    }
    return 0;
}

/*
 * SV_movestep's vertical dance: one hull-1 trace from (new xy, z +
 * STEPSIZE) down to (new xy, z - STEPSIZE), so a step down finds its
 * floor and a step up climbs one. Nothing within the band is an edge,
 * and the step is refused. SV_CheckBottom's four-corner support test is
 * not ported, so a monster can teeter over a corner id would refuse.
 */
static short mdl_movestep( World *world, Player *player, MdlEnt far *ent,
                            float dx, float dy )
{
    BspVec3 start, fin;
    TraceResult tr;

    if ( ent->kind == MDL_KIND_WIZARD )
        return mdl_flystep( world, player, ent, dx, dy );

    start.x = ent->pos.x + dx;
    start.y = ent->pos.y + dy;
    start.z = ent->pos.z + MDL_STEPSIZE;
    fin = start;
    fin.z = ent->pos.z - MDL_STEPSIZE;

    pl_trace( world, &start, &fin, &tr );
    if ( tr.all_solid ) return 0;

    if ( tr.start_solid ) {
        start.z = ent->pos.z;
        pl_trace( world, &start, &fin, &tr );
        if ( tr.all_solid || tr.start_solid ) return 0;
    }
    if ( tr.frac > 0.999f ) return 0;

    ent->pos = tr.end_pos;
    return -1;
}

/*
 * SV_StepDirection, oddity included: the step is reverted (position
 * only, not the turn) when the monster is not yet within 45 degrees of
 * the heading, and TRUE is still returned. That is why one turns in
 * place for a think or two before it walks.
 */
static short mdl_step_dir( World *world, Player *player, MdlEnt far *ent,
                            float yaw, float dist )
{
    BspVec3 old;
    float rad, delta;

    ent->ideal_yaw = yaw;
    mdl_change_yaw( ent );

    rad = yaw * DEG2RAD;
    old = ent->pos;
    if ( !mdl_movestep( world, player, ent,
                         (float) cos( rad ) * dist, (float) sin( rad ) * dist ) )
        return 0;

    delta = mdl_anglemod( ent->yaw - ent->ideal_yaw );
    if ( delta > 45.0f && delta < 315.0f ) ent->pos = old;
    return -1;
}

/* SV_NewChaseDir: the diagonal, the two cardinals (order coin-flipped
   as id's own (rand()&3)&1 does), the old heading, a randomised sweep
   of all eight, then reverse. */
static void mdl_new_chase_dir( World *world, Player *player, MdlEnt far *ent,
                                BspVec3 *goal, float dist )
{
    float deltax, deltay, d1, d2, tdir, tmp, olddir, turnaround;

    olddir = mdl_anglemod( (float) (long) ( ent->ideal_yaw / 45.0f ) * 45.0f );
    turnaround = mdl_anglemod( olddir - 180.0f );

    deltax = goal->x - ent->pos.x;
    deltay = goal->y - ent->pos.y;

    if      ( deltax >  10.0f ) d1 = 0.0f;
    else if ( deltax < -10.0f ) d1 = 180.0f;
    else                        d1 = -1.0f;

    if      ( deltay < -10.0f ) d2 = 270.0f;
    else if ( deltay >  10.0f ) d2 = 90.0f;
    else                        d2 = -1.0f;

    if ( d1 != -1.0f && d2 != -1.0f ) {
        if ( d1 == 0.0f ) tdir = ( d2 == 90.0f ) ? 45.0f : 315.0f;
        else              tdir = ( d2 == 90.0f ) ? 135.0f : 215.0f;
        if ( tdir != turnaround &&
             mdl_step_dir( world, player, ent, tdir, dist ) ) return;
    }

    if ( ( (long) ( mdl_rnd() * 4.0f ) & 1 ) || fabs( deltay ) > fabs( deltax ) ) {
        tmp = d1; d1 = d2; d2 = tmp;
    }
    if ( d1 != -1.0f && d1 != turnaround &&
         mdl_step_dir( world, player, ent, d1, dist ) ) return;
    if ( d2 != -1.0f && d2 != turnaround &&
         mdl_step_dir( world, player, ent, d2, dist ) ) return;

    if ( olddir != -1.0f && mdl_step_dir( world, player, ent, olddir, dist ) ) return;

    if ( (long) ( mdl_rnd() * 2.0f ) ) {
        for ( tdir = 0.0f; tdir <= 315.0f; tdir += 45.0f )
            if ( tdir != turnaround &&
                 mdl_step_dir( world, player, ent, tdir, dist ) ) return;
    } else {
        for ( tdir = 315.0f; tdir >= 0.0f; tdir -= 45.0f )
            if ( tdir != turnaround &&
                 mdl_step_dir( world, player, ent, tdir, dist ) ) return;
    }

    if ( mdl_step_dir( world, player, ent, turnaround, dist ) ) return;

    ent->ideal_yaw = olddir;    /* can't move */
}

/* SV_MoveToGoal: a 1-in-4 chance to skip the direct step. */
static void mdl_move_to_goal( World *world, Player *player, MdlEnt far *ent,
                               BspVec3 *goal, float dist )
{
    short skip = (short) ( (long) ( mdl_rnd() * 4.0f ) == 1 );
    short stepped = 0;

    if ( !skip ) stepped = mdl_step_dir( world, player, ent, ent->ideal_yaw, dist );
    if ( skip || !stepped )
        mdl_new_chase_dir( world, player, ent, goal, dist );
}

/*
 * FindTarget, collapsed to the one enemy this world has. RANGE_MELEE
 * skips infront -- "will become hostile even if back is turned";
 * RANGE_NEAR needs it unless the player fired within the second.
 * visible() goes through hull 1, the clipnodes pl_trace already walks,
 * not id's hull-0 traceline: a real point trace sees past a few corners
 * this cannot.
 */
static short mdl_find_target( World *world, Player *player, Fight *fight,
                               Renderer *rdr, MdlEnt far *ent )
{
    BspVec3 eye, peye;
    TraceResult tr;
    float dx, dy, dz, r, yaw_rad, dlen, dot;

    eye  = ent->pos;    eye.z  += MDL_VIEW_OFS;
    peye = player->pos; peye.z += PL_EYE;

    dx = peye.x - eye.x; dy = peye.y - eye.y; dz = peye.z - eye.z;
    r = (float) sqrt( dx*dx + dy*dy + dz*dz );
    if ( r >= MDL_RANGE_MID ) return 0;          /* RANGE_FAR */

    pl_trace( world, &eye, &peye, &tr );
    if ( tr.frac <= 0.999f || tr.all_solid ) return 0;   /* not visible */

    if ( r >= MDL_RANGE_NEAR || fight->show_hostile < rdr->anim_time ) {
        if ( r >= MDL_RANGE_MELEE ) {
            yaw_rad = ent->yaw * DEG2RAD;
            dlen = (float) sqrt( dx*dx + dy*dy );
            dot = dlen > 0.0f
                ? ( dx * (float) cos( yaw_rad ) + dy * (float) sin( yaw_rad ) ) / dlen
                : 1.0f;
            if ( dot <= 0.3f ) return 0;         /* not infront */
        }
    }

    ent->ideal_yaw = mdl_vectoyaw( dx, dy );     /* HuntTarget faces at once */
    return -1;
}

/* the goal is corner i, and the face towards it (t_movetarget) */
static void mdl_patrol_to( World *world, MdlEnt far *ent, short i )
{
    PathCorner far *c = &world->corner[i];

    ent->corner = i;
    ent->goal = c->org;
    ent->ideal_yaw = mdl_vectoyaw( c->org.x - ent->pos.x, c->org.y - ent->pos.y );
}

/* Not id's: a point on a circle round where the monster is NOW, so one
   that has wandered somewhere keeps drifting instead of yo-yoing back
   to its spawn. An unreachable goal times out in mdl_think. */
static void mdl_pick_goal( MdlEnt far *ent )
{
    float ang  = mdl_rnd() * 6.28318531f;
    float dist = MDL_WANDER_MIN + mdl_rnd() * ( MDL_WANDER_MAX - MDL_WANDER_MIN );

    ent->goal.x = ent->pos.x + (float) cos( ang ) * dist;
    ent->goal.y = ent->pos.y + (float) sin( ang ) * dist;
    ent->goal.z = ent->pos.z;
}

/* ai_melee's and Demon_Melee's test: the player within range of the origin */
static short mdl_in_reach( Player *player, MdlEnt far *ent, float range )
{
    float dx = player->pos.x - ent->pos.x;
    float dy = player->pos.y - ent->pos.y;
    float dz = player->pos.z - ent->pos.z;

    return (short) ( dx*dx + dy*dy + dz*dz <= range * range );
}

/* army_fire: four pellets at the player's position 0.2 s back along
   their own velocity, each traced through the world and then against
   the player's box. */
static void mdl_fire( World *world, Player *player, Fight *fight,
                       Renderer *rdr, MdlEnt far *ent )
{
    BspVec3 org, fin, aim, dir;
    TraceResult tr;
    float l;
    short p, dmg = 0;

    aim.x = player->pos.x - player->vel.x * MDL_AIM_LAG - ent->pos.x;
    aim.y = player->pos.y - player->vel.y * MDL_AIM_LAG - ent->pos.y;
    aim.z = player->pos.z - player->vel.z * MDL_AIM_LAG - ent->pos.z;
    l = (float) sqrt( aim.x*aim.x + aim.y*aim.y + aim.z*aim.z );
    if ( l < 1.0f ) return;
    aim.x /= l; aim.y /= l; aim.z /= l;

    org.x = ent->pos.x + aim.x * 10.0f;
    org.y = ent->pos.y + aim.y * 10.0f;
    org.z = ent->pos.z + MDL_ZLO + ( MDL_ZHI - MDL_ZLO ) * 0.7f;

    for ( p = 0; p < MDL_PELLETS; p++ ) {
        pl_spread_dir( &aim, MDL_SPREAD, MDL_SPREAD, &dir );
        fin.x = org.x + dir.x * PL_SHOT_RANGE;
        fin.y = org.y + dir.y * PL_SHOT_RANGE;
        fin.z = org.z + dir.z * PL_SHOT_RANGE;
        pl_trace( world, &org, &fin, &tr );
        if ( mdl_ray_player( &player->pos, &org, &dir, PL_SHOT_RANGE * tr.frac ) >= 0.0f )
            dmg = (short) ( dmg + MDL_PELLET_DMG );
    }
    if ( dmg > 0 ) pl_damage( fight, rdr, dmg );
}

/* CastLightning: a line from 40 up toward 16 above the player's origin,
   traced 600, and LightningDamage where it crosses their box. Nothing is
   drawn for it. */
static void mdl_bolt( World *world, Player *player, Fight *fight,
                       Renderer *rdr, MdlEnt far *ent )
{
    BspVec3 org, fin, d;
    TraceResult tr;
    float l;

    org = ent->pos;
    org.z += SHAMBLER_BOLT_UP;
    d.x = player->pos.x - org.x;
    d.y = player->pos.y - org.y;
    d.z = player->pos.z + SHAMBLER_BOLT_AIM - org.z;
    l = (float) sqrt( d.x*d.x + d.y*d.y + d.z*d.z );
    if ( l < 1.0f ) return;
    d.x /= l; d.y /= l; d.z /= l;
    fin.x = org.x + d.x * SHAMBLER_BOLT_RANGE;
    fin.y = org.y + d.y * SHAMBLER_BOLT_RANGE;
    fin.z = org.z + d.z * SHAMBLER_BOLT_RANGE;
    pl_trace( world, &org, &fin, &tr );
    if ( mdl_ray_player( &player->pos, &org, &d,
                          SHAMBLER_BOLT_RANGE * tr.frac ) >= 0.0f )
        pl_damage( fight, rdr, SHAMBLER_BOLT_DMG );
}

/* dog_leap2 and demon1_jump4: ai_face, a unit up, and the velocity */
static void mdl_leap( Fight *fight, MdlEnt far *ent,
                       float dx, float dy, float fwd, float up )
{
    ent->ideal_yaw = mdl_vectoyaw( dx, dy );
    ent->yaw = ent->ideal_yaw;
    ent->pos.z += 1.0f;
    ent->vel.x = (float) cos( ent->yaw * DEG2RAD ) * fwd;
    ent->vel.y = (float) sin( ent->yaw * DEG2RAD ) * fwd;
    ent->vel.z = up;
    ent->leapt = 0;
    ent->state = MDL_ST_LEAP;
    ent->anim_frame = 0;
    fight->leaps++;
}

/* CheckDogJump's and CheckDemonJump's height test: the player's body
   between a quarter and three quarters up the monster's */
static short mdl_leap_height( float dz )
{
    return (short) ( MDL_ZLO < dz + PL_ZLO + 0.75f * ( PL_ZHI - PL_ZLO ) &&
                     MDL_ZHI > dz + PL_ZLO + 0.25f * ( PL_ZHI - PL_ZLO ) );
}

void mdl_spawn( World *world, MdlEnt far *ent )
{
    BspVec3 fin;
    TraceResult tr;

    ent->ideal_yaw = ent->yaw;
    ent->next_think = 0.0f;
    ent->state = MDL_ST_STAND;
    ent->anim_frame = 0;
    ent->goal = ent->pos;
    ent->wander_ticks = 0;
    ent->hunting = 0;
    ent->next_attack = 0.0f;
    ent->flash_until = 0.0f;
    ent->pain_finished = 0.0f;
    ent->leapt = 0;
    ent->vel.x = ent->vel.y = ent->vel.z = 0.0f;

    /* walkmonster_start_go: a target is a path_corner, and th_walk at once */
    ent->corner = ent->patrol;
    if ( ent->corner >= 0 && ent->corner < world->corner_count ) {
        mdl_patrol_to( world, ent, ent->corner );
        ent->state = MDL_ST_RUN;
    }

    switch ( ent->kind ) {
    case MDL_KIND_KNIGHT:   ent->health = KNIGHT_HEALTH;   break;
    case MDL_KIND_DOG:      ent->health = DOG_HEALTH;      break;
    case MDL_KIND_OGRE:     ent->health = OGRE_HEALTH;     break;
    case MDL_KIND_DEMON:    ent->health = DEMON_HEALTH;    break;
    case MDL_KIND_ZOMBIE:   ent->health = ZOMBIE_HEALTH;   break;
    case MDL_KIND_WIZARD:   ent->health = WIZARD_HEALTH;   break;
    case MDL_KIND_SHAMBLER: ent->health = SHAMBLER_HEALTH; break;
    default:                ent->health = MDL_HEALTH;      break;
    }

    /* staggered: a row of monsters spawned in one tick would otherwise
       all pick their first wander goal on the same think */
    ent->stand_until = mdl_rnd() * MDL_STAND_MAX;

    /* droptofloor. The map puts a monster at its own origin, which can
       be well above the floor, and nothing here has gravity: without
       this it stands in mid-air for ever, since mdl_movestep's own
       +-STEPSIZE band only finds a floor already within 18 units. */
    fin = ent->pos;
    fin.z -= 256.0f;
    pl_trace( world, &ent->pos, &fin, &tr );
    /* flymonster_start_go: a flyer stays where the map put it */
    if ( ent->kind != MDL_KIND_WIZARD && tr.frac < 1.0f && !tr.all_solid )
        ent->pos = tr.end_pos;
    ent->spawn = ent->pos;
}

void mdl_think( World *world, Player *player, Fight *fight, Renderer *rdr,
                 MdlEnt far *ent, MdlState *m, short can_chase )
{
    BspVec3 goal, fin;
    TraceResult tr;
    float dist = 0.0f, dx, dy, dz, d2, chance, thr;
    short knight, dog, ogre, demon, zombie, wizard, shambler, dmg;

    if ( !m->loaded ) return;
    if ( rdr->anim_time < ent->next_think ) return;
    ent->next_think = rdr->anim_time + 0.1f;

    knight   = (short) ( ent->kind == MDL_KIND_KNIGHT );
    dog      = (short) ( ent->kind == MDL_KIND_DOG );
    ogre     = (short) ( ent->kind == MDL_KIND_OGRE );
    demon    = (short) ( ent->kind == MDL_KIND_DEMON );
    zombie   = (short) ( ent->kind == MDL_KIND_ZOMBIE );
    wizard   = (short) ( ent->kind == MDL_KIND_WIZARD );
    shambler = (short) ( ent->kind == MDL_KIND_SHAMBLER );

    /* Dead: the death frames once, then a corpse. */
    if ( ent->state == MDL_ST_DEAD ) {
        if ( ent->anim_frame < m->ndeath - 1 ) ent->anim_frame++;
        return;
    }

    /* Hit: the flinch, then the hunt. */
    if ( ent->state == MDL_ST_PAIN ) {
        /* a dropped zombie lies on its last pain frame until it may rise */
        if ( zombie && ent->anim_frame >= m->npain - 1 &&
             rdr->anim_time < ent->pain_finished ) return;
        ent->anim_frame++;
        if ( ent->anim_frame >= m->npain ) {
            ent->state = MDL_ST_RUN;
            ent->anim_frame = 0;
        }
        return;
    }

    /* The attack set, facing the player: the knight's and the demon's
       charge the frame's distance and strike on their own frames. The
       ogre's grenade, the zombie's gib and the wizard's spikes want the
       projectile array the weapons subsystem owns, so those sets play
       their frames and throw nothing yet. */
    if ( ent->state == MDL_ST_ATTACK ) {
        ent->ideal_yaw = mdl_vectoyaw( player->pos.x - ent->pos.x,
                                        player->pos.y - ent->pos.y );
        mdl_change_yaw( ent );
        if ( knight && ent->anim_frame < 10 ) dist = knight_atk_dist[ ent->anim_frame ];
        if ( demon  && ent->anim_frame < 15 ) dist = demon_atk_dist[ ent->anim_frame ];
        if ( dist > 0.0f )
            mdl_movestep( world, player, ent,
                           (float) cos( ent->yaw * DEG2RAD ) * dist,
                           (float) sin( ent->yaw * DEG2RAD ) * dist );

        if ( knight && ent->anim_frame >= KNIGHT_ATK_FIRST &&
                        ent->anim_frame <= KNIGHT_ATK_LAST &&
             mdl_in_reach( player, ent, KNIGHT_MELEE_RANGE ) ) {
            dmg = (short) ( ( mdl_rnd() + mdl_rnd() + mdl_rnd() ) * KNIGHT_MELEE_DMG );
            if ( dmg > 0 ) pl_damage( fight, rdr, dmg );
        }
        if ( demon && ( ent->anim_frame == DEMON_CLAW_A || ent->anim_frame == DEMON_CLAW_B ) &&
             mdl_in_reach( player, ent, DEMON_CLAW_RANGE ) )
            pl_damage( fight, rdr,
                        (short) ( DEMON_CLAW_BASE + (short) ( mdl_rnd() * DEMON_CLAW_DMG ) ) );
        if ( shambler && ( ent->anim_frame == SHAMBLER_BOLT_A ||
                            ent->anim_frame == SHAMBLER_BOLT_B ||
                            ent->anim_frame == SHAMBLER_BOLT_C ) )
            mdl_bolt( world, player, fight, rdr, ent );

        ent->anim_frame++;
        /* knight_atk10 is the last frame id uses; attackb11 is in the file */
        if ( ent->anim_frame >= m->natk || ( knight && ent->anim_frame > 9 ) ) {
            ent->state = MDL_ST_RUN;
            ent->anim_frame = 0;
        }
        return;
    }

    /* In the air: gravity on the velocity, a trace along it, and
       Dog_JumpTouch. A stop while falling is the ground; one while
       rising is a wall, and the leaper drops down it. */
    if ( ent->state == MDL_ST_LEAP ) {
        ent->vel.z -= fight->gravity * 0.1f;
        fin.x = ent->pos.x + ent->vel.x * 0.1f;
        fin.y = ent->pos.y + ent->vel.y * 0.1f;
        fin.z = ent->pos.z + ent->vel.z * 0.1f;
        pl_trace( world, &ent->pos, &fin, &tr );
        ent->pos = tr.end_pos;
        if ( !ent->leapt ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            if ( fabs( dx ) < MDL_HALF + PL_HALF && fabs( dy ) < MDL_HALF + PL_HALF &&
                 fabs( dz ) < MDL_ZHI - PL_ZLO ) {
                thr = demon ? DEMON_LEAP_TOUCH : DOG_LEAP_SPEED;
                if ( ent->vel.x * ent->vel.x + ent->vel.y * ent->vel.y +
                     ent->vel.z * ent->vel.z > thr * thr ) {
                    pl_damage( fight, rdr, demon
                        ? (short) ( DEMON_LEAP_DMG + mdl_rnd() * 10.0f )
                        : (short) ( DOG_LEAP_DMG + mdl_rnd() * DOG_LEAP_DMG ) );
                    ent->leapt = -1;
                }
            }
        }
        if ( tr.frac < 1.0f ) {
            if ( ent->vel.z <= 0.0f ) {
                ent->state = MDL_ST_RUN;
                ent->anim_frame = 0;
                return;
            }
            ent->vel.x = ent->vel.y = 0.0f;
        }
        ent->anim_frame = (short) ( ( ent->anim_frame + 1 ) % m->nrun );
        return;
    }

    if ( ent->state == MDL_ST_STAND ) {
        if ( can_chase && mdl_find_target( world, player, fight, rdr, ent ) ) {
            ent->hunting = -1;
            ent->state = MDL_ST_RUN;
            ent->anim_frame = 0;
            ent->wander_ticks = 0;
        } else if ( rdr->anim_time >= ent->stand_until ) {
            if ( ent->corner >= 0 ) {
                mdl_patrol_to( world, ent, ent->corner );
            } else {
                mdl_pick_goal( ent );
                ent->ideal_yaw = mdl_vectoyaw( ent->goal.x - ent->pos.x,
                                                ent->goal.y - ent->pos.y );
            }
            ent->state = MDL_ST_RUN;
            ent->anim_frame = 0;
            ent->wander_ticks = 0;
        } else {
            ent->anim_frame = (short) ( ( ent->anim_frame + 1 ) % m->nstand );
        }
        return;
    }

    switch ( ent->kind ) {
    case MDL_KIND_KNIGHT:   dist = knight_run_dist[ ent->anim_frame % 8 ]; break;
    case MDL_KIND_DOG:      dist = dog_run_dist[ ent->anim_frame % 12 ]; break;
    case MDL_KIND_OGRE:     dist = ogre_run_dist[ ent->anim_frame % 8 ]; break;
    case MDL_KIND_DEMON:    dist = demon_run_dist[ ent->anim_frame % 6 ]; break;
    case MDL_KIND_ZOMBIE:   dist = zombie_run_dist[ ent->anim_frame % 8 ]; break;
    case MDL_KIND_WIZARD:   dist = WIZARD_FLY_DIST; break;
    case MDL_KIND_SHAMBLER: dist = shambler_run_dist[ ent->anim_frame % 6 ]; break;
    default:                dist = army_run_dist[ ent->anim_frame % 8 ]; break;
    }

    goal = player->pos;
    if ( ent->hunting && knight ) {
        /* CheckAttack for a monster with th_melee only: in RANGE_MELEE
           with a clear line, the sword instead of a step. */
        if ( mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            if ( dx*dx + dy*dy + dz*dz < MDL_RANGE_MELEE * MDL_RANGE_MELEE ) {
                ent->state = MDL_ST_ATTACK;
                ent->anim_frame = 0;
                return;
            }
        }
    } else if ( ent->hunting && dog ) {
        /* DogCheckAttack: dog_bite on the run within range, once an
           attack cycle -- no attack set fits the page -- else the leap,
           CheckDogJump's 80 to 150 level with the body at its height. */
        if ( rdr->anim_time >= ent->next_attack &&
             mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            if ( dx*dx + dy*dy + dz*dz < DOG_BITE_RANGE * DOG_BITE_RANGE ) {
                ent->next_attack = rdr->anim_time + DOG_BITE_RATE;
                dmg = (short) ( ( mdl_rnd() + mdl_rnd() + mdl_rnd() ) * DOG_BITE_DMG );
                if ( dmg > 0 ) pl_damage( fight, rdr, dmg );
            } else if ( dx*dx + dy*dy > DOG_LEAP_MIN * DOG_LEAP_MIN &&
                        dx*dx + dy*dy < DOG_LEAP_MAX * DOG_LEAP_MAX &&
                        mdl_leap_height( dz ) ) {
                mdl_leap( fight, ent, dx, dy, DOG_LEAP_SPEED, DOG_LEAP_UP );
                ent->next_attack = rdr->anim_time + DOG_BITE_RATE;
                return;
            }
        }
    } else if ( ent->hunting && ogre ) {
        /* CheckAttack with a th_melee: the chainsaw on the run in
           RANGE_MELEE -- swing5..11's (r+r+r)*4 every other think -- and
           past it the grenade, which nothing throws yet. */
        if ( mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            d2 = dx*dx + dy*dy + dz*dz;
            if ( d2 < MDL_RANGE_MELEE * MDL_RANGE_MELEE ) {
                if ( rdr->anim_time >= ent->next_attack )
                    ent->next_attack = rdr->anim_time + OGRE_SWING;
                if ( ( ent->anim_frame & 1 ) && mdl_in_reach( player, ent, OGRE_SAW_RANGE ) ) {
                    dmg = (short) ( ( mdl_rnd() + mdl_rnd() + mdl_rnd() ) * OGRE_SAW_DMG );
                    if ( dmg > 0 ) pl_damage( fight, rdr, dmg );
                }
            } else if ( rdr->anim_time >= ent->next_attack ) {
                chance = MDL_ATK_MID;
                if ( d2 < MDL_RANGE_NEAR * MDL_RANGE_NEAR ) chance = MDL_ATK_NEAR_MELEE;
                if ( d2 >= MDL_RANGE_MID * MDL_RANGE_MID )  chance = 0.0f;
                if ( mdl_rnd() < chance ) {
                    ent->next_attack = rdr->anim_time + 2.0f * mdl_rnd();
                    ent->state = MDL_ST_ATTACK;
                    ent->anim_frame = 0;
                    return;
                }
            }
        }
    } else if ( ent->hunting && demon ) {
        /* DemonCheckAttack: the claws in RANGE_MELEE, else the leap. */
        if ( mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            if ( dx*dx + dy*dy + dz*dz < MDL_RANGE_MELEE * MDL_RANGE_MELEE ) {
                ent->state = MDL_ST_ATTACK;
                ent->anim_frame = 0;
                return;
            } else if ( rdr->anim_time >= ent->next_attack ) {
                d2 = dx*dx + dy*dy;
                if ( d2 > DEMON_LEAP_MIN * DEMON_LEAP_MIN &&
                     ( d2 < DEMON_LEAP_MAX * DEMON_LEAP_MAX || mdl_rnd() < 0.1f ) &&
                     mdl_leap_height( dz ) ) {
                    mdl_leap( fight, ent, dx, dy, DEMON_LEAP_SPEED, DEMON_LEAP_UP );
                    ent->next_attack = rdr->anim_time + 2.0f * mdl_rnd();
                    return;
                }
            }
        }
    } else if ( ent->hunting && shambler ) {
        /* ShamCheckAttack: the smash in RANGE_MELEE, else the lightning. */
        if ( mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            d2 = dx*dx + dy*dy + dz*dz;
            if ( d2 < MDL_RANGE_MELEE * MDL_RANGE_MELEE ) {
                if ( rdr->anim_time >= ent->next_attack ) {
                    ent->next_attack = rdr->anim_time + SHAMBLER_SMASH;
                    dmg = (short) ( ( mdl_rnd() + mdl_rnd() + mdl_rnd() ) * SHAMBLER_SMASH_DMG );
                    if ( dmg > 0 ) pl_damage( fight, rdr, dmg );
                }
            } else if ( rdr->anim_time >= ent->next_attack &&
                        d2 < SHAMBLER_BOLT_RANGE * SHAMBLER_BOLT_RANGE ) {
                ent->next_attack = rdr->anim_time + SHAMBLER_ATK_WAIT + 2.0f * mdl_rnd();
                ent->state = MDL_ST_ATTACK;
                ent->anim_frame = 0;
                return;
            }
        }
    } else if ( ent->hunting && ( zombie || wizard ) ) {
        /* CheckAttack with a th_missile alone, and WizardCheckAttack:
           a clear line, ready, and a chance by range. */
        if ( rdr->anim_time >= ent->next_attack &&
             mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            d2 = dx*dx + dy*dy + dz*dz;
            if ( d2 < MDL_RANGE_MELEE * MDL_RANGE_MELEE )
                chance = MDL_ATK_MELEE;
            else if ( d2 < MDL_RANGE_NEAR * MDL_RANGE_NEAR )
                chance = wizard ? WIZARD_ATK_NEAR : ZOMBIE_ATK_NEAR;
            else if ( d2 < MDL_RANGE_MID * MDL_RANGE_MID )
                chance = wizard ? WIZARD_ATK_MID : ZOMBIE_ATK_MID;
            else
                chance = 0.0f;
            if ( mdl_rnd() < chance ) {
                ent->next_attack = rdr->anim_time +
                    ( wizard ? WIZARD_ATK_WAIT : 2.0f * mdl_rnd() );
                ent->state = MDL_ST_ATTACK;
                ent->anim_frame = 0;
                return;
            }
        }
    } else if ( ent->hunting ) {
        /* SoldierCheckAttack: a clear line, attack_finished passed, and
           a chance by range each think; then army_fire and 1 + random(). */
        if ( rdr->anim_time >= ent->next_attack &&
             mdl_find_target( world, player, fight, rdr, ent ) ) {
            dx = player->pos.x - ent->pos.x;
            dy = player->pos.y - ent->pos.y;
            dz = player->pos.z - ent->pos.z;
            d2 = dx*dx + dy*dy + dz*dz;
            if ( d2 < MDL_RANGE_MELEE * MDL_RANGE_MELEE )     chance = MDL_ATK_MELEE;
            else if ( d2 < MDL_RANGE_NEAR * MDL_RANGE_NEAR )  chance = MDL_ATK_NEAR;
            else if ( d2 < MDL_RANGE_MID * MDL_RANGE_MID )    chance = MDL_ATK_MID;
            else                                              chance = 0.0f;
            if ( mdl_rnd() < chance ) {
                ent->next_attack = rdr->anim_time + 1.0f + mdl_rnd();
                ent->flash_until = rdr->anim_time + MDL_FLASH;
                mdl_fire( world, player, fight, rdr, ent );
            }
        }
    } else {
        /* ai_walk: FindTarget every frame of the walk too; HuntTarget
           then starts the run cycle and the step is skipped */
        if ( can_chase && mdl_find_target( world, player, fight, rdr, ent ) ) {
            ent->hunting = -1;
            ent->anim_frame = 0;
            return;
        }
        goal = ent->goal;
        if ( ent->corner >= 0 ) dist = MDL_PATROL_STEP;
    }

    mdl_move_to_goal( world, player, ent, &goal, dist );
    ent->anim_frame = (short) ( ( ent->anim_frame + 1 ) % m->nrun );

    /* t_movetarget: at the corner, its wait standing, then the next; a
       corner with no target is stood at for good. */
    if ( !ent->hunting && ent->corner >= 0 ) {
        dx = ent->pos.x - ent->goal.x;
        dy = ent->pos.y - ent->goal.y;
        if ( dx*dx + dy*dy < MDL_WANDER_ARRIVE * MDL_WANDER_ARRIVE ) {
            PathCorner far *c = &world->corner[ ent->corner ];
            if ( c->nxt < 0 ) {
                ent->corner = -1;
                ent->state = MDL_ST_STAND;
                ent->stand_until = 1.0e9f;
            } else if ( c->wait > 0.0f ) {
                ent->corner = c->nxt;
                ent->state = MDL_ST_STAND;
                ent->stand_until = rdr->anim_time + c->wait;
            } else {
                mdl_patrol_to( world, ent, c->nxt );
            }
            ent->anim_frame = 0;
        }
        return;
    }

    /* The wander rests on arrival, or gives up -- the same compass
       search a real chase can also fail to route around. A hunt does
       neither, which is why this is gated on hunting. */
    if ( !ent->hunting ) {
        ent->wander_ticks++;
        dx = ent->pos.x - ent->goal.x;
        dy = ent->pos.y - ent->goal.y;
        if ( dx*dx + dy*dy < MDL_WANDER_ARRIVE * MDL_WANDER_ARRIVE ||
             ent->wander_ticks >= MDL_WANDER_MAXTICKS ) {
            ent->state = MDL_ST_STAND;
            ent->anim_frame = 0;
            ent->stand_until = rdr->anim_time + MDL_STAND_MIN +
                                mdl_rnd() * ( MDL_STAND_MAX - MDL_STAND_MIN );
        }
    }
}

/* What the AI actually did this run, for a headless assertion: a frame
   cannot show a monster hunting, and a still one cannot be told from a
   working one that had nobody to chase. */
void mdl_ai_stats( World *world, short *hunting, short *moved )
{
    short i, h = 0, mv = 0;

    for ( i = 0; i < world->mon_count; i++ ) {
        MdlEnt far *e = &world->mon[i];
        float dx = e->pos.x - e->spawn.x, dy = e->pos.y - e->spawn.y;
        if ( e->hunting ) h++;
        if ( dx*dx + dy*dy > 32.0f * 32.0f ) mv++;
    }
    *hunting = h;
    *moved = mv;
}

void mdl_tick( World *world, Player *player, Fight *fight, Renderer *rdr )
{
    short i;

    if ( rdr->no_ai ) return;
    for ( i = 0; i < world->mon_count; i++ ) {
        MdlState *m = mdl_of( world, world->mon[i].kind );
        if ( m ) mdl_think( world, player, fight, rdr, &world->mon[i], m, -1 );
    }
}
