''
'' Player physics state.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' Quake's contents values, straight off the leaf/clipnode child index. A
'' negative child is not a node number but a contents code.
''
''
'' A CONST carries no separate declaration, so unlike a variable its
'' sigil is the type rather than a redundant restatement of it. Without
'' the ! the float constants below are a syntax error.
''
const CONTENTS_EMPTY = -1
const CONTENTS_SOLID = -2
const CONTENTS_WATER = -3

''
'' Hull 1 is the 32x32x56 player box. The hulls are pre-expanded by the
'' compiler, so the player is traced as a point through hull 1 rather than as
'' a box through hull 0.
''
const PLAYER_HULL   = 1

'' units per second squared
const PL_FALLACC#    = 800.0
const PL_MAXVEL#     = 2000.0
const PL_STOP_EPS#   = 0.1
'' 1/32, Quake's DIST_EPSILON
const PL_CLIP_EPS#   = 0.03125
'' the tallest stair the player walks up
const PL_STEP#       = 18.0
'' eye above the hull origin
const PL_EYE#        = 22.0
'' cos of the steepest walkable slope
const PL_GROUND_NRM# = 0.7
const PL_ACCEL#      = 500.0
const PL_FRICTION#   = 4.0
const PL_MAXSPEED#   = 320.0

''
'' The result of sweeping the player hull from one point to another.
'' frac is how far it got, 0..1; norm is the plane it stopped against.
''
type TraceResult
    frac        as single
    end_pos     as vec3
    norm        as vec3
    all_solid   as integer      '' the whole sweep was inside solid
    start_solid as integer      '' it began inside solid
end type

type PlayerState
    pos         as vec3         '' BSP space, Z up -- NOT the renderer's Y up
    vel         as vec3
    on_ground   as integer
    noclip      as integer      '' true = the old free-fly camera, no physics
end type

common shared /pl_s/ pl as PlayerState
