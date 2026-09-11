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
    nitem       as integer
    ndoor       as integer
    ntrig       as integer
    nmon        as integer
    namb        as integer
end type

'' A monster where the map put it, first in the file so host_init can
'' read them without walking the rest. Skill easy: mkassets drops the
'' ones flagged NOT_EASY.
type EntsMon
    kind        as integer      '' MDL_KIND_*
    org         as Vec3
    angle       as single       '' the map's, CCW from +x
end type

type EntsItem
    kind        as integer
    amount      as integer
    org         as Vec3
end type

'' A pickup: item_health or item_shells where the map put it, dropped
'' to the floor at load, or a dead soldier's backpack. Single player:
'' taken is taken until pl_game_reset.
type ItemEnt
    kind        as integer
    amount      as integer     '' healamount or aflag
    pos         as Vec3         '' BSP space, on the floor
    gone        as integer
end type

'' An ambient_* point, last in the file: the SND_* it loops and 255
'' times misc.qc's volume. snd_mix.c holds them; nothing here does.
type EntsAmb
    snd         as integer
    vol         as integer
    org         as Vec3
end type

const ENT_ITEM_HEALTH   = 0
const ENT_ITEM_SHELLS   = 1
const ENT_ITEM_ARMOR1   = 2      '' green, 100 at 0.3; amount is the value
const ENT_ITEM_ARMOR2   = 3      '' yellow, 150 at 0.6
const ENT_ITEM_SSG      = 4      '' weapon_supershotgun; amount is its shells
const ENT_ITEM_NAILS    = 5      '' item_spikes, 25 or 50
const ENT_ITEM_NAILGUN  = 6      '' weapon_nailgun; amount is its nails
const ENT_ITEM_QUAD     = 7      '' item_artifact_super_damage; amount is its seconds
const ENT_ITEM_SUIT     = 8      '' item_artifact_envirosuit
const ENT_ITEM_EXPLOBOX = 9      '' misc_explobox; amount is its health, shot down
const ENT_BOX_HALF#     = 15.0   '' b_explob.bsp, 30 by 30 by 62
const ENT_BOX_TOP#      = 62.0
const ENT_BOX_DMG#      = 160.0  '' barrel_explode: T_RadiusDamage 160
const ENT_ITEM_HALF#    = 10.0   '' the box's half width
const ENT_ITEM_TOP#     = 20.0   '' and its height
const ENT_ITEM_REACH#   = 32.0   '' Quake's touch: item box against the player's
const ENT_ITEM_MEGA%    = 100    '' item_health's healamount when it is the mega one
const ENT_BACKPACK%     = 5      '' army_die3: ammo_shells = 5; DropBackpack
'' pal.raw's nearest entries: white, red, yellow, brown
const ENT_COL_WHITE%    = 254
const ENT_COL_RED%      = 251
const ENT_COL_YELLOW%   = 111
const ENT_COL_BROWN%    = 28
const ENT_COL_BLUE%     = 210    '' the quad
const ENT_COL_GREEN%    = 176    '' the suit

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

'' A func_door, resolved offline: travel is movedir * (size along it -
'' lip), start_open swaps which end is shut, nolink is DOOR_DONT_LINK.
type EntsDoor
    model       as integer
    travel      as Vec3
    mid         as Vec3         '' a secret door's first leg; travel is the second's end
    speed       as single
    hold        as single       '' "wait": seconds open; below zero stays
    start_open  as integer
    nolink      as integer
    targeted    as integer      '' its targetname's id: opens by trigger, not touch
    secret      as integer      '' func_door_secret: touch says the message only
    shoot       as integer      '' a pellet opens it
    snd         as integer      '' "sounds": doors.qc's set, 0 none
    msg         as string * 40  '' centerprint on touch, space padded
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

const ENT_DOOR_SHUT    = 0
const ENT_DOOR_OPENING = 1
const ENT_DOOR_OPEN    = 2
const ENT_DOOR_CLOSING = 3
const ENT_DOOR_OUT1    = 4      '' a secret door's first leg, to ofs_mid
const ENT_DOOR_PAUSE_OUT  = 5   '' the second it stands there before the second leg
const ENT_DOOR_PAUSE_BACK = 6   '' and on the way back, CLOSING having reached ofs_mid
const ENT_DOOR_BACK2   = 7      '' the last leg home
const ENT_DOOR_PAUSE#  = 1.0
const ENT_DOOR_FIELD#  = 60.0   '' spawn_field: the touch box grows this much in x and y
const ENT_DOOR_FIELDZ# = 8.0    '' and this much in z

''
'' A func_door: doors.qc without the sounds, keys and damage. A touch
'' anywhere in the field sends every door of its linked group to the open
'' end, where it holds and comes back; a touch while closing sends it out
'' again. Linked doors are those whose brushes touch, as LinkDoors does.
''
type DoorEnt
    model       as integer
    ofs_shut    as Vec3         '' brush offset at each end of the travel
    ofs_open    as Vec3
    ofs_mid     as Vec3         '' a secret door's corner
    speed       as single
    hold        as single
    hold_left   as single
    pause_left  as single
    state       as integer
    secret      as integer
    shoot       as integer
    link        as integer      '' lowest door index of its group
    nolink      as integer
    targeted    as integer
    snd         as integer
    mins        as Vec3         '' the touch field
    maxs        as Vec3
    msg         as string * 40
end type

const ENT_TRIG_ONCE    = 0
const ENT_TRIG_MULTI   = 1
const ENT_TRIG_COUNTER = 2
const ENT_TRIG_BUTTON  = 3
const ENT_TRIG_EXIT    = 4      '' trigger_changelevel: the level ends
const ENT_TRIG_SHOOT   = 5      '' a trigger with health: pl_fire's pellets fire it
const ENT_TRIG_SECRET  = 6      '' trigger_secret: a once that counts

'' Anything that fires a target, resolved offline: a trigger's volume, a
'' button's travel. Names are ids -- a door's targeted, a trigger's name
'' and target -- matched by number, never by string, at run time.
type EntsTrig
    model       as integer
    kind        as integer      '' ENT_TRIG_*
    target      as integer      '' what it fires, 0 none
    name        as integer      '' what fires it, 0 none
    kill        as integer      '' killtarget: the triggers it removes first, 0 none
    count       as integer      '' a counter's count
    wait        as single       '' re-arm delay; below zero fires once, or stays pressed
    speed       as single       '' a button's
    travel      as Vec3
    snd         as integer      '' "sounds": a trigger's 1 secret, 2 talk; a button's set
    msg         as string * 40
end type

const ENT_TRIG_READY = 0
const ENT_TRIG_GOING = 1        '' a button on its way in
const ENT_TRIG_HELD  = 2        '' pressed, or a trigger waiting to re-arm
const ENT_TRIG_BACK  = 3        '' a button on its way out
const ENT_TRIG_DONE  = 4
const ENT_MSG_TIME#     = 2.0   '' scr_centertime
const ENT_TOUCH_SLACK#  = 2.0   '' a brush is touched from this close

''
'' triggers.qc and buttons.qc without sounds, health and delay: a touch
'' fires a trigger's target and says its message; a counter fires its
'' own when used count times; a button slides in when touched, fires on
'' arrival, and comes back after wait.
''
type TrigEnt
    model       as integer
    kind        as integer
    target      as integer
    name        as integer
    kill        as integer
    state       as integer      '' ENT_TRIG_READY..DONE
    left        as integer      '' a counter's uses to go
    count       as integer      '' what left resets to
    wait        as single
    wait_left   as single
    speed       as single
    ofs_out     as Vec3         '' a button's pressed offset
    snd         as integer
    mins        as Vec3         '' the volume, or the button's brush
    maxs        as Vec3
    msg         as string * 40
end type

''
'' ent.bas. Declared here: these name World, PlayerState and Env.
''

