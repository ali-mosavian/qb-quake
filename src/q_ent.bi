''
'' Entities: the map's non-geometry contents.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''


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

''
'' ents.bin, as tools/mkassets.py emits it: the entities text resolved
'' offline -- spawn, matched teleporter pairs, func_plats, and which
'' submodels a trigger hides. Read with GET straight into these, so the
'' layout here IS the file format; change one and regenerate the other.
'' Coordinates are BSP-space, unswapped, and dest carries no PL_TELE_LIFT
'' -- the readers keep applying both, as they did to the text.
''
type EntsHead
    spawn       as Vec3
    angle       as single
    nmodels     as integer      '' stamp: must equal the map's model count,
                                '' or the assets are from another map
    ntele       as integer
    nplat       as integer
    nhide       as integer
end type

type EntsTele
    model       as integer
    dest        as Vec3
    yaw         as single
end type

type EntsPlat
    model       as integer
    speed       as single
    travel      as single
end type

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

