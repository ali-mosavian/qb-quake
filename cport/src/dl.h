#ifndef __DL_H__
#define __DL_H__

#include "renderer.h"
#include "bsptypes.h"
#include "fight.h"

/* CL_AllocDlight keys: an entity's light reuses its own slot. 0 is a
   light no entity owns, the explosion's; a projectile's is negative,
   since the monster count has no cap. */
#define DL_KEY_PLAYER 1
#define DL_KEY_MON    2      /* + the monster's index */

/* CL_DecayLights, at the top of a tick. */
void dl_decay( Renderer *rdr, float dt );

/* EF_MUZZLEFLASH from org, the entity's origin, facing fwd (unit). */
void dl_muzzle( Renderer *rdr, short key, BspVec3 *org, BspVec3 *fwd );

/* TE_EXPLOSION's light. */
void dl_explosion( Renderer *rdr, BspVec3 *org );

/* The relink's per-tick lights: the quad's and pentagram's EF_DIMLIGHT
   on the player, EF_ROCKET on rockets and lava balls. At the end of a
   tick, after anim_time has moved. */
void dl_relink( Renderer *rdr, Player *player, Fight *fight );

/* The lights a frame draws, a bit a slot; 0 under -nodlight. */
unsigned long dl_live( Renderer *rdr );

/* R_MarkLights, per face rather than per node: the live lights whose
   sphere reaches the face's plane within a radius of its luxel rect --
   texturemins tms/tmt, extents extw/exth -- where a luxel can take
   light. The plane alone marks every coplanar face on the map. */
unsigned long dl_mark( Renderer *rdr, unsigned long live, Plane far *pl,
                       TexInfo far *ti, short tms, short tmt,
                       short extw, short exth );

/* The surface cache stag of a lit face: negative, which ls_face_key never
   is, and new every tick, so a lit face rebuilds each tick it stays lit
   and once after. */
short dl_stag( Renderer *rdr );

/* R_AddDynamicLights onto a lmw x lmh grid of luxel bytes. */
void dl_add_luxels( Renderer *rdr, unsigned long bits, Plane far *pl,
                    TexInfo far *ti, short tms, short tmt,
                    unsigned char *lum, short lmw, short lmh );

/* 1, or the negative number of the check that failed. */
short dl_selftest( void );

#endif
