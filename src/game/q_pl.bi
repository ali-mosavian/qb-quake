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

'' The player as a combatant: what the soldiers can take away and what
'' the shotgun spends. After vis in Game, so the C offsets stay put.
'' a nail in flight, MOVETYPE_FLYMISSILE: no gravity, gone at the first touch
type Spike
    pos         as Vec3
    vel         as Vec3
    alive       as integer
    die_at      as single
end type

type PlayerCombat
    health      as integer
    shells      as integer
    kills       as integer
    deaths      as integer
    next_fire   as single      '' anim_time the shotgun is ready again
    show_hostile as single     '' W_Attack: time + 1, monsters notice a shot from behind
    flash_until as single      '' the muzzle flash widens the dlight until then
    hurt_until  as single      '' the status line reads red until then
    spawn       as Vec3        '' where dying puts the player back
    state       as integer     '' GS_*: what the tick and the overlay do
    state_until as single      '' when GS_DEAD ends
    fire_prev   as integer     '' last tick's fire, so a held button is one press
    rot_at      as single      '' megahealth: the next point over 100 rots then
    dmg_pct     as single      '' V_ParseDamage: the red shift, 0..150, fading 150/s
    bonus_pct   as single      '' the pickup flash, 50, fading 100/s
    msg         as string * 40 '' centerprint, shown until msg_until
    msg_until   as single
    leaps       as integer     '' dogs that left the ground, for the bench
    secrets     as integer     '' trigger_secrets found
    armor       as integer     '' armorvalue
    armor_type  as single      '' armortype: the share of a hit it takes, 0 none
    items       as integer     '' the weapons owned, PL_IT_* bits
    weapon      as integer     '' the one in hand, a PL_IT_* bit
    nails       as integer
    nail_side   as integer     '' player_nail1/2: the barrel the next nail leaves
    quad_until  as single      '' super_damage_finished: hits do four times
    suit_until  as single      '' radsuit_finished: slime does nothing, lava a fifth
    dmg_time    as single      '' the next slime or lava bite
    booms       as integer     '' exploding boxes gone, for the bench
    fire_at     as single      '' anim_time of the last shot, the view weapon's frames run from it
    pain_at     as single      '' PainSound's pain_finished: one grunt a half second
    inter       as Vec3        '' the intermission camera, BSP space
    inter_pitch as single
    inter_yaw   as single
    secret_total as integer    '' trigger_secrets the map has
    level_start as single      '' anim_time the level began, for the intermission's clock
    exit_time   as single
    next_map    as string * 8  '' where the exit leads, from ents.bin; blank for nowhere
    carry       as integer     '' -carry: CARRY.BIN holds the last level's kit
end type

'' What a level hands the next through CARRY.BIN: SetChangeParms' parms,
'' keys and powerups left behind, health 50..100, at least 25 shells
type PlayerCarry
    items       as integer
    health      as integer
    armor       as integer
    armor_type  as single
    shells      as integer
    nails       as integer
    weapon      as integer
end type

const PL_HEALTH%       = 100
const PL_ARMOR1_TYPE#  = 0.3    '' armor_touch: green, and yellow
const PL_ARMOR2_TYPE#  = 0.6
const PL_SHELLS%       = 25     '' Quake's starting shells
const PL_CARRY_MIN%    = 50     '' SetChangeParms: health goes on at 50 at least
const PL_INTER_HOLD#   = 2.0    '' intermission_exittime: the tally stays this long at least
const PL_FIRE_RATE#    = 0.5    '' the shotgun's attack_finished
const PL_IT_SHOTGUN%   = 1
const PL_IT_SSG%       = 2
const PL_IT_NAILGUN%   = 4
'' W_FireSpikes: a nail every 0.2 from 16 up and 4 aside, alternating,
'' at 1000 for 9 (spike_touch), gone after 6 s (SUB_Remove)
const PL_NG_RATE#      = 0.2
const PL_NG_SPEED#     = 1000.0
const PL_NG_DMG%       = 9
const PL_NG_OX#        = 4.0
const PL_NG_UP#        = 16.0
const PL_NG_LIFE#      = 6.0
const PL_NAILS_CAP%    = 200
const PL_NAILS_MAX%    = 24    '' in flight at once
const PL_QUAD_MUL%     = 4
'' client.qc: lava 10 * waterlevel each 0.2 s (a second in the suit),
'' slime 4 * waterlevel each second and none in the suit
const PL_LAVA_DMG%     = 10
const PL_SLIME_DMG%    = 4
const PL_PAIN_GAP#     = 0.5
const PL_LAND_SOFT#    = -300.0 '' PlayerPreThink: land.wav below this fall speed
const PL_LAND_HARD#    = -650.0 '' land2.wav and five points
'' the sounds, in tools/mksnd.py's SOUNDS order; SND_MON + kind * 4 is
'' a monster's sight, then attack, pain, death
const SND_COUNT%       = 59
const SND_SHOTGUN%     = 0
const SND_SSG%         = 1
const SND_NAIL%        = 2
const SND_BOOM%        = 3
const SND_HEALTH%      = 4
const SND_HEALTH_ROT%  = 5
const SND_HEALTH_MEGA% = 6
const SND_ARMOR%       = 7
const SND_WEAPON%      = 8
const SND_AMMO%        = 9
const SND_QUAD%        = 10
const SND_SUIT%        = 11
const SND_SECRET%      = 12
const SND_TALK%        = 13
const SND_PAIN1%       = 14    '' three of them
const SND_DEATH%       = 17
const SND_JUMP%        = 18
const SND_LAND%        = 19
const SND_LAND2%       = 20
const SND_SLIME%       = 21
const SND_BURN1%       = 22    '' two
const SND_MON%         = 24
const SND_DOOR%        = 36    '' doors.qc's sounds 1..4: stop, move
const SND_SECRET1%     = 44    '' func_door_secret's 1..3: noise1..3
const SND_BUTTON%      = 53    '' func_button's 0..3
'' 57, 58 are comp1 and drone6, the ambient_* points; mkassets writes
'' their ids into ents.bin, so nothing here names them -- and a const
'' SND_AMBIENT% is the sub snd_ambient to BC, sigil or not
'' W_FireSuperShotgun: FireBullets (14, dir, '0.14 0.08 0'), two shells,
'' 0.7 to be ready; with one shell left it fires as the shotgun
const PL_SSG_RATE#     = 0.7
const PL_SSG_PELLETS%  = 14
const PL_SSG_SPREAD_X# = 0.14
const PL_SSG_SPREAD_Y# = 0.08
const PL_SHOT_RANGE#   = 2048.0
'' W_FireShotgun: FireBullets (6, dir, '0.04 0.04 0'), TraceAttack (4, ...)
const PL_PELLETS%      = 6
const PL_PELLET_DMG%   = 4
const PL_SPREAD#       = 0.04
const PL_SHELLS_MAX%   = 100
const PL_HEALTH_MEGA%  = 250    '' T_Heal ignoring the cap stops here
const PL_ROT_DELAY#    = 5.0    '' item_megahealth_rot: 5 s, then a point a second
'' view.c: cshifts. Damage 3 a point capped at 150 and fading 150/s in
'' red; a bonus 50 fading 100/s in 215,186,69.
const PL_DMG_SHIFT#    = 3.0
const PL_DMG_SHIFT_MAX# = 150.0
const PL_DMG_FADE#     = 150.0
const PL_BONUS_SHIFT#  = 50.0
const PL_BONUS_FADE#   = 100.0
'' the player's setsize, what a soldier's pellet hits
const PL_HALF#         = 16.0
const PL_ZLO#          = -24.0
const PL_ZHI#          = 32.0
const PL_DEATH_PAUSE#  = 1.5    '' seconds YOU DIED stays before the respawn

const GS_TITLE% = 0             '' fire starts the fight
const GS_PLAY%  = 1
const GS_DEAD%  = 2             '' the pause, then pl_respawn
const GS_WON%   = 3             '' every soldier down; fire resets them all
const GS_EXIT%  = 4             '' the slipgate: LEVEL COMPLETE, fire held two seconds on goes on
const GS_NEXT%  = 5             '' leaving for the next map: the host loop ends


''
'' pl_move.bas. Declared here: these name PlayerState and TraceResult.
''

''
'' Procedures whose signatures can be read from here.
''
