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
const CONTENTS_SLIME = -4
const CONTENTS_LAVA  = -5
const CONTENTS_SKY   = -6

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
'' upward speed of a jump. Quake's, so the arc feels the same
const PL_JUMP#       = 270.0
'' noclip fly speed, units per second
const PL_NOCLIP#     = 200.0
'' downward drift in water: not gravity, just enough to sink slowly
const PL_WATERSINK#  = 60.0
'' how fast jump swims upward
const PL_SWIM#       = 100.0
'' water is thick: this much of your speed survives each second
const PL_WATERFRIC#  = 4.0
'' and it caps how fast you can move through it
const PL_WATERSPEED# = 160.0
'' the player box: origin sits this far above the feet, eyes this far above
'' the origin. Quake's -24 and +22.
const PL_FEET#       = 24.0

''
'' The result of sweeping the player hull from one point to another.
'' frac is how far it got, 0..1; norm is the plane it stopped against.
''
type TraceResult
    frac        as single
    end_pos     as Vec3
    norm        as Vec3
    all_solid   as integer      '' the whole sweep was inside solid
    start_solid as integer      '' it began inside solid
end type

type PlayerState
    pos         as Vec3         '' BSP space, Z up -- NOT the renderer's Y up
    vel         as Vec3
    on_ground   as integer
    noclip      as integer      '' true = the old free-fly camera, no physics
    peak_z      as single      '' highest z reached, so -jump is checkable
    water_level as integer      '' 0 dry, 1 feet, 2 waist, 3 eyes under
    water_type  as integer      '' CONTENTS_WATER, _SLIME or _LAVA
end type

common shared /pl_s/ pl as PlayerState

''
'' pl_move.bas. Declared here: these name PlayerState and TraceResult.
''
declare sub pl_gravity ( _
    byval dt as single, _
    pl as PlayerState, _
    tr as TraceResult, _
    byval nmodels as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare function pl_hull_check ( _
    byval node as integer, _
    byval p1f as single, _
    byval p2f as single, _
    p1 as Vec3, _
    p2 as Vec3, _
    tr as TraceResult, _
    clip() as ClipNode, _
    planes() as Plane _
) as integer
declare sub pl_init ( _
    pl as PlayerState, _
    cam as CamState, _
    env as Env _
)
declare sub pl_move ( _
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval jump as integer, _
    byval dt as single, _
    pl as PlayerState, _
    cam as CamState, _
    byval nmodels as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane _
)
declare sub pl_slide_move ( _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    tr as TraceResult, _
    byval nmodels as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_step_move ( _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    pl as PlayerState, _
    tr as TraceResult, _
    byval nmodels as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_trace ( _
    start as Vec3, _
    fin as Vec3, _
    tr as TraceResult, _
    byval nmodels as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_water_level ( _
    pl as PlayerState, _
    nodes() as Node, _
    planes() as Plane _
)
