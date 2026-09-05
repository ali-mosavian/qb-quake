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

'' units per second squared. Quake's sv_gravity.
const PL_FALLACC#    = 800.0
'' a per-axis safety clamp, not a gameplay speed cap. Quake's sv_maxvelocity.
const PL_MAXVEL#     = 2000.0
const PL_STOP_EPS#   = 0.1
'' 1/32, Quake's DIST_EPSILON
const PL_CLIP_EPS#   = 0.03125
'' the tallest stair the player walks up. Quake's STEPSIZE.
const PL_STEP#       = 18.0
'' eye above the hull origin
const PL_EYE#        = 22.0
'' What Quake's info_teleport_destination adds to its own origin when it
'' spawns. The entity lump stores the mapper's mark; the arrival point is
'' this much above it, which is what keeps a teleported player out of the
'' floor. Without it the player lands wedged and cannot move.
const PL_TELE_LIFT#  = 27.0
'' cos of the steepest walkable slope
const PL_GROUND_NRM# = 0.7
''
'' Quake's sv_accelerate: not an acceleration in units/s^2, a dimensionless
'' rate at which velocity closes on wishspeed -- see pl_accelerate and
'' pl_air_accelerate, both ported from sv_user.c's SV_Accelerate and
'' SV_AirAccelerate. The two are separate procedures, not one with a flag,
'' because SV_AirAccelerate keeps a deliberate quirk: it caps the SPEED
'' allowed to be gained (PL_AIRSPEEDCAP#) but not the RATE, which is what
'' makes air strafing gain more per tick than a naive reading suggests.
''
const PL_ACCELERATE# = 10.0
'' SV_AirAccelerate's hardcoded cap on wishspeed while airborne
const PL_AIRSPEEDCAP# = 30.0
'' Quake's sv_friction, ground and water alike -- SV_WaterMove reuses it
const PL_FRICTION#   = 4.0
'' the floor under ground friction's falloff, so a near-stop still stops.
'' Quake's sv_stopspeed.
const PL_STOPSPEED#  = 100.0
const PL_MAXSPEED#   = 320.0
''
'' Quake's cl_forwardspeed. 320 is sv_maxspeed -- what +speed gets you,
'' not what walking does: cl_movespeedkey doubles 200 to 400 and the
'' clamp brings it back to 320. Without a run key, 200 is the walk.
''
const PL_FWDSPEED#   = 200.0
'' sv_edgefriction: friction DOUBLES when the leading edge overhangs a
'' drop, which is what stops you sliding off a ledge. Costs one trace
'' per tick -- SV_UserFriction's own.
const PL_EDGEFRIC#   = 2.0
'' how far ahead SV_UserFriction probes, and how far down
const PL_EDGE_FWD#   = 16.0
const PL_EDGE_DROP#  = 34.0
'' upward speed of a jump. Quake's, so the arc feels the same
const PL_JUMP#       = 270.0
'' noclip fly speed, units per second
const PL_NOCLIP#     = 200.0
'' downward drift in water when there is no input: SV_WaterMove's wishvel.z
'' of -60, before pl_water_move's own accel/friction is applied to it --
'' not a separate force the way it used to be.
const PL_WATERSINK#  = 60.0
'' swim-up speed on jump at waterlevel>=2, by liquid: Quake's JumpButton
'' sets velocity.z to exactly one of these, keyed on watertype.
const PL_SWIM_WATER# = 100.0
const PL_SWIM_SLIME# = 80.0
const PL_SWIM_LAVA#  = 50.0
'' SV_WaterMove's wishspeed *= 0.7
const PL_WATERSCALE# = 0.7
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
    no_clip      as integer      '' true = the old free-fly camera, no physics
    peak_z      as single      '' highest z reached, so -jump is checkable
    water_level as integer      '' 0 dry, 1 feet, 2 waist, 3 eyes under
    water_type  as integer      '' CONTENTS_WATER, _SLIME or _LAVA
end type


''
'' pl_move.bas. Declared here: these name PlayerState and TraceResult.
''

''
'' Procedures whose signatures can be read from here.
''
