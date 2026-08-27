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
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'

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
dim shared h_clp as long



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
function pl_hull_contents ( _
    byval node as integer, _
    p as Vec3, _
    clip() as ClipNode, _
    planes() as Plane _
) as integer
    dim mc as long
    dim d as single
    dim pid as integer

    do while ( node >= 0 )
        pid = clip(node).plane_num

        d = p.x*planes(pid).norm.x + _
            p.y*planes(pid).norm.y + _
            p.z*planes(pid).norm.z - planes(pid).dist

        if ( d >= 0.0 ) then
            node = clip(node).front
        else
            node = clip(node).back
        end if
    loop

    pl_hull_contents = node

end function




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
    pl as PlayerState, _
    nodes() as Node, _
    planes() as Plane _
)
    dim p as Vec3
    dim c as integer

    pl.water_level = 0
    pl.water_type  = CONTENTS_EMPTY

    p = pl.pos
    p.z = pl.pos.z - PL_FEET# + 1.0
    c = pl_point_contents( p, nodes(), planes() )

    if ( c > CONTENTS_WATER ) then exit sub          '' EMPTY or SOLID: dry

    pl.water_type  = c
    pl.water_level = 1

    p.z = pl.pos.z
    if ( pl_point_contents( p, nodes(), planes() ) <= CONTENTS_WATER ) then
        pl.water_level = 2

        p.z = pl.pos.z + PL_EYE#
        if ( pl_point_contents( p, nodes(), planes() ) <= CONTENTS_WATER ) then pl.water_level = 3
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
function pl_hull_check ( _
    byval node as integer, _
    byval p1f as single, _
    byval p2f as single, _
    p1 as Vec3, _
    p2 as Vec3, _
    tr as TraceResult, _
    clip() as ClipNode, _
    planes() as Plane _
) as integer
    dim pid as integer
    dim t1 as single, t2 as single
    dim frac as single, midf as single
    dim midp as Vec3
    dim side as integer, other as integer
    dim mc as long

    ''
    '' A leaf: solid stops the sweep, anything else lets it through.
    ''
    if ( node < 0 ) then
        if ( node = CONTENTS_SOLID ) then
            tr.all_solid = true
        else
            tr.all_solid = false
        end if
        pl_hull_check = true
        exit function
    end if

    pid = clip(node).plane_num
    t1 = p1.x*planes(pid).norm.x + p1.y*planes(pid).norm.y + _
         p1.z*planes(pid).norm.z - planes(pid).dist
    t2 = p2.x*planes(pid).norm.x + p2.y*planes(pid).norm.y + _
         p2.z*planes(pid).norm.z - planes(pid).dist

    '' wholly on one side: recurse into that child alone
    if ( t1 >= 0.0 and t2 >= 0.0 ) then
        pl_hull_check = pl_hull_check( clip(node).front, p1f, p2f, p1, p2, tr, clip(), planes() )
        exit function
    end if
    if ( t1 < 0.0 and t2 < 0.0 ) then
        pl_hull_check = pl_hull_check( clip(node).back, p1f, p2f, p1, p2, tr, clip(), planes() )
        exit function
    end if

    ''
    '' Straddles the plane. Split at the crossing, backing off by an epsilon so
    '' the near half stops just short of the surface rather than exactly on it.
    ''
    if ( t1 < 0.0 ) then
        frac = (t1 + PL_CLIP_EPS#) / (t1 - t2)
        side = 1
    else
        frac = (t1 - PL_CLIP_EPS#) / (t1 - t2)
        side = 0
    end if

    if ( frac < 0.0 ) then frac = 0.0
    if ( frac > 1.0 ) then frac = 1.0

    midf  = p1f + (p2f - p1f) * frac
    midp.x = p1.x + (p2.x - p1.x) * frac
    midp.y = p1.y + (p2.y - p1.y) * frac
    midp.z = p1.z + (p2.z - p1.z) * frac

    '' the near half first: an earlier hit wins
    if ( side = 0 ) then
        if ( pl_hull_check( clip(node).front, p1f, midf, p1, midp, tr, clip(), planes() ) = false ) then
            pl_hull_check = false
            exit function
        end if
        '' the recursion above moved the window; map before reading again
        other = clip(node).back
    else
        if ( pl_hull_check( clip(node).back, p1f, midf, p1, midp, tr, clip(), planes() ) = false ) then
            pl_hull_check = false
            exit function
        end if
        other = clip(node).front
    end if

    '' far half is open: carry on through it
    if ( pl_hull_contents( other, midp, clip(), planes() ) <> CONTENTS_SOLID ) then
        pl_hull_check = pl_hull_check( other, midf, p2f, midp, p2, tr, clip(), planes() )
        exit function
    end if

    '' far half is solid: this plane is the impact
    if ( tr.all_solid ) then
        tr.start_solid = true
        pl_hull_check  = false
        exit function
    end if

    if ( tr.frac > midf ) then
        tr.frac    = midf
        tr.end_pos = midp

        if ( side = 1 ) then
            tr.norm.x = -planes(pid).norm.x
            tr.norm.y = -planes(pid).norm.y
            tr.norm.z = -planes(pid).norm.z
        else
            tr.norm.x = planes(pid).norm.x
            tr.norm.y = planes(pid).norm.y
            tr.norm.z = planes(pid).norm.z
        end if
    end if

    pl_hull_check = false

end function




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
sub pl_trace ( _
    start as Vec3, _
    fin as Vec3, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
    dim dummy as integer
    dim i as integer
    dim any_solid as integer
    dim s2 as Vec3, f2 as Vec3

    tr.frac        = 1.0
    tr.end_pos     = fin
    tr.norm.x      = 0.0
    tr.norm.y      = 0.0
    tr.norm.z      = 0.0
    tr.start_solid = false

    tr.all_solid = true
    dummy = pl_hull_check( int( models(0).head_node1 ), 0.0, 1.0, start, fin, tr, clip(), planes() )
    any_solid = tr.all_solid

    for  i = 1 to model_count-1
        if ( brush(i).solid ) then
            s2 = start
            f2 = fin
            s2.z = s2.z - brush(i).zofs
            f2.z = f2.z - brush(i).zofs

            tr.all_solid = true
            dummy = pl_hull_check( int( models(i).head_node1 ), 0.0, 1.0, s2, f2, tr, clip(), planes() )
            if ( tr.all_solid ) then any_solid = true
        end if
    next i

    tr.all_solid = any_solid

    if ( tr.frac < 1.0 ) then
        tr.end_pos.x = start.x + (fin.x - start.x) * tr.frac
        tr.end_pos.y = start.y + (fin.y - start.y) * tr.frac
        tr.end_pos.z = start.z + (fin.z - start.z) * tr.frac
    end if

end sub




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
    org as Vec3, _
    vel as Vec3, _
    byval dt as single, _
    pl as PlayerState, _
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
    if ( pl.on_ground = false and pl.water_level < 2 ) then
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
''::::::::::
sub pl_gravity ( _
    byval dt as single, _
    pl as PlayerState, _
    tr as TraceResult, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    clip() as ClipNode, _
    planes() as Plane _
)
    dim below as Vec3
    dim speed as single

    below   = pl.pos
    below.z = below.z - 1.0

    pl_trace pl.pos, below, tr, model_count, models(), brush(), clip(), planes()

    ''
    '' Swimming: no ground, and a slow sink instead of a fall. Checked before
    '' the ground test because a floor underwater should not stop you
    '' floating -- otherwise the player walks along the bottom of a pool.
    ''
    if ( pl.water_level >= 2 ) then
        pl.on_ground = false
        pl.vel.z = pl.vel.z - PL_WATERSINK#*dt
        exit sub
    end if

    if ( tr.frac < 1.0 and tr.norm.z > PL_GROUND_NRM# ) then
        pl.on_ground = true
        if ( pl.vel.z < 0.0 ) then pl.vel.z = 0.0
    else
        pl.on_ground = false
        pl.vel.z = pl.vel.z - PL_FALLACC#*dt
    end if

    speed = sqr( pl.vel.x*pl.vel.x + pl.vel.y*pl.vel.y + pl.vel.z*pl.vel.z )
    if ( speed > PL_MAXVEL# ) then
        pl.vel.x = pl.vel.x * (PL_MAXVEL#/speed)
        pl.vel.y = pl.vel.y * (PL_MAXVEL#/speed)
        pl.vel.z = pl.vel.z * (PL_MAXVEL#/speed)
    end if

end sub




''::::::::::
'' name: pl_init
'' desc: Seeds the player from the spawn point the map gave the camera.
''       cam.pos is Y-up; pl.pos is Z-up; the eye sits PL_EYE# above the hull
''       origin, so the spawn height has to come down by that much.
''::::::::::
sub pl_init ( _
    pl as PlayerState, _
    cam as CamState, _
    env as Env _
)
    if ( env.start_set ) then
        pl.pos.x = env.start_x
        pl.pos.y = env.start_y
        pl.pos.z = env.start_z
    else
        pl.pos.x = cam.pos.x
        pl.pos.y = cam.pos.z
        pl.pos.z = cam.pos.y - PL_EYE#
    end if

    pl.vel.x = 0.0
    pl.vel.y = 0.0
    pl.vel.z = 0.0

    pl.on_ground = false

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
    byval fwd as single, _
    byval strafe as single, _
    byval dir_x as single, _
    byval dir_y as single, _
    byval jump as integer, _
    byval dt as single, _
    pl as PlayerState, _
    cam as CamState, _
    byval model_count as integer, _
    models() as Submodel, _
    brush() as BrushModel, _
    nodes() as Node, _
    planes() as Plane _
)
    dim speed as single, drop as single, newspeed as single
    dim tr as TraceResult

    ''
    '' dir is the horizontal look direction in BSP space, passed in rather than
    '' read from cam.look_at: that vector is a direction for part of
    '' v_update_camera and an absolute point for the rest, and depending on
    '' which half of the routine called us would be a trap.
    ''
    pl.vel.x = pl.vel.x + (dir_x*fwd - dir_y*strafe) * PL_ACCEL# * dt
    pl.vel.y = pl.vel.y + (dir_y*fwd + dir_x*strafe) * PL_ACCEL# * dt

    '' water drags in all three axes, ground friction only horizontally
    if ( pl.water_level >= 3 ) then
        '' full drag only when fully under. At the surface the vertical
        '' component is left alone so a jump out is not damped away.
        speed = sqr( pl.vel.x*pl.vel.x + pl.vel.y*pl.vel.y + pl.vel.z*pl.vel.z )
        if ( speed > 0.0 ) then
            newspeed = speed - speed*PL_WATERFRIC#*dt
            if ( newspeed < 0.0 ) then newspeed = 0.0
            pl.vel.x = pl.vel.x * (newspeed/speed)
            pl.vel.y = pl.vel.y * (newspeed/speed)
            pl.vel.z = pl.vel.z * (newspeed/speed)
        end if
    end if

    '' ground friction, horizontal only
    if ( pl.on_ground ) then
        speed = sqr( pl.vel.x*pl.vel.x + pl.vel.y*pl.vel.y )
        if ( speed > 0.0 ) then
            drop     = speed * PL_FRICTION# * dt
            newspeed = speed - drop
            if ( newspeed < 0.0 ) then newspeed = 0.0
            pl.vel.x = pl.vel.x * (newspeed/speed)
            pl.vel.y = pl.vel.y * (newspeed/speed)
        end if
    end if

    '' and a ceiling on how fast walking can get
    speed = sqr( pl.vel.x*pl.vel.x + pl.vel.y*pl.vel.y )
    if ( pl.water_level >= 2 ) then
        if ( speed > PL_WATERSPEED# ) then
            pl.vel.x = pl.vel.x * (PL_WATERSPEED#/speed)
            pl.vel.y = pl.vel.y * (PL_WATERSPEED#/speed)
        end if
    elseif ( speed > PL_MAXSPEED# ) then
        pl.vel.x = pl.vel.x * (PL_MAXSPEED#/speed)
        pl.vel.y = pl.vel.y * (PL_MAXSPEED#/speed)
    end if

    pl_water_level pl, nodes(), planes()

    pl_gravity dt, pl, tr, model_count, models(), brush(), clp_buffer(), planes()

    ''
    '' Jump. Only from the ground, and after pl_gravity, which is what
    '' decides whether there is any ground -- doing it before would read
    '' last frame's answer and allow a second jump in mid-air.
    ''
    '' The velocity is set rather than added, so holding the key gives one
    '' jump of a fixed height instead of accumulating thrust.
    ''
    if ( pl.water_level >= 3 ) then
        ''
        '' Fully under: the jump key swims, every tick rather than only
        '' from a surface.
        ''
        if ( jump ) then pl.vel.z = PL_SWIM#

    elseif ( pl.water_level = 2 ) then
        ''
        '' Head out, body in -- at the surface. Swim speed is not enough to
        '' leave the water here: the moment the waist clears it gravity
        '' comes back, and 100 up against 800 down is a six unit hop, which
        '' clears nothing. A jump from the surface is a real jump.
        ''
        if ( jump ) then pl.vel.z = PL_JUMP#

    elseif ( jump and pl.on_ground ) then
        pl.vel.z     = PL_JUMP#
        pl.on_ground = false
    end if

    pl_step_move pl.pos, pl.vel, dt, pl, tr, model_count, models(), brush(), clp_buffer(), planes()

    if ( pl.pos.z > pl.peak_z ) then pl.peak_z = pl.pos.z

    ''
    '' Hand the eye back to the renderer, converting Z-up to Y-up. This is the
    '' only place the two spaces meet.
    ''
    cam.pos.x = pl.pos.x
    cam.pos.y = pl.pos.z + PL_EYE#
    cam.pos.z = pl.pos.y

end sub


''::::::::::
'' name: pl_load_hulls
'' desc: Builds the clip-hull store and binds it. Called by the map loader,
''       which passes the count and nothing else -- it does not need to
''       know where the hulls live.
''::::::::::
sub pl_load_hulls ( byval cnt as long )
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
    h_clp = uglArrNew&( UGL.MEM, len( clp_buffer(0) ), cnt, 0 )
    if ( h_clp = 0 ) then
        h_clp = uglArrNew&( UGL.EMS, len( clp_buffer(0) ), cnt, PAGE_SLOT )
    end if
    if ( h_clp = 0 ) then sys_error "0x0033, no room for the clip hulls"

    '' Hands the descriptor over. NOT ceremony: this is what takes it out
    '' of the far heap's chain, and only BASIC can do that correctly. Left
    '' in, B$FHCompact walks into a descriptor aimed at memory it does not
    '' own and moves it -- the far heap is then corrupt. The variable still
    '' exists afterwards, which is what uglArrMap binds to.
    erase clp_buffer

    if ( fileOpen%( f, "clip.pag", F4READ ) = 0 ) then
        sys_error "0x0034, clip.pag missing"
    end if
    if ( uglArrLoad%( f, h_clp ) = 0 ) then
        fileClose f
        sys_error "0x0035, clip.pag short or unreadable"
    end if
    fileClose f

    ''
    '' ONE map, for the whole array. A MEM store is flat, so this points
    '' the descriptor at the entire block and every subscript works from
    '' here on with no further calls.
    ''
    mapped = uglArrMap&( h_clp, clp_buffer(), 0 )
end sub

'' Clipnode record size, for the bench report.
function pl_hull_rec ( ) as integer
    pl_hull_rec = len( clp_buffer(0) )
end function
