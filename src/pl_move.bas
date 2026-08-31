option explicit
''
'' pl_move.bas -- player physics: collision, gravity, sliding, stairs.
''
''                Ported from softquake's bsp_trace.c and pl_move.c, which are
''                themselves Quake's SV_RecursiveHullCheck and SV_FlyMove.
''
'' COORDINATE SPACE. This module works in BSP space, where Z is up. The
'' renderer works in Y-up: mod_find_spawn already swaps, storing origin[1]
'' into cam.pos.z and origin[2] into cam.pos.y. pl.pos is the authority and
'' cam.pos is derived from it once per frame in pl_move, so the swap lives in
'' exactly one place.
''
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bspfile.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_snd.bi'
'$include: 'q_game.bi'

''
'' This module's own procedures.
''
declare function pl_hull_contents ( _
    byval node as integer, _
    p as Vec3, _
    clip() as ClipNode, _
    planes() as Plane _
) as integer
declare function pl_point_contents ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
declare sub pl_clip_velocity ( _
    v as Vec3, _
    norm as Vec3 _
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
declare sub pl_gravity ( _
    g as Game, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_slide_move ( _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_step_move ( _
    g as Game, _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_trace ( _
    start as Vec3, _
    fin as Vec3, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
declare sub pl_water_level ( _
    g as Game, _
    nodes() as Node, _
    planes() as Plane _
)
declare sub pl_ground_friction ( _
    vel as Vec3, _
    byval dt as single _
)
declare sub pl_ground_accel ( _
    vel as Vec3, _
    wishdir as Vec3, _
    byval wishspeed as single, _
    byval dt as single _
)
declare sub pl_air_accel ( _
    vel as Vec3, _
    wishdir as Vec3, _
    byval wishspeed as single, _
    byval dt as single _
)
declare sub pl_water_move ( _
    vel as Vec3, _
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval dt as single _
)

''
'' This module's own procedures.
''
declare sub pl_init ( _
    g as Game _
)
declare sub pl_move ( _
    g as Game, _
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval jump as integer, _
    byval dt as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane _
)
declare sub pl_load_hulls ( _
    g as Game _
)
declare function pl_hull_rec ( ) as integer

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare function r_leaf_contents ( byval leafnr as integer ) as integer

''
'' THE COLLISION HULLS. Owned here, not in COMMON: this module is the only
'' reader, so the array, its store and its loader all live together.
''
'' They were global because an array must be visible where it is indexed
'' and REDIM forces module level -- so every array the renderer touched
'' had to be declared once, globally, whatever used it. Splitting uglArr's
'' create from its bind removes that: pl_load_hulls makes the store and
'' binds this stub, and nothing outside needs to see either.
''
dim shared clp_buffer() as ClipNode



''
'' Recursion scratch. pl_hull_check calls itself once per plane it straddles,
'' so its depth is the hull tree's depth -- tens, not thousands. The trace it
'' fills is module state rather than a parameter because BASIC has no pointers
'' and passing a UDT down every level of the recursion would copy it.
''
'$static




''::::::::::
'' name: pl_hull_contents
'' desc: Walks the hull tree to find what is at a point. A negative child is
''       not a node index but a contents code, which is the terminator.
''::::::::::
''
'' Moved to src/pl_trace.c -- see pl_trace's own note below for why,
'' and r_walk.c's header for the general reasoning. Declare above is
'' the only trace of the BASIC body left; see git history to recover it.
''




''::::::::::
'' name: pl_point_contents
'' desc: What is at a point, from hull 0 -- the render tree.
''
''       Not the collision hulls: those are built for a box to move through and
''       carry only EMPTY and SOLID. Checked, on dm3ish: 579 EMPTY and 1077
''       SOLID clipnode children, and not one WATER. Water and lava exist only
''       as leaf contents in hull 0, so that is where this looks.
''
''       A child with the high bit set is a leaf rather than a node, and NOT
''       turns it into the leaf index -- the same convention
''       r_recursive_world_node walks.
''::::::::::
function pl_point_contents ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
    dim leafnr as integer

    '' hoisted: BC will not take a call with array arguments inside
    '' another call's argument list
    leafnr = r_point_leaf( p, nodes(), planes() )
    pl_point_contents = r_leaf_contents( leafnr )
end function




''::::::::::
'' name: pl_water_level
'' desc: How deep the player is: 0 dry, 1 feet wet, 2 waist, 3 eyes under.
''       Three samples up the body, which is what Quake does and what lets
''       wading feel different from swimming.
''::::::::::
sub pl_water_level ( _
    g as Game, _
    nodes() as Node, _
    planes() as Plane _
)
    dim p as Vec3
    dim c as integer

    g.pl.water_level = 0
    g.pl.water_type  = CONTENTS_EMPTY

    p = g.pl.pos
    p.z = g.pl.pos.z - PL_FEET# + 1.0
    c = pl_point_contents( p, nodes(), planes() )

    if ( c > CONTENTS_WATER ) then exit sub          '' EMPTY or SOLID: dry

    g.pl.water_type  = c
    g.pl.water_level = 1

    p.z = g.pl.pos.z
    if ( pl_point_contents( p, nodes(), planes() ) <= CONTENTS_WATER ) then
        g.pl.water_level = 2

        p.z = g.pl.pos.z + PL_EYE#
        if ( pl_point_contents( p, nodes(), planes() ) <= CONTENTS_WATER ) then g.pl.water_level = 3
    end if

end sub




''::::::::::
'' name: pl_hull_check
'' desc: Sweeps the point p1->p2 through the hull, recording in tr the first
''       solid plane it meets. p1f/p2f are the fractions of the whole sweep
''       that p1 and p2 represent, so a hit deep in the recursion still reports
''       its distance along the original line.
''
''       Returns true while the sweep is still clear.
''::::::::::
''
'' Moved to src/pl_trace.c -- see pl_trace's own note below for why,
'' and r_walk.c's header for the general reasoning. Declare above is
'' the only trace of the BASIC body left; see git history to recover it.
''




''::::::::::
'' name: pl_trace
'' desc: Sweeps the player hull from start to fin, against the world and every
''       solid brush entity, leaving the closest hit in tr.
''
''       A brush entity is traced by moving the LINE rather than the hull: its
''       tree is at the position the map compiled it, so subtracting the
''       entity's offset from both ends of the sweep asks the same question of
''       a stationary tree that moving the tree would ask of a stationary line.
''
''       tr keeps the earliest hit by itself -- pl_hull_check only writes when
''       it beats tr.frac -- so the hulls can be walked in any order. all_solid
''       is the exception: each walk sets it, so it is gathered by hand.
''::::::::::
''
'' pl_trace, pl_hull_check and pl_hull_contents now live in
'' src/pl_trace.c, compiled with bcc and linked in under these same
'' names -- see r_walk.c's own header for the general reasoning and
'' pl_trace.c's for why this port needed none of sb_build.c's extra
'' care (no calls out to other BASIC functions, no g as Game).
''
'' Kept as an EXTERNAL declare only -- see git history for this file
'' for the original BASIC body, if this ever needs reverting or
'' comparing.
''




''::::::::::
'' name: pl_clip_velocity
'' desc: Removes the component of v that points into the plane, which is what
''       turns a head-on stop into a slide along the wall.
''::::::::::
sub pl_clip_velocity ( _
    v as Vec3, _
    norm as Vec3 _
)
    dim backoff as single

    backoff = v.x*norm.x + v.y*norm.y + v.z*norm.z

    v.x = v.x - norm.x*backoff
    v.y = v.y - norm.y*backoff
    v.z = v.z - norm.z*backoff

    if ( abs( v.x ) < PL_STOP_EPS# ) then v.x = 0.0
    if ( abs( v.y ) < PL_STOP_EPS# ) then v.y = 0.0
    if ( abs( v.z ) < PL_STOP_EPS# ) then v.z = 0.0

end sub



''::::::::::
'' name: pl_slide_move
'' desc: Moves pos along vel for dt, sliding along whatever it hits. Four
''       attempts: each impact clips the velocity into the surface and the
''       remaining time is retried, so an inside corner resolves in two bumps
''       and a dead end stops.
''::::::::::
sub pl_slide_move ( _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
    dim bump as integer
    dim time_left as single
    dim fin as Vec3

    time_left = dt

    for  bump = 0 to 3
        if ( vel.x = 0.0 and vel.y = 0.0 and vel.z = 0.0 ) then exit for

        fin.x = org.x + vel.x*time_left
        fin.y = org.y + vel.y*time_left
        fin.z = org.z + vel.z*time_left

        pl_trace org, fin, tr, model_count, models(), brush(), clip(), planes()

        ''
        '' Started inside solid. Refusing to move is the safe answer: moving
        '' would push further in, and Quake's unstick logic is not here.
        ''
        if ( tr.all_solid ) then
            vel.z = 0.0
            exit sub
        end if

        if ( tr.frac > 0.0 ) then org = tr.end_pos

        if ( tr.frac = 1.0 ) then exit for

        time_left = time_left - time_left*tr.frac

        pl_clip_velocity vel, tr.norm
    next bump

end sub




''::::::::::
'' name: pl_step_move
'' desc: The same move, but if it is blocked by something short enough, climb
''       it. Try the move from PL_STEP# higher, then drop back down: if the
''       landing is above where we started and within one step, the obstacle
''       was a stair and the higher path is kept.
''
''       Without this the player is stopped by every step and every doorframe
''       lip, because a 16 unit stair and a wall are the same thing to a trace.
''::::::::::
sub pl_step_move ( _
    g as Game, _
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
    dim flat_pos as Vec3, flat_vel as Vec3
    dim up_pos as Vec3, down_pos as Vec3
    dim climbed as single

    '' the ordinary slide, kept in case the step attempt is worse
    flat_pos = org
    flat_vel = vel
    pl_slide_move flat_pos, flat_vel, dt, tr, model_count, models(), brush(), clip(), planes()

    ''
    '' Ground, or water. Standing on something is the usual reason to be
    '' able to climb a step, but swimming sets on_ground false, and refusing
    '' to step then means every stair and ledge in a pool stops the player
    '' dead -- they can neither walk up it nor swim over it, because the
    '' slide has already been clipped flat against the riser.
    ''
    if ( g.pl.on_ground = false and g.pl.water_level < 2 ) then
        org = flat_pos
        vel = flat_vel
        exit sub
    end if

    '' lift, move, and drop back
    up_pos = org
    up_pos.z = up_pos.z + PL_STEP#
    pl_trace org, up_pos, tr, model_count, models(), brush(), clip(), planes()
    if ( tr.all_solid ) then
        org = flat_pos
        vel = flat_vel
        exit sub
    end if
    up_pos = tr.end_pos

    pl_slide_move up_pos, vel, dt, tr, model_count, models(), brush(), clip(), planes()

    down_pos   = up_pos
    down_pos.z = down_pos.z - PL_STEP#
    pl_trace up_pos, down_pos, tr, model_count, models(), brush(), clip(), planes()
    if ( tr.all_solid = false ) then up_pos = tr.end_pos

    ''
    '' Keep whichever path travelled further horizontally. The flat move wins
    '' on open ground -- stepping up and dropping back would cost the same
    '' distance for extra work -- and the stepped one wins at a stair, where
    '' the flat move is against a riser and got nowhere.
    ''
    climbed = up_pos.z - org.z

    if ( climbed > 0.1 and climbed <= PL_STEP# + 0.5 ) then
        org = up_pos
    else
        org = flat_pos
        vel = flat_vel
    end if

end sub




''::::::::::
'' name: pl_gravity
'' desc: Ground test and fall. A surface counts as ground only if it is more
''       floor than wall, which is what PL_GROUND_NRM# measures -- otherwise the
''       player would stand on vertical surfaces.
''
''       Gravity is suppressed by ANY water contact, not just being fully
''       submerged -- Quake's SV_CheckWater gates SV_AddGravity on waterlevel
''       being nonzero at all (sv_phys.c, SV_Physics_Client). Sinking is
''       pl_water_move's job at water_level>=2, folded into its own
''       accel/friction rather than a separate force; at water_level=1
''       (feet only) there is neither fall nor sink.
''::::::::::
sub pl_gravity ( _
    g as Game, _
    byval dt as single, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
    dim below as Vec3

    below   = g.pl.pos
    below.z = below.z - 1.0

    pl_trace g.pl.pos, below, tr, model_count, models(), brush(), clip(), planes()

    if ( tr.frac < 1.0 and tr.norm.z > PL_GROUND_NRM# ) then
        g.pl.on_ground = true
        if ( g.pl.vel.z < 0.0 ) then g.pl.vel.z = 0.0
    else
        g.pl.on_ground = false
        if ( g.pl.water_level = 0 ) then g.pl.vel.z = g.pl.vel.z - PL_FALLACC#*dt
    end if

end sub




''::::::::::
'' name: pl_ground_friction
'' desc: Ground friction, horizontal only. Ported from sv_user.c's
''       SV_UserFriction.
''
''       The PL_STOPSPEED# floor is what makes a near-stop actually stop: the
''       decay is proportional to speed, so without a floor it approaches
''       zero without ever reaching it. Quake's own edge-friction bonus (extra
''       drag with a dropoff underfoot) needs a second trace per tick and is
''       not ported -- what is here is the part that changes the numbers that
''       matter: acceleration, top speed, and how fast the player stops.
''::::::::::
sub pl_ground_friction ( _
    vel as Vec3, _
    byval dt as single _
)
    dim speed as single, speed_floor as single, newspeed as single

    speed = sqr( vel.x*vel.x + vel.y*vel.y )
    if ( speed = 0.0 ) then exit sub

    speed_floor = speed
    if ( speed_floor < PL_STOPSPEED# ) then speed_floor = PL_STOPSPEED#

    newspeed = speed - dt*speed_floor*PL_FRICTION#
    if ( newspeed < 0.0 ) then newspeed = 0.0
    newspeed = newspeed / speed

    vel.x = vel.x * newspeed
    vel.y = vel.y * newspeed

end sub




''::::::::::
'' name: pl_ground_accel
'' desc: Ground acceleration towards wishdir at wishspeed. Ported from
''       sv_user.c's SV_Accelerate: the gain is proportional to how far
''       current speed along wishdir is from wishspeed, so it tapers off
''       approaching top speed rather than adding a flat amount every tick.
''::::::::::
sub pl_ground_accel ( _
    vel as Vec3, _
    wishdir as Vec3, _
    byval wishspeed as single, _
    byval dt as single _
)
    dim currentspeed as single, addspeed as single, accelspeed as single

    currentspeed = vel.x*wishdir.x + vel.y*wishdir.y

    addspeed = wishspeed - currentspeed
    if ( addspeed <= 0.0 ) then exit sub

    accelspeed = PL_ACCELERATE# * wishspeed * dt
    if ( accelspeed > addspeed ) then accelspeed = addspeed

    vel.x = vel.x + accelspeed*wishdir.x
    vel.y = vel.y + accelspeed*wishdir.y

end sub




''::::::::::
'' name: pl_air_accel
'' desc: The airborne counterpart of pl_ground_accel. Ported from sv_user.c's
''       SV_AirAccelerate, quirk and all: addspeed is capped at
''       PL_AIRSPEEDCAP# (30), but accelspeed is scaled by the UNCAPPED
''       wishspeed, not by wishspd. That mismatch is what lets air strafing
''       gain more speed per tick than the 30 cap alone suggests -- it is
''       Quake's own arithmetic, not a bug to tidy up here.
''::::::::::
sub pl_air_accel ( _
    vel as Vec3, _
    wishdir as Vec3, _
    byval wishspeed as single, _
    byval dt as single _
)
    dim wishspd as single, currentspeed as single
    dim addspeed as single, accelspeed as single

    wishspd = wishspeed
    if ( wishspd > PL_AIRSPEEDCAP# ) then wishspd = PL_AIRSPEEDCAP#

    currentspeed = vel.x*wishdir.x + vel.y*wishdir.y

    addspeed = wishspd - currentspeed
    if ( addspeed <= 0.0 ) then exit sub

    accelspeed = PL_ACCELERATE# * wishspeed * dt
    if ( accelspeed > addspeed ) then accelspeed = addspeed

    vel.x = vel.x + accelspeed*wishdir.x
    vel.y = vel.y + accelspeed*wishdir.y

end sub




''::::::::::
'' name: pl_water_move
'' desc: Swimming: horizontal wishdir from the same input as ground movement,
''       plus a drift towards the bottom when nothing is pressed. Ported from
''       sv_user.c's SV_WaterMove.
''
''       Friction and acceleration both act on the FULL three-axis speed
''       here, unlike ground movement's horizontal-only friction -- swimming
''       drags vertical motion down too, which is what makes a dive glide to
''       a stop rather than coast forever.
''
''       STRUCTURAL NOTE: real Quake's wishvel comes from AngleVectors on the
''       full view angle, so looking up or down tilts the swim direction --
''       you swim where you look. dir_x/dir_y here are already flattened to
''       the horizontal look (v_update_camera renormalises them so aiming at
''       the floor does not slow walking down), and no pitch reaches this
''       module. So this ports the horizontal wishdir and the idle sink
''       exactly, but pitch-steered vertical swimming is not reachable
''       without changing what v_update_camera hands down -- out of scope
''       for this pass, and noted rather than faked.
''::::::::::
sub pl_water_move ( _
    vel as Vec3, _
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval dt as single _
)
    dim wishvel as Vec3, wishdir as Vec3
    dim wishspeed as single, wishlen as single, scale as single
    dim speed as single, newspeed as single
    dim addspeed as single, accelspeed as single

    wishvel.x = dir_x*fwd*PL_MAXSPEED# - dir_y*strafe*PL_MAXSPEED#
    wishvel.y = dir_y*fwd*PL_MAXSPEED# + dir_x*strafe*PL_MAXSPEED#

    if ( fwd = 0.0 and strafe = 0.0 ) then
        wishvel.z = -PL_WATERSINK#
    else
        wishvel.z = 0.0
    end if

    wishspeed = sqr( wishvel.x*wishvel.x + wishvel.y*wishvel.y + wishvel.z*wishvel.z )
    if ( wishspeed > PL_MAXSPEED# ) then
        scale = PL_MAXSPEED# / wishspeed
        wishvel.x = wishvel.x * scale
        wishvel.y = wishvel.y * scale
        wishvel.z = wishvel.z * scale
        wishspeed = PL_MAXSPEED#
    end if
    wishlen   = wishspeed
    wishspeed = wishspeed * PL_WATERSCALE#

    '' water friction: the full 3D speed, not just horizontal
    speed = sqr( vel.x*vel.x + vel.y*vel.y + vel.z*vel.z )
    if ( speed > 0.0 ) then
        newspeed = speed - dt*speed*PL_FRICTION#
        if ( newspeed < 0.0 ) then newspeed = 0.0
        vel.x = vel.x * (newspeed/speed)
        vel.y = vel.y * (newspeed/speed)
        vel.z = vel.z * (newspeed/speed)
    else
        newspeed = 0.0
    end if

    if ( wishspeed = 0.0 ) then exit sub
    addspeed = wishspeed - newspeed
    if ( addspeed <= 0.0 ) then exit sub

    wishdir.x = wishvel.x / wishlen
    wishdir.y = wishvel.y / wishlen
    wishdir.z = wishvel.z / wishlen

    accelspeed = PL_ACCELERATE# * wishspeed * dt
    if ( accelspeed > addspeed ) then accelspeed = addspeed

    vel.x = vel.x + accelspeed*wishdir.x
    vel.y = vel.y + accelspeed*wishdir.y
    vel.z = vel.z + accelspeed*wishdir.z

end sub




''::::::::::
'' name: pl_init
'' desc: Seeds the player from the spawn point the map gave the camera.
''       cam.pos is Y-up and pl.pos is Z-up, so y and z swap. The height
''       does NOT: info_player_start's origin is the player's own origin,
''       the same thing pl.pos holds, and the eye goes PL_EYE# ABOVE it
''       (pl_move does that on the way out). Taking PL_EYE# off here put
''       the player 22 units under the spawn -- open air on dm3ish, so it
''       merely fell and landed, but inside the floor on e1m7, where it
''       traced solid in every direction and could not move at all.
''::::::::::
sub pl_init ( _
    g as Game _
)
    if ( g.env.start_set ) then
        g.pl.pos.x = g.env.start_x
        g.pl.pos.y = g.env.start_y
        g.pl.pos.z = g.env.start_z
    else
        g.pl.pos.x = g.cam.pos.x
        g.pl.pos.y = g.cam.pos.z
        g.pl.pos.z = g.cam.pos.y
    end if

    g.pl.vel.x = 0.0
    g.pl.vel.y = 0.0
    g.pl.vel.z = 0.0

    g.pl.on_ground = false

end sub




''::::::::::
'' name: pl_move
'' desc: One tick of player physics: accelerate along the look direction,
''       apply friction and gravity, move with collision, then put the eye
''       where the camera can use it.
''
''       fwd and strafe are -1, 0 or 1.
''::::::::::
sub pl_move ( _
    g as Game, _
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval jump as integer, _
    byval dt as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane _
)
    dim tr as TraceResult
    dim wishvel as Vec3, wishdir as Vec3
    dim wishspeed as single

    ''
    '' dir is the horizontal look direction in BSP space, passed in rather than
    '' read from g.cam.look_at: that vector is a direction for part of
    '' v_update_camera and an absolute point for the rest, and depending on
    '' which half of the routine called us would be a trap.
    ''
    '' g.pl.water_level here is last tick's value -- pl_water_level below
    '' refreshes it for pl_gravity and for the NEXT tick's read of this same
    '' branch, exactly the one-tick lag SV_ClientThink has against
    '' SV_CheckWater in sv_phys.c/sv_user.c: friction and accel run before
    '' the server re-checks where the player ended up wet.
    ''
    if ( g.pl.water_level >= 2 ) then
        pl_water_move g.pl.vel, fwd, strafe, dir_x, dir_y, dt
    else
        wishvel.x = dir_x*fwd*PL_MAXSPEED# - dir_y*strafe*PL_MAXSPEED#
        wishvel.y = dir_y*fwd*PL_MAXSPEED# + dir_x*strafe*PL_MAXSPEED#

        wishspeed = sqr( wishvel.x*wishvel.x + wishvel.y*wishvel.y )
        if ( wishspeed > 0.0 ) then
            wishdir.x = wishvel.x / wishspeed
            wishdir.y = wishvel.y / wishspeed
        else
            wishdir.x = 0.0
            wishdir.y = 0.0
        end if
        if ( wishspeed > PL_MAXSPEED# ) then wishspeed = PL_MAXSPEED#

        if ( g.pl.on_ground ) then
            pl_ground_friction g.pl.vel, dt
            pl_ground_accel g.pl.vel, wishdir, wishspeed, dt
        else
            pl_air_accel g.pl.vel, wishdir, wishspeed, dt
        end if
    end if

    pl_water_level g, nodes(), planes()

    pl_gravity g, dt, tr, model_count, models(), brush(), clp_buffer(), planes()

    ''
    '' Jump. After pl_gravity, which is what decides whether there is any
    '' ground -- doing it before would read last frame's answer and allow a
    '' second jump in mid-air. Swimming and jumping share the key but not the
    '' effect: at waterlevel>=2 it is a swim stroke, keyed on liquid type,
    '' every tick the key is held rather than a one-shot launch. Ported from
    '' QuakeWorld's pmove.c JumpButton, which mirrors id1's QC.
    ''
    '' The velocity is set rather than added, so holding the key gives one
    '' jump or one stroke instead of accumulating thrust.
    ''
    if ( g.pl.water_level >= 2 ) then
        if ( jump ) then
            select case g.pl.water_type
                case CONTENTS_SLIME
                    g.pl.vel.z = PL_SWIM_SLIME#
                case CONTENTS_WATER
                    g.pl.vel.z = PL_SWIM_WATER#
                case else
                    g.pl.vel.z = PL_SWIM_LAVA#
            end select
            g.pl.on_ground = false
        end if

    elseif ( jump and g.pl.on_ground ) then
        g.pl.vel.z     = PL_JUMP#
        g.pl.on_ground = false
    end if

    ''
    '' A per-axis safety clamp, not a speed cap -- Quake's SV_CheckVelocity
    '' against sv_maxvelocity. The real ceiling on walking/swimming speed is
    '' wishspeed inside pl_ground_accel/pl_air_accel/pl_water_move; this
    '' only stops a runaway (e.g. a bad trace) from producing a NaN-adjacent
    '' velocity that the next frame's move can't recover from.
    ''
    if ( g.pl.vel.x >  PL_MAXVEL# ) then g.pl.vel.x =  PL_MAXVEL#
    if ( g.pl.vel.x < -PL_MAXVEL# ) then g.pl.vel.x = -PL_MAXVEL#
    if ( g.pl.vel.y >  PL_MAXVEL# ) then g.pl.vel.y =  PL_MAXVEL#
    if ( g.pl.vel.y < -PL_MAXVEL# ) then g.pl.vel.y = -PL_MAXVEL#
    if ( g.pl.vel.z >  PL_MAXVEL# ) then g.pl.vel.z =  PL_MAXVEL#
    if ( g.pl.vel.z < -PL_MAXVEL# ) then g.pl.vel.z = -PL_MAXVEL#

    pl_step_move g, g.pl.pos, g.pl.vel, dt, tr, model_count, models(), brush(), _
                  clp_buffer(), planes()

    if ( g.pl.pos.z > g.pl.peak_z ) then g.pl.peak_z = g.pl.pos.z

    ''
    '' Hand the eye back to the renderer, converting Z-up to Y-up. This is the
    '' only place the two spaces meet.
    ''
    g.cam.pos.x = g.pl.pos.x
    g.cam.pos.y = g.pl.pos.z + PL_EYE#
    g.cam.pos.z = g.pl.pos.y

end sub


''::::::::::
'' name: pl_load_hulls
'' desc: Builds the clip-hull store and binds it. Called by the map loader,
''       which passes the count and nothing else -- it does not need to
''       know where the hulls live.
''::::::::::
sub pl_load_hulls ( _
    g as Game _
)
    dim f as FILE
    dim mapped as long

    redim clp_buffer(0) as ClipNode

    ''
    '' MEM, not EMS. These hulls are walked several times a frame, and EMS
    '' costs an INT 67h per access where MEM costs a segment calculation --
    '' the same difference that made the EMS-backed node tree unusable. Hot
    '' data does not go in EMS.
    ''
    '' EMS would show a better FRE at this mark, but the number is
    '' misleading: FRE(-1) is the LARGEST FREE BLOCK, and what taking a
    '' large array out of the far heap really buys is a bigger contiguous
    '' hole for the allocations that come after. The far heap is the
    '' fragmented pool; DOS memory is not.
    ''
    g.wld.store.clips = uglArrNew&( UGL.MEM, len( clp_buffer(0) ), g.wld.count.clips, 0 )
    if ( g.wld.store.clips = 0 ) then
        g.wld.store.clips = uglArrNew&( UGL.EMS, len( clp_buffer(0) ), g.wld.count.clips, PAGE_SLOT )
    end if
    if ( g.wld.store.clips = 0 ) then sys_error "0x0033, no room for the clip hulls"

    '' Hands the descriptor over. NOT ceremony: this is what takes it out
    '' of the far heap's chain, and only BASIC can do that correctly. Left
    '' in, B$FHCompact walks into a descriptor aimed at memory it does not
    '' own and moves it -- the far heap is then corrupt. The variable still
    '' exists afterwards, which is what uglArrMap binds to.
    erase clp_buffer

    if ( fileOpen%( f, "clip.pag", F4READ ) = 0 ) then
        sys_error "0x0034, clip.pag missing"
    end if
    if ( uglArrLoad%( f, g.wld.store.clips ) = 0 ) then
        fileClose f
        sys_error "0x0035, clip.pag short or unreadable"
    end if
    fileClose f

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = uglArrMap&( g.wld.store.clips, clp_buffer(), 0 )
end sub

'' Clipnode record size, for the bench report.
function pl_hull_rec ( ) as integer
    pl_hull_rec = len( clp_buffer(0) )
end function
