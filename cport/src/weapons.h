#ifndef __WEAPONS_H__
#define __WEAPONS_H__

#include "world.h"
#include "renderer.h"
#include "pl_move.h"
#include "input.h"
#include "fight.h"

/*
 * weapons.h -- the player's guns and everything in flight, plus the
 * monster's side of taking a hit. weapons.qc's W_Fire*, spike_touch,
 * GrenadeExplode and T_RadiusDamage, and ai.qc's pain and death.
 *
 * fight.h holds the state and the numbers; this holds what acts on it,
 * because these signatures need World and Player and fight.h is
 * included by both.
 */

/*
 * name: pl_fire
 * desc: One shot of whatever is in hand, if attack_finished has passed.
 *       The shotguns are hitscan -- every pellet traced through the
 *       world, then against every monster's box, an exploding box, a
 *       shootable trigger and a secret door -- and the damage lands per
 *       monster once all the pellets are in, as ApplyMultiDamage does.
 *       The other four leave a Spike.
 */
void pl_fire( World *world, Player *player, Camera *cam, Fight *fight,
               Renderer *rdr );

/*
 * name: pl_select_weapon
 * desc: W_ChangeWeapon on the number keys, for the weapons owned.
 */
void pl_select_weapon( Input *input, Fight *fight );

/*
 * name: pl_spikes_tick
 * desc: Every projectile a step along its velocity: what it hits, what
 *       it does about it, and what ends it.
 */
void pl_spikes_tick( World *world, Player *player, Fight *fight,
                      Renderer *rdr, float dt );

/*
 * name: pl_traps_tick
 * desc: The spike shooters and fireball emitters a trigger armed this
 *       tick, each sending one hostile Spike.
 */
void pl_traps_tick( World *world, Fight *fight, Renderer *rdr );

/*
 * name: mdl_damage
 * desc: T_Damage on a monster: its death at 0 -- and a soldier's
 *       backpack -- or its pain, gated by pain_finished, and the player
 *       is now its enemy.
 */
void mdl_damage( World *world, Player *player, Fight *fight, Renderer *rdr,
                  MdlEnt far *ent, short dmg );

/*
 * name: mdl_spike / mdl_grenade / mdl_gib
 * desc: The three monster attacks that leave a projectile: the wizard's
 *       spikes, the ogre's grenade and the zombie's gib.
 */
void mdl_spike( World *world, Player *player, Fight *fight, Renderer *rdr,
                 MdlEnt far *ent );
void mdl_grenade( Player *player, Fight *fight, Renderer *rdr, MdlEnt far *ent );
void mdl_gib( Player *player, Fight *fight, Renderer *rdr, MdlEnt far *ent );

/*
 * name: pl_ray_box / pl_spread_dir / pl_nail_free
 * desc: Shared with the monsters' own fire (mdl_ai.c): a ray against a
 *       box, a pellet's spread, and a free projectile slot with every
 *       flag of the last one cleared.
 */
float pl_ray_box( BspVec3 *mins, BspVec3 *maxs, BspVec3 *org,
                   BspVec3 *dir, float maxt );
float mdl_ray_player( BspVec3 *pl, BspVec3 *org, BspVec3 *dir, float maxt );
void  pl_spread_dir( BspVec3 *dir, float sx, float sy, BspVec3 *out );
short pl_nail_free( Fight *fight );

#endif
