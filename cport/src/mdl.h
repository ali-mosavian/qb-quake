#ifndef __MDL_H__
#define __MDL_H__

#include "world.h"
#include "mdltypes.h"

/*
 * mdl.h -- one alias (.mdl) model, and the monsters spawned from it.
 * d_mdl.bas's MdlState/MdlEnt, minus the AI, which is not ported yet:
 * a monster here stands where the map put it, facing the map's way.
 *
 * The model's vertices live in EMS, one page for all its frames and a
 * second for its triangles -- 32K of an EMS handle, nothing in the far
 * heap. That is what decides the frame count: the dog's 236 vertices
 * leave room for 23 frames, the soldier's 170 for 32.
 */
/*
 * name: mdl_load
 * desc: <name>.geo/.vtx/.skn out of the map container. Leaves
 *       m->loaded 0 and says why on stderr if the model will not fit
 *       or is not there.
 */
void mdl_load( MdlState *m, char *name );

/*
 * name: mdl_load_monsters
 * desc: ents.bin's monster records, from the reader's own offset, and
 *       the models the kinds among them need.
 */
void mdl_load_monsters( World *world, unsigned char far *buf, long *ofs, short count );

/* The model for a kind, or NULL when the map spawns none of it. */
MdlState *mdl_of( World *world, short kind );

#endif
