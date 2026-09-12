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
 * name: pl_carry_save / pl_carry_load
 * desc: SetChangeParms and DecodeLevelParms: the kit that travels to
 *       the next map, through CARRY.BIN. Keys and powerups stay behind.
 */
void pl_carry_save( Fight *fight );
void pl_carry_load( Fight *fight );

/*
 * name: ent_intermission
 * desc: execute_changelevel's view: the camera at the map's
 *       info_intermission, at its mangle, the player held there.
 */
void ent_intermission( Player *player, Camera *cam, Fight *fight,
                        short scr_x_res, short scr_y_res );

/*
 * name: host_next_level
 * desc: The kit to CARRY.BIN and the next map's command line to
 *       NEXT.BAT, then GS_NEXT, which ends the host loop. A map is a
 *       container file and a run loads one, so the next level is the
 *       next process.
 */
void host_next_level( Fight *fight );

/*
 * name: host_state
 * desc: One tick of the state machine: dying and respawning, the area
 *       cleared, and the intermission's held fire -- on to the next
 *       map, or this one again.
 */
void host_state( World *world, Player *player, Camera *cam, Fight *fight,
                  Renderer *rdr, short fire, short scr_x_res );

#endif
