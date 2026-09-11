''
'' q_mdl.bi -- state for ONE alias (.mdl) model rendered as real geometry.
''
'' Triangle/vertex data stays in module-level arrays (arrays cannot be TYPE
'' members) -- MdlState only holds what a UDT can: counts and the skin dc.
''
'' Must be included before q_game.bi, which embeds MdlState as g.vmdl.
'' Needs u3dVector3f (u3d.bi) seen already -- every module that reaches
'' this far already has it, the same way q_cam.bi's CamState does.
''

'' id's own monster AI, ported from the GPL source (~/work/badlogic/Quake/
'' WinQuake/sv_move.c, ai.qc, soldier.qc) -- exact constants, not
'' approximated. A monster_army stands (ai_stand) until FindTarget sees
'' the player, then chases forever (ai_run/SV_MoveToGoal/SV_NewChaseDir);
'' there is no idle "explore" state in stock Quake -- a walkmonster with
'' no path_corner target sets pausetime=99999999 and never leaves stand
'' on its own (monsters.qc:walkmonster_start_go). See pl_move.bas for the
'' movement port and its own documented simplifications.
const MDL_ST_STAND%    = 0
const MDL_ST_RUN%      = 1
const MDL_ST_DEAD%     = 2    '' plays the death frames once, then lies there
const MDL_ST_PAIN%     = 3    '' the flinch a hit that does not kill plays, standing
const MDL_ST_ATTACK%   = 4    '' the knight's sword, charging
const MDL_ST_LEAP%     = 5    '' the dog in the air, on its velocity
'' The frame sets -- stand, run, death, pain, attack -- are contiguous
'' in that order and their counts come from the .geo header, so the
'' Makefile's frameset IS the layout: soldier stand,run,death,pain fills
'' the page at 32 frames of 170 vertices; the knight's 108 fit attackb.
const MDL_KIND_ARMY%   = 0
const MDL_KIND_KNIGHT% = 1
const MDL_KIND_DOG%    = 2
const MDL_KINDS%       = 3       '' mon() in main.bas: one MdlState a kind
const MDL_HEALTH%       = 30  '' monster_army's health
'' army_fire: FireBullets (4, dir, '0.1 0.1 0'), 4 damage a pellet, aimed
'' 0.2 s behind the player's velocity
const MDL_PELLETS%      = 4
const MDL_PELLET_DMG%   = 4
const MDL_SPREAD#       = 0.1
const MDL_AIM_LAG#      = 0.2
'' SoldierCheckAttack's chance per think, by range, then 1 + random()
const MDL_ATK_MELEE#    = 0.9
const MDL_ATK_NEAR#     = 0.4
const MDL_ATK_MID#      = 0.05
'' army_pain: pain_finished 0.6 for the short flinch, 1.1 for the others
const MDL_PAIN_SHORT#   = 0.6
const MDL_PAIN_LONG#    = 1.1
const MDL_PAIN_SHORT_P# = 0.2
'' monster_army's setsize: '-16 -16 -24' '16 16 40', what a pellet hits
const MDL_HALF#         = 16.0
const MDL_ZLO#          = -24.0
const MDL_ZHI#          = 40.0
const MDL_FLASH#        = 0.12 '' seconds the muzzle flash shows
const MDL_GUN_FWD#      = 20.0 '' the muzzle, ahead of and above the origin
const MDL_GUN_UP#       = 28.0
const MDL_BACKPACK%     = 5   '' the shells a dead soldier's backpack carries
const MDL_YAW_SPEED#    = 20.0   '' walkmonster_start_go's yaw_speed
const MDL_RANGE_MELEE#  = 120.0  '' ai.qc range() -- visible() alone is enough here
const MDL_RANGE_NEAR#   = 500.0  '' range(): < MELEE, < NEAR, < MID, else FAR
const MDL_RANGE_MID#    = 1000.0 '' range() >= this is RANGE_FAR, never noticed
const MDL_VIEW_OFS#     = 25.0   '' walkmonster_start_go's view_ofs
'' monster_knight: the same box, 75 health, no gun. In RANGE_MELEE it
'' charges through attackb1..10 (ai_charge by the frame's distance) and
'' ai_melee on 6, 7 and 8: (random()+random()+random())*3 within 60.
'' knight_pain's short flinch, pain_finished 1 s; painb does not fit.
const KNIGHT_HEALTH%     = 75
const KNIGHT_MELEE_RANGE# = 60.0
const KNIGHT_MELEE_DMG#  = 3.0
const KNIGHT_PAIN#       = 1.0
const KNIGHT_ATK_FIRST%  = 5     '' the frames that strike, 0-based
const KNIGHT_ATK_LAST%   = 7
'' dog.qc: 25 health, a bite within 100 for (r+r+r)*8, an eight-frame
'' attack cycle. No attack set fits the page, so it bites on the run.
const DOG_HEALTH%        = 25
const DOG_BITE_RANGE#    = 100.0
const DOG_BITE_DMG#      = 8.0
const DOG_BITE_RATE#     = 0.8
const DOG_LEAP_SPEED#    = 300.0 '' dog_leap2: v_forward * 300 + '0 0 200'
const DOG_LEAP_UP#       = 200.0
const DOG_LEAP_MIN#      = 80.0  '' CheckDogJump's range, level distance
const DOG_LEAP_MAX#      = 150.0
const DOG_LEAP_DMG#      = 10.0  '' Dog_JumpTouch: 10 + 10 * random

'' NOT in stock Quake: a walkmonster with no path_corner target just
'' stands forever (see the note above) -- there is no explore state to
'' port. This crowd needs one anyway, so it is layered on top of the
'' exact port rather than mixed into it: mdl_think reuses the same
'' SV_MoveToGoal/mdl_new_chase_dir compass search (collision and
'' stepping identical to a real chase) aimed at a self-picked point
'' instead of the player, and reuses the same STAND/RUN frame sets, so
'' the animation is still always the one matching what the entity is
'' actually doing -- standing or walking, never picked separately.
const MDL_WANDER_MIN#     = 64.0    '' shortest own-goal wander hop
const MDL_WANDER_MAX#     = 256.0   '' longest own-goal wander hop
const MDL_WANDER_ARRIVE#  = 24.0    '' close enough counts as arrived
const MDL_PATROL_STEP#    = 2.0     '' ai_walk's stride a think: army_walk's average
const MDL_WANDER_MAXTICKS% = 100    '' give up after 10s of think-ticks (10Hz)
const MDL_STAND_MIN#      = 1.0     '' shortest idle pause between wanders
const MDL_STAND_MAX#      = 4.0     '' longest idle pause between wanders

'' How many can be on screen at once -- an array, not a scalar, so
'' host_init can spawn a crowd instead of the one soldier this used to
'' be limited to. e1m1 on easy places nine soldiers.
const MDL_MAX_ENTS%     = 48    '' e1m1 on hard spawns 42
'' the crowd scattered on a map with no monsters of its own; the fight
'' and model gates stand beside one of these eight
const MDL_CROWD%        = 8

type MdlState
    loaded      as integer     '' 0 until mdl_load succeeds
    ntri        as integer
    nvert       as integer
    nframe      as integer
    skin        as long        '' the skin's dc
    vtx_hnd     as integer     '' qglGemAlloc's handle -- see mdl_rotate_all
    scale       as Vec3 '' vertex byte -> model unit: unit = byte*scale + origin
    origin      as Vec3
    radius      as single      '' the box any frame at any yaw fits in,
    zlo         as single      '' from the header: horizontal reach about
    zhi         as single      '' the origin, and the z span
    nstand      as integer     '' the frame sets, in this order
    nrun        as integer
    ndeath      as integer
    npain       as integer
    natk        as integer
end type

'' One spawned instance's own state -- everything mdl_think (pl_move.bas)
'' owns, separate from MdlState's shared asset data above so a crowd can
'' share one loaded model. BSP space, Z up, same convention as
'' PlayerState.pos -- Vec3, not u3dVector3f, so it can be handed to
'' pl_trace directly with no field-by-field copy.
type MdlEnt
    pos         as Vec3
    yaw         as single      '' actual current facing (self.angles_y)
    ideal_yaw   as single      '' desired facing (self.ideal_yaw)
    state       as integer     '' MDL_ST_STAND% or MDL_ST_RUN% -- one-way,
                                '' same as real Quake for an enemy that
                                '' never dies (self.enemy.health<=0 is the
                                '' only reversion in ai_run, and this
                                '' renderer's player has no health)
    anim_frame  as integer     '' 0..7 within the current state's cycle
    next_think  as single      '' g.rdr.anim_time of the next 10Hz think
    '' Own-goal wandering (not in stock Quake -- see the note above).
    goal        as Vec3        '' current wander destination
    stand_until as single      '' g.rdr.anim_time to leave STAND and pick a new goal
    wander_ticks as integer    '' think-ticks spent chasing the current goal
    health      as integer
    hunting     as integer     '' has seen the player: RUN chases instead of wandering
    next_attack as single      '' anim_time of the next volley
    flash_until as single      '' the volley's muzzle flash shows until then
    pain_finished as single    '' army_pain: no new flinch before this
    spawn       as Vec3        '' where it respawns
    kind        as integer     '' MDL_KIND_ARMY%, KNIGHT or DOG
    vel         as Vec3        '' a leaping dog's, MOVETYPE_STEP off the ground
    leapt       as integer     '' this leap's Dog_JumpTouch has landed its damage
    patrol      as integer     '' the map's target path_corner, -1 none; corner the one bound for
    corner      as integer
end type

'' A triangle on disk and in the model's page 1: three vertex indices and
'' three (u,v) pairs, integers, u and v as 0..32767 = 0.0..1.0 -- d_alias.c's
'' MdlTri, and mkmdl.py's UV_SCALE must match. No BASIC code holds one.
const MDL_TRI_BYTES = 18

'' Vertices are packed bytes (trivertx_t, one per axis), flat and
'' frame-major, ONE EMS page (raw emsAlloc/emsMapEx, not a uGL DC or
'' array) -- g.mdl.vtx_hnd, read with PEEK. Three OTHER designs were
'' tried this session, in order, each ruled out by measurement, not
'' guesswork:
''   1. space$()'d BASIC string, PEEK via SSEG/SADD -- ~8KB put data in
''      conventional memory AND BASIC's own separate, much smaller
''      "string space" pool; going from 8 frames to 16 (id's real
''      monster AI needs both stand and run -- see pl_move.bas) overran
''      both (runtime errors 14 and 7).
''   2. uglArrLoad into an EMS array -- refused outright: uglArrNew's own
''      store table is UA_MAX=4 slots (uglarr.asm), all already taken by
''      this renderer's own faces/nodes/leaves/clips arrays.
''   3. memAlloc + uarReadH into conventional memory (the PVS lump's own
''      idiom, model.bas's mod_load_vis) -- fits the allocator, but not
''      the budget: only ~13KB of conventional memory is free by the
''      time the model loads, and 8,160 more bytes there leaves too
''      little for host_main's own setup (measured: "Out of string
''      space" a few hundred bytes later).
'' EMS is what is actually left with room: the skin and Z-buffer already
'' prove it.

'' mdl_load/mdl_draw take `g as Game`, so their declares live in
'' q_game.bi (below this include), next to mod_cm_map and its kin --
'' Game does not exist yet at this point in the include chain.
