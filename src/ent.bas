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
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'

''
'' Destinations, held only while the entity lump is being read: a trigger may
'' name a destination that appears later in the text, so the links cannot be
'' resolved in one pass.
''
'$static
dim shared dest_name( ENT_MAXTELE ) as string * 32
dim shared dest_org( ENT_MAXTELE ) as Vec3
dim shared dest_yaw( ENT_MAXTELE ) as single
dim shared dest_count as integer

dim shared trig_target( ENT_MAXTELE ) as string * 32
dim shared trig_model( ENT_MAXTELE ) as integer
dim shared trig_count as integer
'$dynamic




''::::::::::
'' name: ent_value
'' desc: The value following key in a tokenised entity block, or "" if absent.
''::::::::::
function ent_value ( _
    strm() as string, _
    byval strm_cnt as integer, _
    kname as string _
) as string
    dim j as integer

    ent_value = ""

    for  j = 0 to strm_cnt-2
        if ( strm(j) = kname ) then
            ent_value = strm(j+1)
            exit function
        end if
    next j

end function




''::::::::::
'' name: ent_vec
'' desc: The three numbers following kname. An entity value like
''       "448 416 176" arrives already split, because space is one of the
''       separators the block was tokenised with.
''::::::::::
sub ent_vec ( _
    strm() as string, _
    byval strm_cnt as integer, _
    kname as string, _
    v as Vec3 _
)
    dim j as integer

    v.x = 0.0
    v.y = 0.0
    v.z = 0.0

    for  j = 0 to strm_cnt-4
        if ( strm(j) = kname ) then
            v.x = val( strm(j+1) )
            v.y = val( strm(j+2) )
            v.z = val( strm(j+3) )
            exit sub
        end if
    next j

end sub




''::::::::::
'' name: ent_load_teleports
'' desc: Reads the entity lump and pairs every trigger_teleport with the
''       destination it targets.
''
''       Must run while the map file is still open, so before mod_close.
''::::::::::
sub ent_load_teleports ( _
    wld as MapState, _
    models() as Submodel _
)
    dim entity as string
    dim strm(50) as string
    dim strm_cnt as integer
    dim ch as string, blk as string
    dim inblk as integer, fchar as integer
    dim i as integer, j as integer, k as integer
    dim s as string
    dim mdlnum as integer

    redim tele( ENT_MAXTELE ) as Teleporter
    redim brush( 63 ) as BrushModel
    redim face_mdl( wld.tri_count ) as integer
    redim plat( ENT_MAXTELE ) as PlatEnt

    tele_count = 0
    dest_count = 0
    trig_count = 0

    plat_count = 0

    '' every submodel draws and blocks unless something claims it as a trigger
    for  i = 0 to 63
        brush(i).draw  = true
        brush(i).solid = true
        brush(i).zofs  = 0.0
    next i

    ''
    '' Which submodel owns each face. The world's faces come first and the
    '' submodels' follow in order, so this is a walk rather than a search.
    ''
    for  i = 0 to wld.tri_count-1
        face_mdl(i) = 0
    next i

    for  j = 1 to wld.mdl_count-1
        for  k = models(j).firstface to models(j).firstface + models(j).numfaces - 1
            if ( k >= 0 and k <= wld.tri_count-1 ) then face_mdl(k) = j
        next k
    next j

    entity$ = space$( wld.head.entities.size )
    seek #wld.file, wld.head.entities.offs+1
    get #wld.file,, entity$

    ''
    '' Walk the text a block at a time, the same way mod_find_spawn does.
    ''
    for  i = 1 to len( entity$ )
        ch$ = mid$( entity$, i, 1 )

        if ( ch$ = "{" ) then
            inblk = 1
            fchar = i
        end if

        if ( ch$ = "}" and inblk = 1 ) then
            blk$ = mid$( entity$, fchar, i-fchar+1 )
            com_tokenize strm(), strm_cnt, " {}"+chr$(34)+chr$(10)+chr$(13), blk$

            s$ = ent_value( strm(), strm_cnt, "classname" )

            if ( s$ = "info_teleport_destination" and dest_count < ENT_MAXTELE ) then
                dest_name( dest_count ) = ent_value( strm(), strm_cnt, "targetname" )

                ''
                '' Space is one of the block separators, so "448 416 176"
                '' is already three tokens by the time we get here and the
                '' value of "origin" is just the first of them. Read all
                '' three, which is what mod_find_spawn does.
                ''
                ent_vec strm(), strm_cnt, "origin", dest_org( dest_count )

                dest_yaw( dest_count ) = val( ent_value( strm(), strm_cnt, "angle" ) )

                dest_count = dest_count + 1

            elseif ( s$ = "func_plat" and plat_count < ENT_MAXTELE ) then
                s$ = ent_value( strm(), strm_cnt, "model" )
                if ( left$( s$, 1 ) = "*" ) then
                    mdlnum = val( mid$( s$, 2 ) )

                    if ( mdlnum > 0 and mdlnum <= wld.mdl_count-1 ) then
                        plat( plat_count ).model  = mdlnum
                        plat( plat_count ).speed  = val( ent_value( strm(), strm_cnt, "speed" ) )
                        plat( plat_count ).travel = val( ent_value( strm(), strm_cnt, "height" ) )
                        plat( plat_count ).mins   = models(mdlnum).mins
                        plat( plat_count ).maxs   = models(mdlnum).maxs

                        if ( plat( plat_count ).speed  <= 0.0 ) then plat( plat_count ).speed  = 150.0
                        if ( plat( plat_count ).travel <= 0.0 ) then _
                            plat( plat_count ).travel = models(mdlnum).maxs.z - models(mdlnum).mins.z

                        '' Quake positions the brush raised, so a lift at rest
                        '' is one full travel below where the map drew it.
                        plat( plat_count ).state = ENT_PLAT_DOWN
                        brush( mdlnum ).zofs = -plat( plat_count ).travel

                        plat_count = plat_count + 1
                    end if
                end if

            elseif ( s$ = "trigger_teleport" and trig_count < ENT_MAXTELE ) then
                trig_target( trig_count ) = ent_value( strm(), strm_cnt, "target" )

                ''
                '' "model" "*1" -- the star is not decoration, it says the
                '' number is a submodel rather than a file name.
                ''
                s$ = ent_value( strm(), strm_cnt, "model" )
                if ( left$( s$, 1 ) = "*" ) then
                    trig_model( trig_count ) = val( mid$( s$, 2 ) )
                    brush( trig_model( trig_count ) ).draw  = false
                    brush( trig_model( trig_count ) ).solid = false
                    trig_count = trig_count + 1
                end if
            end if

            inblk = 0
        end if
    next i

    ''
    '' Second pass: match each trigger's target to a destination's targetname.
    '' A trigger whose destination is missing is dropped rather than kept as a
    '' hole that teleports the player to the origin.
    ''
    for  j = 0 to trig_count-1
        for  k = 0 to dest_count-1
            if ( rtrim$(trig_target(j)) = rtrim$(dest_name(k)) ) then
                mdlnum = trig_model(j)

                if ( mdlnum > 0 and mdlnum <= wld.mdl_count-1 ) then
                    tele( tele_count ).mins = models(mdlnum).mins
                    tele( tele_count ).maxs = models(mdlnum).maxs
                    tele( tele_count ).dest = dest_org(k)
                    tele( tele_count ).yaw  = dest_yaw(k)
                    tele_count = tele_count + 1
                end if

                exit for
            end if
        next k
    next j

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
    pl as PlayerState, _
    env as Env _
)
    dim i as integer
    dim pmin as Vec3, pmax as Vec3

    if ( pl.noclip ) then exit sub

    pmin.x = pl.pos.x - 16.0
    pmin.y = pl.pos.y - 16.0
    pmin.z = pl.pos.z - PL_FEET#
    pmax.x = pl.pos.x + 16.0
    pmax.y = pl.pos.y + 16.0
    pmax.z = pl.pos.z + 32.0

    for  i = 0 to tele_count-1
        if ( pmax.x >= tele(i).mins.x and pmin.x <= tele(i).maxs.x and _
             pmax.y >= tele(i).mins.y and pmin.y <= tele(i).maxs.y and _
             pmax.z >= tele(i).mins.z and pmin.z <= tele(i).maxs.z ) then

            pl.pos   = tele(i).dest
            pl.vel.x = 0.0
            pl.vel.y = 0.0
            pl.vel.z = 0.0

            ''
            '' Face the way the destination says. The camera reads its angle
            '' from the mouse, so the mouse is what has to move -- the same
            '' trick host_main uses to apply the spawn angle.
            ''
            mousePos (env.x_res-1) * tele(i).yaw/360.0, 110

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
    byval p as integer, _
    pl as PlayerState _
) as integer
    dim top as single

    ent_plat_touched = false

    if ( pl.pos.x + 16.0 < plat(p).mins.x ) then exit function
    if ( pl.pos.x - 16.0 > plat(p).maxs.x ) then exit function
    if ( pl.pos.y + 16.0 < plat(p).mins.y ) then exit function
    if ( pl.pos.y - 16.0 > plat(p).maxs.y ) then exit function

    ''
    '' Above its surface and within a body's height of it. Anything higher is
    '' someone on a walkway over the shaft, not a passenger.
    ''
    top = plat(p).maxs.z + brush( plat(p).model ).zofs

    if ( pl.pos.z - PL_FEET# < top - 8.0  ) then exit function
    if ( pl.pos.z - PL_FEET# > top + 64.0 ) then exit function

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
    byval dt as single, _
    pl as PlayerState _
)
    dim p as integer
    dim m as integer
    dim goal as single, step_z as single, moved as single, was as single
    dim riding as integer

    for  p = 0 to plat_count-1
        m = plat(p).model

        riding = ent_plat_touched( p, pl )

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
            pl.pos.z = pl.pos.z + moved
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
    byval nmodels as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane _
)
    dim m as integer

    for  m = 1 to nmodels-1
        brush(m).node = ent_find_node( m, models(), nodes(), planes() )
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
    planes() as Plane _
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
        pid = nodes(nodenr).planeid

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
