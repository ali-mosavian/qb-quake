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

''
'' Which submodel owns each face, so the renderer can find the offset without
'' searching. Built once at load.
''

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

''
'' ent.bas. Declared here: these name World, PlayerState and Env.
''

