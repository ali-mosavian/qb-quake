/*
 * item.c -- the pickups. pl_move.bas's pl_items_drop, pl_item_sound's
 * caller-visible half, pl_key_name and pl_items_touch.
 *
 * Nothing here traces the player: the touch is a box test against the
 * item's, exactly as Quake's own touch is, and the only trace is the
 * one that drops each item onto the floor once at load.
 *
 * Not ported with the rest: pl_boxes_sync -- an exploding box is solid in the BASIC branch
 * because pl_trace keeps a table of solid boxes, which cport's
 * pl_trace does not have. So an explobox here is drawn and walked
 * through rather than walked around, and nothing can shoot it.
 */

#include <mem.h>    /* _fmemcpy */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "item.h"
#include "snd.h"
#include "ent.h"
#include "ent_move.h"
#include "pl_trace.h"
#include "qgl.h"

void ent_load_items( World *world, unsigned char far *buf, long *ofs, short count )
{
    short i;

    /* Room for the map's own plus one backpack a monster: a dead
       soldier drops one, and nothing else is ever added. */
    world->item_count = count;
    world->item_max = (short) ( count + world->mon_count );
    world->item = (ItemEnt far *) qglMemAlloc(
                     (long) ( world->item_max ? world->item_max : 1 ) * sizeof(ItemEnt) );
    if ( !world->item ) {
        fprintf( stderr, "ents.bin: out of memory for %d items\n", (int) count );
        exit( 1 );
    }

    for ( i = 0; i < count; i++ ) {
        EntsItem it;
        ItemEnt far *p = &world->item[i];

        _fmemcpy( &it, buf + *ofs, sizeof(EntsItem) ); *ofs += sizeof(EntsItem);

        p->kind   = it.kind;
        p->amount = it.amount;
        p->target = it.target;
        p->crate  = it.crate;
        p->pos    = it.org;
        p->gone   = 0;
    }
}

void ent_load_crates( World *world, unsigned char far *buf, long *ofs, short count )
{
    world->crate_count = count;
    world->crate = (CrateModel far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(CrateModel) );
    if ( !world->crate ) {
        fprintf( stderr, "ents.bin: out of memory for %d crates\n", (int) count );
        exit( 1 );
    }
    if ( count ) _fmemcpy( world->crate, buf + *ofs, (long) count * sizeof(CrateModel) );
    *ofs += (long) count * sizeof(CrateModel);
}

/*
 * The trace starts PL_FEET ABOVE the origin, not at it:
 * SV_ClipMoveToEntity offsets the hull's clip_mins against the item's
 * mins, and an item the map put within 24 units of its floor otherwise
 * starts inside hull 1's grown solid. Where a room lay under it within
 * 256 it fell through; where none did it stopped 24 above the floor and
 * floated.
 */
void pl_items_drop( World *world )
{
    short i;
    BspVec3 org, fin;
    TraceResult tr;

    for ( i = 0; i < world->item_count; i++ ) {
        org = world->item[i].pos;
        org.z += PL_FEET;
        fin = org;
        fin.z -= 256.0f;
        pl_trace( world, &org, &fin, &tr );
        if ( tr.frac < 1.0f && !tr.all_solid ) {
            world->item[i].pos = tr.end_pos;
            world->item[i].pos.z -= PL_FEET;
        }
    }
}

/* items.qc's netname for a key: silver or gold, then the worldtype's word */
static void pl_key_name( char *out, short wt, short kind )
{
    strcpy( out, "You got the " );
    strcat( out, kind == ENT_ITEM_KEY2 ? "gold " : "silver " );
    strcat( out, wt == 1 ? "runekey" : ( wt == 2 ? "keycard" : "key" ) );
}

/* which sound a pickup makes: the ammo's, the weapon's, the armor's,
   the powerup's, or one of health's three by how much it heals. A key's
   is the worldtype's, as its name is. */
static short pl_item_sound( Fight *fight, ItemEnt far *it )
{
    short wt = (short) ( fight->worldtype > 1 ? 1 : fight->worldtype );

    switch ( it->kind ) {
    case ENT_ITEM_KEY1:
    case ENT_ITEM_KEY2:    return (short) ( SND_KEY + wt );
    case ENT_ITEM_SHELLS:
    case ENT_ITEM_NAILS:
    case ENT_ITEM_ROCKETS: return SND_AMMO;
    case ENT_ITEM_SSG:
    case ENT_ITEM_NAILGUN:
    case ENT_ITEM_GL:
    case ENT_ITEM_SNG:
    case ENT_ITEM_RL:      return SND_WEAPON;
    case ENT_ITEM_ARMOR1:
    case ENT_ITEM_ARMOR2:  return SND_ARMOR;
    case ENT_ITEM_QUAD:    return SND_QUAD;
    case ENT_ITEM_SUIT:    return SND_SUIT;
    case ENT_ITEM_PENT:    return SND_PENT;
    case ENT_ITEM_SIGIL:   return SND_KEY + 1;    /* misc/runekey */
    }
    if ( it->amount == ENT_ITEM_MEGA ) return SND_HEALTH_MEGA;
    return (short) ( it->amount < 15 ? SND_HEALTH_ROT : SND_HEALTH );
}

/* CheckPowerups: once, three seconds before a powerup runs out */
static void pl_powerup_warn( Player *player, Renderer *rdr, float until, float *warned, short id )
{
    if ( until <= rdr->anim_time || rdr->anim_time < until - 3.0f || *warned == until ) return;
    *warned = until;
    snd_self( player, CHAN_AUTO, id );
}

void pl_items_touch( World *world, Player *player, Fight *fight, Renderer *rdr )
{
    short i, bit, cap;
    float dz, atype;

    /* item_megahealth_rot: over 100, a point a second after five */
    if ( fight->health > PL_HEALTH && rdr->anim_time >= fight->rot_at ) {
        fight->health--;
        fight->rot_at = rdr->anim_time + 1.0f;
    }

    pl_powerup_warn( player, rdr, fight->quad_until, &fight->quad_warn, SND_QUAD_END );
    pl_powerup_warn( player, rdr, fight->suit_until, &fight->suit_warn, SND_SUIT_END );
    pl_powerup_warn( player, rdr, fight->pent_until, &fight->pent_warn, SND_PENT_END );

    for ( i = 0; i < world->item_count; i++ ) {
        ItemEnt far *it = &world->item[i];

        if ( it->gone ) continue;

        dz = player->pos.z - it->pos.z;
        if ( (float) fabs( player->pos.x - it->pos.x ) >= ENT_ITEM_REACH ) continue;
        if ( (float) fabs( player->pos.y - it->pos.y ) >= ENT_ITEM_REACH ) continue;
        if ( dz <= -ENT_ITEM_TOP - PL_FEET || dz >= ENT_ITEM_TOP + PL_FEET ) continue;

        switch ( it->kind ) {
        case ENT_ITEM_SHELLS:
            /* ammo_touch: refused at the cap, capped after */
            if ( fight->shells < PL_SHELLS_MAX ) {
                fight->shells = (short) ( fight->shells + it->amount );
                if ( fight->shells > PL_SHELLS_MAX ) fight->shells = PL_SHELLS_MAX;
                it->gone = -1;
            }
            break;

        case ENT_ITEM_NAILS:
            if ( fight->nails < PL_NAILS_CAP ) {
                fight->nails = (short) ( fight->nails + it->amount );
                if ( fight->nails > PL_NAILS_CAP ) fight->nails = PL_NAILS_CAP;
                it->gone = -1;
            }
            break;

        case ENT_ITEM_ROCKETS:
            if ( fight->rockets < PL_ROCKETS_CAP ) {
                fight->rockets = (short) ( fight->rockets + it->amount );
                if ( fight->rockets > PL_ROCKETS_CAP ) fight->rockets = PL_ROCKETS_CAP;
                it->gone = -1;
            }
            break;

        /* weapon_touch: the weapon, its ammo, and it is the one in hand */
        case ENT_ITEM_SSG:
            fight->items |= PL_IT_SSG;
            fight->weapon = PL_IT_SSG;
            fight->shells = (short) ( fight->shells + it->amount );
            if ( fight->shells > PL_SHELLS_MAX ) fight->shells = PL_SHELLS_MAX;
            it->gone = -1;
            break;

        case ENT_ITEM_NAILGUN:
        case ENT_ITEM_SNG:
            fight->items |= ( it->kind == ENT_ITEM_SNG ? PL_IT_SNG : PL_IT_NAILGUN );
            fight->weapon = (short) ( it->kind == ENT_ITEM_SNG ? PL_IT_SNG : PL_IT_NAILGUN );
            fight->nails = (short) ( fight->nails + it->amount );
            if ( fight->nails > PL_NAILS_CAP ) fight->nails = PL_NAILS_CAP;
            it->gone = -1;
            break;

        case ENT_ITEM_GL:
        case ENT_ITEM_RL:
            fight->items |= ( it->kind == ENT_ITEM_RL ? PL_IT_RL : PL_IT_GL );
            fight->weapon = (short) ( it->kind == ENT_ITEM_RL ? PL_IT_RL : PL_IT_GL );
            fight->rockets = (short) ( fight->rockets + it->amount );
            if ( fight->rockets > PL_ROCKETS_CAP ) fight->rockets = PL_ROCKETS_CAP;
            it->gone = -1;
            break;

        /* powerup_touch: the item's own seconds from the pickup */
        case ENT_ITEM_QUAD:
            fight->quad_until = rdr->anim_time + it->amount;
            it->gone = -1;
            break;
        case ENT_ITEM_SUIT:
            fight->suit_until = rdr->anim_time + it->amount;
            it->gone = -1;
            break;
        case ENT_ITEM_PENT:
            fight->pent_until = rdr->anim_time + it->amount;
            it->gone = -1;
            break;

        case ENT_ITEM_EXPLOBOX:
            break;              /* shot, never taken */

        case ENT_ITEM_SIGIL:
            /* sigil_touch: no serverflags here; its target is the point */
            ent_say( fight, rdr, (char far *) "You got the rune!" );
            it->gone = -1;
            break;

        case ENT_ITEM_KEY1:
        case ENT_ITEM_KEY2: {
            /* key_touch: one of each; the name is the worldtype's */
            char line[ENT_MSG_LEN + 1];

            bit = (short) ( it->kind == ENT_ITEM_KEY2 ? PL_IT_KEY2 : PL_IT_KEY1 );
            if ( fight->items & bit ) break;
            fight->items |= bit;
            memset( line, 0, sizeof(line) );
            pl_key_name( line, fight->worldtype, it->kind );
            ent_say( fight, rdr, (char far *) line );
            it->gone = -1;
            break;
        }

        case ENT_ITEM_ARMOR1:
        case ENT_ITEM_ARMOR2:
            /* armor_touch: only what beats the armor worn, type * value */
            atype = ( it->kind == ENT_ITEM_ARMOR2 ) ? PL_ARMOR2_TYPE : PL_ARMOR1_TYPE;
            if ( fight->armor_type * fight->armor < atype * it->amount ) {
                fight->armor_type = atype;
                fight->armor = it->amount;
                it->gone = -1;
            }
            break;

        default:
            /* T_Heal: the mega one ignores the 100 cap and stops at 250 */
            cap = ( it->amount == ENT_ITEM_MEGA ) ? PL_HEALTH_MEGA : PL_HEALTH;
            if ( fight->health < cap ) {
                fight->health = (short) ( fight->health + it->amount );
                if ( fight->health > cap ) fight->health = cap;
                if ( fight->health > PL_HEALTH ) fight->rot_at = rdr->anim_time + PL_ROT_DELAY;
                it->gone = -1;
            }
            break;
        }

        if ( it->gone ) {
            fight->bonus_pct = PL_BONUS_SHIFT;
            snd_self( player, CHAN_ITEM, pl_item_sound( fight, it ) );
            /* SUB_UseTargets: every touch fires the item's target */
            ent_use_targets( world, player, fight, rdr, it->target );
        }
    }
}

short item_taken( World *world )
{
    short i, n = 0;
    for ( i = 0; i < world->item_count; i++ ) if ( world->item[i].gone ) n++;
    return n;
}

void pl_item_add( World *world, short kind, short amount, BspVec3 far *org )
{
    ItemEnt far *it;

    if ( world->item_count >= world->item_max ) return;
    it = &world->item[ world->item_count ];
    it->kind = kind;
    it->amount = amount;
    it->target = 0;
    it->crate = -1;
    it->pos = *org;
    it->gone = 0;
    world->item_count++;
}
