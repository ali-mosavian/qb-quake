#ifndef __GSTATE_H__
#define __GSTATE_H__

#include "world.h"
#include "renderer.h"
#include "pl_move.h"
#include "fight.h"

/*
 * gstate.h -- the game's own state: dying, respawning, and putting the
 * level back. pl_move.bas's half of it, which is not physics; the state
 * machine that drives it is host_tick's.
 */

/*
 * name: pl_reset_player
 * desc: The kit a level starts with, and the player back at the spawn.
 */
void pl_reset_player( Player *player, Fight *fight, Renderer *rdr );

/*
 * name: pl_respawn
 * desc: One death counted, then the kit again. The world keeps
 *       whatever the player did to it -- Quake's own respawn.
 */
void pl_respawn( Player *player, Fight *fight, Renderer *rdr );

/*
 * name: pl_game_reset
 * desc: The fight again: every monster back at its spawn, every pickup
 *       back, the player at the start. Kills and deaths keep counting.
 */
void pl_game_reset( World *world, Player *player, Camera *cam, Fight *fight,
                     Renderer *rdr, short scr_x_res );

/*
 * name: host_state
 * desc: One tick of the state machine: death when the health runs out,
 *       and the respawn once the pause is up.
 */
void host_state( World *world, Player *player, Camera *cam, Fight *fight,
                  Renderer *rdr, short scr_x_res );

#endif
