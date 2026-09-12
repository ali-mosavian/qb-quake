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
'' snd.bas: the DSP is up and snd.raw is in the handle
type SndState
    on          as integer
    off         as integer      '' -nosound
    hnd         as integer      '' the samples' EMS handle
    started     as integer      '' sounds begun, for the bench
    under       as integer      '' frames the DMA got ahead of the mixer
    loops       as integer      '' ambients looping on the static channels
end type

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
    mdl_drawn   as integer        '' monsters drawn this frame, after the cull
    mdl_count   as integer        '' how many of mdl_ent() are actually spawned
    fight       as PlayerCombat   '' health, shells, kills, the shotgun's timers
    item_count  as integer        '' pickups in item(): the map's, then dropped backpacks
    item_fixed  as integer        '' how many of those are the map's
    door_count  as integer
    trig_count  as integer
    vmdl        as MdlState       '' the view weapon, v_shot
    smdl        as MdlState       '' and v_shot2, the super shotgun's
    nmdl        as MdlState       '' and v_nail, the nailgun's
    gmdl        as MdlState       '' and v_rock, the grenade launcher's
    n2mdl       as MdlState       '' and v_nail2, the super nailgun's
    rmdl        as MdlState       '' and v_rock2, the rocket launcher's
    snd         as SndState       '' the sound layer

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
declare sub snd_init ( g as Game )
declare sub snd_frame ( g as Game )
declare sub snd_shutdown ( g as Game )
declare sub snd_ambient ( _
    g as Game, _
    byval id as integer, _
    byval vol as integer, _
    org as Vec3 _
)
declare sub snd_play ( _
    g as Game, _
    byval id as integer, _
    org as Vec3 _
)
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
    m as MdlState, _
    mdlname as string _
)
declare sub mdl_draw_view ( _
    g as Game, _
    m as MdlState, _
    byval frame as integer, _
    org as Vec3, _
    byval cyaw as single, _
    byval syaw as single, _
    byval cpitch as single, _
    byval spitch as single, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
)
declare sub mdl_draw ( _
    g as Game, _
    m as MdlState, _
    ent as MdlEnt, _
    mtx_fin as Mat4, _
    byval xresh as single, _
    byval yresh as single, _
    byval z_near as single, _
    byval dst as long _
)
