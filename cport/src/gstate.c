/*
 * gstate.c -- see gstate.h.
 */

#include "gstate.h"
#include "mdl_ai.h"
#include "item.h"
#include "ent_move.h"
#include "snd.h"
#include "qgl.h"
#include <stdio.h>
#include <stdlib.h>

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

/* SetChangeParms: the kit the next level starts with, to CARRY.BIN.
   Keys and powerups are the level's own and do not travel. */
void pl_carry_save( Fight *fight )
{
    PlayerCarry c;
    FILE *f;

    c.items   = fight->items & ~( (long) ( PL_IT_KEY1 | PL_IT_KEY2 ) );
    c.health  = fight->health;
    if ( c.health > PL_HEALTH )    c.health = PL_HEALTH;
    if ( c.health < PL_CARRY_MIN ) c.health = PL_CARRY_MIN;
    c.armor      = fight->armor;
    c.armor_type = fight->armor_type;
    c.shells     = fight->shells;
    if ( c.shells < PL_SHELLS ) c.shells = PL_SHELLS;
    c.nails   = fight->nails;
    c.rockets = fight->rockets;
    c.weapon  = fight->weapon;

    f = fopen( "CARRY.BIN", "wb" );
    if ( !f ) return;
    fwrite( &c, sizeof(c), 1, f );
    fclose( f );
}

/* DecodeLevelParms: -carry reads it back over pl_reset_player's kit.
   A short or missing file leaves the starting kit alone rather than
   filling the player with whatever the read did not overwrite. */
void pl_carry_load( Fight *fight )
{
    PlayerCarry c;
    FILE *f = fopen( "CARRY.BIN", "rb" );

    if ( !f ) return;
    if ( fread( &c, sizeof(c), 1, f ) != 1 ) { fclose( f ); return; }
    fclose( f );

    fight->items      = c.items;
    fight->health     = c.health;
    fight->armor      = c.armor;
    fight->armor_type = c.armor_type;
    fight->shells     = c.shells;
    fight->nails      = c.nails;
    fight->rockets    = c.rockets;
    fight->weapon     = c.weapon;
}

/* execute_changelevel's intermission: the view from the map's
   info_intermission, at its mangle, the player held there in noclip.
   Quake's pitch is positive down, ours up. */
void ent_intermission( Player *player, Camera *cam, Fight *fight,
                        short scr_x_res, short scr_y_res )
{
    float yaw;

    player->no_clip = -1;
    player->pos = fight->inter;
    player->vel.x = player->vel.y = player->vel.z = 0.0f;
    cam->pos.x = fight->inter.x;
    cam->pos.z = fight->inter.y;
    cam->pos.y = fight->inter.z;

    yaw = 360.0f - fight->inter_yaw;
    if ( yaw >= 360.0f ) yaw -= 360.0f;
    qglMousePos( (short) ( ( scr_x_res - 1 ) * yaw / 360.0f ),
                 (short) ( scr_y_res * ( 90.0f + fight->inter_pitch ) / 180.0f - 2.0f ) );
}

/* changelevel: the kit to CARRY.BIN, the next map's run to NEXT.BAT,
   and the host loop ends. The next map is a new process because its
   container is a different file and nothing here unloads one.
   run.sh runs NEXT.BAT from a copy, since a batch deleted while it is
   running is "Batch file missing". */
void host_next_level( Fight *fight )
{
    FILE *f;

    pl_carry_save( fight );
    f = fopen( "NEXT.BAT", "w" );
    if ( f ) {
        fprintf( f, "QCPORT.EXE %s.qmp -carry%s >> run.out\n",
                 fight->next_map, fight->next_flags );
        fclose( f );
    }
    fight->state = GS_NEXT;
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
    fight->level_start = rdr->anim_time;
    qglMousePos( (short) ( ( scr_x_res - 1 ) * cam->start_angle / 360.0f ), 110 );
}

void host_state( World *world, Player *player, Camera *cam, Fight *fight,
                  Renderer *rdr, short fire, short scr_x_res )
{
    short i, ndead;

    switch ( fight->state ) {
    case GS_PLAY:
        if ( fight->health <= 0 ) {
            fight->state = GS_DEAD;
            /* PlayerDie: GibPlayer's gib or udeath under -40, else
               DeathSound's h2odeath under water or one of five,
               rint(random() * 4 + 1) */
            if ( fight->health < -40 )
                i = (short) ( rand() & 1 ? SND_GIB : SND_UDEATH );
            else if ( player->water_level == 3 )
                i = SND_H2ODEATH;
            else if ( ( ndead = (short) ( (float) rand() / RAND_MAX * 4.0f + 0.5f ) ) == 0 )
                i = SND_DEATH;
            else
                i = (short) ( SND_DEATH2 + ndead - 1 );
            snd_start( player, SND_ENT_PLAYER, CHAN_VOICE, i, &player->pos, ATTN_NONE );
            fight->state_until = rdr->anim_time + PL_DEATH_PAUSE;
            break;
        }
        ndead = 0;
        for ( i = 0; i < world->mon_count; i++ )
            if ( world->mon[i].state == MDL_ST_DEAD ) ndead++;
        if ( world->mon_count > 0 && ndead == world->mon_count ) fight->state = GS_WON;
        break;

    case GS_DEAD:
        if ( rdr->anim_time >= fight->state_until ) {
            pl_respawn( player, fight, rdr );
            fight->state = GS_PLAY;
        }
        break;

    case GS_EXIT:
        /* IntermissionThink: the tally stays up for exittime whatever
           the player does, then a held button goes on. With no next
           map -- dm3ish, and every map whose changelevel names one the
           shareware pak does not have -- this level again. */
        if ( fire && rdr->anim_time >= fight->exit_time + PL_INTER_HOLD ) {
            if ( fight->next_map[0] ) {
                host_next_level( fight );
            } else {
                pl_game_reset( world, player, cam, fight, rdr, scr_x_res );
                ent_reset( world, fight );
                fight->state = GS_PLAY;
            }
        }
        break;

    case GS_NEXT:
        /* already leaving: the host loop ends at the top of the next
           frame, and a frame may run more than one tick -- without
           this, a fire press in the second of them would put the run
           back into GS_PLAY with NEXT.BAT already written. */
        return;

    default:
        /* GS_WON: a fresh press, not the one still held from the shot
           that killed the last monster. */
        if ( fire && !fight->fire_prev ) {
            if ( fight->state == GS_WON ) {
                pl_game_reset( world, player, cam, fight, rdr, scr_x_res );
                ent_reset( world, fight );
            }
            fight->state = GS_PLAY;
        }
        break;
    }
    fight->fire_prev = fire;
}
