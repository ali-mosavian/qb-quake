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
const MDL_STAND_FRAMES% = 8   '' army_stand1..8
const MDL_RUN_FRAMES%   = 8   '' army_run1..8
const MDL_YAW_SPEED#    = 20.0   '' walkmonster_start_go's yaw_speed
const MDL_RANGE_MELEE#  = 120.0  '' ai.qc range() -- visible() alone is enough here
const MDL_RANGE_MID#    = 1000.0 '' range() >= this is RANGE_FAR, never noticed
const MDL_VIEW_OFS#     = 25.0   '' walkmonster_start_go's view_ofs

type MdlState
    loaded      as integer     '' 0 until mdl_load succeeds
    ntri        as integer
    nvert       as integer
    nframe      as integer
    skin        as long        '' the skin's dc
    vtx_hnd     as integer     '' emsAlloc's handle -- see mdl_rotate_all
    scale       as u3dVector3f '' vertex byte -> model unit: unit = byte*scale + origin
    origin      as u3dVector3f
    '' mdl_think's own state (pl_move.bas). BSP space, Z up, same
    '' convention as PlayerState.pos -- Vec3, not u3dVector3f, so it can
    '' be handed to pl_trace directly with no field-by-field copy.
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
