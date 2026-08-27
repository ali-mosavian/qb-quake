''
'' Entities: the map's non-geometry contents.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

const ENT_MAXTELE = 8

''
'' A teleporter is a trigger_teleport entity whose brush is one of the
'' submodels -- model "*1" is mdl_buffer(1) -- paired by name with an
'' info_teleport_destination.
''
type Teleporter
    mins        as Vec3         '' the trigger volume, from the submodel
    maxs        as Vec3
    dest        as Vec3         '' where it puts you
    yaw         as single       '' and which way you face on arrival
end type

''
'' COMMON can only declare an array as name(), with no bound, so this is
'' REDIMmed in ent_load_teleports rather than sized here.
''
'' Per-submodel run-time state. See BrushModel for what each field means.
common shared /ent_s/ brush() as BrushModel

common shared /ent_s/ tele() as Teleporter
common shared /ent_s/ tele_count as integer




''
'' Which submodel owns each face, so the renderer can find the offset without
'' searching. Built once at load.
''
common shared /ent_s/ face_mdl() as integer


const ENT_PLAT_DOWN = 0
const ENT_PLAT_UP   = 1

''
'' A func_plat. Quake puts the brush at the top of its travel, so a lowered
'' plat sits at -height and a raised one at 0.
''
type PlatEnt
    model       as integer
    travel      as single       '' how far down it goes
    speed       as single       '' units per second
    state       as integer      '' heading down, or up
    mins        as Vec3         '' its volume at the map position
    maxs        as Vec3
end type

common shared /ent_s/ plat() as PlatEnt
common shared /ent_s/ plat_count as integer


''
'' ent.bas. Declared here: these name MapState, PlayerState and Env.
''
declare sub ent_check_teleport ( _
    pl as PlayerState, _
    env as Env _
)
declare function ent_find_node ( _
    byval m as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane _
) as integer
declare sub ent_load_teleports ( _
    wld as MapState, _
    models() as Submodel _
)
declare sub ent_move_plats ( _
    byval dt as single, _
    pl as PlayerState _
)
declare sub ent_place_models ( _
    byval nmodels as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane _
)
declare function ent_plat_touched ( _
    byval p as integer, _
    pl as PlayerState _
) as integer
declare function ent_point_leaf ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
declare function ent_value ( _
    strm() as string, _
    byval strm_cnt as integer, _
    kname as string _
) as string
declare sub ent_vec ( _
    strm() as string, _
    byval strm_cnt as integer, _
    kname as string, _
    v as Vec3 _
)
