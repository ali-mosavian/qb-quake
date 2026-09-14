#ifndef __ENT_H__
#define __ENT_H__

#include "renderer.h"
#include "world.h"
#include "fight.h"

short ent_find_node( short m, World *world );
short ent_point_leaf( BspVec3 *p, World *world );
short ent_plat_touched( Player *player, World *world, short p );
void  ent_check_teleport( Player *player, World *world, short scr_x_res );
void  ent_move_plats( World *world, Player *player, float dt );
void  ent_place_models( World *world );

/* q_ent.bi's EntsHead/EntsTele/EntsPlat -- ents.bin's own layout,
   mkassets.py's already-resolved entity data (targetname pairing,
   trigger/plat validation, all done offline; nothing here parses the
   map's entity TEXT, which BASIC's own 32,767-byte string cap made
   impossible for some maps in the first place). */
/* q_ent.bi's EntsHead -- 76 bytes, the whole of what mkassets.py now
   resolves out of the entities text. cport reads the spawn, the
   teleporters, the plats and the hidden submodels; the rest are counts
   it skips over, and they are here because the records they size sit
   between the ones it does read. */
typedef struct {
    BspVec3 spawn;
    float   angle;
    BspVec3 inter;          /* info_intermission: where the exit looks from */
    float   inter_pitch;
    float   inter_yaw;
    short   nmodels;        /* stamp: must equal the map's model count, or
                                these assets are from another map */
    short   ntele;
    short   nplat;
    short   nhide;
    short   nitem;
    short   ndoor;
    short   ntrig;
    short   nmon;
    short   namb;
    short   ntrain;
    short   ncorner;
    short   worldtype;
    short   ncrate;
    float   gravity;
    char    next_map[8];    /* space padded, blank for none */
    short   nmsg;
    short   nlight;
} EntsHead;

/* A monster record. Not read -- the file puts the monsters FIRST, ahead
   of the teleporters, so its size is what the reader has to skip. */
typedef struct {
    short   kind;
    BspVec3 org;
    float   angle;
    short   first;
} EntsMon;

typedef struct {
    short model;
    BspVec3  dest;
    float yaw;
} EntsTele;

typedef struct {
    short model;
    float speed;
    float travel;
} EntsPlat;

/* The records between the ones cport reads. ents.bin's order is
   monsters, teleporters, plats, hides, items, doors, triggers,
   ambients, trains, corners, crates, lights, messages. */
typedef struct {
    short   kind, amount, target, crate;
    BspVec3 org;
} EntsItem;

typedef struct {
    short   model;
    BspVec3 travel;
    BspVec3 mid;
    float   speed, hold;
    short   start_open, nolink, targeted, secret, shoot, snd, key, msg;
} EntsDoor;

typedef struct {
    short   model, kind, target, name, kill, count;
    float   wait, speed;
    BspVec3 travel;
    BspVec3 org;
    short   snd, msg;
    float   delay;
} EntsTrig;

typedef struct {
    short   snd, vol;
    BspVec3 org;
} EntsAmb;

typedef struct {
    short model;
    float speed;
    short targeted, first;
} EntsTrain;

typedef struct {
    short name, style, on;
} EntsLight;

/* q_ent.bi's PathCorner is the file record too. */

/* ents.bin's own records, checked the same way bsptypes.h checks the
   map's -- see the note there. */
#define REC_ENTSHEAD 78
#define REC_ENTSMON  20
#define REC_ENTSTELE 18
#define REC_ENTSPLAT 10
#define REC_ENTSITEM 20
#define REC_CRATE    92
#define REC_ENTSDOOR 50
#define REC_ENTSTRIG 52
#define REC_ENTSAMB  16
#define REC_ENTSTRAIN 10
#define REC_PATHCORNER 18
#define REC_ENTSLIGHT 6
typedef char rec_entslight_ok[ sizeof(EntsLight) == REC_ENTSLIGHT ? 1 : -1 ];

typedef char rec_entshead_ok[ sizeof(EntsHead) == REC_ENTSHEAD ? 1 : -1 ];
typedef char rec_entsmon_ok [ sizeof(EntsMon)  == REC_ENTSMON  ? 1 : -1 ];
typedef char rec_entstele_ok[ sizeof(EntsTele) == REC_ENTSTELE ? 1 : -1 ];
typedef char rec_entsplat_ok[ sizeof(EntsPlat) == REC_ENTSPLAT ? 1 : -1 ];
typedef char rec_entsitem_ok[ sizeof(EntsItem) == REC_ENTSITEM ? 1 : -1 ];
typedef char rec_crate_ok[ sizeof(CrateModel) == REC_CRATE ? 1 : -1 ];
typedef char rec_entsdoor_ok[ sizeof(EntsDoor) == REC_ENTSDOOR ? 1 : -1 ];
typedef char rec_entstrig_ok[ sizeof(EntsTrig) == REC_ENTSTRIG ? 1 : -1 ];
typedef char rec_entsamb_ok [ sizeof(EntsAmb)  == REC_ENTSAMB  ? 1 : -1 ];
typedef char rec_entstrain_ok[ sizeof(EntsTrain) == REC_ENTSTRAIN ? 1 : -1 ];
typedef char rec_pathcorner_ok[ sizeof(PathCorner) == REC_PATHCORNER ? 1 : -1 ];

/*
 * name: ent_load_spawn
 * desc: The spawn point, from ents.bin. BSP is Z-up and the camera is
 *       Y-up, so y and z swap here.
 */
void ent_load_spawn( World *world, Camera *cam, Fight *fight );

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

/* the map's trigger_secret count, for the intermission's tally */
short ent_secret_total( World *world );

#endif
