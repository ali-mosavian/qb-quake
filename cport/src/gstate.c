/*
 * gstate.c -- see gstate.h.
 */

#include "gstate.h"
#include "mdl_ai.h"
#include "item.h"
#include "qgl.h"

void pl_reset_player( Player *player, Fight *fight, Renderer *rdr )
{
    fight->health     = PL_HEALTH;
    fight->shells     = PL_SHELLS;
    fight->armor      = 0;
    fight->armor_type = 0.0f;
    fight->secrets    = 0;
    fight->items      = PL_IT_SHOTGUN;
    fight->weapon     = PL_IT_SHOTGUN;
    fight->nails      = 0;
    fight->rockets    = 0;
    fight->quad_until = 0.0f;
    fight->suit_until = 0.0f;
    fight->pent_until = 0.0f;
    fight->next_fire  = 0.0f;
    fight->show_hostile = 0.0f;
    fight->rot_at     = 0.0f;
    (void) rdr;

    player->pos = fight->spawn;
    player->vel.x = player->vel.y = player->vel.z = 0.0f;
}

void pl_respawn( Player *player, Fight *fight, Renderer *rdr )
{
    fight->deaths++;
    pl_reset_player( player, fight, rdr );
}

void pl_game_reset( World *world, Player *player, Camera *cam, Fight *fight,
                     Renderer *rdr, short scr_x_res )
{
    short i;

    for ( i = 0; i < world->mon_count; i++ ) {
        world->mon[i].pos = world->mon[i].spawn;
        mdl_spawn( world, &world->mon[i] );
    }
    /* the map's own pickups back; a backpack a soldier dropped is not
       one of them, so the count goes back to what ents.bin held */
    world->item_count = (short) ( world->item_max - world->mon_count );
    for ( i = 0; i < world->item_count; i++ ) world->item[i].gone = 0;
    for ( i = 0; i < PL_NAILS_MAX; i++ ) fight->nail[i].alive = 0;

    pl_reset_player( player, fight, rdr );
    /* on foot, facing the map's way: the camera reads its angle from
       the mouse, so the mouse is what has to move */
    player->no_clip = 0;
    qglMousePos( (short) ( ( scr_x_res - 1 ) * cam->start_angle / 360.0f ), 110 );
}

void host_state( World *world, Player *player, Camera *cam, Fight *fight,
                  Renderer *rdr, short scr_x_res )
{
    (void) world; (void) cam; (void) scr_x_res;

    if ( fight->state == GS_DEAD ) {
        if ( rdr->anim_time >= fight->state_until ) {
            pl_respawn( player, fight, rdr );
            fight->state = GS_PLAY;
        }
        return;
    }
    if ( fight->health <= 0 ) {
        fight->state = GS_DEAD;
        fight->state_until = rdr->anim_time + PL_DEATH_PAUSE;
    }
}
