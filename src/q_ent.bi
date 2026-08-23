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
    mins        as vec3         '' the trigger volume, from the submodel
    maxs        as vec3
    dest        as vec3         '' where it puts you
    yaw         as single       '' and which way you face on arrival
end type

''
'' COMMON can only declare an array as name(), with no bound, so this is
'' REDIMmed in ent_load_teleports rather than sized here.
''
common shared /ent_s/ tele() as Teleporter
common shared /ent_s/ tele_count as integer

''
'' Whether each submodel is drawn. A func_plat is; a trigger volume is not --
'' its brush exists to be walked into, not looked at, and drawing it would
'' hang a slab of teleport texture in mid air.
''
common shared /ent_s/ mdl_draw() as integer

''
'' Whether a submodel stops the player. A trigger does not; a lift does. Not
'' the same question as whether it is drawn -- a func_illusionary would be
'' drawn and not solid -- so they are separate flags even though every
'' entity in dm3ish answers both the same way.
''
common shared /ent_s/ mdl_solid() as integer

''
'' How far each submodel has moved from where the map put it, along z, which
'' is the only axis anything in dm3ish travels. The renderer adds it to every
'' vertex of the entity's faces and the collision subtracts it from the point
'' being traced, which is the same thing seen from either end.
''
common shared /ent_s/ mdl_zofs() as single

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
    mins        as vec3         '' its volume at the map position
    maxs        as vec3
end type

common shared /ent_s/ plat() as PlatEnt
common shared /ent_s/ plat_count as integer

''
'' Set once an entity has been emitted this frame. A brush entity usually
'' overlaps several leaves and the walk may visit all of them; without this
'' it would be drawn once per leaf.
''
common shared /ent_s/ mdl_done() as integer
