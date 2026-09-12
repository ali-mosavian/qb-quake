#ifndef __MDLTYPES_H__
#define __MDLTYPES_H__

#include "bsptypes.h"

/*
 * mdltypes.h -- MdlState and MdlEnt alone, so world.h can hold them
 * without including mdl.h, which includes world.h. Everything else
 * about a model is mdl.h's.
 */
#define MDL_MAXV      236        /* the dog's, the largest that fits */
#define MDL_TRI_BYTES 18
#define MDL_KINDS     8

/* MDL_KIND_*, mkassets.py's own numbering */
#define MDL_KIND_ARMY     0
#define MDL_KIND_KNIGHT   1
#define MDL_KIND_DOG      2
#define MDL_KIND_OGRE     3
#define MDL_KIND_DEMON    4
#define MDL_KIND_ZOMBIE   5
#define MDL_KIND_WIZARD   6
#define MDL_KIND_SHAMBLER 7

/* mkmdl.py's .geo header, 48 bytes. Read whole and picked apart, so
   the field order here is the file's. */
typedef struct {
    long  magic;
    short ntri, nvert, nframe;
    short skin_w, skin_h;
    BspVec3 scale;              /* vertex byte -> model unit */
    BspVec3 origin;
    short nstand, nrun, ndeath, npain, natk;
} MdlHead;

#define REC_MDLHEAD 48
typedef char rec_mdlhead_ok[ sizeof(MdlHead) == REC_MDLHEAD ? 1 : -1 ];

/* One loaded model, shared by every monster of its kind. */
typedef struct {
    short   loaded;
    short   ntri, nvert, nframe;
    QSurf   skin;
    short   vtx_hnd;            /* qglGemAlloc: page 0 vertices, page 1 triangles */
    BspVec3 scale, origin;
    float   radius, zlo, zhi;   /* the box any frame at any yaw fits in */
    short   nstand, nrun, ndeath, npain, natk;
} MdlState;

/* One spawned monster. BSP space, Z up, like Player.pos. */
typedef struct {
    BspVec3 pos;
    float   yaw;                /* Quake's own, CCW from +x -- not mirrored */
    short   kind;
    short   frame;              /* into the model's frame list */
} MdlEnt;


#endif
