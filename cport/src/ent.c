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
#include "pl_move.h"    /* PL_FEET/PL_TELE_LIFT -- shared with pl_move.c, one fact one place */
#include "r_bsp.h"      /* r_point_leaf -- r_bsp.bas, not yet ported */
#include "assets.h"

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
    float x0 = sm->mins.x, x1 = sm->maxs.x;
    float y0 = sm->mins.y, y1 = sm->maxs.y;
    float z0 = sm->mins.z + world->brush[m].zofs;
    float z1 = sm->maxs.z + world->brush[m].zofs;

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
    for ( m = 1; m < world->model_count; m++ ) {
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
    top = plt->maxs.z + world->brush[plt->model].zofs;

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

        was = br->zofs;
        if ( br->zofs < goal ) {
            step_z = plt->speed * dt;
            br->zofs += step_z;
            if ( br->zofs > goal ) br->zofs = goal;
        } else if ( br->zofs > goal ) {
            step_z = plt->speed * dt;
            br->zofs -= step_z;
            if ( br->zofs < goal ) br->zofs = goal;
        }
        moved = br->zofs - was;

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
void ent_load_spawn( World *world, Camera *cam )
{
    long n;
    unsigned char far *buf = asset_load_whole( "assets.zip::ents.bin", &n );
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
    cam->start_angle = h.angle;
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
    unsigned char far *buf = asset_load_whole( "assets.zip::ents.bin", &n );
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
    world->face_mdl = (short far *) qglMemAlloc( (long) world->face_count * sizeof(short) );
    world->tele = (Teleporter far *) qglMemAlloc( (long) (h.ntele ? h.ntele : 1) * sizeof(Teleporter) );
    world->plat = (PlatEnt far *) qglMemAlloc( (long) (h.nplat ? h.nplat : 1) * sizeof(PlatEnt) );
    if ( !world->brush || !world->face_mdl || !world->tele || !world->plat ) {
        fprintf( stderr, "ents.bin: out of memory\n" );
        exit( 1 );
    }

    world->tele_count = 0;
    world->plat_count = 0;

    /* every submodel draws and blocks unless something claims it as a trigger */
    for ( i = 0; i < world->model_count; i++ ) {
        world->brush[i].draw  = 1;
        world->brush[i].solid = 1;
        world->brush[i].zofs  = 0.0f;
    }

    /* Which submodel owns each face. The world's faces come first and
       the submodels' follow in order, so this is a walk, not a search. */
    for ( i = 0; i < world->face_count; i++ ) world->face_mdl[i] = 0;

    for ( j = 1; j < world->model_count; j++ ) {
        for ( k = (short) world->models[j].first_face;
              k < (short) (world->models[j].first_face + world->models[j].num_faces); k++ ) {
            if ( k >= 0 && k < world->face_count ) world->face_mdl[k] = j;
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
            world->brush[mdlnum].zofs = -p->travel;

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

    qglMemFree( (long) buf );
}
