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
    pal         as long           '' the palette dc
    mymod       as UGMMOD         '' the music module
    tele_count  as integer        '' entities: filled by ent_load_teleports
    plat_count  as integer
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
