#ifndef __ENT_MOVE_H__
#define __ENT_MOVE_H__

#include "world.h"
#include "renderer.h"
#include "fight.h"

/*
 * The movers: doors, triggers, buttons and trains. One subsystem with
 * ent.c -- same prefix, same data -- in its own file because ent.c
 * loads and places and this runs a state machine every tick.
 */

/*
 * name: ent_use_targets
 * desc: SUB_UseTargets. Fires everything whose name is id: a door's
 *       group goes, a waiting train starts, a counter counts down, a
 *       relay passes it on. id 0 is none.
 */
void ent_use_targets( World *world, Player *player, Fight *fight,
                       Renderer *rdr, short id );

/*
 * name: ent_move_doors
 * desc: The touch fields, then every door's state machine. A door with
 *       a targetname waits for ent_use_targets and only says its
 *       message when touched; one with a key wants the key.
 */
void ent_move_doors( World *world, Player *player, Fight *fight,
                      Renderer *rdr, float dt );

/*
 * name: ent_move_trigs
 * desc: The touches, and every button's travel. A button fires when it
 *       ARRIVES, not when it is pressed, as button_wait does.
 */
void ent_move_trigs( World *world, Player *player, Camera *cam, Fight *fight,
                      Renderer *rdr, float dt, short scr_x_res, short scr_y_res );

/*
 * name: ent_move_trains
 * desc: Every func_train one leg on, carrying its rider.
 */
void ent_move_trains( World *world, Player *player, float dt );

/*
 * name: ent_train_init
 * desc: func_train_find: the brush's mins on its first corner. One with
 *       a targetname waits there for its trigger; the rest go at once.
 */
void ent_train_init( World *world, PlatEnt far *p );

/*
 * name: ent_link_doors
 * desc: LinkDoors: doors whose brushes touch open as one group, unless
 *       DOOR_DONT_LINK. Run once, after every door is loaded.
 */
void ent_link_doors( World *world );

/*
 * name: ent_say
 * desc: centerprint: msg is shown for ENT_MSG_TIME. An empty one is
 *       not a message and clears nothing.
 */
/*
 * name: ent_door_fire / ent_trig_fire
 * desc: Send a door's linked group out, and fire a trigger's target.
 *       Public because a pellet or a nail fires a shootable trigger and
 *       a secret door, which is fight.c's business, not a touch.
 */
void ent_door_fire( World *world, short grp );
void ent_trig_fire( World *world, Player *player, Fight *fight,
                     Renderer *rdr, short k );

void ent_say( Fight *fight, Renderer *rdr, char far *msg );

/*
 * name: ent_reset
 * desc: Every door shut and every trigger, button and train as the map
 *       loaded. pl_game_reset's half of the world.
 */
void ent_reset( World *world, Fight *fight );

#endif
