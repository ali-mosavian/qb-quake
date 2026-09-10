''
'' q_mdl.bi -- state for ONE alias (.mdl) model rendered as real geometry.
''
'' Triangle/vertex data stays in module-level arrays (arrays cannot be TYPE
'' members) -- MdlState only holds what a UDT can: counts and the skin dc.
''
'' Must be included before q_game.bi, which embeds MdlState as g.mdl.
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
const MDL_STAND_FRAMES% = 8   '' army_stand1..8
const MDL_RUN_FRAMES%   = 8   '' army_run1..8
const MDL_DEATH_FRAMES% = 10  '' army_death1..10, after the run set
const MDL_PAIN_FRAMES%  = 6   '' army_pain1..6, after the death set: 32 frames fill the page
const MDL_HEALTH%       = 30  '' monster_army's health
const MDL_DAMAGE%       = 8   '' about half of army_fire's four pellets landing
const MDL_HIT_CHANCE#   = 0.5
const MDL_ATTACK_RATE#  = 1.0 '' seconds between volleys
const MDL_BACKPACK%     = 5   '' the shells a dead soldier's backpack carries
const MDL_RESPAWN#      = 15.0 '' seconds a corpse lies before it is a soldier again
const MDL_YAW_SPEED#    = 20.0   '' walkmonster_start_go's yaw_speed
const MDL_RANGE_MELEE#  = 120.0  '' ai.qc range() -- visible() alone is enough here
const MDL_RANGE_MID#    = 1000.0 '' range() >= this is RANGE_FAR, never noticed
const MDL_VIEW_OFS#     = 25.0   '' walkmonster_start_go's view_ofs

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
const MDL_WANDER_MAXTICKS% = 100    '' give up after 10s of think-ticks (10Hz)
const MDL_STAND_MIN#      = 1.0     '' shortest idle pause between wanders
const MDL_STAND_MAX#      = 4.0     '' longest idle pause between wanders

'' How many can be on screen at once -- an array, not a scalar, so
'' host_init can spawn a crowd instead of the one soldier this used to
'' be limited to. Sized for DGROUP headroom, not for any map's own need.
const MDL_MAX_ENTS%     = 8

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
    drawn       as integer     '' models drawn this frame, after the cull
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
    dead_at     as single      '' anim_time it died, for the respawn
    spawn       as Vec3        '' where it respawns
end type

'' UV as fixed-point Integer (0..32767 = 0.0..1.0), not Single -- halves
'' this record versus 6 floats, and the unpack is one divide, not a
'' string op. mkmdl.py's own UV_SCALE must match.
type MdlTri
    a  as integer
    b  as integer
    c  as integer
    u1 as integer
    v1 as integer
    u2 as integer
    v2 as integer
    u3 as integer
    v3 as integer
end type

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
