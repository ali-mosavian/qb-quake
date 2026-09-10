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
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'
'$include: 'qgl.bi'

''
'' This module's own procedures.
''
''
'' qgl's paged-array store. flname is NOT byval: VBDOS passes a plain
'' "as string" parameter as a near pointer to its descriptor, which is
'' what the assembly wants.
''
declare function qglArLoadBas ( _
    flname as string, _
    byval typ as integer, _
    byval elsz as integer, _
    byval cnt as long, _
    byval slot as integer _
) as long
declare function qglArMap ( _
    byval h as long, _
    a() as any, _
    byval idx as long _
) as long

declare function pl_hull_contents ( _
    byval node as integer, _
    p as Vec3, _
    clip() as ClipNode, _
    planes() as Plane _
) as integer
declare function mdl_slab ( _
    byval lo as single, _
    byval hi as single, _
    byval o as single, _
    byval d as single, _
    tn as single, _
    tf as single _
) as integer
declare function mdl_ray_box ( _
    c as Vec3, _
    byval hx as single, _
    byval zlo as single, _
    byval zhi as single, _
    org as Vec3, _
    dir as Vec3, _
    byval maxt as single _
) as single
declare sub pl_spread_dir ( _
    dir as Vec3, _
    byval spread as single, _
    outdir as Vec3 _
)
declare sub mdl_damage ( _
    g as Game, _
    ent as MdlEnt, _
    byval dmg as integer, _
    item() as ItemEnt _
)
declare sub mdl_fire ( _
    g as Game, _
    ent as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub pl_item_add ( _
    g as Game, _
    item() as ItemEnt, _
    byval kind as integer, _
    byval amount as integer, _
    org as Vec3 _
)
declare sub pl_respawn ( g as Game )
declare sub pl_reset_player ( g as Game )
declare sub pl_game_reset ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub pl_items_drop ( _
    g as Game, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub pl_items_touch ( g as Game, item() as ItemEnt )
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
declare sub mdl_think ( _
    g as Game, _
    ent as MdlEnt, _
    byval can_chase as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub mdl_spawn ( _
    g as Game, _
    ent as MdlEnt, _
    org as Vec3, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare function pl_hull_rec ( ) as integer

'' id's own monster-movement primitives (sv_move.c/ai.qc), private to this
'' module -- mdl_think is the only caller, same reasoning r_leaf_contents
'' gets below: a shared header would hand these to modules that never use
'' them, and BC's symbol table is finite.
declare function mdl_anglemod ( byval v as single ) as single
declare function mdl_atan2 ( byval y as single, byval x as single ) as single
declare function mdl_vectoyaw ( byval dx as single, byval dy as single ) as single
declare sub mdl_change_yaw ( ent as MdlEnt )
declare sub mdl_pick_goal ( ent as MdlEnt )
declare function mdl_movestep ( _
    g as Game, _
    ent as MdlEnt, _
    byval dx as single, _
    byval dy as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
declare function mdl_step_dir ( _
    g as Game, _
    ent as MdlEnt, _
    byval yaw as single, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
declare sub mdl_new_chase_dir ( _
    g as Game, _
    ent as MdlEnt, _
    goal as Vec3, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare sub mdl_move_to_goal ( _
    g as Game, _
    ent as MdlEnt, _
    goal as Vec3, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare function mdl_find_target ( _
    g as Game, _
    ent as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer

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

'' army_run1..8's own ai_run() distances (soldier.qc) -- redim'd and
'' filled once by mdl_spawn, a SUB, since a bare module-level fixed-bound
'' dim in a non-main module is the ls_tab trap (AGENTS.md): it never runs.
dim shared mdl_run_dist() as integer

'' sv_move.c's own STEPSIZE -- see mdl_movestep.
const MDL_STEPSIZE# = 18.0




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
''       result lands on walkable ground, the obstacle was a stair and the
''       higher path is kept. Ported from sv_phys.c's SV_WalkMove.
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
    dim step_vel as Vec3
    dim old_vel_z as single

    '' the ordinary slide, kept in case the step attempt is worse
    flat_pos = org
    flat_vel = vel
    pl_slide_move flat_pos, flat_vel, dt, tr, model_count, models(), brush(), clip(), planes()

    ''
    '' Nothing to step over: the flat move's velocity came out exactly as it
    '' went in, so nothing clipped it against a plane anywhere along the
    '' way. Matches SV_WalkMove's own gate (it only tries stepping when
    '' FlyMove reports it was blocked), and checking velocity rather than
    '' tr.frac matters here: pl_slide_move can clip against a riser on its
    '' first bump and then finish the REMAINING distance unobstructed on a
    '' later bump, leaving tr.frac at 1.0 even though the move was blocked.
    '' As a side effect this also stops the probe below from zeroing a swim
    '' stroke's vertical velocity when there was nothing to climb at all.
    ''
    if ( flat_vel.x = vel.x and flat_vel.y = vel.y and flat_vel.z = vel.z ) then
        org = flat_pos
        vel = flat_vel
        exit sub
    end if

    ''
    '' Ground, or water. Standing on something is the usual reason to be
    '' able to climb a step, but swimming sets on_ground false, and refusing
    '' to step then means every stair and ledge in a pool stops the player
    '' dead -- they can neither walk up it nor swim over it, because the
    '' slide has already been clipped flat against the riser. Matches
    '' SV_WalkMove's own gate: don't stair up while jumping, but any wetness
    '' at all is enough to allow it.
    ''
    if ( g.pl.on_ground = false and g.pl.water_level = 0 ) then
        org = flat_pos
        vel = flat_vel
        exit sub
    end if

    old_vel_z = vel.z

    '' lift, then move forward with the vertical component held at zero --
    '' the step height stands in for it, so falling speed should not also
    '' carry the probe forward at the raised height
    up_pos = org
    up_pos.z = up_pos.z + PL_STEP#
    pl_trace org, up_pos, tr, model_count, models(), brush(), clip(), planes()

    if ( tr.all_solid ) then
        org = flat_pos
        vel = flat_vel
        exit sub
    end if
    up_pos = tr.end_pos

    step_vel   = vel
    step_vel.z = 0.0
    pl_slide_move up_pos, step_vel, dt, tr, model_count, models(), brush(), clip(), planes()

    '' drop back down, extended by however far the original fall speed would
    '' have carried this tick
    down_pos   = up_pos
    down_pos.z = down_pos.z - PL_STEP# + old_vel_z*dt
    pl_trace up_pos, down_pos, tr, model_count, models(), brush(), clip(), planes()

    ''
    '' Keep the stepped path only if it lands on walkable ground. A slope too
    '' steep to climb, or open air past the edge, fails this -- tr.norm is
    '' left at (0,0,0) by pl_trace when nothing is hit, which is not > 0.7
    '' either -- and falls back to the flat move.
    ''
    if ( tr.norm.z > PL_GROUND_NRM# ) then
        org = tr.end_pos
        vel = step_vel
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
    dim speed as single, speed_floor as single, newspeed as single
    dim fric as single
    dim edge_a as Vec3, edge_b as Vec3

    speed = sqr( vel.x*vel.x + vel.y*vel.y )
    if ( speed = 0.0 ) then exit sub

    ''
    '' Edge friction. Probe one player-width ahead along the way we
    '' are travelling, from the feet down 34 units: if nothing is
    '' under it the leading edge overhangs a drop, and friction
    '' doubles. That is what stops you sliding off a ledge, and it
    '' is the one part of SV_UserFriction that costs a trace.
    ''
    edge_a.x = org.x + vel.x/speed*PL_EDGE_FWD#
    edge_a.y = org.y + vel.y/speed*PL_EDGE_FWD#
    edge_a.z = org.z - PL_FEET#
    edge_b.x = edge_a.x
    edge_b.y = edge_a.y
    edge_b.z = edge_a.z - PL_EDGE_DROP#

    pl_trace edge_a, edge_b, tr, model_count, models(), brush(), clip(), planes()

    fric = PL_FRICTION#
    if ( tr.frac = 1.0 ) then fric = PL_FRICTION# * PL_EDGEFRIC#

    speed_floor = speed
    if ( speed_floor < PL_STOPSPEED# ) then speed_floor = PL_STOPSPEED#

    newspeed = speed - dt*speed_floor*fric
    if ( newspeed < 0.0 ) then newspeed = 0.0
    newspeed = newspeed / speed

    '' All THREE components, as SV_UserFriction does: the speed is
    '' measured from x and y, but the scaling is applied to z as well.
    vel.x = vel.x * newspeed
    vel.y = vel.y * newspeed
    vel.z = vel.z * newspeed

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

    wishvel.x = dir_x*fwd*PL_FWDSPEED# - dir_y*strafe*PL_FWDSPEED#
    wishvel.y = dir_y*fwd*PL_FWDSPEED# + dir_x*strafe*PL_FWDSPEED#

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
        wishvel.x = dir_x*fwd*PL_FWDSPEED# - dir_y*strafe*PL_FWDSPEED#
        wishvel.y = dir_y*fwd*PL_FWDSPEED# + dir_x*strafe*PL_FWDSPEED#

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
            pl_ground_friction g.pl.pos, g.pl.vel, dt, tr, model_count, _
                               models(), brush(), clp_buffer(), planes()
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
    g.wld.store.clips = qglArLoadBas&( "assets.zip::clip.pag", QGL_AR_MEM, len( clp_buffer(0) ), _
                                            clng( g.wld.count.clips ), 0 )
    if ( g.wld.store.clips = 0 ) then
        g.wld.store.clips = qglArLoadBas&( "assets.zip::clip.pag", QGL_AR_EMS, len( clp_buffer(0) ), _
                                                clng( g.wld.count.clips ), PAGE_SLOT )
    end if
    if ( g.wld.store.clips = 0 ) then sys_error "0x0033, clip.pag would not load"

    '' Hands the descriptor over. NOT ceremony: this is what takes it out
    '' of the far heap's chain, and only BASIC can do that correctly. Left
    '' in, B$FHCompact walks into a descriptor aimed at memory it does not
    '' own and moves it -- the far heap is then corrupt. The variable still
    '' exists afterwards, which is what qglArMap binds to.
    erase clp_buffer

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = qglArMap&( g.wld.store.clips, clp_buffer(), 0 )
end sub

'' Clipnode record size, for the bench report.
function pl_hull_rec ( ) as integer
    pl_hull_rec = len( clp_buffer(0) )
end function

''::::::::::::::
'' name: mdl_spawn
'' desc: sets the model's WORLD position once, and (re)seeds the run
''       animation's own per-frame move distances -- army_run1..8's
''       ai_run(N) calls in soldier.qc, exact: 11,15,10,10,8,15,10,8.
''       Called from host_init, after mdl_load succeeds -- not from
''       mdl_draw, which used to recompute a position from the player
''       every frame and so looked "stuck" to whoever was watching it
''       rather than standing in the map on its own.
''::::::::::::::
sub mdl_spawn ( _
    g as Game, _
    ent as MdlEnt, _
    org as Vec3, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim fin as Vec3
    dim tr as TraceResult

    ent.pos.x = org.x
    ent.pos.y = org.y
    ent.pos.z = org.z
    ent.yaw = 0.0
    ent.ideal_yaw = 0.0
    ent.next_think = 0.0
    ent.state = MDL_ST_STAND%
    ent.anim_frame = 0
    ent.goal.x = org.x : ent.goal.y = org.y : ent.goal.z = org.z
    ent.wander_ticks = 0
    ent.health = MDL_HEALTH%
    ent.hunting = 0
    ent.next_attack = 0.0
    ent.pain_finished = 0.0
    '' staggered, not all-at-0: eight monsters spawned in the same tick
    '' otherwise all pick their first wander goal on the same think.
    ent.stand_until = rnd * MDL_STAND_MAX#

    '' walkmonster_start_go's own droptofloor(): org came from g.pl.pos at
    '' host_init time, before host_main's first physics tick has run
    '' pl_gravity even once -- that is the player's raw, not-yet-settled
    '' spawn height, and this model has no gravity of its own to fall the
    '' rest of the way. Without this it stands in mid-air forever at
    '' whatever height was copied in; mdl_movestep's own +-STEPSIZE band
    '' only ever finds a floor already within 18 units, and a fresh spawn
    '' can be well outside that.
    fin.x = ent.pos.x
    fin.y = ent.pos.y
    fin.z = ent.pos.z - 256.0
    pl_trace ent.pos, fin, tr, g.wld.count.models, models(), brush(), clp_buffer(), planes()
    if ( tr.frac < 1.0 and tr.all_solid = 0 ) then
        ent.pos.x = tr.end_pos.x
        ent.pos.y = tr.end_pos.y
        ent.pos.z = tr.end_pos.z
    end if
    ent.spawn.x = ent.pos.x : ent.spawn.y = ent.pos.y : ent.spawn.z = ent.pos.z

    redim mdl_run_dist( MDL_RUN_FRAMES% - 1 ) as integer
    mdl_run_dist(0) = 11 : mdl_run_dist(1) = 15 : mdl_run_dist(2) = 10 : mdl_run_dist(3) = 10
    mdl_run_dist(4) =  8 : mdl_run_dist(5) = 15 : mdl_run_dist(6) = 10 : mdl_run_dist(7) =  8
end sub

''::::::::::::::
'' name: mdl_anglemod
'' desc: ai.qc's anglemod -- wrap to [0,360).
''::::::::::::::
function mdl_anglemod ( byval v as single ) as single
    do while ( v >= 360.0 )
        v = v - 360.0
    loop
    do while ( v < 0.0 )
        v = v + 360.0
    loop
    mdl_anglemod = v
end function

''::::::::::::::
'' name: mdl_atan2
'' desc: BASIC has no ATN2 -- the standard four-quadrant construction from
''       ATN, needed so mdl_vectoyaw can match PF_vectoyaw exactly.
''::::::::::::::
function mdl_atan2 ( byval y as single, byval x as single ) as single
    dim r as single
    if ( x > 0.0 ) then
        r = atn( y / x )
    elseif ( x < 0.0 ) then
        if ( y >= 0.0 ) then
            r = atn( y / x ) + 3.14159265
        else
            r = atn( y / x ) - 3.14159265
        end if
    else
        if ( y > 0.0 ) then
            r = 1.57079633
        elseif ( y < 0.0 ) then
            r = -1.57079633
        else
            r = 0.0
        end if
    end if
    mdl_atan2 = r
end function

''::::::::::::::
'' name: mdl_vectoyaw
'' desc: PF_vectoyaw (pr_cmds.c), exact -- including the (int) truncation
''       toward zero, which BASIC's own int() does NOT do (int() floors;
''       see AGENTS.md's own note on the two disagreeing for negatives).
''::::::::::::::
function mdl_vectoyaw ( byval dx as single, byval dy as single ) as single
    dim yaw as single

    if ( dx = 0.0 and dy = 0.0 ) then
        mdl_vectoyaw = 0.0
        exit function
    end if

    yaw = mdl_atan2( dy, dx ) * 57.29577951
    if ( yaw < 0.0 ) then
        yaw = -int( -yaw )
    else
        yaw = int( yaw )
    end if
    if ( yaw < 0.0 ) then yaw = yaw + 360.0

    mdl_vectoyaw = yaw
end function

''::::::::::::::
'' name: mdl_change_yaw
'' desc: PF_changeyaw (pr_cmds.c) -- turns ent.yaw towards ideal_yaw at
''       up to MDL_YAW_SPEED# degrees per 0.1s think. Exact port.
''::::::::::::::
sub mdl_change_yaw ( ent as MdlEnt )
    dim cur as single, ideal as single, mv as single

    cur = mdl_anglemod( ent.yaw )
    ideal = ent.ideal_yaw
    if ( cur = ideal ) then exit sub

    mv = ideal - cur
    if ( ideal > cur ) then
        if ( mv >= 180.0 ) then mv = mv - 360.0
    else
        if ( mv <= -180.0 ) then mv = mv + 360.0
    end if

    if ( mv > 0.0 ) then
        if ( mv > MDL_YAW_SPEED# ) then mv = MDL_YAW_SPEED#
    else
        if ( mv < -MDL_YAW_SPEED# ) then mv = -MDL_YAW_SPEED#
    end if

    ent.yaw = mdl_anglemod( cur + mv )
end sub

''::::::::::::::
'' name: mdl_movestep
'' desc: SV_movestep's own vertical dance (sv_move.c) -- the piece a bare
''       pl_trace does not do, and the reason the model used to float:
''       a horizontal-only trace at a fixed z never touches a floor that
''       stepped down (nothing blocks it, so it "succeeds" at the old
''       height), and never climbs one that stepped up either.
''
''       One trace of the entity's own box (pl_trace, hull 1 -- the same
''       collision the player uses), from (new xy, old z + STEPSIZE) down
''       to (new xy, old z - STEPSIZE): whatever it lands on within that
''       18-unit-either-way band is the new floor. Starting inside solid
''       (a low ceiling at +STEPSIZE) retries once from the ORIGINAL
''       height instead, matching the C original exactly. Nothing hit
''       anywhere in the band means the step would walk off an edge, and
''       is refused outright -- there is no FL_PARTIALGROUND fall-through
''       here (that recovers a monster standing on a lift that got
''       pulled out from under it, which nothing in this world does yet).
''
''       NOT ported: SV_CheckBottom's four-corner support check, so a
''       monster can still teeter over a corner where the real game would
''       refuse the step. cport's own mob.c has the full version.
''::::::::::::::
function mdl_movestep ( _
    g as Game, _
    ent as MdlEnt, _
    byval dx as single, _
    byval dy as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
    dim start as Vec3, fin as Vec3
    dim tr as TraceResult

    start.x = ent.pos.x + dx
    start.y = ent.pos.y + dy
    start.z = ent.pos.z + MDL_STEPSIZE#

    fin.x = start.x
    fin.y = start.y
    fin.z = ent.pos.z - MDL_STEPSIZE#

    pl_trace start, fin, tr, model_count, models(), brush(), clp_buffer(), planes()

    if ( tr.all_solid ) then
        mdl_movestep = 0
        exit function
    end if

    if ( tr.start_solid ) then
        start.z = ent.pos.z
        pl_trace start, fin, tr, model_count, models(), brush(), clp_buffer(), planes()
        if ( tr.all_solid or tr.start_solid ) then
            mdl_movestep = 0
            exit function
        end if
    end if

    if ( tr.frac > 0.999 ) then
        '' nothing within +-STEPSIZE of the new xy: an edge, not a floor
        mdl_movestep = 0
        exit function
    end if

    ent.pos.x = tr.end_pos.x
    ent.pos.y = tr.end_pos.y
    ent.pos.z = tr.end_pos.z
    mdl_movestep = -1
end function

''::::::::::::::
'' name: mdl_step_dir
'' desc: SV_StepDirection (sv_move.c), exact -- including its own oddity:
''       the step is REVERTED (position only, not the turn) when not yet
''       within 45 degrees of the requested heading, but TRUE is still
''       returned. A monster not yet facing a new direction visibly turns
''       in place for a tick or two before it starts walking -- that is
''       this, not a bug.
''::::::::::::::
function mdl_step_dir ( _
    g as Game, _
    ent as MdlEnt, _
    byval yaw as single, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
    dim rad as single
    dim old as Vec3
    dim dx as single, dy as single
    dim delta as single

    ent.ideal_yaw = yaw
    mdl_change_yaw ent

    rad = yaw * 0.017453293
    old.x = ent.pos.x : old.y = ent.pos.y : old.z = ent.pos.z
    dx = cos( rad ) * dist
    dy = sin( rad ) * dist

    if ( mdl_movestep( g, ent, dx, dy, model_count, models(), brush(), planes() ) ) then
        delta = mdl_anglemod( ent.yaw - ent.ideal_yaw )
        if ( delta > 45.0 and delta < 315.0 ) then
            ent.pos.x = old.x : ent.pos.y = old.y : ent.pos.z = old.z
        end if
        mdl_step_dir = -1
    else
        mdl_step_dir = 0
    end if
end function

''::::::::::::::
'' name: mdl_new_chase_dir
'' desc: SV_NewChaseDir (sv_move.c), exact -- the real "path finding":
''       eight compass directions, a direct-diagonal try first, then the
''       two cardinal components (order coin-flipped the same way the
''       original does), then the old heading, then a full randomised
''       sweep, then reverse. No graph, no search, no A* -- this IS what
''       id shipped.
''::::::::::::::
sub mdl_new_chase_dir ( _
    g as Game, _
    ent as MdlEnt, _
    goal as Vec3, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim deltax as single, deltay as single
    dim d1 as single, d2 as single, tdir as single, tmp as single
    dim olddir as single, turnaround as single

    olddir = mdl_anglemod( int( ent.ideal_yaw / 45.0 ) * 45.0 )
    turnaround = mdl_anglemod( olddir - 180.0 )

    deltax = goal.x - ent.pos.x
    deltay = goal.y - ent.pos.y

    if ( deltax > 10.0 ) then
        d1 = 0.0
    elseif ( deltax < -10.0 ) then
        d1 = 180.0
    else
        d1 = -1.0
    end if

    if ( deltay < -10.0 ) then
        d2 = 270.0
    elseif ( deltay > 10.0 ) then
        d2 = 90.0
    else
        d2 = -1.0
    end if

    '' direct diagonal route
    if ( d1 <> -1.0 and d2 <> -1.0 ) then
        if ( d1 = 0.0 ) then
            if ( d2 = 90.0 ) then tdir = 45.0 else tdir = 315.0
        else
            if ( d2 = 90.0 ) then tdir = 135.0 else tdir = 215.0
        end if
        if ( tdir <> turnaround ) then
            if ( mdl_step_dir( g, ent, tdir, dist, model_count, models(), brush(), planes() ) ) then exit sub
        end if
    end if

    '' the two cardinal components, order coin-flipped exactly as the
    '' original's own (rand()&3)&1 -- a plain OR here would risk BASIC
    '' evaluating both operands and losing the intended 50/50 skip, so
    '' it is a single AND-1 test, not two.
    if ( ( int( rnd * 4 ) and 1 ) or ( abs( deltay ) > abs( deltax ) ) ) then
        tmp = d1 : d1 = d2 : d2 = tmp
    end if

    if ( d1 <> -1.0 and d1 <> turnaround ) then
        if ( mdl_step_dir( g, ent, d1, dist, model_count, models(), brush(), planes() ) ) then exit sub
    end if
    if ( d2 <> -1.0 and d2 <> turnaround ) then
        if ( mdl_step_dir( g, ent, d2, dist, model_count, models(), brush(), planes() ) ) then exit sub
    end if

    '' no direct path -- hold the old heading, then sweep all eight
    '' compass points in a randomised order, then reverse
    if ( olddir <> -1.0 ) then
        if ( mdl_step_dir( g, ent, olddir, dist, model_count, models(), brush(), planes() ) ) then exit sub
    end if

    if ( int( rnd * 2 ) ) then
        for tdir = 0.0 to 315.0 step 45.0
            if ( tdir <> turnaround ) then
                if ( mdl_step_dir( g, ent, tdir, dist, model_count, models(), brush(), planes() ) ) then exit sub
            end if
        next tdir
    else
        for tdir = 315.0 to 0.0 step -45.0
            if ( tdir <> turnaround ) then
                if ( mdl_step_dir( g, ent, tdir, dist, model_count, models(), brush(), planes() ) ) then exit sub
            end if
        next tdir
    end if

    if ( mdl_step_dir( g, ent, turnaround, dist, model_count, models(), brush(), planes() ) ) then exit sub

    ent.ideal_yaw = olddir   '' can't move
end sub

''::::::::::::::
'' name: mdl_move_to_goal
'' desc: SV_MoveToGoal (sv_move.c), exact: a 1-in-4 chance to skip the
''       direct step and go straight to the compass search, matching
''       C's short-circuit || (mdl_step_dir has side effects, so this is
''       written to guarantee it is not called on the skip roll, unlike
''       a plain BASIC OR which does not guarantee short-circuiting).
''::::::::::::::
sub mdl_move_to_goal ( _
    g as Game, _
    ent as MdlEnt, _
    goal as Vec3, _
    byval dist as single, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim skip as integer, stepped as integer

    skip = ( int( rnd * 4 ) = 1 )
    if ( skip = 0 ) then
        stepped = mdl_step_dir( g, ent, ent.ideal_yaw, dist, model_count, models(), brush(), planes() )
    else
        stepped = 0
    end if

    if ( skip or ( stepped = 0 ) ) then
        mdl_new_chase_dir g, ent, goal, dist, model_count, models(), brush(), planes()
    end if
end sub

''::::::::::::::
'' name: mdl_find_target
'' desc: FindTarget (ai.qc), collapsed to the one enemy this world can
''       ever have -- the player. RANGE_NEAR and RANGE_MID both end up
''       requiring infront() here (client.show_hostile is a monster-only
''       field, never set on a player, so client.show_hostile < time is
''       always true for a real player and the two ranges behave alike).
''       RANGE_MELEE skips infront -- "will become hostile even if back
''       is turned" (ai.qc's own comment).
''
''       visible() is approximated through hull 1 (the player-sized
''       clipnodes pl_trace already walks), not the true hull-0 point
''       trace id's traceline() uses -- this renderer has no hull-0 line
''       trace. A real point trace sees past a few corners this cannot.
''::::::::::::::
function mdl_find_target ( _
    g as Game, _
    ent as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
    dim eye as Vec3, peye as Vec3
    dim dx as single, dy as single, dz as single
    dim r as single
    dim tr as TraceResult
    dim yaw_rad as single
    dim fwd_x as single, fwd_y as single
    dim dlen as single, dot as single

    mdl_find_target = 0

    eye.x  = ent.pos.x : eye.y  = ent.pos.y : eye.z  = ent.pos.z + MDL_VIEW_OFS#
    peye.x = g.pl.pos.x  : peye.y = g.pl.pos.y  : peye.z = g.pl.pos.z  + PL_EYE#

    dx = peye.x - eye.x : dy = peye.y - eye.y : dz = peye.z - eye.z
    r = sqr( dx*dx + dy*dy + dz*dz )
    if ( r >= MDL_RANGE_MID# ) then exit function   '' RANGE_FAR

    pl_trace eye, peye, tr, g.wld.count.models, models(), brush(), clp_buffer(), planes()
    if ( tr.frac <= 0.999 or tr.all_solid ) then exit function   '' not visible

    if ( r >= MDL_RANGE_MELEE# ) then
        yaw_rad = ent.yaw * 0.017453293
        fwd_x = cos( yaw_rad ) : fwd_y = sin( yaw_rad )
        dlen = sqr( dx*dx + dy*dy )
        if ( dlen > 0.0 ) then
            dot = ( dx*fwd_x + dy*fwd_y ) / dlen
        else
            dot = 1.0
        end if
        if ( dot <= 0.3 ) then exit function   '' not infront
    end if

    '' found -- HuntTarget's own side effect: face the enemy immediately
    ent.ideal_yaw = mdl_vectoyaw( dx, dy )
    mdl_find_target = -1
end function

''::::::::::::::
'' name: mdl_pick_goal
'' desc: NOT in stock Quake -- see q_mdl.bi's own note. A random point on
''       a circle of MDL_WANDER_MIN#..MDL_WANDER_MAX# around the entity's
''       CURRENT position, not its spawn point, so a monster that has
''       already wandered somewhere keeps drifting rather than yo-yoing
''       back to where it started. No reachability check: an unreachable
''       goal just times out in mdl_think (MDL_WANDER_MAXTICKS%), the
''       same as a chase the compass search cannot route around.
''::::::::::::::
sub mdl_pick_goal ( ent as MdlEnt )
    dim ang as single, dist as single

    ang = rnd * 6.28318531
    dist = MDL_WANDER_MIN# + rnd * ( MDL_WANDER_MAX# - MDL_WANDER_MIN# )
    ent.goal.x = ent.pos.x + cos( ang ) * dist
    ent.goal.y = ent.pos.y + sin( ang ) * dist
    ent.goal.z = ent.pos.z
end sub

''::::::::::::::
'' name: mdl_think
'' desc: id's own monster AI (ai.qc/sv_move.c), ported exactly, PLUS an
''       own-goal wander loop stock Quake never had (see q_mdl.bi's own
''       note: a walkmonster with no path_corner target just stands
''       forever). STAND either finds the player (can_chase path, exact
''       port -- FindTarget/ai_run/SV_MoveToGoal/SV_NewChaseDir) or, once
''       its own idle pause elapses, picks a nearby point and moves there
''       the SAME way a chase would: mdl_move_to_goal, so collision,
''       stepping and the 8-direction compass search are identical either
''       way. The "path finding" is that compass search; there is no A*,
''       no graph, because id never shipped one and this doesn't add one.
''
''       Movement distance and displayed frame are the SAME state: while
''       army_runN is on screen, ai_run(N)'s own distance is what moves
''       that tick, and the frame only advances afterwards -- matching
''       soldier.qc's state-machine frames exactly, not a fixed per-think
''       distance. Because wandering reuses RUN's animation and STAND
''       reuses STAND's, the displayed frame always matches what the
''       entity is actually doing -- walking or standing -- never picked
''       independently of the movement that drives it.
''
''       10Hz, like the player's own tick rate and Quake's real think
''       clock -- driven off g.rdr.anim_time, already running at real
''       seconds, so no new clock is needed.
''
''       can_chase gates the FindTarget call only. A monster spawned with
''       it false never hunts the player -- same as real Quake's own
''       walkmonster with no path_corner target and no player ever in
''       range -- but it still wanders on its own goals, which real Quake
''       never does at all.
''::::::::::::::
sub mdl_think ( _
    g as Game, _
    ent as MdlEnt, _
    byval can_chase as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim dist as single
    dim goal as Vec3
    dim dx as single, dy as single, d2 as single
    dim chance as single

    if ( g.mdl.loaded = 0 ) then exit sub
    if ( g.rdr.anim_time < ent.next_think ) then exit sub
    ent.next_think = g.rdr.anim_time + 0.1

    '' Dead: the death frames once, then a corpse until pl_game_reset.
    if ( ent.state = MDL_ST_DEAD% ) then
        if ( ent.anim_frame < MDL_DEATH_FRAMES% - 1 ) then ent.anim_frame = ent.anim_frame + 1
        exit sub
    end if

    '' Hit: the flinch, standing, then the hunt.
    if ( ent.state = MDL_ST_PAIN% ) then
        ent.anim_frame = ent.anim_frame + 1
        if ( ent.anim_frame >= MDL_PAIN_FRAMES% ) then
            ent.state = MDL_ST_RUN%
            ent.anim_frame = 0
        end if
        exit sub
    end if

    if ( ent.state = MDL_ST_STAND% ) then
        if ( can_chase and mdl_find_target( g, ent, models(), brush(), planes() ) ) then
            ent.hunting = -1
            ent.state = MDL_ST_RUN%
            ent.anim_frame = 0
            ent.wander_ticks = 0
        elseif ( g.rdr.anim_time >= ent.stand_until ) then
            mdl_pick_goal ent
            ent.ideal_yaw = mdl_vectoyaw( ent.goal.x - ent.pos.x, ent.goal.y - ent.pos.y )
            ent.state = MDL_ST_RUN%
            ent.anim_frame = 0
            ent.wander_ticks = 0
        else
            ent.anim_frame = ( ent.anim_frame + 1 ) mod MDL_STAND_FRAMES%
        end if
        exit sub
    end if

    dist = mdl_run_dist( ent.anim_frame )
    if ( ent.hunting ) then
        '' SoldierCheckAttack: a clear line, attack_finished passed, and a
        '' chance by range each think; then army_fire and 1 + random().
        if ( g.rdr.anim_time >= ent.next_attack ) then
            if ( mdl_find_target( g, ent, models(), brush(), planes() ) ) then
                dx = g.pl.pos.x - ent.pos.x : dy = g.pl.pos.y - ent.pos.y
                d2 = dx*dx + dy*dy + ( g.pl.pos.z - ent.pos.z ) * ( g.pl.pos.z - ent.pos.z )
                if ( d2 < MDL_RANGE_MELEE# * MDL_RANGE_MELEE# ) then
                    chance = MDL_ATK_MELEE#
                elseif ( d2 < MDL_RANGE_NEAR# * MDL_RANGE_NEAR# ) then
                    chance = MDL_ATK_NEAR#
                elseif ( d2 < MDL_RANGE_MID# * MDL_RANGE_MID# ) then
                    chance = MDL_ATK_MID#
                else
                    chance = 0.0
                end if
                if ( rnd < chance ) then
                    ent.next_attack = g.rdr.anim_time + 1.0 + rnd
                    ent.flash_until = g.rdr.anim_time + MDL_FLASH#
                    mdl_fire g, ent, models(), brush(), planes()
                end if
            end if
        end if
        goal.x = g.pl.pos.x : goal.y = g.pl.pos.y : goal.z = g.pl.pos.z
    else
        goal.x = ent.goal.x : goal.y = ent.goal.y : goal.z = ent.goal.z
    end if
    mdl_move_to_goal g, ent, goal, dist, g.wld.count.models, models(), brush(), planes()
    ent.anim_frame = ( ent.anim_frame + 1 ) mod MDL_RUN_FRAMES%

    '' Own-goal wandering rests on arrival (or gives up after a timeout,
    '' the same compass search a real chase can also fail to route
    '' around) -- a real chase never does either, an enemy hunt is
    '' unconditional, which is exactly why this is gated on can_chase.
    if ( ent.hunting = 0 ) then
        ent.wander_ticks = ent.wander_ticks + 1
        dx = ent.pos.x - ent.goal.x : dy = ent.pos.y - ent.goal.y
        d2 = dx*dx + dy*dy
        if ( d2 < MDL_WANDER_ARRIVE#*MDL_WANDER_ARRIVE# or ent.wander_ticks >= MDL_WANDER_MAXTICKS% ) then
            ent.state = MDL_ST_STAND%
            ent.anim_frame = 0
            ent.stand_until = g.rdr.anim_time + MDL_STAND_MIN# + rnd * ( MDL_STAND_MAX# - MDL_STAND_MIN# )
        end if
    end if
end sub

''::::::::::::::
'' name: mdl_slab
'' desc: One axis of the ray-box test: narrows tn..tf to the slab lo..hi.
''       0 when the ray misses the slab outright.
''::::::::::::::
function mdl_slab ( _
    byval lo as single, _
    byval hi as single, _
    byval o as single, _
    byval d as single, _
    tn as single, _
    tf as single _
) as integer
    dim t0 as single, t1 as single

    mdl_slab = 0
    if ( abs( d ) < 0.0001 ) then
        if ( o < lo or o > hi ) then exit function
        mdl_slab = -1
        exit function
    end if
    t0 = ( lo - o ) / d
    t1 = ( hi - o ) / d
    if ( t0 > t1 ) then swap t0, t1
    if ( t0 > tn ) then tn = t0
    if ( t1 < tf ) then tf = t1
    mdl_slab = ( tn <= tf )
end function

''::::::::::::::
'' name: mdl_ray_box
'' desc: Where a ray from org along dir enters the soldier's box, in
''       units along dir, or -1 past maxt or missing. The box is the one
''       r_mdl_visible culls with.
''::::::::::::::
function mdl_ray_box ( _
    c as Vec3, _
    byval hx as single, _
    byval zlo as single, _
    byval zhi as single, _
    org as Vec3, _
    dir as Vec3, _
    byval maxt as single _
) as single
    dim tn as single, tf as single

    mdl_ray_box = -1.0
    tn = 0.0 : tf = maxt
    if ( mdl_slab( c.x - hx, c.x + hx, org.x, dir.x, tn, tf ) = 0 ) then exit function
    if ( mdl_slab( c.y - hx, c.y + hx, org.y, dir.y, tn, tf ) = 0 ) then exit function
    if ( mdl_slab( c.z + zlo, c.z + zhi, org.z, dir.z, tn, tf ) = 0 ) then exit function
    mdl_ray_box = tn
end function

''::::::::::::::
'' name: pl_spread_dir
'' desc: FireBullets' pellet: dir + crandom*spread*right + crandom*spread*up,
''       right and up built from dir and the world's up.
''::::::::::::::
sub pl_spread_dir ( _
    dir as Vec3, _
    byval spread as single, _
    outdir as Vec3 _
)
    dim rx as single, ry as single, rl as single
    dim ux as single, uy as single, uz as single
    dim a as single, b as single

    rx = dir.y : ry = -dir.x
    rl = sqr( rx*rx + ry*ry )
    if ( rl < 0.001 ) then rx = 1.0 : ry = 0.0 : rl = 1.0
    rx = rx / rl : ry = ry / rl
    '' up = right x dir
    ux = ry * dir.z
    uy = -rx * dir.z
    uz = rx * dir.y - ry * dir.x
    a = ( 2.0 * rnd - 1.0 ) * spread
    b = ( 2.0 * rnd - 1.0 ) * spread
    outdir.x = dir.x + a * rx + b * ux
    outdir.y = dir.y + a * ry + b * uy
    outdir.z = dir.z + b * uz
end sub

''::::::::::::::
'' name: pl_fire
'' desc: W_FireShotgun: six pellets of four, spread 0.04, each traced
''       through the world and then against every live soldier's box;
''       the damage lands per soldier once all six are in, as
''       ApplyMultiDamage does.
''::::::::::::::
sub pl_fire ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane, _
    item() as ItemEnt _
)
    dim org as Vec3, fin as Vec3, aim as Vec3, dir as Vec3
    dim tr as TraceResult
    dim i as integer, p as integer, best as integer
    dim t as single, bt as single
    dim hit( MDL_MAX_ENTS% - 1 ) as integer

    if ( g.rdr.anim_time < g.fight.next_fire ) then exit sub
    if ( g.fight.shells <= 0 ) then exit sub
    g.fight.next_fire = g.rdr.anim_time + PL_FIRE_RATE#
    g.fight.shells = g.fight.shells - 1
    g.fight.flash_until = g.rdr.anim_time + 0.1

    '' cam.look_at is the POINT the eye looks at by now -- a direction
    '' only inside v_update_camera -- one unit from cam.pos, in renderer
    '' space, Y up: BSP y is renderer z and BSP z is renderer y.
    aim.x = g.cam.look_at.x - g.cam.pos.x
    aim.y = g.cam.look_at.z - g.cam.pos.z
    aim.z = g.cam.look_at.y - g.cam.pos.y
    org.x = g.pl.pos.x : org.y = g.pl.pos.y : org.z = g.pl.pos.z + PL_EYE#

    for i = 0 to g.mdl_count - 1
        hit(i) = 0
    next i
    for p = 1 to PL_PELLETS%
        pl_spread_dir aim, PL_SPREAD#, dir
        fin.x = org.x + dir.x * PL_SHOT_RANGE#
        fin.y = org.y + dir.y * PL_SHOT_RANGE#
        fin.z = org.z + dir.z * PL_SHOT_RANGE#
        pl_trace org, fin, tr, g.wld.count.models, models(), brush(), clp_buffer(), planes()
        best = -1
        bt = PL_SHOT_RANGE# * tr.frac
        for i = 0 to g.mdl_count - 1
            if ( mdl_ent(i).state <> MDL_ST_DEAD% ) then
                t = mdl_ray_box( mdl_ent(i).pos, MDL_HALF#, MDL_ZLO#, MDL_ZHI#, org, dir, bt )
                if ( t >= 0.0 and t < bt ) then bt = t : best = i
            end if
        next i
        if ( best >= 0 ) then hit(best) = hit(best) + PL_PELLET_DMG%
    next p
    for i = 0 to g.mdl_count - 1
        if ( hit(i) > 0 ) then mdl_damage g, mdl_ent(i), hit(i), item()
    next i
end sub

''::::::::::::::
'' name: mdl_damage
'' desc: T_Damage on a soldier: army_die at 0 -- kills, the backpack --
''       or army_pain, gated by pain_finished, and the attacker is now
''       the enemy.
''::::::::::::::
sub mdl_damage ( _
    g as Game, _
    ent as MdlEnt, _
    byval dmg as integer, _
    item() as ItemEnt _
)
    ent.health = ent.health - dmg
    if ( ent.health <= 0 ) then
        ent.state = MDL_ST_DEAD%
        ent.anim_frame = 0
        g.fight.kills = g.fight.kills + 1
        pl_item_add g, item(), ENT_ITEM_SHELLS, ENT_BACKPACK%, ent.pos
        exit sub
    end if
    ent.hunting = -1
    ent.ideal_yaw = mdl_vectoyaw( g.pl.pos.x - ent.pos.x, g.pl.pos.y - ent.pos.y )
    if ( g.rdr.anim_time < ent.pain_finished ) then exit sub
    if ( rnd < MDL_PAIN_SHORT_P# ) then
        ent.pain_finished = g.rdr.anim_time + MDL_PAIN_SHORT#
    else
        ent.pain_finished = g.rdr.anim_time + MDL_PAIN_LONG#
    end if
    ent.state = MDL_ST_PAIN%
    ent.anim_frame = 0
end sub

''::::::::::::::
'' name: mdl_fire
'' desc: army_fire: four pellets of four, spread 0.1, aimed 0.2 s behind
''       the player's velocity, from the gun's height; each traced through
''       the world and then against the player's box.
''::::::::::::::
sub mdl_fire ( _
    g as Game, _
    ent as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim org as Vec3, fin as Vec3, aim as Vec3, dir as Vec3
    dim tr as TraceResult
    dim p as integer, dmg as integer
    dim l as single, t as single

    aim.x = g.pl.pos.x - g.pl.vel.x * MDL_AIM_LAG# - ent.pos.x
    aim.y = g.pl.pos.y - g.pl.vel.y * MDL_AIM_LAG# - ent.pos.y
    aim.z = g.pl.pos.z - g.pl.vel.z * MDL_AIM_LAG# - ent.pos.z
    l = sqr( aim.x*aim.x + aim.y*aim.y + aim.z*aim.z )
    if ( l < 1.0 ) then exit sub
    aim.x = aim.x / l : aim.y = aim.y / l : aim.z = aim.z / l
    org.x = ent.pos.x + aim.x * 10.0
    org.y = ent.pos.y + aim.y * 10.0
    org.z = ent.pos.z + MDL_ZLO# + ( MDL_ZHI# - MDL_ZLO# ) * 0.7

    dmg = 0
    for p = 1 to MDL_PELLETS%
        pl_spread_dir aim, MDL_SPREAD#, dir
        fin.x = org.x + dir.x * PL_SHOT_RANGE#
        fin.y = org.y + dir.y * PL_SHOT_RANGE#
        fin.z = org.z + dir.z * PL_SHOT_RANGE#
        pl_trace org, fin, tr, g.wld.count.models, models(), brush(), clp_buffer(), planes()
        t = mdl_ray_box( g.pl.pos, PL_HALF#, PL_ZLO#, PL_ZHI#, org, dir, PL_SHOT_RANGE# * tr.frac )
        if ( t >= 0.0 ) then dmg = dmg + MDL_PELLET_DMG%
    next p
    if ( dmg = 0 ) then exit sub
    g.fight.health = g.fight.health - dmg
    g.fight.hurt_until = g.rdr.anim_time + 0.3
    g.fight.dmg_pct = g.fight.dmg_pct + dmg * PL_DMG_SHIFT#
    if ( g.fight.dmg_pct > PL_DMG_SHIFT_MAX# ) then g.fight.dmg_pct = PL_DMG_SHIFT_MAX#
end sub

''::::::::::::::
'' name: pl_item_add
'' desc: A dropped pickup, in the slots after the map's own.
''::::::::::::::
sub pl_item_add ( _
    g as Game, _
    item() as ItemEnt, _
    byval kind as integer, _
    byval amount as integer, _
    org as Vec3 _
)
    if ( g.item_count > ubound( item ) ) then exit sub
    item( g.item_count ).kind = kind
    item( g.item_count ).amount = amount
    item( g.item_count ).pos = org
    item( g.item_count ).gone = 0
    g.item_count = g.item_count + 1
end sub

''::::::::::::::
'' name: pl_respawn
'' desc: Back at the spawn with everything the game started with.
''::::::::::::::
sub pl_respawn ( g as Game )
    g.fight.deaths = g.fight.deaths + 1
    pl_reset_player g
end sub

sub pl_reset_player ( g as Game )
    g.fight.health = PL_HEALTH%
    g.fight.shells = PL_SHELLS%
    g.fight.next_fire = 0.0
    g.pl.pos.x = g.fight.spawn.x : g.pl.pos.y = g.fight.spawn.y : g.pl.pos.z = g.fight.spawn.z
    g.pl.vel.x = 0.0 : g.pl.vel.y = 0.0 : g.pl.vel.z = 0.0
end sub

''::::::::::::::
'' name: pl_game_reset
'' desc: The fight again: every soldier back at its spawn, every pickup
''       back, the player at the start. Kills and deaths keep counting.
''::::::::::::::
sub pl_game_reset ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim i as integer
    dim org as Vec3

    for i = 0 to g.mdl_count - 1
        org = mdl_ent(i).spawn
        mdl_spawn g, mdl_ent(i), org, models(), brush(), planes()
    next i
    g.item_count = g.item_fixed
    for i = 0 to g.item_count - 1
        item(i).gone = 0
    next i
    pl_reset_player g
end sub

''::::::::::::::
'' name: pl_items_drop
'' desc: Quake's droptofloor: each item falls to the hull floor under it.
''::::::::::::::
sub pl_items_drop ( _
    g as Game, _
    item() as ItemEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
    dim i as integer
    dim fin as Vec3
    dim tr as TraceResult

    for i = 0 to g.item_count - 1
        fin = item(i).pos
        fin.z = fin.z - 256.0
        pl_trace item(i).pos, fin, tr, g.wld.count.models, models(), brush(), clp_buffer(), planes()
        if ( tr.frac < 1.0 and tr.all_solid = 0 ) then item(i).pos = tr.end_pos
    next i
end sub

''::::::::::::::
'' name: pl_items_touch
'' desc: Picks up whatever the player's box overlaps, and puts back what
''       megahealth rots. ammo_touch and T_Heal's caps.
''::::::::::::::
sub pl_items_touch ( g as Game, item() as ItemEnt )
    dim i as integer
    dim dz as single, cap as integer

    '' item_megahealth_rot: over 100, a point a second after five
    if ( g.fight.health > PL_HEALTH% and g.rdr.anim_time >= g.fight.rot_at ) then
        g.fight.health = g.fight.health - 1
        g.fight.rot_at = g.rdr.anim_time + 1.0
    end if

    for i = 0 to g.item_count - 1
        if ( item(i).gone = 0 ) then
            dz = g.pl.pos.z - item(i).pos.z
            if ( abs( g.pl.pos.x - item(i).pos.x ) < ENT_ITEM_REACH# and _
                 abs( g.pl.pos.y - item(i).pos.y ) < ENT_ITEM_REACH# and _
                 dz > -ENT_ITEM_TOP# - PL_FEET# and dz < ENT_ITEM_TOP# + PL_FEET# ) then
                if ( item(i).kind = ENT_ITEM_SHELLS ) then
                    '' ammo_touch: refused at the cap, capped after
                    if ( g.fight.shells < PL_SHELLS_MAX% ) then
                        g.fight.shells = g.fight.shells + item(i).amount
                        if ( g.fight.shells > PL_SHELLS_MAX% ) then g.fight.shells = PL_SHELLS_MAX%
                        item(i).gone = -1
                    end if
                else
                    '' T_Heal: the mega one ignores the 100 cap and stops at 250
                    cap = PL_HEALTH%
                    if ( item(i).amount = ENT_ITEM_MEGA% ) then cap = PL_HEALTH_MEGA%
                    if ( g.fight.health < cap ) then
                        g.fight.health = g.fight.health + item(i).amount
                        if ( g.fight.health > cap ) then g.fight.health = cap
                        if ( g.fight.health > PL_HEALTH% ) then g.fight.rot_at = g.rdr.anim_time + PL_ROT_DELAY#
                        item(i).gone = -1
                    end if
                end if
                if ( item(i).gone ) then g.fight.bonus_pct = PL_BONUS_SHIFT#
            end if
        end if
    next i
end sub
