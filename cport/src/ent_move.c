/*
 * ent_move.c -- doors, triggers, buttons and trains, one tick at a time.
 *
 * Ported from ent.bas's door/trigger half and ent_door.c's two sweeps.
 * The BASIC split existed because a touch scan and a state machine over
 * descriptor-addressed arrays cost 0.408ms a tick on e1m6's 47 doors;
 * here World's arrays are far pointers already, so the sweeps are the
 * loops and there is no list to hand back.
 *
 * The ORDER the BASIC ran them in is kept, and it is not incidental:
 * every touch first -- which opens doors, and so changes state -- and
 * only then every step.
 */

#include <string.h>

#include "ent_move.h"
#include "ent.h"
#include "qgl.h"

/* q_pl.bi: the player box the touch fields are tested against. */
#define PL_HALF  16.0f
#define PL_ZLO  (-24.0f)
#define PL_ZHI   32.0f
#define PL_FEET  24.0f

/* A message by its 1-based id, or a pointer to 40 spaces for none.
   Not NUL-terminated on disk, so the length travels with it. */
static char far *ent_msg( World *world, short id )
{
    if ( id < 1 || id > world->msg_count || !world->msgs ) return 0;
    return world->msgs + (long) ( id - 1 ) * ENT_MSG_LEN;
}

void ent_say( Fight *fight, Renderer *rdr, char far *msg )
{
    short i, last = -1;

    if ( !msg ) return;
    for ( i = 0; i < ENT_MSG_LEN; i++ )
        if ( msg[i] != ' ' && msg[i] != '\0' ) last = i;
    if ( last < 0 ) return;             /* blank is not a message */

    for ( i = 0; i <= last; i++ ) fight->msg[i] = msg[i];
    fight->msg[last + 1] = '\0';
    fight->msg_until = rdr->anim_time + ENT_MSG_TIME;
}

/* The player's box against one grown by slack. */
static short ent_box_touched( Player *player, BspVec3 far *mins, BspVec3 far *maxs, float slack )
{
    if ( player->pos.x + PL_HALF + slack < mins->x ) return 0;
    if ( player->pos.x - PL_HALF - slack > maxs->x ) return 0;
    if ( player->pos.y + PL_HALF + slack < mins->y ) return 0;
    if ( player->pos.y - PL_HALF - slack > maxs->y ) return 0;
    if ( player->pos.z + PL_ZHI  + slack < mins->z ) return 0;
    if ( player->pos.z + PL_ZLO  - slack > maxs->z ) return 0;
    return 1;
}

/*
 * Quake's fast inverse square root, kept from ent_door.c: this build
 * has an 8087 and could call sqrt, but the arrival test below is done
 * on the SQUARE, exactly, so only the size of an intermediate step
 * rides on the root -- and by/d is by*rsqrt(l2), so the divide goes
 * with it. Changing it would move where a door is on a given tick.
 */
static float q_rsqrt( float n )
{
    union { float f; long l; } u;
    float half = n * 0.5f;

    u.f = n;
    u.l = 0x5f3759dfL - ( u.l >> 1 );
    u.f = u.f * ( 1.5f - half * u.f * u.f );
    u.f = u.f * ( 1.5f - half * u.f * u.f );
    return u.f;
}

/* toward goal by at most `by`; 1 when it arrives */
static short ent_step_to( BspVec3 far *p, BspVec3 far *goal, float by )
{
    float dx = goal->x - p->x;
    float dy = goal->y - p->y;
    float dz = goal->z - p->z;
    float l2 = dx*dx + dy*dy + dz*dz;
    float s;

    if ( l2 <= by * by ) {
        p->x = goal->x; p->y = goal->y; p->z = goal->z;
        return 1;
    }
    s = by * q_rsqrt( l2 );
    p->x += dx * s;
    p->y += dy * s;
    p->z += dz * s;
    return 0;
}

void ent_link_doors( World *world )
{
    short i, j, k, was, touch;
    DoorEnt far *d = world->door;

    for ( i = 0; i < world->door_count; i++ ) {
        for ( j = i + 1; j < world->door_count; j++ ) {
            touch = ( d[i].nolink == 0 && d[j].nolink == 0 );
            /* The fields are the brushes GROWN by the margin, so shrink
               them back before asking whether the brushes touch. */
            if ( d[i].mins.x + ENT_DOOR_FIELD  > d[j].maxs.x - ENT_DOOR_FIELD  ) touch = 0;
            if ( d[i].mins.y + ENT_DOOR_FIELD  > d[j].maxs.y - ENT_DOOR_FIELD  ) touch = 0;
            if ( d[i].mins.z + ENT_DOOR_FIELDZ > d[j].maxs.z - ENT_DOOR_FIELDZ ) touch = 0;
            if ( d[i].maxs.x - ENT_DOOR_FIELD  < d[j].mins.x + ENT_DOOR_FIELD  ) touch = 0;
            if ( d[i].maxs.y - ENT_DOOR_FIELD  < d[j].mins.y + ENT_DOOR_FIELD  ) touch = 0;
            if ( d[i].maxs.z - ENT_DOOR_FIELDZ < d[j].mins.z + ENT_DOOR_FIELDZ ) touch = 0;
            if ( !touch ) continue;

            was = d[j].link;
            for ( k = 0; k < world->door_count; k++ )
                if ( d[k].link == was ) d[k].link = d[i].link;
        }
    }
}

/* door_go_up for a whole linked group: a shut or closing door sets out,
   an open one restarts its hold. */
static void ent_door_fire( World *world, short grp )
{
    short k;
    DoorEnt far *d = world->door;

    for ( k = 0; k < world->door_count; k++ ) {
        if ( d[k].link != grp ) continue;

        if ( d[k].secret ) {
            /* fd_secret_use: nothing while it is anywhere but home */
            if ( d[k].state == ENT_DOOR_SHUT ) d[k].state = ENT_DOOR_OUT1;
            continue;
        }
        switch ( d[k].state ) {
        case ENT_DOOR_SHUT:
        case ENT_DOOR_CLOSING:
            d[k].state = ENT_DOOR_OPENING;
            break;
        case ENT_DOOR_OPEN:
            d[k].hold_left = d[k].hold;
            break;
        }
    }
}

/* SUB_UseTargets' remove(): every trigger named id is gone until the
   level restarts. A door or a monster by that name stays. */
static void ent_kill_targets( World *world, short id )
{
    short k;

    if ( !id ) return;
    for ( k = 0; k < world->trig_count; k++ )
        if ( world->trig[k].name == id ) world->trig[k].state = ENT_TRIG_DONE;
}

static void ent_trig_fire( World *world, Player *player, Fight *fight,
                            Renderer *rdr, short k );

void ent_use_targets( World *world, Player *player, Fight *fight,
                       Renderer *rdr, short id )
{
    short k;

    if ( !id ) return;

    for ( k = 0; k < world->door_count; k++ )
        if ( world->door[k].targeted == id ) ent_door_fire( world, world->door[k].link );

    /* train_use: once */
    for ( k = 0; k < world->plat_count; k++ )
        if ( world->plat[k].kind == ENT_PLAT_KIND_TRAIN &&
             world->plat[k].targeted == id &&
             world->plat[k].state == ENT_TRAIN_IDLE )
            world->plat[k].state = ENT_TRAIN_WAIT;

    for ( k = 0; k < world->trig_count; k++ ) {
        if ( world->trig[k].name != id ) continue;

        switch ( world->trig[k].kind ) {
        case ENT_TRIG_COUNTER:
            if ( world->trig[k].state != ENT_TRIG_DONE ) {
                world->trig[k].left--;
                if ( world->trig[k].left <= 0 ) ent_trig_fire( world, player, fight, rdr, k );
            }
            break;
        case ENT_TRIG_ONCE:
        case ENT_TRIG_MULTI:
            if ( world->trig[k].state == ENT_TRIG_READY ) ent_trig_fire( world, player, fight, rdr, k );
            break;
        case ENT_TRIG_RELAY:
            ent_trig_fire( world, player, fight, rdr, k );
            break;
        case ENT_TRIG_SHOOTER:
        case ENT_TRIG_BOSS:
            /* Armed, and nothing reads it yet: the spikes and Chthon
               are pl_move's, not ported. Set anyway so the state is the
               one the rest of the game will find when they are. */
            if ( world->trig[k].state == ENT_TRIG_READY ) world->trig[k].state = ENT_TRIG_ARMED;
            break;
        }
    }
}

/* multi_trigger: the message, then the targets; a once and a counter
   are done, a multiple re-arms after wait. */
static void ent_trig_fire( World *world, Player *player, Fight *fight,
                            Renderer *rdr, short k )
{
    TrigEnt far *t = &world->trig[k];

    if ( t->kind == ENT_TRIG_SECRET ) fight->secrets++;
    ent_say( fight, rdr, ent_msg( world, t->msg ) );

    if ( t->kind == ENT_TRIG_COUNTER || t->wait < 0.0f ) {
        t->state = ENT_TRIG_DONE;
    } else {
        t->state = ENT_TRIG_HELD;
        t->wait_left = t->wait;
    }

    /* SUB_UseTargets' delay: the kill and the fire wait in ent_move_trigs */
    if ( t->delay > 0.0f ) {
        t->delay_left = t->delay;
        return;
    }
    ent_kill_targets( world, t->kill );
    ent_use_targets( world, player, fight, rdr, t->target );
}

/* door_touch's key half: without the key the message, two seconds
   apart; with it the key is spent and the group goes. */
static void ent_door_key( World *world, Player *player, Fight *fight,
                           Renderer *rdr, short k )
{
    DoorEnt far *d = &world->door[k];
    long bit;

    if ( d->state != ENT_DOOR_SHUT ) return;
    bit = ( d->key == 2 ) ? PL_IT_KEY2 : PL_IT_KEY1;

    if ( ( fight->items & bit ) == 0 ) {
        if ( rdr->anim_time < d->say_at ) return;
        d->say_at = rdr->anim_time + 2.0f;
        ent_say( fight, rdr, ent_msg( world, d->msg ) );
        return;
    }
    fight->items &= ~bit;
    ent_door_fire( world, d->link );
}

void ent_move_doors( World *world, Player *player, Fight *fight,
                      Renderer *rdr, float dt )
{
    short k;
    DoorEnt far *d;
    BrushModel far *b;
    BspVec3 was;

    /* Every touch first, then every step -- opening a door changes
       state, and the BASIC's two sweeps ran in that order. */
    for ( k = 0; k < world->door_count; k++ ) {
        d = &world->door[k];
        if ( !ent_box_touched( player, &d->mins, &d->maxs, 0.0f ) ) continue;

        if ( d->key )
            ent_door_key( world, player, fight, rdr, k );
        else if ( !d->targeted && !d->secret )
            ent_door_fire( world, d->link );
        else
            ent_say( fight, rdr, ent_msg( world, d->msg ) );
    }

    for ( k = 0; k < world->door_count; k++ ) {
        d = &world->door[k];
        b = &world->brush[ d->model ];
        was = b->ofs;

        switch ( d->state ) {
        case ENT_DOOR_OPENING:
            if ( ent_step_to( &b->ofs, &d->ofs_open, d->speed * dt ) ) {
                d->state = ENT_DOOR_OPEN;
                d->hold_left = d->hold;
            }
            break;

        case ENT_DOOR_OPEN:
            if ( d->hold >= 0.0f ) {
                d->hold_left -= dt;
                if ( d->hold_left <= 0.0f ) d->state = ENT_DOOR_CLOSING;
            }
            break;

        case ENT_DOOR_CLOSING:
            if ( d->secret ) {
                if ( ent_step_to( &b->ofs, &d->ofs_mid, d->speed * dt ) ) {
                    d->state = ENT_DOOR_PAUSE_BACK;
                    d->pause_left = ENT_DOOR_PAUSE;
                }
            } else if ( ent_step_to( &b->ofs, &d->ofs_shut, d->speed * dt ) ) {
                d->state = ENT_DOOR_SHUT;
            }
            break;

        case ENT_DOOR_OUT1:
            if ( ent_step_to( &b->ofs, &d->ofs_mid, d->speed * dt ) ) {
                d->state = ENT_DOOR_PAUSE_OUT;
                d->pause_left = ENT_DOOR_PAUSE;
            }
            break;

        case ENT_DOOR_PAUSE_OUT:
            d->pause_left -= dt;
            if ( d->pause_left <= 0.0f ) d->state = ENT_DOOR_OPENING;
            break;

        case ENT_DOOR_PAUSE_BACK:
            d->pause_left -= dt;
            if ( d->pause_left <= 0.0f ) d->state = ENT_DOOR_BACK2;
            break;

        case ENT_DOOR_BACK2:
            if ( ent_step_to( &b->ofs, &d->ofs_shut, d->speed * dt ) ) d->state = ENT_DOOR_SHUT;
            break;
        }

        if ( b->ofs.x != was.x || b->ofs.y != was.y || b->ofs.z != was.z )
            b->node = ENT_NODE_DIRTY;
    }
}

void ent_move_trigs( World *world, Player *player, Fight *fight,
                      Renderer *rdr, float dt )
{
    short k;
    TrigEnt far *t;
    BrushModel far *b;
    BspVec3 was, home;

    home.x = home.y = home.z = 0.0f;

    for ( k = 0; k < world->trig_count; k++ ) {
        t = &world->trig[k];
        b = &world->brush[ t->model ];
        was = b->ofs;

        if ( t->delay_left > 0.0f ) {
            t->delay_left -= dt;
            if ( t->delay_left <= 0.0f ) {
                ent_kill_targets( world, t->kill );
                ent_use_targets( world, player, fight, rdr, t->target );
            }
        }

        switch ( t->kind ) {
        case ENT_TRIG_BUTTON:
            switch ( t->state ) {
            case ENT_TRIG_READY:
                if ( ent_box_touched( player, &t->mins, &t->maxs, ENT_TOUCH_SLACK ) )
                    t->state = ENT_TRIG_GOING;
                break;
            case ENT_TRIG_GOING:
                if ( ent_step_to( &b->ofs, &t->ofs_out, t->speed * dt ) ) {
                    t->state = ENT_TRIG_HELD;
                    t->wait_left = t->wait;
                    ent_say( fight, rdr, ent_msg( world, t->msg ) );
                    ent_use_targets( world, player, fight, rdr, t->target );
                }
                break;
            case ENT_TRIG_HELD:
                if ( t->wait >= 0.0f ) {
                    t->wait_left -= dt;
                    if ( t->wait_left <= 0.0f ) t->state = ENT_TRIG_BACK;
                }
                break;
            case ENT_TRIG_BACK:
                /* button_blocked without the push: wait for the player
                   to step off rather than move the brush through them. */
                if ( !ent_box_touched( player, &t->mins, &t->maxs, 0.0f ) ) {
                    if ( ent_step_to( &b->ofs, &home, t->speed * dt ) ) t->state = ENT_TRIG_READY;
                }
                break;
            }
            break;

        case ENT_TRIG_ONCE:
        case ENT_TRIG_MULTI:
        case ENT_TRIG_SHOOT:
        case ENT_TRIG_SECRET:
            switch ( t->state ) {
            case ENT_TRIG_READY:
                /* A shootable trigger is fired by a pellet, never by a
                   touch; pl_fire is not ported, so it stays ready. */
                if ( t->kind != ENT_TRIG_SHOOT &&
                     ent_box_touched( player, &t->mins, &t->maxs, 0.0f ) )
                    ent_trig_fire( world, player, fight, rdr, k );
                break;
            case ENT_TRIG_HELD:
                t->wait_left -= dt;
                if ( t->wait_left <= 0.0f ) t->state = ENT_TRIG_READY;
                break;
            }
            break;
        }

        if ( b->ofs.x != was.x || b->ofs.y != was.y || b->ofs.z != was.z )
            b->node = ENT_NODE_DIRTY;
    }
}

/* the player standing on a mover's brush where it is now */
static short ent_mover_ridden( Player *player, World *world, PlatEnt far *p )
{
    BrushModel far *b = &world->brush[ p->model ];
    float top;

    if ( player->pos.x + 16.0f < p->mins.x + b->ofs.x ) return 0;
    if ( player->pos.x - 16.0f > p->maxs.x + b->ofs.x ) return 0;
    if ( player->pos.y + 16.0f < p->mins.y + b->ofs.y ) return 0;
    if ( player->pos.y - 16.0f > p->maxs.y + b->ofs.y ) return 0;
    top = p->maxs.z + b->ofs.z;
    if ( player->pos.z - PL_FEET < top - 8.0f  ) return 0;
    if ( player->pos.z - PL_FEET > top + 64.0f ) return 0;
    return 1;
}

/* func_train_find: the brush's mins to its first corner. One with a
   targetname waits there for its trigger; the rest go on at once. */
void ent_train_init( World *world, PlatEnt far *p )
{
    BrushModel far *b = &world->brush[ p->model ];

    p->corner = p->first;
    b->ofs.x = world->corner[ p->first ].org.x - p->mins.x;
    b->ofs.y = world->corner[ p->first ].org.y - p->mins.y;
    b->ofs.z = world->corner[ p->first ].org.z - p->mins.z;
    b->node = ENT_NODE_DIRTY;
    p->wait_left = 0.0f;
    p->state = p->targeted ? ENT_TRAIN_IDLE : ENT_TRAIN_WAIT;
}

void ent_move_trains( World *world, Player *player, float dt )
{
    short i, riding;
    PlatEnt far *p;
    BrushModel far *b;
    BspVec3 goal, was;

    for ( i = 0; i < world->plat_count; i++ ) {
        p = &world->plat[i];
        if ( p->kind != ENT_PLAT_KIND_TRAIN ) continue;
        if ( p->state == ENT_TRAIN_IDLE ) continue;
        if ( p->first < 0 || p->first >= world->corner_count ) continue;

        if ( p->state == ENT_TRAIN_WAIT ) {
            p->wait_left -= dt;
            if ( p->wait_left > 0.0f ) continue;
            if ( world->corner[ p->corner ].nxt < 0 ) continue;
            p->corner = world->corner[ p->corner ].nxt;
            p->state = ENT_TRAIN_MOVE;
        }

        b = &world->brush[ p->model ];
        goal.x = world->corner[ p->corner ].org.x - p->mins.x;
        goal.y = world->corner[ p->corner ].org.y - p->mins.y;
        goal.z = world->corner[ p->corner ].org.z - p->mins.z;

        riding = ent_mover_ridden( player, world, p );
        was = b->ofs;

        if ( ent_step_to( &b->ofs, &goal, p->speed * dt ) ) {
            p->state = ENT_TRAIN_WAIT;
            p->wait_left = world->corner[ p->corner ].wait;
            /* id's -1 is a wait of nothing, not a wait for ever */
            if ( p->wait_left <= 0.0f ) p->wait_left = 0.1f;
        }

        if ( b->ofs.x != was.x || b->ofs.y != was.y || b->ofs.z != was.z )
            b->node = ENT_NODE_DIRTY;

        if ( !riding ) continue;
        player->pos.x += b->ofs.x - was.x;
        player->pos.y += b->ofs.y - was.y;
        /* carried up, never pushed down: a descending mover is left to
           drop away under the player, as Quake does */
        if ( b->ofs.z > was.z ) player->pos.z += b->ofs.z - was.z;
    }
}

void ent_reset( World *world, Fight *fight )
{
    short k;

    for ( k = 0; k < world->door_count; k++ ) {
        world->door[k].state = ENT_DOOR_SHUT;
        world->door[k].hold_left = 0.0f;
        world->door[k].pause_left = 0.0f;
        world->brush[ world->door[k].model ].ofs = world->door[k].ofs_shut;
    }
    for ( k = 0; k < world->trig_count; k++ ) {
        world->trig[k].state = ENT_TRIG_READY;
        world->trig[k].left = world->trig[k].count;
        world->trig[k].wait_left = 0.0f;
        world->trig[k].delay_left = 0.0f;
        if ( world->trig[k].kind == ENT_TRIG_BUTTON ) {
            world->brush[ world->trig[k].model ].ofs.x = 0.0f;
            world->brush[ world->trig[k].model ].ofs.y = 0.0f;
            world->brush[ world->trig[k].model ].ofs.z = 0.0f;
        }
    }
    for ( k = 0; k < world->plat_count; k++ )
        if ( world->plat[k].kind == ENT_PLAT_KIND_TRAIN ) ent_train_init( world, &world->plat[k] );

    fight->msg_until = 0.0f;
    fight->msg[0] = '\0';
    for ( k = 1; k < world->model_count; k++ ) world->brush[k].node = ENT_NODE_DIRTY;
}
