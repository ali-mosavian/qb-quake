''
'' ==========================================================================
''  THE PROGRAM'S STATE
'' ==========================================================================
''
'' One struct holding every piece of state that is not an array. Procedures
'' take `g as Game` instead of the twelve separate parameters they used to,
'' and the arrays -- which cannot be TYPE members -- stay separate.
''
'' Nested rather than flat: g.pl.pos.z says which subsystem owns the field,
'' and the groups already existed as their own types.
''
type Game
    wld         as World          '' the loaded map: counts, stores, dcs
    env         as Env            '' configuration, from stuff.ini and argv
    pl          as PlayerState    '' position, velocity, water
    cam         as CamState       '' eye and look direction
    rdr         as RenderState    '' per-frame toggles and counters
    vis         as VisState       '' visibility walk state
    scr         as ScreenState    '' fps and the stats overlay
    cp          as CamPath        '' the scripted walkthrough
    ft          as FrameTimes     '' frame-time accumulators
    pt          as PhaseTimes     '' where inside the frame it went
    tele_count  as integer        '' entities: filled by ent_load_teleports
    plat_count  as integer
    mdl         as MdlState       '' the one loaded model asset, shared by every spawned instance
    mdl_count   as integer        '' how many of mdl_ent() are actually spawned
    fight       as PlayerCombat   '' health, shells, kills, the shotgun's timers
    item_count  as integer        '' pickups in item(), from ents.bin

    '' LAST, deliberately. r_walk.c and sb_build.c reach g.vis and
    '' g.rdr.dlight by byte offset -- GAME_VIS_OFFSET 4970 and
    '' GAME_DLIGHT_OFFSET 4954 -- so a field added anywhere above here
    '' moves both and the startup layout check fails, which is exactly
    '' what it did when this went into Env instead.
    qgl_check   as integer        '' -qglcheck: run the qgl ABI test and exit
    qgl_diff    as integer        '' -qgldiff: qgl against mgl, then exit
    qgl_arr     as integer        '' -qglarr: the paged-array store
    qgl_face    as integer        '' -qglface: one real face, replayed
end type

''
'' Procedures whose signatures can be read from here.
''
declare function mod_cm_map ( _
    g as Game _
) as long
declare function mod_geom_map ( _
    g as Game, _
    byval row as integer _
) as long
declare function mod_tex_raw ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
declare function mod_tex_shaded ( _
    g as Game, _
    byval k as integer, _
    byval mip as integer _
) as long
declare sub scr_screenshot ( _
    g as Game, _
    flname as string, _
    byval dc as long _
)
declare sub mod_tex_dump ( g as Game )

declare sub mdl_load ( _
    g as Game, _
    mdlname as string, _
    tri() as MdlTri _
)
declare sub mdl_draw ( _
    g as Game, _
    tri() as MdlTri, _
    ent as MdlEnt, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
)
