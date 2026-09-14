/*
 * weapons.c -- weapons.qc's W_Fire*, everything in flight, and the
 * monster's side of taking a hit. The shotguns are hitscan and land
 * their damage per monster once every pellet is in (ApplyMultiDamage);
 * the other four leave a Spike that pl_spikes_tick walks a step at a
 * time.
 *
 * A projectile is traced through hull 1, the player's, so a wall stops
 * it 16 units early -- which is why everything that can be shot is
 * tested to bt + PL_HALF rather than to where the trace stopped. A
 * hostile spike is the exception: it leaves from a point inside hull
 * 1's grown solid, so it walks as a point through hull 0.
 */

#include <math.h>
#include <stdlib.h>

#include "weapons.h"
#include "snd.h"
#include "mdl_ai.h"
#include "pl_trace.h"
#include "item.h"
#include "ent_move.h"
#include "dl.h"

#define DEG2RAD 0.017453293f

static float fg_rnd( void )
{
    return (float) rand() / ( (float) RAND_MAX + 1.0f );
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

float pl_ray_box( BspVec3 *mins, BspVec3 *maxs, BspVec3 *org,
                   BspVec3 *dir, float maxt )
{
    float tn = 0.0f, tf = maxt;

    if ( !mdl_slab( mins->x, maxs->x, org->x, dir->x, &tn, &tf ) ) return -1.0f;
    if ( !mdl_slab( mins->y, maxs->y, org->y, dir->y, &tn, &tf ) ) return -1.0f;
    if ( !mdl_slab( mins->z, maxs->z, org->z, dir->z, &tn, &tf ) ) return -1.0f;
    return tn;
}

float mdl_ray_player( BspVec3 *pl, BspVec3 *org, BspVec3 *dir, float maxt )
{
    BspVec3 mins, maxs;

    mins.x = pl->x - PL_HALF; maxs.x = pl->x + PL_HALF;
    mins.y = pl->y - PL_HALF; maxs.y = pl->y + PL_HALF;
    mins.z = pl->z + PL_ZLO;  maxs.z = pl->z + PL_ZHI;
    return pl_ray_box( &mins, &maxs, org, dir, maxt );
}

/* a monster's box, the one the model is culled with */
static float mdl_ray_box( BspVec3 far *c, BspVec3 *org, BspVec3 *dir, float maxt )
{
    BspVec3 mins, maxs;

    mins.x = c->x - MDL_HALF; maxs.x = c->x + MDL_HALF;
    mins.y = c->y - MDL_HALF; maxs.y = c->y + MDL_HALF;
    mins.z = c->z + MDL_ZLO;  maxs.z = c->z + MDL_ZHI;
    return pl_ray_box( &mins, &maxs, org, dir, maxt );
}

/* an exploding box: its brush plus the touch slack, as a shootable
   door's is */
static float pl_box_ray( BspVec3 far *at, BspVec3 *org, BspVec3 *dir, float maxt )
{
    BspVec3 mins, maxs;

    mins.x = at->x - ENT_BOX_HALF - ENT_TOUCH_SLACK;
    maxs.x = at->x + ENT_BOX_HALF + ENT_TOUCH_SLACK;
    mins.y = at->y - ENT_BOX_HALF - ENT_TOUCH_SLACK;
    maxs.y = at->y + ENT_BOX_HALF + ENT_TOUCH_SLACK;
    mins.z = at->z - ENT_TOUCH_SLACK;
    maxs.z = at->z + ENT_BOX_TOP + ENT_TOUCH_SLACK;
    return pl_ray_box( &mins, &maxs, org, dir, maxt );
}

void pl_spread_dir( BspVec3 *dir, float sx, float sy, BspVec3 *out )
{
    float rx = dir->y, ry = -dir->x, rl;
    float ux, uy, uz, a, b;

    rl = (float) sqrt( rx*rx + ry*ry );
    if ( rl < 0.001f ) { rx = 1.0f; ry = 0.0f; rl = 1.0f; }
    rx /= rl; ry /= rl;
    ux =  ry * dir->z;
    uy = -rx * dir->z;
    uz =  rx * dir->y - ry * dir->x;
    a = ( 2.0f * fg_rnd() - 1.0f ) * sx;
    b = ( 2.0f * fg_rnd() - 1.0f ) * sy;
    out->x = dir->x + a * rx + b * ux;
    out->y = dir->y + a * ry + b * uy;
    out->z = dir->z + b * uz;
}

short pl_nail_free( Fight *fight )
{
    short n;

    for ( n = 0; n < PL_NAILS_MAX; n++ )
        if ( !fight->nail[n].alive ) {
            fight->nail[n].hostile = 0;
            fight->nail[n].grenade = 0;
            fight->nail[n].gib     = 0;
            fight->nail[n].rocket  = 0;
            fight->nail[n].toss    = 0;
            fight->nail[n].wiz     = 0;
            fight->nail[n].water   = 0;
            return n;
        }
    return -1;
}

/* each kind's die: under this it gibs, and udeath is its sound. The
   zombie always gibs, and its death sound is z_gib already. */
static short mdl_gib_below[8] = { -35, -40, -35, -80, -80, 1, -40, -60 };

void mdl_damage( World *world, Player *player, Fight *fight, Renderer *rdr,
                  MdlEnt far *ent, short dmg )
{
    float r;

    ent->health = (short) ( ent->health - dmg );
    if ( ent->health <= 0 ) {
        ent->state = MDL_ST_DEAD;
        ent->anim_frame = 0;
        if ( ent->kind != MDL_KIND_ZOMBIE && ent->health < mdl_gib_below[ ent->kind ] )
            mdl_voice( player, ent, CHAN_VOICE, SND_UDEATH, ATTN_NORM );
        else
            mdl_say( player, ent, 3 );
        fight->kills++;
        if ( ent->kind == MDL_KIND_ARMY )
            pl_item_add( world, ENT_ITEM_SHELLS, ENT_BACKPACK, &ent->pos );
        return;
    }
    ent->hunting = -1;
    ent->ideal_yaw = mdl_vectoyaw( player->pos.x - ent->pos.x,
                                    player->pos.y - ent->pos.y );

    if ( ent->kind == MDL_KIND_ZOMBIE ) {
        /* zombie_pain: z_pain at every hit, the health always back, so
           only one hit of 60 kills; under 9 ignored, 25 or more drops it
           for three seconds. Half the flinches are painb and painc, whose
           frames say z_pain1. */
        ent->health = ZOMBIE_HEALTH;
        mdl_say( player, ent, 2 );
        if ( dmg < ZOMBIE_PAIN_MIN ) return;
        if ( rdr->anim_time < ent->pain_finished ) return;
        ent->pain_finished = rdr->anim_time +
            ( dmg >= ZOMBIE_FALL_DMG ? ZOMBIE_FALL_TIME : ZOMBIE_FLINCH );
        r = fg_rnd();
        if ( dmg < ZOMBIE_FALL_DMG && r >= 0.25f && r < 0.75f )
            mdl_voice( player, ent, CHAN_VOICE, SND_Z_PAIN1, ATTN_NORM );
        ent->state = MDL_ST_PAIN;
        ent->anim_frame = 0;
        return;
    }

    if ( rdr->anim_time < ent->pain_finished ) return;
    switch ( ent->kind ) {
    case MDL_KIND_KNIGHT:
    case MDL_KIND_OGRE:
    case MDL_KIND_DEMON:
        ent->pain_finished = rdr->anim_time + KNIGHT_PAIN;
        break;
    case MDL_KIND_SHAMBLER:
        ent->pain_finished = rdr->anim_time + SHAMBLER_PAIN;
        break;
    default:
        r = fg_rnd();
        ent->pain_finished = rdr->anim_time +
            ( r < MDL_PAIN_SHORT_P ? MDL_PAIN_SHORT : MDL_PAIN_LONG );
        /* army_pain: pain1 with the short flinch, pain2 with the others */
        if ( ent->kind == MDL_KIND_ARMY && r >= MDL_PAIN_SHORT_P ) {
            mdl_voice( player, ent, CHAN_VOICE, SND_ARMY_PAIN2, ATTN_NORM );
            ent->state = MDL_ST_PAIN;
            ent->anim_frame = 0;
            return;
        }
        break;
    }
    mdl_say( player, ent, 2 );
    /* demon1_pain and sham_pain: a hit under the roll does not flinch */
    if ( ent->kind == MDL_KIND_DEMON   && fg_rnd() * 200.0f > dmg ) return;
    if ( ent->kind == MDL_KIND_SHAMBLER && fg_rnd() * SHAMBLER_PAIN_ROLL > dmg ) return;

    ent->state = MDL_ST_PAIN;
    ent->anim_frame = 0;
}

/* barrel_explode: 160 from the box's centre, less half the distance, to
   the player through the armor and to every monster standing --
   CanDamage's line is not asked. */
static void pl_box_hit( World *world, Player *player, Fight *fight,
                         Renderer *rdr, short i, short dmg )
{
    ItemEnt far *it = &world->item[i];
    BspVec3 c;
    float dx, dy, dz, pts;
    short m;

    it->amount = (short) ( it->amount - dmg );
    if ( it->amount > 0 ) return;
    it->gone = -1;
    fight->booms++;

    c = it->pos;
    c.z += ENT_BOX_TOP * 0.5f;
    snd_play( player, SND_BOOM, &c );
    dl_explosion( rdr, &c );
    dx = player->pos.x - c.x;
    dy = player->pos.y - c.y;
    dz = player->pos.z + ( PL_ZLO + PL_ZHI ) * 0.5f - c.z;
    pts = ENT_BOX_DMG - 0.5f * (float) sqrt( dx*dx + dy*dy + dz*dz );
    if ( pts > 0.0f ) pl_damage( player, fight, rdr, (short) pts );

    for ( m = 0; m < world->mon_count; m++ ) {
        MdlEnt far *e = &world->mon[m];
        if ( e->state == MDL_ST_DEAD ) continue;
        dx = e->pos.x - c.x;
        dy = e->pos.y - c.y;
        dz = e->pos.z + ( MDL_ZLO + MDL_ZHI ) * 0.5f - c.z;
        pts = ENT_BOX_DMG - 0.5f * (float) sqrt( dx*dx + dy*dy + dz*dz );
        if ( pts > 0.0f ) mdl_damage( world, player, fight, rdr, e, (short) pts );
    }
}

/* GrenadeExplode: T_RadiusDamage from where it lies, the blast less
   half the distance. The player's own hurts them half (head ==
   attacker) and reaches every monster; a monster's spares them, having
   no owner to spare from. */
static void pl_grenade_explode( World *world, Player *player, Fight *fight,
                                 Renderer *rdr, Spike *s )
{
    float dx, dy, dz, pts;
    short m;

    s->alive = 0;
    snd_play( player, SND_BOOM, &s->pos );
    dl_explosion( rdr, &s->pos );
    dx = player->pos.x - s->pos.x;
    dy = player->pos.y - s->pos.y;
    dz = player->pos.z + ( PL_ZLO + PL_ZHI ) * 0.5f - s->pos.z;
    pts = s->dmg - 0.5f * (float) sqrt( dx*dx + dy*dy + dz*dz );
    if ( !s->hostile ) pts *= 0.5f;
    if ( pts > 0.0f ) pl_damage( player, fight, rdr, (short) pts );
    if ( s->hostile ) return;

    for ( m = 0; m < world->mon_count; m++ ) {
        MdlEnt far *e = &world->mon[m];
        if ( e->state == MDL_ST_DEAD ) continue;
        dx = e->pos.x - s->pos.x;
        dy = e->pos.y - s->pos.y;
        dz = e->pos.z + ( MDL_ZLO + MDL_ZHI ) * 0.5f - s->pos.z;
        pts = s->dmg - 0.5f * (float) sqrt( dx*dx + dy*dy + dz*dz );
        if ( pts > 0.0f ) mdl_damage( world, player, fight, rdr, e, (short) pts );
    }
}

/* Whatever a shot can set off short of where the pellet stopped: an
   exploding box, a shootable trigger, a secret door. Shared by the
   pellets and the nails, and the reason both reach bt + PL_HALF. */
static void pl_shot_touch( World *world, Player *player, Fight *fight,
                            Renderer *rdr, BspVec3 *org, BspVec3 *dir,
                            float bt, short dmg, short *stopped )
{
    short i;

    for ( i = 0; i < world->item_count; i++ )
        if ( world->item[i].kind == ENT_ITEM_EXPLOBOX && !world->item[i].gone &&
             pl_box_ray( &world->item[i].pos, org, dir, bt + PL_HALF ) >= 0.0f ) {
            pl_box_hit( world, player, fight, rdr, i, dmg );
            if ( stopped ) *stopped = -1;
        }

    for ( i = 0; i < world->trig_count; i++ )
        if ( world->trig[i].kind == ENT_TRIG_SHOOT &&
             world->trig[i].state == ENT_TRIG_READY &&
             pl_ray_box( (BspVec3 *) &world->trig[i].mins,
                          (BspVec3 *) &world->trig[i].maxs, org, dir,
                          bt + PL_HALF ) >= 0.0f ) {
            ent_trig_fire( world, player, fight, rdr, i );
            if ( stopped ) *stopped = -1;
        }

    for ( i = 0; i < world->door_count; i++ )
        if ( world->door[i].shoot && world->door[i].state == ENT_DOOR_SHUT &&
             pl_ray_box( (BspVec3 *) &world->door[i].mins,
                          (BspVec3 *) &world->door[i].maxs, org, dir,
                          bt + PL_HALF ) >= 0.0f ) {
            ent_door_fire( world, player, world->door[i].link );
            if ( stopped ) *stopped = -1;
        }
}

/* EF_MUZZLEFLASH on the player. The relink turns the player entity's
   angles, whose pitch is the view's over -3, through AngleVectors, which
   reads pitch the view's way: so looking down lifts the light. */
static void pl_muzzle_light( Player *player, Camera *cam, Renderer *rdr )
{
    BspVec3 fwd;
    float ax = cam->look_at.x - cam->pos.x;
    float ay = cam->look_at.z - cam->pos.z;   /* renderer z is bsp y */
    float az = cam->look_at.y - cam->pos.y;
    float h  = (float) sqrt( ax*ax + ay*ay );
    float p  = (float) atan2( az, h ) / 3.0f;

    if ( h < 0.001f ) { ax = 1.0f; ay = 0.0f; h = 1.0f; }
    fwd.x = ax / h * (float) cos( p );
    fwd.y = ay / h * (float) cos( p );
    fwd.z = (float) -sin( p );
    dl_muzzle( rdr, DL_KEY_PLAYER, &player->pos, &fwd );
}

/* CL_ParseTEnt's TE_SPIKE: a tink, one in five a ricochet */
static void pl_spike_hit( Player *player, BspVec3 *at )
{
    short r;

    if ( rand() % 5 ) { snd_play( player, SND_TINK, at ); return; }
    r = (short) ( rand() & 3 );
    snd_play( player, (short) ( r == 1 ? SND_RIC1 : r == 2 ? SND_RIC1 + 1 : SND_RIC1 + 2 ), at );
}

static void pl_fire_nail( Player *player, Camera *cam, Fight *fight, Renderer *rdr )
{
    BspVec3 aim;
    float rx, ry, rl;
    short i, super;

    if ( fight->nails <= 0 ) return;
    i = pl_nail_free( fight );
    if ( i < 0 ) return;

    /* W_FireSuperSpikes with two nails: both from the middle for 18.
       With one left the super nailgun fires as the nailgun. */
    super = (short) ( fight->weapon == PL_IT_SNG && fight->nails >= 2 );
    fight->next_fire = rdr->anim_time + PL_NG_RATE;
    fight->fire_at = rdr->anim_time;
    fight->show_hostile = rdr->anim_time + 1.0f;
    fight->flash_until = rdr->anim_time + 0.1f;
    pl_muzzle_light( player, cam, rdr );
    fight->nails =(short) ( fight->nails - ( super ? 2 : 1 ) );
    fight->nail_side = (short) ( -fight->nail_side - 1 );
    snd_self( player, CHAN_WEAPON, (short) ( super ? SND_SPIKE2 : SND_NAIL ) );

    aim.x = cam->look_at.x - cam->pos.x;
    aim.y = cam->look_at.z - cam->pos.z;   /* renderer z is bsp y */
    aim.z = cam->look_at.y - cam->pos.y;

    rx = aim.y; ry = -aim.x;
    rl = (float) sqrt( rx*rx + ry*ry );
    if ( rl < 0.001f ) { rx = 1.0f; ry = 0.0f; rl = 1.0f; }
    rx = rx / rl * PL_NG_OX;
    ry = ry / rl * PL_NG_OX;
    if ( fight->nail_side ) { rx = -rx; ry = -ry; }
    if ( super ) { rx = 0.0f; ry = 0.0f; }

    fight->nail[i].pos.x = player->pos.x + rx;
    fight->nail[i].pos.y = player->pos.y + ry;
    fight->nail[i].pos.z = player->pos.z + PL_NG_UP;
    fight->nail[i].vel.x = aim.x * PL_NG_SPEED;
    fight->nail[i].vel.y = aim.y * PL_NG_SPEED;
    fight->nail[i].vel.z = aim.z * PL_NG_SPEED;
    fight->nail[i].die_at = rdr->anim_time + PL_NG_LIFE;
    fight->nail[i].dmg = (short) ( super ? PL_SNG_DMG : PL_NG_DMG );
    fight->nail[i].alive = -1;
}

static void pl_fire_grenade( Player *player, Camera *cam, Fight *fight, Renderer *rdr )
{
    short i;

    if ( fight->rockets <= 0 ) return;
    i = pl_nail_free( fight );
    if ( i < 0 ) return;

    fight->next_fire = rdr->anim_time + PL_GL_RATE;
    fight->fire_at = rdr->anim_time;
    fight->show_hostile = rdr->anim_time + 1.0f;
    fight->rockets--;
    snd_self( player, CHAN_WEAPON, SND_GRENADE );
    pl_muzzle_light( player, cam, rdr );   /* player_rocket1, as the launcher's */

    fight->nail[i].pos = player->pos;
    fight->nail[i].vel.x = ( cam->look_at.x - cam->pos.x ) * PL_GL_SPEED;
    fight->nail[i].vel.y = ( cam->look_at.z - cam->pos.z ) * PL_GL_SPEED;
    fight->nail[i].vel.z = ( cam->look_at.y - cam->pos.y ) * PL_GL_SPEED + PL_GL_UP;
    fight->nail[i].die_at = rdr->anim_time + PL_GL_FUSE;
    fight->nail[i].grenade = -1;
    fight->nail[i].dmg = (short) ( rdr->anim_time < fight->quad_until
                                    ? PL_GL_DMG * PL_QUAD_MUL : PL_GL_DMG );
    fight->nail[i].alive = -1;
}

/* W_FireRocket, from the origin rather than id's 8 forward: aimed at
   the floor, those 8 units start it inside hull 1's grown solid and the
   trace then carries it through unstopped. */
static void pl_fire_rocket( Player *player, Camera *cam, Fight *fight, Renderer *rdr )
{
    BspVec3 aim;
    short i;

    if ( fight->rockets <= 0 ) return;
    i = pl_nail_free( fight );
    if ( i < 0 ) return;

    fight->next_fire = rdr->anim_time + PL_RL_RATE;
    fight->fire_at = rdr->anim_time;
    fight->show_hostile = rdr->anim_time + 1.0f;
    fight->flash_until = rdr->anim_time + 0.1f;
    pl_muzzle_light( player, cam, rdr );
    fight->rockets--;
    snd_self( player, CHAN_WEAPON, SND_ROCKET );

    aim.x = cam->look_at.x - cam->pos.x;
    aim.y = cam->look_at.z - cam->pos.z;
    aim.z = cam->look_at.y - cam->pos.y;

    fight->nail[i].pos = player->pos;
    fight->nail[i].vel.x = aim.x * PL_RL_SPEED;
    fight->nail[i].vel.y = aim.y * PL_RL_SPEED;
    fight->nail[i].vel.z = aim.z * PL_RL_SPEED;
    fight->nail[i].die_at = rdr->anim_time + PL_RL_LIFE;
    fight->nail[i].rocket = -1;
    fight->nail[i].dmg = (short) ( PL_RL_HIT + (short) ( fg_rnd() * PL_RL_HIT_RND ) );
    fight->nail[i].alive = -1;
}

void pl_fire( World *world, Player *player, Camera *cam, Fight *fight,
               Renderer *rdr )
{
    BspVec3 org, fin, aim, dir;
    TraceResult tr;
    short hit[MDL_MAX_ENTS];
    short i, p, best, npellet, pdmg;
    float t, bt, sx, sy, rate;

    if ( rdr->anim_time < fight->next_fire ) return;
    /* W_WeaponFrame's SuperDamageSound, a second apart */
    if ( rdr->anim_time < fight->quad_until && rdr->anim_time >= fight->quad_snd_at ) {
        fight->quad_snd_at = rdr->anim_time + 1.0f;
        snd_self( player, CHAN_BODY, SND_QUAD_SHOT );
    }
    if ( fight->weapon == PL_IT_NAILGUN || fight->weapon == PL_IT_SNG ) {
        pl_fire_nail( player, cam, fight, rdr );
        return;
    }
    if ( fight->weapon == PL_IT_GL ) { pl_fire_grenade( player, cam, fight, rdr ); return; }
    if ( fight->weapon == PL_IT_RL ) { pl_fire_rocket( player, cam, fight, rdr ); return; }
    if ( fight->shells <= 0 ) return;

    npellet = PL_PELLETS; sx = PL_SPREAD; sy = PL_SPREAD; rate = PL_FIRE_RATE;
    if ( fight->weapon == PL_IT_SSG ) {
        rate = PL_SSG_RATE;
        if ( fight->shells >= 2 ) {
            npellet = PL_SSG_PELLETS;
            sx = PL_SSG_SPREAD_X;
            sy = PL_SSG_SPREAD_Y;
            fight->shells--;
        }
    }
    fight->next_fire = rdr->anim_time + rate;
    fight->fire_at = rdr->anim_time;
    fight->show_hostile = rdr->anim_time + 1.0f;
    fight->flash_until = rdr->anim_time + 0.1f;
    pl_muzzle_light( player, cam, rdr );
    fight->shells--;
    snd_self( player, CHAN_WEAPON, (short) ( npellet == PL_SSG_PELLETS ? SND_SSG : SND_SHOTGUN ) );

    /* cam->look_at is the POINT the eye looks at by now -- a direction
       only inside v_update_camera -- one unit away in renderer space,
       y up: bsp y is renderer z and bsp z is renderer y. */
    aim.x = cam->look_at.x - cam->pos.x;
    aim.y = cam->look_at.z - cam->pos.z;
    aim.z = cam->look_at.y - cam->pos.y;
    org = player->pos;
    org.z += PL_EYE;

    for ( i = 0; i < world->mon_count && i < MDL_MAX_ENTS; i++ ) hit[i] = 0;

    for ( p = 0; p < npellet; p++ ) {
        pl_spread_dir( &aim, sx, sy, &dir );
        fin.x = org.x + dir.x * PL_SHOT_RANGE;
        fin.y = org.y + dir.y * PL_SHOT_RANGE;
        fin.z = org.z + dir.z * PL_SHOT_RANGE;
        pl_trace( world, &org, &fin, &tr );

        best = -1;
        bt = PL_SHOT_RANGE * tr.frac;
        for ( i = 0; i < world->mon_count && i < MDL_MAX_ENTS; i++ ) {
            if ( world->mon[i].state == MDL_ST_DEAD ) continue;
            t = mdl_ray_box( &world->mon[i].pos, &org, &dir, bt );
            if ( t >= 0.0f && t < bt ) { bt = t; best = i; }
        }
        pdmg = (short) ( rdr->anim_time < fight->quad_until
                          ? PL_PELLET_DMG * PL_QUAD_MUL : PL_PELLET_DMG );
        if ( best >= 0 ) hit[best] = (short) ( hit[best] + pdmg );

        pl_shot_touch( world, player, fight, rdr, &org, &dir, bt, pdmg, (short *) 0 );
    }

    for ( i = 0; i < world->mon_count && i < MDL_MAX_ENTS; i++ )
        if ( hit[i] > 0 )
            mdl_damage( world, player, fight, rdr, &world->mon[i], hit[i] );
}

void pl_select_weapon( Input *input, Fight *fight )
{
    Keys *k = &input->keyboard;

    if ( k->k[KEY_ONE] )                                   fight->weapon = PL_IT_SHOTGUN;
    if ( k->k[KEY_TWO] && ( fight->items & PL_IT_SSG ) )     fight->weapon = PL_IT_SSG;
    if ( k->k[KEY_THREE] && ( fight->items & PL_IT_NAILGUN ) ) fight->weapon = PL_IT_NAILGUN;
    if ( k->k[KEY_FOUR] && ( fight->items & PL_IT_GL ) )      fight->weapon = PL_IT_GL;
    if ( k->k[KEY_FIVE] && ( fight->items & PL_IT_SNG ) )     fight->weapon = PL_IT_SNG;
    if ( k->k[KEY_SIX] && ( fight->items & PL_IT_RL ) )      fight->weapon = PL_IT_RL;
}

/* MOVETYPE_BOUNCE, either side's: what it can hurt over the step blows
   it up (GrenadeTouch); else gravity, a hull-1 trace, the velocity off
   what it hits at ClipVelocity's 1.5, and SV_Physics_Toss lays it still
   on a floor under 60 up. */
static void pl_grenade_tick( World *world, Player *player, Fight *fight,
                              Renderer *rdr, Spike *s, float dt,
                              BspVec3 *dir, float reach )
{
    BspVec3 fin;
    TraceResult tr;
    float t, backoff;
    short i;

    if ( s->hostile ) {
        t = mdl_ray_player( &player->pos, &s->pos, dir, reach );
        if ( t >= 0.0f && s->gib ) {
            /* ZombieGrenadeTouch: z_hit on what bleeds; a spent one
               (SUB_Remove) just goes */
            if ( s->gib < 0 ) {
                pl_damage( player, fight, rdr, s->dmg );
                snd_play( player, SND_Z_HIT, &s->pos );
            }
            s->alive = 0;
            return;
        }
        if ( t >= 0.0f ) { pl_grenade_explode( world, player, fight, rdr, s ); return; }
    } else {
        for ( i = 0; i < world->mon_count; i++ ) {
            if ( world->mon[i].state == MDL_ST_DEAD ) continue;
            if ( mdl_ray_box( &world->mon[i].pos, &s->pos, dir, reach ) >= 0.0f ) {
                pl_grenade_explode( world, player, fight, rdr, s );
                return;
            }
        }
    }

    s->vel.z -= fight->gravity * dt;
    fin.x = s->pos.x + s->vel.x * dt;
    fin.y = s->pos.y + s->vel.y * dt;
    fin.z = s->pos.z + s->vel.z * dt;
    pl_trace( world, &s->pos, &fin, &tr );
    s->pos = tr.end_pos;
    if ( tr.frac >= 1.0f ) return;
    if ( s->gib ) {
        /* the miss's z_miss, and its touch is SUB_Remove from then */
        if ( s->gib > 0 ) { s->alive = 0; return; }
        snd_play( player, SND_Z_MISS, &s->pos );
        s->gib = 1;
        s->vel.x = s->vel.y = s->vel.z = 0.0f;
        return;
    }

    snd_play( player, SND_BOUNCE, &s->pos );
    backoff = ( s->vel.x * tr.norm.x + s->vel.y * tr.norm.y +
                s->vel.z * tr.norm.z ) * PL_BOUNCE;
    s->vel.x -= tr.norm.x * backoff;
    s->vel.y -= tr.norm.y * backoff;
    s->vel.z -= tr.norm.z * backoff;
    if ( tr.norm.z > 0.7f && s->vel.z < 60.0f )
        s->vel.x = s->vel.y = s->vel.z = 0.0f;
}

void pl_spikes_tick( World *world, Player *player, Fight *fight,
                      Renderer *rdr, float dt )
{
    BspVec3 fin, dir;
    TraceResult tr;
    float t, bt, reach, spd;
    short n, i, best, ndmg, stopped;

    for ( n = 0; n < PL_NAILS_MAX; n++ ) {
        Spike *s = &fight->nail[n];

        if ( !s->alive ) continue;
        /* SV_CheckWaterTransition, sky counting as a liquid as id's does */
        i = (short) ( pl_point_contents( &s->pos, world ) <= CONTENTS_WATER ? 1 : -1 );
        if ( s->water && s->water != i ) snd_play( player, SND_H2OHIT, &s->pos );
        s->water = i;
        if ( rdr->anim_time >= s->die_at ) {
            s->alive = 0;
            /* a grenade goes off on its fuse; a gib just stops */
            if ( s->grenade && !s->gib )
                pl_grenade_explode( world, player, fight, rdr, s );
            continue;
        }

        fin.x = s->pos.x + s->vel.x * dt;
        fin.y = s->pos.y + s->vel.y * dt;
        fin.z = s->pos.z + s->vel.z * dt;
        spd = (float) sqrt( s->vel.x*s->vel.x + s->vel.y*s->vel.y + s->vel.z*s->vel.z );
        if ( spd < 1.0f ) spd = 1.0f;
        reach = spd * dt;
        dir.x = s->vel.x / spd;
        dir.y = s->vel.y / spd;
        dir.z = s->vel.z / spd;

        if ( s->grenade ) {
            pl_grenade_tick( world, player, fight, rdr, s, dt, &dir, reach );
            continue;
        }

        if ( s->hostile ) {
            /* spike_touch. A trap's spike leaves from a point 8 units
               off its wall, inside hull 1's grown solid, so it walks as
               a point through hull 0: a step into solid ends it. */
            t = mdl_ray_player( &player->pos, &s->pos, &dir, reach );
            if ( s->toss ) s->vel.z -= fight->gravity * dt;
            if ( pl_point_contents( &fin, world ) == CONTENTS_SOLID ) {
                s->alive = 0;
                /* TE_WIZSPIKE or TE_SPIKE; a lava ball says nothing */
                if ( s->wiz ) snd_play( player, SND_WIZ_HIT, &s->pos );
                else if ( !s->toss ) pl_spike_hit( player, &s->pos );
            } else {
                if ( t >= 0.0f ) { pl_damage( player, fight, rdr, s->dmg ); s->alive = 0; }
                s->pos = fin;
            }
            continue;
        }

        pl_trace( world, &s->pos, &fin, &tr );
        bt = reach * tr.frac;
        best = -1;
        for ( i = 0; i < world->mon_count; i++ ) {
            if ( world->mon[i].state == MDL_ST_DEAD ) continue;
            t = mdl_ray_box( &world->mon[i].pos, &s->pos, &dir, bt );
            if ( t >= 0.0f && t < bt ) { bt = t; best = i; }
        }
        ndmg = (short) ( rdr->anim_time < fight->quad_until
                          ? s->dmg * PL_QUAD_MUL : s->dmg );
        if ( best >= 0 ) {
            mdl_damage( world, player, fight, rdr, &world->mon[best], ndmg );
            s->alive = 0;
        }

        stopped = 0;
        pl_shot_touch( world, player, fight, rdr, &s->pos, &dir, bt, ndmg, &stopped );
        if ( stopped ) s->alive = 0;
        if ( tr.frac < 1.0f ) {
            if ( s->alive && !s->rocket ) pl_spike_hit( player, &tr.end_pos );
            s->alive = 0;
        }

        if ( s->rocket && !s->alive ) {
            /* T_MissileTouch: the direct hit landed above; the blast is
               from where it stopped -- the monster met short of the
               step, or the wall. */
            s->pos.x += dir.x * bt;
            s->pos.y += dir.y * bt;
            s->pos.z += dir.z * bt;
            s->dmg = (short) ( rdr->anim_time < fight->quad_until
                                ? PL_RL_DMG * PL_QUAD_MUL : PL_RL_DMG );
            pl_grenade_explode( world, player, fight, rdr, s );
            continue;
        }
        if ( s->alive ) s->pos = tr.end_pos;
    }
}

void pl_traps_tick( World *world, Player *player, Fight *fight, Renderer *rdr )
{
    short k, n;

    for ( k = 0; k < world->trig_count; k++ ) {
        TrigEnt far *t = &world->trig[k];

        if ( t->kind == ENT_TRIG_SHOOTER && t->state == ENT_TRIG_ARMED ) {
            t->state = ENT_TRIG_READY;
            n = pl_nail_free( fight );
            if ( n < 0 ) continue;
            fight->nail[n].pos = t->mins;
            fight->nail[n].vel.x = t->ofs_out.x * t->speed;
            fight->nail[n].vel.y = t->ofs_out.y * t->speed;
            fight->nail[n].vel.z = t->ofs_out.z * t->speed;
            fight->nail[n].die_at = rdr->anim_time + PL_NG_LIFE;
            fight->nail[n].hostile = -1;
            fight->nail[n].dmg = t->count;
            fight->nail[n].alive = -1;
            snd_play( player, SND_SPIKE2, &fight->nail[n].pos );
        }
        if ( t->kind == ENT_TRIG_FIREBALL && t->state == ENT_TRIG_ARMED ) {
            /* fire_fly: up at speed plus up to 200, 50 either way
               across, five seconds; fire_touch bites 20 and is gone */
            t->state = ENT_TRIG_READY;
            n = pl_nail_free( fight );
            if ( n < 0 ) continue;
            fight->nail[n].pos = t->mins;
            fight->nail[n].vel.x = fg_rnd() * 100.0f - 50.0f;
            fight->nail[n].vel.y = fg_rnd() * 100.0f - 50.0f;
            fight->nail[n].vel.z = t->speed + fg_rnd() * 200.0f;
            fight->nail[n].die_at = rdr->anim_time + 5.0f;
            fight->nail[n].hostile = -1;
            fight->nail[n].toss = -1;
            fight->nail[n].dmg = PL_FIREBALL_DMG;
            fight->nail[n].alive = -1;
            t->left++;
        }
    }
}

/* Wiz_FastFire: a spike from 30 up, straight at the player at 600. */
void mdl_spike( World *world, Player *player, Fight *fight, Renderer *rdr,
                 MdlEnt far *ent )
{
    BspVec3 d;
    float l;
    short n;

    (void) world;
    n = pl_nail_free( fight );
    if ( n < 0 ) return;
    d.x = player->pos.x - ent->pos.x;
    d.y = player->pos.y - ent->pos.y;
    d.z = player->pos.z - ( ent->pos.z + WIZARD_SPIKE_Z );
    l = (float) sqrt( d.x*d.x + d.y*d.y + d.z*d.z );
    if ( l < 1.0f ) return;

    fight->nail[n].pos = ent->pos;
    fight->nail[n].pos.z += WIZARD_SPIKE_Z;
    fight->nail[n].vel.x = d.x / l * WIZARD_SPIKE_SPEED;
    fight->nail[n].vel.y = d.y / l * WIZARD_SPIKE_SPEED;
    fight->nail[n].vel.z = d.z / l * WIZARD_SPIKE_SPEED;
    fight->nail[n].die_at = rdr->anim_time + PL_NG_LIFE;
    fight->nail[n].hostile = -1;
    fight->nail[n].wiz = -1;
    fight->nail[n].dmg = WIZARD_SPIKE_DMG;
    fight->nail[n].alive = -1;
}

/* OgreFireGrenade: toward the player at 600 with 200 up. */
void mdl_grenade( Player *player, Fight *fight, Renderer *rdr, MdlEnt far *ent )
{
    BspVec3 d;
    float l;
    short n;

    n = pl_nail_free( fight );
    if ( n < 0 ) return;
    d.x = player->pos.x - ent->pos.x;
    d.y = player->pos.y - ent->pos.y;
    d.z = player->pos.z - ent->pos.z;
    l = (float) sqrt( d.x*d.x + d.y*d.y + d.z*d.z );
    if ( l < 1.0f ) return;

    fight->nail[n].pos = ent->pos;
    fight->nail[n].vel.x = d.x / l * OGRE_GREN_SPEED;
    fight->nail[n].vel.y = d.y / l * OGRE_GREN_SPEED;
    fight->nail[n].vel.z = OGRE_GREN_UP;
    fight->nail[n].die_at = rdr->anim_time + OGRE_GREN_FUSE;
    fight->nail[n].hostile = -1;
    fight->nail[n].grenade = -1;
    fight->nail[n].dmg = (short) OGRE_GREN_DMG;
    fight->nail[n].alive = -1;
    mdl_voice( player, ent, CHAN_WEAPON, SND_GRENADE, ATTN_NORM );
}

/* ZombieFireGrenade: 600 toward the player with 200 up, biting 10 where
   it lands and going out with no blast. */
void mdl_gib( Player *player, Fight *fight, Renderer *rdr, MdlEnt far *ent )
{
    BspVec3 d;
    float l;
    short n;

    n = pl_nail_free( fight );
    if ( n < 0 ) return;
    d.x = player->pos.x - ent->pos.x;
    d.y = player->pos.y - ent->pos.y;
    d.z = player->pos.z - ( ent->pos.z + ZOMBIE_GIB_Z );
    l = (float) sqrt( d.x*d.x + d.y*d.y + d.z*d.z );
    if ( l < 1.0f ) return;

    fight->nail[n].pos = ent->pos;
    fight->nail[n].pos.z += ZOMBIE_GIB_Z;
    fight->nail[n].vel.x = d.x / l * ZOMBIE_GIB_SPEED;
    fight->nail[n].vel.y = d.y / l * ZOMBIE_GIB_SPEED;
    fight->nail[n].vel.z = ZOMBIE_GIB_UP;
    fight->nail[n].die_at = rdr->anim_time + ZOMBIE_GIB_LIFE;
    fight->nail[n].hostile = -1;
    fight->nail[n].grenade = -1;
    fight->nail[n].gib = -1;
    fight->nail[n].dmg = ZOMBIE_GIB_DMG;
    fight->nail[n].alive = -1;
    mdl_say( player, ent, 1 );
}
