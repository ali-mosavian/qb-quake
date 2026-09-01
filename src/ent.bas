option explicit
''
'' ent.bas -- entities. Currently just teleporters, which are the first thing
''            in this engine that is neither geometry nor the player.
''
''            A trigger_teleport carries a brush model rather than an origin:
''            "model" "*1" means submodel 1, whose bounding box mdl_buffer
''            already holds. Its "target" names an info_teleport_destination,
''            which carries the origin and facing to arrive at.
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
declare function ent_find_node ( _
    byval m as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
) as integer
declare function ent_point_leaf ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
declare function ent_plat_touched ( _
    g as Game, _
    byval p as integer, _
    brush() as BrushModel, _
    plat() as PlatEnt _
) as integer

''
'' This module's own procedures.
''
declare function ent_open_bin ( _
    g as Game, _
    h as EntsHead _
) as integer
declare sub ent_load_spawn ( _
    g as Game _
)
declare sub ent_load_teleports ( _
    g as Game, _
    models() as Submodel, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    face_mdl() as integer, _
    plat() as PlatEnt _
)
declare sub ent_check_teleport ( _
    g as Game, _
    tele() as Teleporter _
)
declare sub ent_move_plats ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    plat() as PlatEnt _
)
declare sub ent_place_models ( _
    byval model_count as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
)





''::::::::::
'' name: ent_open_bin
'' desc: Opens ents.bin for GET and validates it against this map. A BASIC
''       binary OPEN creates the file it fails to find, so a bad one is
''       KILLed before erroring rather than left to poison the next run.
''::::::::::
function ent_open_bin ( _
    g as Game, _
    h as EntsHead _
) as integer
    dim f as integer

    f = freefile
    open "ents.bin" for binary as #f
    if ( lof(f) < len(h) ) then
        close #f
        kill "ents.bin"
        sys_error "0x0043, ents.bin missing or short"
    end if
    get #f, , h
    if ( h.nmodels <> g.wld.count.models ) then
        close #f
        sys_error "0x0045, ents.bin is from another map"
    end if
    ent_open_bin = f
end function




''::::::::::
'' name: ent_load_spawn
'' desc: The spawn point, from ents.bin -- the entities text resolved by
''       mkassets. The text itself never reaches the target: BASIC strings
''       cap at 32,767 bytes and e1m3's entities lump is 45,762.
''::::::::::
sub ent_load_spawn ( _
    g as Game _
)
    dim f as integer
    dim h as EntsHead

    f = ent_open_bin( g, h )
    close #f

    '' BSP is Z-up and the camera is Y-up, so y and z swap here
    g.cam.pos.x = h.spawn.x
    g.cam.pos.z = h.spawn.y
    g.cam.pos.y = h.spawn.z
    g.cam.start_angle = h.angle

    scr_load_step

end sub




''::::::::::
'' name: ent_load_teleports
'' desc: Loads ents.bin -- teleporter pairs already matched by targetname,
''       plats and hidden submodels already validated, all by mkassets.
''       What stays here is what needs the loaded submodels: trigger
''       volumes and plat defaults come from models(), which mkassets has
''       no reason to duplicate.
''::::::::::
sub ent_load_teleports ( _
    g as Game, _
    models() as Submodel, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    face_mdl() as integer, _
    plat() as PlatEnt _
)
    dim f as integer
    dim h as EntsHead
    dim tr as EntsTele
    dim pr as EntsPlat
    dim i as integer, j as integer, k as integer
    dim mdlnum as integer

    f = ent_open_bin( g, h )

    '' Sized to the map, not a fixed 64: e1m3 has 106 submodels, and
    '' ent_place_models and pl_trace walk every one of them.
    redim brush( g.wld.count.models-1 ) as BrushModel
    redim face_mdl( g.wld.count.faces ) as integer
    redim tele( h.ntele ) as Teleporter
    redim plat( h.nplat ) as PlatEnt

    g.tele_count = 0
    g.plat_count = 0

    '' every submodel draws and blocks unless something claims it as a trigger
    for  i = 0 to g.wld.count.models-1
        brush(i).draw  = true
        brush(i).solid = true
        brush(i).zofs  = 0.0
    next i

    ''
    '' Which submodel owns each face. The world's faces come first and the
    '' submodels' follow in order, so this is a walk rather than a search.
    ''
    for  i = 0 to g.wld.count.faces-1
        face_mdl(i) = 0
    next i

    for  j = 1 to g.wld.count.models-1
        for  k = models(j).first_face to models(j).first_face + models(j).num_faces - 1
            if ( k >= 0 and k <= g.wld.count.faces-1 ) then face_mdl(k) = j
        next k
    next j

    for  i = 1 to h.ntele
        get #f, , tr
        mdlnum = tr.model
        if ( mdlnum > 0 and mdlnum <= g.wld.count.models-1 ) then
            tele( g.tele_count ).mins = models(mdlnum).mins
            tele( g.tele_count ).maxs = models(mdlnum).maxs
            tele( g.tele_count ).dest = tr.dest
            '' the arrival point is above the mapper's mark --
            '' see PL_TELE_LIFT#
            tele( g.tele_count ).dest.z = _
                tele( g.tele_count ).dest.z + PL_TELE_LIFT#
            tele( g.tele_count ).yaw  = tr.yaw
            g.tele_count = g.tele_count + 1
        end if
    next i

    for  i = 1 to h.nplat
        get #f, , pr
        mdlnum = pr.model
        if ( mdlnum > 0 and mdlnum <= g.wld.count.models-1 ) then
            plat( g.plat_count ).model  = mdlnum
            plat( g.plat_count ).speed  = pr.speed
            plat( g.plat_count ).travel = pr.travel
            plat( g.plat_count ).mins   = models(mdlnum).mins
            plat( g.plat_count ).maxs   = models(mdlnum).maxs

            if ( plat( g.plat_count ).speed  <= 0.0 ) then plat( g.plat_count ).speed  = 150.0
            if ( plat( g.plat_count ).travel <= 0.0 ) then _
                plat( g.plat_count ).travel = models(mdlnum).maxs.z - models(mdlnum).mins.z

            '' Quake positions the brush raised, so a lift at rest
            '' is one full travel below where the map drew it.
            plat( g.plat_count ).state = ENT_PLAT_DOWN
            brush( mdlnum ).zofs = -plat( g.plat_count ).travel

            g.plat_count = g.plat_count + 1
        end if
    next i

    for  i = 1 to h.nhide
        get #f, , mdlnum
        if ( mdlnum > 0 and mdlnum <= g.wld.count.models-1 ) then
            brush( mdlnum ).draw  = false
            brush( mdlnum ).solid = false
        end if
    next i

    close #f

end sub




''::::::::::
'' name: ent_check_teleport
'' desc: Moves the player if their box overlaps a teleporter's.
''
''       Box against box, not point against box: a trigger is often thinner
''       than the player, and testing the origin alone lets a fast enough
''       player pass through one without ever having their centre inside it.
''::::::::::
sub ent_check_teleport ( _
    g as Game, _
    tele() as Teleporter _
)
    dim i as integer
    dim pmin as Vec3, pmax as Vec3

    if ( g.pl.no_clip ) then exit sub

    pmin.x = g.pl.pos.x - 16.0
    pmin.y = g.pl.pos.y - 16.0
    pmin.z = g.pl.pos.z - PL_FEET#
    pmax.x = g.pl.pos.x + 16.0
    pmax.y = g.pl.pos.y + 16.0
    pmax.z = g.pl.pos.z + 32.0

    for  i = 0 to g.tele_count-1
        if ( pmax.x >= tele(i).mins.x and pmin.x <= tele(i).maxs.x and _
             pmax.y >= tele(i).mins.y and pmin.y <= tele(i).maxs.y and _
             pmax.z >= tele(i).mins.z and pmin.z <= tele(i).maxs.z ) then

            g.pl.pos   = tele(i).dest
            g.pl.vel.x = 0.0
            g.pl.vel.y = 0.0
            g.pl.vel.z = 0.0

            ''
            '' Face the way the destination says. The camera reads its angle
            '' from the mouse, so the mouse is what has to move -- the same
            '' trick host_main uses to apply the spawn angle.
            ''
            mousePos (g.env.scr_x_res-1) * tele(i).yaw/360.0, 110

            exit sub
        end if
    next i

end sub



''::::::::::
'' name: ent_plat_touched
'' desc: True when the player is standing on a plat, or in the column above
''       it. Quake builds a trigger brush around the plat for this; the box is
''       close enough and needs nothing from the compiler.
''::::::::::
function ent_plat_touched ( _
    g as Game, _
    byval p as integer, _
    brush() as BrushModel, _
    plat() as PlatEnt _
) as integer
    dim top as single

    ent_plat_touched = false

    if ( g.pl.pos.x + 16.0 < plat(p).mins.x ) then exit function
    if ( g.pl.pos.x - 16.0 > plat(p).maxs.x ) then exit function
    if ( g.pl.pos.y + 16.0 < plat(p).mins.y ) then exit function
    if ( g.pl.pos.y - 16.0 > plat(p).maxs.y ) then exit function

    ''
    '' Above its surface and within a body's height of it. Anything higher is
    '' someone on a walkway over the shaft, not a passenger.
    ''
    top = plat(p).maxs.z + brush( plat(p).model ).zofs

    if ( g.pl.pos.z - PL_FEET# < top - 8.0  ) then exit function
    if ( g.pl.pos.z - PL_FEET# > top + 64.0 ) then exit function

    ent_plat_touched = true

end function




''::::::::::
'' name: ent_move_plats
'' desc: Drives every func_plat, and carries whoever is riding one.
''
''       A plat rises while the player is on it and returns when they leave,
''       which is Quake's behaviour without the delay and the sounds.
''
''       The rider is moved by the same delta the plat moved. Quake does this
''       properly in SV_PushMove, which re-traces everything the mover touches
''       and telefrags what it cannot push; this carries the one entity that
''       exists.
''::::::::::
sub ent_move_plats ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    plat() as PlatEnt _
)
    dim p as integer
    dim m as integer
    dim goal as single, step_z as single, moved as single, was as single
    dim riding as integer

    for  p = 0 to g.plat_count-1
        m = plat(p).model

        riding = ent_plat_touched ( g, p, brush(), plat() )

        if ( riding ) then
            plat(p).state = ENT_PLAT_UP
        else
            plat(p).state = ENT_PLAT_DOWN
        end if

        if ( plat(p).state = ENT_PLAT_UP ) then
            goal = 0.0
        else
            goal = -plat(p).travel
        end if

        was = brush(m).zofs

        if ( brush(m).zofs < goal ) then
            step_z = plat(p).speed * dt
            brush(m).zofs = brush(m).zofs + step_z
            if ( brush(m).zofs > goal ) then brush(m).zofs = goal
        elseif ( brush(m).zofs > goal ) then
            step_z = plat(p).speed * dt
            brush(m).zofs = brush(m).zofs - step_z
            if ( brush(m).zofs < goal ) then brush(m).zofs = goal
        end if

        moved = brush(m).zofs - was

        ''
        '' Carry the rider. Only upward: a descending plat drops out from under
        '' the player and gravity does the rest, which is what it looks like in
        '' Quake. Pushing them down would shove them through the floor of the
        '' shaft on the last step of the descent.
        ''
        if ( riding and moved > 0.0 ) then
            g.pl.pos.z = g.pl.pos.z + moved
        end if
    next p

end sub



''::::::::::
'' name: ent_point_leaf
'' desc: The world leaf a point falls in. The same descent as
''       pl_point_contents, stopping one step earlier: that wants what is at
''       the point, this wants where the point is.
''::::::::::
function ent_point_leaf ( _
    p as Vec3, _
    nodes() as Node, _
    planes() as Plane _
) as integer
    ent_point_leaf = r_point_leaf( p, nodes(), planes() )
end function




''::::::::::
'' name: ent_place_models
'' desc: Works out where in the world's back-to-front order each submodel
''       belongs, once per frame, and leaves the answer in mdl_node.
''
''       Two earlier answers were wrong in instructive ways. Recording the leaf
''       a sample point falls in fails because that leaf is often solid -- a
''       lowered lift sits inside its own shaft -- and a solid leaf is never
''       walked. Drawing at the first visible leaf the box overlaps fails
''       because the walk reaches leaves in depth order, so "first" means
''       "furthest", and everything the entity should hide gets drawn after it.
''::::::::::
sub ent_place_models ( _
    byval model_count as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
)
    dim m as integer

    for  m = 1 to model_count-1
        brush(m).node = ent_find_node( m, models(), nodes(), planes(), brush() )
    next m

end sub



''::::::::::
'' name: ent_find_node
'' desc: The deepest world node whose plane submodel m's box does not straddle.
''
''       That node is where the entity belongs in the painter's order: every
''       world face beyond it is drawn before the walk arrives, every face
''       nearer is drawn after, and the entity goes in between. Descending
''       stops as soon as a plane cuts the box, because past that point the
''       entity is on both sides at once and no single position is right.
''
''       Returns a leaf, bit 15 set, when the box fits inside one.
''::::::::::
function ent_find_node ( _
    byval m as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
) as integer
    dim mp as long
    dim nodenr as integer, pid as integer
    dim dnear as single, dfar as single
    dim x0 as single, x1 as single
    dim y0 as single, y1 as single
    dim z0 as single, z1 as single

    x0 = models(m).mins.x
    x1 = models(m).maxs.x
    y0 = models(m).mins.y
    y1 = models(m).maxs.y
    z0 = models(m).mins.z + brush(m).zofs
    z1 = models(m).maxs.z + brush(m).zofs

    nodenr = 0

    do while ( (nodenr and &h8000) = 0 )
        pid = nodes(nodenr).plane_id

        ''
        '' The box corner furthest along the normal and the one furthest
        '' against it. If both land on the same side of the plane, so does
        '' every other corner.
        ''
        if ( planes(pid).norm.x >= 0.0 ) then
            dnear = planes(pid).norm.x * x0
            dfar  = planes(pid).norm.x * x1
        else
            dnear = planes(pid).norm.x * x1
            dfar  = planes(pid).norm.x * x0
        end if

        if ( planes(pid).norm.y >= 0.0 ) then
            dnear = dnear + planes(pid).norm.y * y0
            dfar  = dfar  + planes(pid).norm.y * y1
        else
            dnear = dnear + planes(pid).norm.y * y1
            dfar  = dfar  + planes(pid).norm.y * y0
        end if

        if ( planes(pid).norm.z >= 0.0 ) then
            dnear = dnear + planes(pid).norm.z * z0
            dfar  = dfar  + planes(pid).norm.z * z1
        else
            dnear = dnear + planes(pid).norm.z * z1
            dfar  = dfar  + planes(pid).norm.z * z0
        end if

        dnear = dnear - planes(pid).dist
        dfar  = dfar  - planes(pid).dist

        if ( dnear >= 0.0 ) then
            nodenr = nodes(nodenr).child0
        elseif ( dfar < 0.0 ) then
            nodenr = nodes(nodenr).child1
        else
            exit do
        end if
    loop

    ent_find_node = nodenr

end function
