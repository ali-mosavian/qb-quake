#ifndef __ENT_H__
#define __ENT_H__

#include "renderer.h"
#include "world.h"

short ent_find_node( short m, World *world );
short ent_point_leaf( Vec3 *p, World *world );
short ent_plat_touched( Player *player, World *world, short p );
void  ent_check_teleport( Player *player, World *world, short scr_x_res );
void  ent_move_plats( World *world, Player *player, float dt );
void  ent_place_models( World *world );

/* q_ent.bi's EntsHead/EntsTele/EntsPlat -- ents.bin's own layout,
   mkassets.py's already-resolved entity data (targetname pairing,
   trigger/plat validation, all done offline; nothing here parses the
   map's entity TEXT, which BASIC's own 32,767-byte string cap made
   impossible for some maps in the first place). */
typedef struct {
    Vec3  spawn;
    float angle;
    short nmodels;   /* stamp: must equal the map's model count, or
                         these assets are from another map */
    short ntele;
    short nplat;
    short nhide;
} EntsHead;

typedef struct {
    short model;
    Vec3  dest;
    float yaw;
} EntsTele;

typedef struct {
    short model;
    float speed;
    float travel;
} EntsPlat;

/*
 * name: ent_load_spawn
 * desc: The spawn point, from ents.bin. BSP is Z-up and the camera is
 *       Y-up, so y and z swap here.
 */
void ent_load_spawn( World *world, Camera *cam );

/*
 * name: ent_load_teleports
 * desc: Loads ents.bin: teleporter pairs already matched by
 *       targetname, plats and hidden submodels already validated, all
 *       by mkassets.py. What stays here is what needs the loaded
 *       submodels -- trigger volumes and plat defaults come from
 *       world->models, which mkassets has no reason to duplicate.
 *       Builds world->brush/face_mdl/tele/plat and sets world->
 *       tele_count/plat_count.
 */
void ent_load_teleports( World *world );

#endif
