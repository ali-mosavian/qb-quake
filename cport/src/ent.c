/*
 * ent.c -- entities. C port of ent.bas.
 *
 * The per-frame math (ent_find_node, ent_place_models,
 * ent_check_teleport, ent_plat_touched, ent_move_plats,
 * ent_point_leaf) and the loading functions (ent_load_spawn,
 * ent_load_teleports, built on assets.h's asset_load_whole rather
 * than a port of ent_get/ent_open_bin's own sequential UAR reads --
 * ents.bin is tiny, so reading it whole and walking a far pointer
 * through the records in memory is simpler than replicating BASIC's
 * GET-one-record-at-a-time shape).
 */

#include <mem.h>    /* _fmemcpy */
#include <stdio.h>
#include "qgl.h"
#include <stdlib.h>

#include "ent.h"
#include "snd.h"
#include "ent_move.h"
#include "pl_move.h"    /* PL_FEET/PL_TELE_LIFT -- shared with pl_move.c, one fact one place */
#include "r_bsp.h"      /* r_point_leaf -- r_bsp.bas, not yet ported */
#include "assets.h"
#include "item.h"
#include "mdl_ai.h"
#include "mdl.h"   /* ent_load_items -- the records sit between the hides and the doors */

/* Neither toolchain here defines F_FTOL@, the runtime helper bcc emits
   for a float/double-to-integer cast (checked bcpp31's and tc201's
   CC.LIB by string search, present in neither) -- so a cast goes
   through this instead, same fix already applied to FSIN in d_poly.c.
   FISTP alone rounds to nearest per the FPU control word; a C cast
   truncates toward zero, so the control word is switched to truncate
   (RC=11) around the store and restored after. */
static short ftol_short( float f )
{
    short cw, tcw, result;
    __asm {
        fld    f
        fnstcw word ptr cw
        mov    ax, cw
        or     ax, 0x0C00
        mov    tcw, ax
        fldcw  word ptr tcw
        fistp  word ptr result
        fldcw  word ptr cw
    }
    return result;
}

/*
 * name: ent_find_node
 * desc: The deepest world node whose plane submodel m's box does not
 *       straddle.
 *
 *       That node is where the entity belongs in the painter's order:
 *       every world face beyond it is drawn before the walk arrives,
 *       every face nearer is drawn after, and the entity goes in
 *       between. Descending stops as soon as a plane cuts the box,
 *       because past that point the entity is on both sides at once
 *       and no single position is right.
 *
 *       Returns a leaf, bit 15 set, when the box fits inside one.
 */
short ent_find_node( short m, World *world )
{
    Submodel far *sm = &world->models[m];
    short node_nr = 0;
    short pid;
    float dnear, dfar;
    BspVec3 far *ofs = &world->brush[m].ofs;
    float x0 = sm->mins.x + ofs->x, x1 = sm->maxs.x + ofs->x;
    float y0 = sm->mins.y + ofs->y, y1 = sm->maxs.y + ofs->y;
    float z0 = sm->mins.z + ofs->z, z1 = sm->maxs.z + ofs->z;

    while ( (node_nr & 0x8000) == 0 ) {
        Node far *n = &world->nodes[node_nr];
        Plane far *pl = &world->planes[n->plane_id];

        /* The box corner furthest along the normal and the one
           furthest against it. If both land on the same side of the
           plane, so does every other corner. */
        if ( pl->norm.x >= 0.0f ) { dnear  = pl->norm.x * x0; dfar  = pl->norm.x * x1; }
        else                      { dnear  = pl->norm.x * x1; dfar  = pl->norm.x * x0; }

        if ( pl->norm.y >= 0.0f ) { dnear += pl->norm.y * y0; dfar += pl->norm.y * y1; }
        else                      { dnear += pl->norm.y * y1; dfar += pl->norm.y * y0; }

        if ( pl->norm.z >= 0.0f ) { dnear += pl->norm.z * z0; dfar += pl->norm.z * z1; }
        else                      { dnear += pl->norm.z * z1; dfar += pl->norm.z * z0; }

        dnear -= pl->dist;
        dfar  -= pl->dist;

        if ( dnear >= 0.0f )      node_nr = n->child0;
        else if ( dfar < 0.0f )   node_nr = n->child1;
        else                      break;
    }

    return node_nr;
}

/*
 * name: ent_point_leaf
 * desc: The world leaf a point falls in. The same descent as
 *       pl_point_contents, stopping one step earlier: that wants what
 *       is at the point, this wants where the point is.
 */
short ent_point_leaf( BspVec3 *p, World *world )
{
    return r_point_leaf( p, world );
}

/*
 * name: ent_place_models
 * desc: Works out where in the world's back-to-front order each
 *       submodel belongs, once per frame, and leaves the answer in
 *       brush[m].node.
 *
 *       Two earlier answers were wrong in instructive ways. Recording
 *       the leaf a sample point falls in fails because that leaf is
 *       often solid -- a lowered lift sits inside its own shaft -- and
 *       a solid leaf is never walked. Drawing at the first visible
 *       leaf the box overlaps fails because the walk reaches leaves in
 *       depth order, so "first" means "furthest", and everything the
 *       entity should hide gets drawn after it.
 */
void ent_place_models( World *world )
{
    short m;
    /* Only the brushes that moved. ent_find_node for every submodel
       every tick was 81ms of e1m3's 131ms frame; a mover stamps its
       own brush ENT_NODE_DIRTY when its offset changes, and a brush
       that did not move is still where it was placed. */
    for ( m = 1; m < world->model_count; m++ ) {
        if ( world->brush[m].node == ENT_NODE_DIRTY )
            world->brush[m].node = ent_find_node( m, world );
    }
}

/*
 * name: ent_plat_touched
 * desc: True when the player is standing on a plat, or in the column
 *       above it. Quake builds a trigger brush around the plat for
 *       this; the box is close enough and needs nothing from the
 *       compiler.
 */
short ent_plat_touched( Player *player, World *world, short p )
{
    PlatEnt far *plt = &world->plat[p];
    float top;

    if ( player->pos.x + 16.0f < plt->mins.x ) return 0;
    if ( player->pos.x - 16.0f > plt->maxs.x ) return 0;
    if ( player->pos.y + 16.0f < plt->mins.y ) return 0;
    if ( player->pos.y - 16.0f > plt->maxs.y ) return 0;

    /* Above its surface and within a body's height of it. Anything
       higher is someone on a walkway over the shaft, not a passenger. */
    top = plt->maxs.z + world->brush[plt->model].ofs.z;

    if ( player->pos.z - PL_FEET < top - 8.0f  ) return 0;
    if ( player->pos.z - PL_FEET > top + 64.0f ) return 0;

    return 1;
}

/*
 * name: ent_move_plats
 * desc: Drives every func_plat, and carries whoever is riding one.
 *
 *       A plat rises while the player is on it and returns when they
 *       leave, which is Quake's behaviour without the delay and the
 *       sounds.
 *
 *       The rider is moved by the same delta the plat moved. Quake
 *       does this properly in SV_PushMove, which re-traces everything
 *       the mover touches and telefrags what it cannot push; this
 *       carries the one entity that exists.
 */
void ent_move_plats( World *world, Player *player, float dt )
{
    short p;

    for ( p = 0; p < world->plat_count; p++ ) {
        PlatEnt far *plt = &world->plat[p];
        BrushModel far *br = &world->brush[plt->model];
        short riding = ent_plat_touched( player, world, p );
        float goal, step_z, moved, was;

        plt->state = riding ? ENT_PLAT_UP : ENT_PLAT_DOWN;
        goal = ( plt->state == ENT_PLAT_UP ) ? 0.0f : -plt->travel;

        was = br->ofs.z;
        if ( br->ofs.z < goal ) {
            step_z = plt->speed * dt;
            br->ofs.z += step_z;
            if ( br->ofs.z > goal ) br->ofs.z = goal;
        } else if ( br->ofs.z > goal ) {
            step_z = plt->speed * dt;
            br->ofs.z -= step_z;
            if ( br->ofs.z < goal ) br->ofs.z = goal;
        }
        moved = br->ofs.z - was;
        if ( moved != 0.0f ) br->node = ENT_NODE_DIRTY;

        /* Carry the rider. Only upward: a descending plat drops out
           from under the player and gravity does the rest, which is
           what it looks like in Quake. Pushing them down would shove
           them through the floor of the shaft on the last step of the
           descent. */
        if ( riding && moved > 0.0f ) {
            player->pos.z += moved;
        }
    }
}

/*
 * name: ent_check_teleport
 * desc: Moves the player if their box overlaps a teleporter's.
 *
 *       Box against box, not point against box: a trigger is often
 *       thinner than the player, and testing the origin alone lets a
 *       fast enough player pass through one without ever having their
 *       centre inside it.
 */
void ent_check_teleport( Player *player, World *world, short scr_x_res )
{
    short i;
    BspVec3 pmin, pmax;

    if ( player->no_clip ) return;

    pmin.x = player->pos.x - 16.0f;
    pmin.y = player->pos.y - 16.0f;
    pmin.z = player->pos.z - PL_FEET;
    pmax.x = player->pos.x + 16.0f;
    pmax.y = player->pos.y + 16.0f;
    pmax.z = player->pos.z + 32.0f;

    for ( i = 0; i < world->tele_count; i++ ) {
        Teleporter far *t = &world->tele[i];

        if ( pmax.x >= t->mins.x && pmin.x <= t->maxs.x &&
             pmax.y >= t->mins.y && pmin.y <= t->maxs.y &&
             pmax.z >= t->mins.z && pmin.z <= t->maxs.z ) {

            player->pos   = t->dest;
            player->vel.x = 0.0f;
            player->vel.y = 0.0f;
            player->vel.z = 0.0f;

            /* Face the way the destination says. The camera reads its
               angle from the mouse, so the mouse is what has to move --
               the same trick host_main uses to apply the spawn angle. */
            qglMousePos( ftol_short( (scr_x_res - 1) * t->yaw / 360.0f ), 110 );

            return;
        }
    }
}

/*
 * name: ent_load_spawn
 * desc: The spawn point, from ents.bin -- the entities text mkassets.py
 *       already resolved. The text itself never reaches the target:
 *       BASIC strings capped at 32,767 bytes and e1m3's entities lump
 *       is 45,762, which cport/ has no reason to inherit but keeps
 *       reading the same pre-resolved header regardless.
 */
void ent_load_spawn( World *world, Camera *cam, Fight *fight )
{
    long n;
    unsigned char far *buf = asset_load_whole( "ents.bin", &n );
    EntsHead h;

    _fmemcpy( &h, buf, sizeof(EntsHead) );
    qglMemFree( (long) buf );

    if ( h.nmodels != world->model_count ) {
        fprintf( stderr, "ents.bin is from another map\n" );
        exit( 1 );
    }

    /* BSP is Z-up and the camera is Y-up, so y and z swap here. */
    cam->pos.x = h.spawn.x;
    cam->pos.z = h.spawn.y;
    cam->pos.y = h.spawn.z;
    /* MIRRORED. The map's angle is CCW from +x; the freelook math
       makes the eye direction (cos a, -sin a) in bsp x,y, so a spawn
       that should face +y (angle 90) needs 270 here. Unmirrored, the
       player starts facing the wall behind them: -walk from e1m1's
       spawn went 47 units backwards and stopped, where it should walk
       the length of the hall. */
    cam->start_angle = 360.0f - h.angle;
    if ( cam->start_angle >= 360.0f ) cam->start_angle -= 360.0f;

    /* worldspawn's, and world.qc's sv_gravity: 100 on e1m8, 800
       elsewhere. Both ride in the header rather than being guessed. */
    fight->worldtype = h.worldtype;
    fight->gravity   = h.gravity > 0.0f ? h.gravity : 800.0f;

    /* the intermission camera and where this level leads. next_map is
       space padded in the file and read back as a C string here. */
    fight->inter       = h.inter;
    fight->inter_pitch = h.inter_pitch;
    fight->inter_yaw   = h.inter_yaw;
    {   short i, last = -1;
        for ( i = 0; i < 8; i++ ) {
            fight->next_map[i] = h.next_map[i];
            if ( h.next_map[i] != ' ' && h.next_map[i] != '\0' ) last = i;
        }
        fight->next_map[ last + 1 ] = '\0';
    }
}


/*
 * The movers, in the order ents.bin puts them. Each takes the running
 * offset by pointer: a record skipped by the wrong size lands the next
 * loader in the middle of a record, and the only symptom is nonsense
 * geometry several loaders later.
 */
static void ent_load_doors( World *world, unsigned char far *buf, long *ofs, short count )
{
    short i, m;
    float fx, fz;

    world->door_count = 0;
    world->door = (DoorEnt far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(DoorEnt) );
    if ( !world->door ) { fprintf( stderr, "ents.bin: no room for the doors\n" ); exit( 1 ); }

    for ( i = 0; i < count; i++ ) {
        EntsDoor dr;
        DoorEnt far *d;

        _fmemcpy( &dr, buf + *ofs, sizeof(EntsDoor) ); *ofs += sizeof(EntsDoor);
        m = dr.model;
        if ( m <= 0 || m >= world->model_count ) continue;

        d = &world->door[ world->door_count ];
        d->model   = m;
        d->speed   = dr.speed;
        d->hold    = dr.hold;
        d->hold_left = 0.0f;
        d->pause_left = 0.0f;
        d->nolink  = dr.nolink;
        d->targeted = dr.targeted;
        d->secret  = dr.secret;
        d->shoot   = dr.shoot;
        d->snd     = dr.snd;
        d->key     = dr.key;
        d->say_at  = 0.0f;
        d->ofs_mid = dr.mid;
        d->msg     = dr.msg;
        d->state   = ENT_DOOR_SHUT;
        d->link    = world->door_count;

        /* DOOR_START_OPEN: drawn shut where the map put it, which is
           the far end of its travel. */
        d->ofs_shut.x = d->ofs_shut.y = d->ofs_shut.z = 0.0f;
        d->ofs_open = dr.travel;
        if ( dr.start_open ) {
            d->ofs_shut = dr.travel;
            d->ofs_open.x = d->ofs_open.y = d->ofs_open.z = 0.0f;
        }
        world->brush[m].ofs = d->ofs_shut;

        /* spawn_field: the brush where it sits, grown 60 in x and y and
           8 in z. A targeted, secret or key door has no field -- touching
           the brush itself is what says its message (door_touch). */
        fx = ENT_DOOR_FIELD; fz = ENT_DOOR_FIELDZ;
        if ( d->targeted || d->secret || d->key ) { fx = ENT_TOUCH_SLACK; fz = ENT_TOUCH_SLACK; }
        d->mins.x = world->models[m].mins.x + d->ofs_shut.x - fx;
        d->mins.y = world->models[m].mins.y + d->ofs_shut.y - fx;
        d->mins.z = world->models[m].mins.z + d->ofs_shut.z - fz;
        d->maxs.x = world->models[m].maxs.x + d->ofs_shut.x + fx;
        d->maxs.y = world->models[m].maxs.y + d->ofs_shut.y + fx;
        d->maxs.z = world->models[m].maxs.z + d->ofs_shut.z + fz;

        world->door_count++;
    }
}

static void ent_load_trigs( World *world, unsigned char far *buf, long *ofs, short count )
{
    short i, m;

    world->trig_count = 0;
    world->trig = (TrigEnt far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(TrigEnt) );
    if ( !world->trig ) { fprintf( stderr, "ents.bin: no room for the triggers\n" ); exit( 1 ); }

    for ( i = 0; i < count; i++ ) {
        EntsTrig xr;
        TrigEnt far *t;

        _fmemcpy( &xr, buf + *ofs, sizeof(EntsTrig) ); *ofs += sizeof(EntsTrig);
        m = xr.model;
        if ( m < 0 || m >= world->model_count ) continue;

        t = &world->trig[ world->trig_count ];
        t->model = m;
        t->kind  = xr.kind;
        t->target = xr.target;
        t->name  = xr.name;
        t->kill  = xr.kill;
        t->state = ENT_TRIG_READY;
        t->left  = xr.count;
        t->count = xr.count;
        t->wait  = xr.wait;
        t->wait_left = 0.0f;
        t->speed = xr.speed;
        t->snd   = xr.snd;
        t->ofs_out = xr.travel;
        t->delay = xr.delay;
        t->delay_left = 0.0f;
        t->msg   = xr.msg;
        t->mins  = world->models[m].mins;
        t->maxs  = world->models[m].maxs;
        /* A shooter and a fireball have no brush: their origin IS the
           volume, so mins and maxs are the same point. */
        if ( xr.kind == ENT_TRIG_SHOOTER || xr.kind == ENT_TRIG_FIREBALL ) {
            t->mins = xr.org;
            t->maxs = xr.org;
        }
        world->trig_count++;
    }
}

/* what the tally counts against: the map's trigger_secrets */
short ent_secret_total( World *world )
{
    short k, n = 0;

    for ( k = 0; k < world->trig_count; k++ )
        if ( world->trig[k].kind == ENT_TRIG_SECRET ) n++;
    return n;
}

static void ent_load_trains( World *world, unsigned char far *buf, long *ofs, short count )
{
    short i, m;

    for ( i = 0; i < count; i++ ) {
        EntsTrain tr;
        PlatEnt far *p;

        _fmemcpy( &tr, buf + *ofs, sizeof(EntsTrain) ); *ofs += sizeof(EntsTrain);
        m = tr.model;
        if ( m <= 0 || m >= world->model_count ) continue;
        if ( world->plat_count >= world->plat_max ) continue;

        p = &world->plat[ world->plat_count ];
        p->model = m;
        p->speed = tr.speed > 0.0f ? tr.speed : 100.0f;
        p->travel = 0.0f;
        p->kind  = ENT_PLAT_KIND_TRAIN;
        p->targeted = tr.targeted;
        p->first = tr.first;
        p->corner = tr.first;
        p->wait_left = 0.0f;
        p->state = ENT_TRAIN_IDLE;
        p->mins  = world->models[m].mins;
        p->maxs  = world->models[m].maxs;
        world->plat_count++;
    }
}

static void ent_load_corners( World *world, unsigned char far *buf, long *ofs, short count )
{
    world->corner_count = count;
    world->corner = (PathCorner far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(PathCorner) );
    if ( !world->corner ) { fprintf( stderr, "ents.bin: no room for the path corners\n" ); exit( 1 ); }
    if ( count ) _fmemcpy( world->corner, buf + *ofs, (long) count * sizeof(PathCorner) );
    *ofs += (long) count * sizeof(PathCorner);
}

static void ent_load_lights( World *world, unsigned char far *buf, long *ofs, short count )
{
    EntsLight lr;
    short i;

    world->light_count = count;
    world->light = (LightEnt far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(LightEnt) );
    if ( !world->light ) { fprintf( stderr, "ents.bin: no room for the lights\n" ); exit( 1 ); }
    for ( i = 0; i < count; i++ ) {
        _fmemcpy( &lr, buf + *ofs, sizeof(EntsLight) );
        *ofs += sizeof(EntsLight);
        world->light[i].name     = lr.name;
        world->light[i].style    = lr.style;
        world->light[i].on       = lr.on;
        world->light[i].start_on = lr.on;
        world->light[i].stamp    = i;
    }
    world->light_clock = count;
}

/* The message table is last, so what is left of the file is what it
   holds -- and a header that disagrees with that is the tell that some
   record above was skipped by the wrong size. */
static void ent_load_msgs( World *world, unsigned char far *buf, long *ofs, short count, long total )
{
    if ( *ofs + (long) count * ENT_MSG_LEN != total ) {
        fprintf( stderr, "ents.bin: %ld bytes of messages, header says %d\n",
                 total - *ofs, (int) count );
        exit( 1 );
    }
    world->msg_count = count;
    world->msgs = (char far *) qglMemAlloc( (long) ( count ? count : 1 ) * ENT_MSG_LEN );
    if ( !world->msgs ) { fprintf( stderr, "ents.bin: no room for the messages\n" ); exit( 1 ); }
    if ( count ) _fmemcpy( world->msgs, buf + *ofs, (long) count * ENT_MSG_LEN );
    *ofs += (long) count * ENT_MSG_LEN;
}

/*
 * name: ent_load_teleports
 * desc: Loads ents.bin: teleporter pairs already matched by
 *       targetname, plats and hidden submodels already validated, all
 *       by mkassets.py. What stays here is what needs the loaded
 *       submodels: trigger volumes and plat defaults come from
 *       world->models, which mkassets has no reason to duplicate.
 */
void ent_load_teleports( World *world )
{
    long n, ofs;
    unsigned char far *buf = asset_load_whole( "ents.bin", &n );
    EntsHead h;
    short i, j, k, mdlnum;

    _fmemcpy( &h, buf, sizeof(EntsHead) );
    ofs = sizeof(EntsHead);

    if ( h.nmodels != world->model_count ) {
        fprintf( stderr, "ents.bin is from another map\n" );
        exit( 1 );
    }

    /* Sized to the map, not a fixed bound: e1m3 has 106 submodels, and
       ent_place_models/pl_trace walk every one of them. */
    world->brush = (BrushModel far *) qglMemAlloc( (long) world->model_count * sizeof(BrushModel) );
    world->tele = (Teleporter far *) qglMemAlloc( (long) (h.ntele ? h.ntele : 1) * sizeof(Teleporter) );
    /* the trains ride this array too, so it is sized for both */
    world->plat_max = (short) ( h.nplat + h.ntrain );
    world->plat = (PlatEnt far *) qglMemAlloc( (long) (world->plat_max ? world->plat_max : 1) * sizeof(PlatEnt) );
    if ( !world->brush || !world->tele || !world->plat ) {
        fprintf( stderr, "ents.bin: out of memory\n" );
        exit( 1 );
    }

    world->tele_count = 0;
    world->plat_count = 0;

    /* The monsters come first in the file, and the models the kinds
       among them need come with them. */
    mdl_load_monsters( world, buf, &ofs, h.nmon );

    /* every submodel draws and blocks unless something claims it as a trigger */
    for ( i = 0; i < world->model_count; i++ ) {
        world->brush[i].draw  = 1;
        world->brush[i].solid = 1;
        world->brush[i].ofs.x = 0.0f;
        world->brush[i].ofs.y = 0.0f;
        world->brush[i].ofs.z = 0.0f;
        world->brush[i].node  = ENT_NODE_DIRTY;
    }

    /* Which submodel owns each face, in the bits above Face.side's
       one. The world's faces come first and the submodels' follow in
       order, so this is a walk, not a search -- and an array of its
       own was 11,032 bytes on e1m1 to hold a number under 64. */
    for ( i = 0; i < world->face_count; i++ )
        world->faces[i].side = (short) ( world->faces[i].side & 1 );

    for ( j = 1; j < world->model_count; j++ ) {
        for ( k = (short) world->models[j].first_face;
              k < (short) (world->models[j].first_face + world->models[j].num_faces); k++ ) {
            if ( k >= 0 && k < world->face_count )
                world->faces[k].side = (short) ( ( world->faces[k].side & 1 ) | ( j << 1 ) );
        }
    }

    for ( i = 0; i < h.ntele; i++ ) {
        EntsTele tr;
        _fmemcpy( &tr, buf + ofs, sizeof(EntsTele) ); ofs += sizeof(EntsTele);

        mdlnum = tr.model;
        if ( mdlnum > 0 && mdlnum < world->model_count ) {
            Teleporter far *t = &world->tele[ world->tele_count ];
            t->mins = world->models[mdlnum].mins;
            t->maxs = world->models[mdlnum].maxs;
            t->dest = tr.dest;
            /* the arrival point is above the mapper's mark -- see PL_TELE_LIFT */
            t->dest.z += PL_TELE_LIFT;
            t->yaw = tr.yaw;
            world->tele_count++;
        }
    }

    for ( i = 0; i < h.nplat; i++ ) {
        EntsPlat pr;
        _fmemcpy( &pr, buf + ofs, sizeof(EntsPlat) ); ofs += sizeof(EntsPlat);

        mdlnum = pr.model;
        if ( mdlnum > 0 && mdlnum < world->model_count ) {
            PlatEnt far *p = &world->plat[ world->plat_count ];
            p->model  = mdlnum;
            p->speed  = pr.speed;
            p->travel = pr.travel;
            p->mins   = world->models[mdlnum].mins;
            p->maxs   = world->models[mdlnum].maxs;

            if ( p->speed  <= 0.0f ) p->speed  = 150.0f;
            if ( p->travel <= 0.0f ) p->travel = world->models[mdlnum].maxs.z - world->models[mdlnum].mins.z;

            /* Quake positions the brush raised, so a lift at rest is
               one full travel below where the map drew it. */
            p->state = ENT_PLAT_DOWN;
            p->kind  = ENT_PLAT_KIND_PLAT;
            p->targeted = 0;
            p->first = p->corner = -1;
            p->wait_left = 0.0f;
            world->brush[mdlnum].ofs.z = -p->travel;

            world->plat_count++;
        }
    }

    for ( i = 0; i < h.nhide; i++ ) {
        short hideidx;
        _fmemcpy( &hideidx, buf + ofs, sizeof(short) ); ofs += sizeof(short);

        if ( hideidx > 0 && hideidx < world->model_count ) {
            world->brush[hideidx].draw  = 0;
            world->brush[hideidx].solid = 0;
        }
    }

    ent_load_items( world, buf, &ofs, h.nitem );

    ent_load_doors( world, buf, &ofs, h.ndoor );
    ent_load_trigs( world, buf, &ofs, h.ntrig );

    /* the map's ambient_* points, recorded now and started by
       snd_init with the card: their volume is the map's, their place
       the mixer's to re-derive every frame. */
    for ( i = 0; i < h.namb; i++ ) {
        EntsAmb ar;
        _fmemcpy( &ar, buf + ofs, sizeof(EntsAmb) ); ofs += sizeof(EntsAmb);
        snd_ambient( ar.snd, ar.vol, &ar.org );
    }

    ent_load_trains( world, buf, &ofs, h.ntrain );
    ent_load_corners( world, buf, &ofs, h.ncorner );

    ent_load_crates( world, buf, &ofs, h.ncrate );
    ent_load_lights( world, buf, &ofs, h.nlight );

    ent_load_msgs( world, buf, &ofs, h.nmsg, n );

    /* Every train stands on its first corner, which needs the corner
       table, and every door learns its group, which needs them all. */
    for ( i = 0; i < world->plat_count; i++ )
        if ( world->plat[i].kind == ENT_PLAT_KIND_TRAIN ) ent_train_init( world, &world->plat[i] );
    ent_link_doors( world );

    /* and every pickup onto the floor under it, which needs every plat
       and door already at the position it loaded in: the trace walks
       their hulls too. */
    pl_items_drop( world );

    /* and every monster onto it, which needs the same hulls and, for a
       patrol, the corner table this file reads two calls up. */
    for ( i = 0; i < world->mon_count; i++ ) mdl_spawn( world, &world->mon[i] );

    qglMemFree( (long) buf );
}
