/*
 * ent_door.c -- the two per-door sweeps, once a tick each.
 *
 * ent_move_doors walked every door twice a tick and paid a BASIC call
 * and a descriptor-addressed subscript at every step of it: 47 doors on
 * e1m6 for 0.408ms a tick, 1.20ms a frame, and half of that is a touch
 * scan that almost never finds anything.
 *
 * WHAT DID NOT MOVE, and why. A touched door may want a key, a message,
 * a linked group or a sound, and those read the fight state, the string
 * table and the sound device -- none of which belongs on this side. So C
 * answers only what the records themselves can answer: WHICH doors the
 * player stands in, and WHERE each door has got to. Both hand back a
 * list for ent.bas to act on, in the order it would have acted anyway.
 *
 * That ordering is the thing to preserve. BASIC ran the touch loop over
 * every door FIRST -- opening what it found, which changes state -- and
 * only then ran the state machine. Hence two entries and not one: the
 * caller processes the hits in between.
 *
 * The records cross by layout alone, the way DrawParams does, and
 * ent_door_layout_ok is what says so before a frame is drawn.
 */

#include "qcshared.h"


/* q_ent.bi */
#define ENT_DOOR_SHUT       0
#define ENT_DOOR_OPENING    1
#define ENT_DOOR_OPEN       2
#define ENT_DOOR_CLOSING    3
#define ENT_DOOR_OUT1       4
#define ENT_DOOR_PAUSE_OUT  5
#define ENT_DOOR_PAUSE_BACK 6
#define ENT_DOOR_BACK2      7
#define ENT_DOOR_PAUSE      1.0f
#define ENT_NODE_DIRTY      ((short)0x8000)

/* q_pl.bi -- the player box the touch field is tested against */
#define PL_HALF   16.0f
#define PL_ZLO   (-24.0f)
#define PL_ZHI    32.0f

typedef struct {
    short draw, solid;
    Vec3  ofs;
    short node;
} BrushRec;                             /* q_ent.bi's BrushModel, 18 */

typedef struct {
    short model;
    Vec3  ofs_shut, ofs_open, ofs_mid;
    float speed, hold, hold_left, pause_left;
    short state, secret, shoot, link, nolink, targeted, snd, key;
    float say_at;
    Vec3  mins, maxs;
    short msg;
} DoorRec;                              /* q_ent.bi's DoorEnt, 100 */

short pascal far ent_door_layout_ok( short brush_sz, short door_sz )
{
    return (short) ( brush_sz == (short) sizeof( BrushRec )
                  && door_sz  == (short) sizeof( DoorRec ) );
}

/*
 * Which doors the player stands in. NOTHING is changed here: what a hit
 * means depends on keys and links, and that is ent.bas's.
 *
 * Returns the count it FOUND, which may exceed what it wrote -- the
 * caller checks that against its own array rather than being handed a
 * silently short list.
 */
short pascal far ent_doors_touch_c(
    short      count,
    Vec3      *pos,                     /* the player, read once */
    BASARRAY  *door_dsc,
    BASARRAY  *hit_dsc,
    short      hit_max )
{
    short k, n = 0;
    float x = pos->x, y = pos->y, z = pos->z;
    DoorRec far *d   = (DoorRec far *) door_dsc->farptr;
    short far   *hit = (short far *)   hit_dsc->farptr;

    for ( k = 0; k < count; k++, d++ ) {
        if ( x + PL_HALF < d->mins.x ) continue;
        if ( x - PL_HALF > d->maxs.x ) continue;
        if ( y + PL_HALF < d->mins.y ) continue;
        if ( y - PL_HALF > d->maxs.y ) continue;
        if ( z + PL_ZHI  < d->mins.z ) continue;
        if ( z + PL_ZLO  > d->maxs.z ) continue;
        if ( n < hit_max ) hit[n] = k;
        n++;
    }
    return n;
}

/*
 * Quake's fast inverse square root. math.h's sqrt is not reachable from
 * here anyway -- it drags CL.LIB's float conversion in, which defines
 * __nfile and __doserrno a second time against the BASIC runtime -- and
 * an inline-asm FSQRT was worse than unreachable: it returned a value
 * that poisoned the brush offset, and the frame after a door moved
 * spun forever.
 *
 * The approximation is safe here because it never decides anything. The
 * arrival test below is done on the SQUARE, exactly, so only the size of
 * an intermediate step rides on the root -- and by/d is by*rsqrt(l2), so
 * the divide goes with it.
 */
static float q_rsqrt( float n )
{
    union { float f; long l; } u;
    float half = n * 0.5f;

    u.f = n;
    u.l = 0x5f3759dfL - ( u.l >> 1 );
    u.f = u.f * ( 1.5f - half * u.f * u.f );
    return u.f;
}

/* toward goal by at most `by`; 1 when it arrives. ent_door_step's. */
static short door_step( Vec3 far *p, Vec3 far *goal, float by )
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

/*
 * Every door one step on. Writes the brush offsets and the door states,
 * and hands back the ends reached as pairs -- door index, then
 * ent_door_sound's own second argument -- because the sound is the
 * caller's.
 *
 * Returns the number of PAIRS found, written or not.
 */
short pascal far ent_doors_step_c(
    short      count,
    float      dt,
    BASARRAY  *brush_dsc,
    BASARRAY  *door_dsc,
    BASARRAY  *ev_dsc,
    short      ev_max )
{
    short k, n = 0, snd;
    DoorRec far  *d     = (DoorRec far *)  door_dsc->farptr;
    BrushRec far *brush = (BrushRec far *) brush_dsc->farptr;
    short far    *ev    = (short far *)    ev_dsc->farptr;
    BrushRec far *b;
    float sx, sy, sz;

    for ( k = 0; k < count; k++, d++ ) {
        b  = brush + d->model;
        sx = b->ofs.x; sy = b->ofs.y; sz = b->ofs.z;
        snd = -1;

        switch ( d->state ) {
        case ENT_DOOR_OPENING:
            if ( door_step( &b->ofs, &d->ofs_open, d->speed * dt ) ) {
                d->state = ENT_DOOR_OPEN;
                d->hold_left = d->hold;
                snd = 0;
            }
            break;

        case ENT_DOOR_OPEN:
            if ( d->hold >= 0.0f ) {
                d->hold_left -= dt;
                if ( d->hold_left <= 0.0f ) {
                    d->state = ENT_DOOR_CLOSING;
                    snd = 1;
                }
            }
            break;

        case ENT_DOOR_CLOSING:
            if ( d->secret ) {
                if ( door_step( &b->ofs, &d->ofs_mid, d->speed * dt ) ) {
                    d->state = ENT_DOOR_PAUSE_BACK;
                    d->pause_left = ENT_DOOR_PAUSE;
                }
            } else if ( door_step( &b->ofs, &d->ofs_shut, d->speed * dt ) ) {
                d->state = ENT_DOOR_SHUT;
                snd = 0;
            }
            break;

        case ENT_DOOR_OUT1:
            if ( door_step( &b->ofs, &d->ofs_mid, d->speed * dt ) ) {
                d->state = ENT_DOOR_PAUSE_OUT;
                d->pause_left = ENT_DOOR_PAUSE;
            }
            break;

        case ENT_DOOR_PAUSE_OUT:
            d->pause_left -= dt;
            if ( d->pause_left <= 0.0f ) {
                d->state = ENT_DOOR_OPENING;
                snd = 1;
            }
            break;

        case ENT_DOOR_PAUSE_BACK:
            d->pause_left -= dt;
            if ( d->pause_left <= 0.0f ) {
                d->state = ENT_DOOR_BACK2;
                snd = 1;
            }
            break;

        case ENT_DOOR_BACK2:
            if ( door_step( &b->ofs, &d->ofs_shut, d->speed * dt ) ) {
                d->state = ENT_DOOR_SHUT;
                snd = 0;
            }
            break;
        }

        if ( snd >= 0 ) {
            if ( n * 2 + 1 < ev_max ) { ev[n*2] = k; ev[n*2+1] = snd; }
            n++;
        }
        if ( b->ofs.x != sx || b->ofs.y != sy || b->ofs.z != sz )
            b->node = ENT_NODE_DIRTY;
    }
    return n;
}
