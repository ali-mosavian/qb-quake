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

declare sub qglMousePos ( byval x as integer, byval y as integer )

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
'' The file layer, qgl's: a plain name or "archive::member", one handle
'' either way. mgl's uar wanted a UAR the caller declared only to pass
'' back.
''
'' flname is NOT byval: VBDOS passes a plain "as string" parameter as a
'' near pointer to its descriptor, which is what the assembly's s:word
'' wants.
''
declare function qglFileOpenBas ( flname as string ) as integer
declare function qglFileRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglFileClose ( byval h as integer )

''
'' This module's own procedures.
''
declare sub ent_get ( _
    byval u as integer, _
    byval dst as long, _
    byval n as integer _
)
declare sub ent_open_bin ( _
    g as Game, _
    u as integer, _
    h as EntsHead _
)
declare sub ent_load_spawn ( _
    g as Game _
)
declare sub ent_load_teleports ( _
    g as Game, _
    models() as Submodel, _
    brush() as BrushModel, _
    tele() as Teleporter, _
    faces() as Face, _
    plat() as PlatEnt, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt _
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
declare sub ent_move_doors ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt _
)
declare sub ent_door_init ( _
    g as Game, _
    dr as EntsDoor, _
    models() as Submodel, _
    brush() as BrushModel, _
    door() as DoorEnt _
)
declare sub ent_link_doors ( _
    g as Game, _
    door() as DoorEnt _
)
declare sub ent_door_fire ( _
    g as Game, _
    byval grp as integer, _
    door() as DoorEnt _
)
declare function ent_door_touched ( _
    g as Game, _
    d as DoorEnt _
) as integer
declare function ent_door_step ( _
    p as Vec3, _
    goal as Vec3, _
    byval by as single _
) as integer
declare sub ent_trig_init ( _
    g as Game, _
    xr as EntsTrig, _
    models() as Submodel, _
    trig() as TrigEnt _
)
declare sub ent_use_targets ( _
    g as Game, _
    byval id as integer, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
declare sub ent_kill_targets ( _
    g as Game, _
    byval id as integer, _
    trig() as TrigEnt _
)
declare sub ent_trig_fire ( _
    g as Game, _
    byval k as integer, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
declare sub ent_move_trigs ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
declare sub ent_reset ( _
    g as Game, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
declare sub ent_say ( _
    g as Game, _
    msg as string _
)
declare sub ent_talk ( _
    g as Game, _
    msg as string _
)
declare sub ent_door_sound ( _
    g as Game, _
    d as DoorEnt, _
    byval leg as integer _
)
declare function ent_box_touched ( _
    g as Game, _
    mins as Vec3, _
    maxs as Vec3, _
    byval slack as single _
) as integer
declare sub mdl_spawn ( _
    g as Game, _
    ent as MdlEnt, _
    org as Vec3, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
)
declare function ent_load_monsters ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
declare sub ent_place_models ( _
    byval model_count as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
)





''::::::::::
'' name: ent_get
'' desc: One record out of the open member, or die: sequential GETs are
''       all ents.bin ever needed.
''::::::::::
sub ent_get ( _
    byval u as integer, _
    byval dst as long, _
    byval n as integer _
)
    if ( qglFileRead( u, dst, clng(n) ) <> clng(n) ) then
        sys_error "0x0043, ents.bin short read"
    end if
end sub


''::::::::::
'' name: ent_open_bin
'' desc: Opens the ents.bin member and validates it against this map.
''::::::::::
sub ent_open_bin ( _
    g as Game, _
    u as integer, _
    h as EntsHead _
)
    u = qglFileOpenBas( "assets.zip::ents.bin" )
    if ( u = 0 ) then
        sys_error "0x0043, ents.bin missing"
    end if
    ent_get u, clng( varseg( h ) ) * 65536& + (clng( varptr( h ) ) and 65535&), len( h )
    if ( h.nmodels <> g.wld.count.models ) then
        qglFileClose u
        sys_error "0x0045, ents.bin is from another map"
    end if
end sub




''::::::::::
'' name: ent_load_spawn
'' desc: The spawn point, from ents.bin -- the entities text resolved by
''       mkassets. The text itself never reaches the target: BASIC strings
''       cap at 32,767 bytes and e1m3's entities lump is 45,762.
''::::::::::
sub ent_load_spawn ( _
    g as Game _
)
    dim u as integer
    dim h as EntsHead

    ent_open_bin g, u, h
    qglFileClose u

    '' BSP is Z-up and the camera is Y-up, so y and z swap here
    g.cam.pos.x = h.spawn.x
    g.cam.pos.z = h.spawn.y
    g.cam.pos.y = h.spawn.z
    '' the map's angle runs CCW from +x; -yaw runs the other way, so
    '' angle 90, +y, is our 270
    g.cam.start_angle = 360.0 - h.angle
    if ( g.cam.start_angle >= 360.0 ) then g.cam.start_angle = g.cam.start_angle - 360.0

    scr_load_step

end sub




''::::::::::
'' name: ent_load_monsters
'' desc: Spawns the map's monsters where it put them, facing its angle;
''       how many, or 0 on a map with none (dm3ish), and host_init then
''       scatters its own crowd.
''::::::::::
function ent_load_monsters ( _
    g as Game, _
    mdl_ent() as MdlEnt, _
    models() as Submodel, _
    brush() as BrushModel, _
    planes() as Plane _
) as integer
    dim u as integer
    dim h as EntsHead
    dim mr as EntsMon
    dim i as integer, n as integer

    ent_open_bin g, u, h
    n = 0
    for  i = 1 to h.nmon
        ent_get u, clng( varseg( mr ) ) * 65536& + (clng( varptr( mr ) ) and 65535&), len( mr )
        if ( n < MDL_MAX_ENTS% ) then
            mdl_ent( n ).kind = mr.kind
            if ( mr.kind = MDL_KIND_KNIGHT% and g.kmdl.loaded = 0 ) then mdl_ent( n ).kind = MDL_KIND_ARMY%
            if ( mr.kind = MDL_KIND_DOG% and g.dmdl.loaded = 0 ) then mdl_ent( n ).kind = MDL_KIND_ARMY%
            mdl_spawn g, mdl_ent( n ), mr.org, models(), brush(), planes()
            mdl_ent( n ).yaw = mr.angle
            mdl_ent( n ).ideal_yaw = mr.angle
            n = n + 1
        end if
    next i
    qglFileClose u
    ent_load_monsters = n
end function


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
    faces() as Face, _
    plat() as PlatEnt, _
    item() as ItemEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
    dim u as integer
    dim h as EntsHead
    dim tr as EntsTele
    dim ir as EntsItem
    dim pr as EntsPlat
    dim dr as EntsDoor
    dim xr as EntsTrig
    dim mr as EntsMon
    dim ar as EntsAmb
    dim i as integer, j as integer, k as integer
    dim mdlnum as integer

    ent_open_bin g, u, h
    '' the monsters come first, for ent_load_monsters
    for  i = 1 to h.nmon
        ent_get u, clng( varseg( mr ) ) * 65536& + (clng( varptr( mr ) ) and 65535&), len( mr )
    next i

    '' Sized to the map, not a fixed 64: e1m3 has 106 submodels, and
    '' ent_place_models and pl_trace walk every one of them.
    redim brush( g.wld.count.models-1 ) as BrushModel
    redim tele( h.ntele ) as Teleporter
    redim plat( h.nplat ) as PlatEnt
    redim door( h.ndoor ) as DoorEnt
    redim trig( h.ntrig ) as TrigEnt
    '' room after the map's items for one backpack a soldier
    redim item( h.nitem + MDL_MAX_ENTS% ) as ItemEnt

    g.tele_count = 0
    g.plat_count = 0
    g.door_count = 0
    g.trig_count = 0
    g.item_count = 0

    '' every submodel draws and blocks unless something claims it as a trigger
    for  i = 0 to g.wld.count.models-1
        brush(i).draw  = true
        brush(i).solid = true
        brush(i).ofs.x = 0.0
        brush(i).ofs.y = 0.0
        brush(i).ofs.z = 0.0
    next i

    ''
    '' Which submodel owns each face, in the bits above Face.side's one:
    '' a table of its own cost 11K on e1m1. The world's faces come first
    '' and the submodels' follow in order, so this is a walk, not a search.
    ''
    for  j = 1 to g.wld.count.models-1
        for  k = models(j).first_face to models(j).first_face + models(j).num_faces - 1
            if ( k >= 0 and k <= g.wld.count.faces-1 ) then
                faces(k).side = ( faces(k).side and 1 ) or ( j * 2 )
            end if
        next k
    next j

    for  i = 1 to h.ntele
        ent_get u, clng( varseg( tr ) ) * 65536& + (clng( varptr( tr ) ) and 65535&), len( tr )
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
        ent_get u, clng( varseg( pr ) ) * 65536& + (clng( varptr( pr ) ) and 65535&), len( pr )
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
            brush( mdlnum ).ofs.z = -plat( g.plat_count ).travel

            g.plat_count = g.plat_count + 1
        end if
    next i

    for  i = 1 to h.nhide
        ent_get u, clng( varseg( mdlnum ) ) * 65536& + (clng( varptr( mdlnum ) ) and 65535&), len( mdlnum )
        if ( mdlnum > 0 and mdlnum <= g.wld.count.models-1 ) then
            brush( mdlnum ).draw  = false
            brush( mdlnum ).solid = false
        end if
    next i

    for  i = 1 to h.nitem
        ent_get u, clng( varseg( ir ) ) * 65536& + (clng( varptr( ir ) ) and 65535&), len( ir )
        item( g.item_count ).kind = ir.kind
        item( g.item_count ).amount = ir.amount
        item( g.item_count ).pos  = ir.org
        item( g.item_count ).gone = 0
        g.item_count = g.item_count + 1
    next i
    g.item_fixed = g.item_count

    for  i = 1 to h.ndoor
        ent_get u, clng( varseg( dr ) ) * 65536& + (clng( varptr( dr ) ) and 65535&), len( dr )
        if ( dr.model > 0 and dr.model <= g.wld.count.models-1 ) then
            ent_door_init g, dr, models(), brush(), door()
        end if
    next i
    ent_link_doors g, door()

    for  i = 1 to h.ntrig
        ent_get u, clng( varseg( xr ) ) * 65536& + (clng( varptr( xr ) ) and 65535&), len( xr )
        if ( xr.model >= 0 and xr.model <= g.wld.count.models-1 ) then
            ent_trig_init g, xr, models(), trig()
        end if
    next i

    for  i = 1 to h.namb
        ent_get u, clng( varseg( ar ) ) * 65536& + (clng( varptr( ar ) ) and 65535&), len( ar )
        snd_ambient g, ar.snd, ar.vol, ar.org
    next i

    qglFileClose u

end sub


sub ent_door_init ( _
    g as Game, _
    dr as EntsDoor, _
    models() as Submodel, _
    brush() as BrushModel, _
    door() as DoorEnt _
)
    dim k as integer, m as integer
    dim d as DoorEnt
    dim fx as single, fz as single

    '' Filled in a local and stored whole. BC miscompiles the first single
    '' stored into a member of an indexed element after another store to
    '' it: the element offset is cached in ax, the value is loaded into
    '' ax:dx, and the member offset is added to ax -- so the value lands at
    '' base + low word of itself. 400.0 has a low word of 0, and every
    '' door's speed went into door(0). Listing: ent.obj.lst, ENT_DOOR_INIT.
    k = g.door_count
    m = dr.model
    d.model     = m
    d.speed     = dr.speed
    d.hold      = dr.hold
    d.hold_left = 0.0
    d.nolink    = dr.nolink
    d.targeted  = dr.targeted
    d.secret    = dr.secret
    d.shoot     = dr.shoot
    d.snd       = dr.snd
    d.ofs_mid   = dr.mid
    d.pause_left = 0.0
    d.msg       = dr.msg
    d.state     = ENT_DOOR_SHUT
    d.link      = k

    '' DOOR_START_OPEN: lit shut, spawned at the far end of its travel
    d.ofs_shut.x = 0.0
    d.ofs_shut.y = 0.0
    d.ofs_shut.z = 0.0
    d.ofs_open = dr.travel
    if ( dr.start_open ) then
        d.ofs_shut = dr.travel
        d.ofs_open.x = 0.0
        d.ofs_open.y = 0.0
        d.ofs_open.z = 0.0
    end if
    brush(m).ofs = d.ofs_shut

    '' spawn_field: the brush's box where it sits, grown 60 in x and y, 8
    '' in z. A targeted or secret door has no field; touching the brush
    '' itself says its message (door_touch, secret_touch)
    fx = ENT_DOOR_FIELD# : fz = ENT_DOOR_FIELDZ#
    if ( d.targeted or d.secret ) then fx = ENT_TOUCH_SLACK# : fz = ENT_TOUCH_SLACK#
    d.mins.x = models(m).mins.x + d.ofs_shut.x - fx
    d.mins.y = models(m).mins.y + d.ofs_shut.y - fx
    d.mins.z = models(m).mins.z + d.ofs_shut.z - fz
    d.maxs.x = models(m).maxs.x + d.ofs_shut.x + fx
    d.maxs.y = models(m).maxs.y + d.ofs_shut.y + fx
    d.maxs.z = models(m).maxs.z + d.ofs_shut.z + fz

    door(k) = d
    g.door_count = g.door_count + 1
end sub


'' LinkDoors: doors whose brushes touch open as one, unless DOOR_DONT_LINK.
'' The fields are the brushes grown by the field margin, so shrink them
'' back for the touch test.
sub ent_link_doors ( _
    g as Game, _
    door() as DoorEnt _
)
    dim i as integer, j as integer, k as integer, was as integer
    dim touch as integer

    for  i = 0 to g.door_count-1
        for  j = i+1 to g.door_count-1
            touch = ( door(i).nolink = 0 and door(j).nolink = 0 )
            if ( door(i).mins.x + ENT_DOOR_FIELD#  > door(j).maxs.x - ENT_DOOR_FIELD#  ) then touch = false
            if ( door(i).mins.y + ENT_DOOR_FIELD#  > door(j).maxs.y - ENT_DOOR_FIELD#  ) then touch = false
            if ( door(i).mins.z + ENT_DOOR_FIELDZ# > door(j).maxs.z - ENT_DOOR_FIELDZ# ) then touch = false
            if ( door(i).maxs.x - ENT_DOOR_FIELD#  < door(j).mins.x + ENT_DOOR_FIELD#  ) then touch = false
            if ( door(i).maxs.y - ENT_DOOR_FIELD#  < door(j).mins.y + ENT_DOOR_FIELD#  ) then touch = false
            if ( door(i).maxs.z - ENT_DOOR_FIELDZ# < door(j).mins.z + ENT_DOOR_FIELDZ# ) then touch = false
            if ( touch ) then
                was = door(j).link
                for  k = 0 to g.door_count-1
                    if ( door(k).link = was ) then door(k).link = door(i).link
                next k
            end if
        next j
    next i
end sub


'' door_trigger_touch: the player's box against the field. Quake's box is
'' 16 either side and runs from 24 below the origin to 32 above it.
function ent_door_touched ( _
    g as Game, _
    d as DoorEnt _
) as integer
    ent_door_touched = ent_box_touched( g, d.mins, d.maxs, 0.0 )
end function


'' The player's box against one grown by slack.
function ent_box_touched ( _
    g as Game, _
    mins as Vec3, _
    maxs as Vec3, _
    byval slack as single _
) as integer
    ent_box_touched = false
    if ( g.pl.pos.x + PL_HALF# + slack < mins.x ) then exit function
    if ( g.pl.pos.x - PL_HALF# - slack > maxs.x ) then exit function
    if ( g.pl.pos.y + PL_HALF# + slack < mins.y ) then exit function
    if ( g.pl.pos.y - PL_HALF# - slack > maxs.y ) then exit function
    if ( g.pl.pos.z + PL_ZHI# + slack < mins.z ) then exit function
    if ( g.pl.pos.z + PL_ZLO# - slack > maxs.z ) then exit function
    ent_box_touched = true
end function


'' door_go_up for a whole linked group: a shut or closing door sets out,
'' an open one restarts its hold.
sub ent_door_fire ( _
    g as Game, _
    byval grp as integer, _
    door() as DoorEnt _
)
    dim k as integer

    for  k = 0 to g.door_count-1
        if ( door(k).link = grp ) then
            if ( door(k).secret ) then
                '' fd_secret_use: nothing while it is anywhere but home
                if ( door(k).state = ENT_DOOR_SHUT ) then
                    door(k).state = ENT_DOOR_OUT1
                    ent_door_sound g, door(k), 2
                end if
            else
                select case door(k).state
                    case ENT_DOOR_SHUT, ENT_DOOR_CLOSING
                        door(k).state = ENT_DOOR_OPENING
                        ent_door_sound g, door(k), 1
                    case ENT_DOOR_OPEN
                        door(k).hold_left = door(k).hold
                end select
            end if
        end if
    next k
end sub


'' Moves p toward goal by at most `by`; true once it is there.
function ent_door_step ( _
    p as Vec3, _
    goal as Vec3, _
    byval by as single _
) as integer
    dim dx as single, dy as single, dz as single, d as single

    dx = goal.x - p.x
    dy = goal.y - p.y
    dz = goal.z - p.z
    d = sqr( dx*dx + dy*dy + dz*dz )
    ent_door_step = false
    if ( d <= by ) then
        p = goal
        ent_door_step = true
        exit function
    end if
    p.x = p.x + dx * ( by / d )
    p.y = p.y + dy * ( by / d )
    p.z = p.z + dz * ( by / d )
end function


''::::::::::
'' name: ent_move_doors
'' desc: The touch fields, then every door's state machine. A door with a
''       targetname waits for ent_use_targets, and says its message
''       when touched.
''::::::::::
sub ent_move_doors ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt _
)
    dim k as integer, m as integer

    for  k = 0 to g.door_count-1
        if ( ent_door_touched( g, door(k) ) ) then
            if ( door(k).targeted = 0 and door(k).secret = 0 ) then
                ent_door_fire g, door(k).link, door()
            else
                ent_talk g, door(k).msg
            end if
        end if
    next k

    for  k = 0 to g.door_count-1
        m = door(k).model
        select case door(k).state
            case ENT_DOOR_OPENING
                if ( ent_door_step( brush(m).ofs, door(k).ofs_open, door(k).speed * dt ) ) then
                    door(k).state = ENT_DOOR_OPEN
                    door(k).hold_left = door(k).hold
                    ent_door_sound g, door(k), 0
                end if
            case ENT_DOOR_OPEN
                if ( door(k).hold >= 0.0 ) then
                    door(k).hold_left = door(k).hold_left - dt
                    if ( door(k).hold_left <= 0.0 ) then
                        door(k).state = ENT_DOOR_CLOSING
                        ent_door_sound g, door(k), 1
                    end if
                end if
            case ENT_DOOR_CLOSING
                if ( door(k).secret ) then
                    if ( ent_door_step( brush(m).ofs, door(k).ofs_mid, door(k).speed * dt ) ) then
                        door(k).state = ENT_DOOR_PAUSE_BACK
                        door(k).pause_left = ENT_DOOR_PAUSE#
                    end if
                elseif ( ent_door_step( brush(m).ofs, door(k).ofs_shut, door(k).speed * dt ) ) then
                    door(k).state = ENT_DOOR_SHUT
                    ent_door_sound g, door(k), 0
                end if
            case ENT_DOOR_OUT1
                if ( ent_door_step( brush(m).ofs, door(k).ofs_mid, door(k).speed * dt ) ) then
                    door(k).state = ENT_DOOR_PAUSE_OUT
                    door(k).pause_left = ENT_DOOR_PAUSE#
                end if
            case ENT_DOOR_PAUSE_OUT
                door(k).pause_left = door(k).pause_left - dt
                if ( door(k).pause_left <= 0.0 ) then
                    door(k).state = ENT_DOOR_OPENING
                    ent_door_sound g, door(k), 1
                end if
            case ENT_DOOR_PAUSE_BACK
                door(k).pause_left = door(k).pause_left - dt
                if ( door(k).pause_left <= 0.0 ) then
                    door(k).state = ENT_DOOR_BACK2
                    ent_door_sound g, door(k), 1
                end if
            case ENT_DOOR_BACK2
                if ( ent_door_step( brush(m).ofs, door(k).ofs_shut, door(k).speed * dt ) ) then
                    door(k).state = ENT_DOOR_SHUT
                    ent_door_sound g, door(k), 0
                end if
        end select
    next k
end sub




sub ent_trig_init ( _
    g as Game, _
    xr as EntsTrig, _
    models() as Submodel, _
    trig() as TrigEnt _
)
    dim t as TrigEnt
    dim m as integer

    '' a local, stored whole: see ent_door_init
    m = xr.model
    t.model     = m
    t.kind      = xr.kind
    t.target    = xr.target
    t.name      = xr.name
    t.kill      = xr.kill
    t.state     = ENT_TRIG_READY
    t.left      = xr.count
    t.count     = xr.count
    t.wait      = xr.wait
    t.wait_left = 0.0
    t.speed     = xr.speed
    t.snd       = xr.snd
    t.ofs_out   = xr.travel
    t.mins      = models(m).mins
    t.maxs      = models(m).maxs
    t.msg       = xr.msg
    trig( g.trig_count ) = t
    g.trig_count = g.trig_count + 1
end sub


'' pl_game_reset's half of the world: every door shut, every trigger and
'' button as the map loaded.
sub ent_reset ( _
    g as Game, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
    dim k as integer
    dim home as Vec3

    for  k = 0 to g.door_count-1
        door(k).state = ENT_DOOR_SHUT
        door(k).hold_left = 0.0
        door(k).pause_left = 0.0
        brush( door(k).model ).ofs = door(k).ofs_shut
    next k
    for  k = 0 to g.trig_count-1
        trig(k).state = ENT_TRIG_READY
        trig(k).left = trig(k).count
        trig(k).wait_left = 0.0
        if ( trig(k).kind = ENT_TRIG_BUTTON ) then brush( trig(k).model ).ofs = home
    next k
    g.fight.msg_until = 0.0
end sub


'' centerprint: shown for ENT_MSG_TIME
sub ent_say ( _
    g as Game, _
    msg as string _
)
    if ( len( rtrim$( msg ) ) = 0 ) then exit sub
    g.fight.msg = msg
    g.fight.msg_until = g.rdr.anim_time + ENT_MSG_TIME#
end sub

'' SUB_UseTargets and door_touch: the message, and misc/talk with it
sub ent_talk ( _
    g as Game, _
    msg as string _
)
    if ( len( rtrim$( msg ) ) = 0 ) then exit sub
    ent_say g, msg
    snd_play g, SND_TALK%, g.pl.pos
end sub

'' leg 0: the stop (a secret door's noise3), 1: a move (noise2),
'' 2: a secret door leaving home (noise1). sounds 0 is a silent door.
sub ent_door_sound ( _
    g as Game, _
    d as DoorEnt, _
    byval leg as integer _
)
    dim id as integer

    if ( d.snd <= 0 ) then exit sub
    if ( d.secret ) then
        id = SND_SECRET1% + ( d.snd - 1 ) * 3 + ( 2 - leg )
    else
        id = SND_DOOR% + ( d.snd - 1 ) * 2 + leg
    end if
    snd_play g, id, d.mins
end sub


'' SUB_UseTargets: every door and trigger named id.
sub ent_use_targets ( _
    g as Game, _
    byval id as integer, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
    dim k as integer

    if ( id = 0 ) then exit sub
    for  k = 0 to g.door_count-1
        if ( door(k).targeted = id ) then ent_door_fire g, door(k).link, door()
    next k
    for  k = 0 to g.trig_count-1
        if ( trig(k).name = id ) then
            select case trig(k).kind
                case ENT_TRIG_COUNTER
                    if ( trig(k).state <> ENT_TRIG_DONE ) then
                        trig(k).left = trig(k).left - 1
                        if ( trig(k).left <= 0 ) then ent_trig_fire g, k, door(), trig()
                    end if
                case ENT_TRIG_ONCE, ENT_TRIG_MULTI
                    if ( trig(k).state = ENT_TRIG_READY ) then ent_trig_fire g, k, door(), trig()
            end select
        end if
    next k
end sub


'' multi_trigger: the message, then the targets; once and counters are
'' done, a multiple re-arms after wait.
sub ent_trig_fire ( _
    g as Game, _
    byval k as integer, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
    if ( trig(k).kind = ENT_TRIG_SECRET ) then g.fight.secrets = g.fight.secrets + 1
    if ( trig(k).snd = 1 ) then
        ent_say g, trig(k).msg
        snd_play g, SND_SECRET%, g.pl.pos
    else
        ent_talk g, trig(k).msg
    end if
    if ( trig(k).kind = ENT_TRIG_COUNTER or trig(k).wait < 0.0 ) then
        trig(k).state = ENT_TRIG_DONE
    else
        trig(k).state = ENT_TRIG_HELD
        trig(k).wait_left = trig(k).wait
    end if
    ent_kill_targets g, trig(k).kill, trig()
    ent_use_targets g, trig(k).target, door(), trig()
end sub

''::::::::::
'' name: ent_kill_targets
'' desc: SUB_UseTargets' remove(): every trigger named id is gone until
''       the level restarts. A door or a monster by that name stays --
''       e1m1 kills only its two hint triggers.
''::::::::::
sub ent_kill_targets ( _
    g as Game, _
    byval id as integer, _
    trig() as TrigEnt _
)
    dim k as integer

    if ( id = 0 ) then exit sub
    for  k = 0 to g.trig_count-1
        if ( trig(k).name = id ) then trig(k).state = ENT_TRIG_DONE
    next k
end sub


''::::::::::
'' name: ent_move_trigs
'' desc: The touches, and every button's travel. A button fires when it
''       arrives, not when it is pressed, as button_wait does.
''::::::::::
sub ent_move_trigs ( _
    g as Game, _
    byval dt as single, _
    brush() as BrushModel, _
    door() as DoorEnt, _
    trig() as TrigEnt _
)
    dim k as integer, m as integer
    dim home as Vec3

    for  k = 0 to g.trig_count-1
        m = trig(k).model
        select case trig(k).kind
            case ENT_TRIG_BUTTON
                select case trig(k).state
                    case ENT_TRIG_READY
                        if ( ent_box_touched( g, trig(k).mins, trig(k).maxs, ENT_TOUCH_SLACK# ) ) then
                            trig(k).state = ENT_TRIG_GOING
                            snd_play g, SND_BUTTON% + trig(k).snd, trig(k).mins
                        end if
                    case ENT_TRIG_GOING
                        if ( ent_door_step( brush(m).ofs, trig(k).ofs_out, trig(k).speed * dt ) ) then
                            trig(k).state = ENT_TRIG_HELD
                            trig(k).wait_left = trig(k).wait
                            ent_talk g, trig(k).msg
                            ent_use_targets g, trig(k).target, door(), trig()
                        end if
                    case ENT_TRIG_HELD
                        if ( trig(k).wait >= 0.0 ) then
                            trig(k).wait_left = trig(k).wait_left - dt
                            if ( trig(k).wait_left <= 0.0 ) then trig(k).state = ENT_TRIG_BACK
                        end if
                    case ENT_TRIG_BACK
                        '' button_blocked, without the push: wait for the player to step off
                        if ( ent_box_touched( g, trig(k).mins, trig(k).maxs, 0.0 ) = 0 ) then
                            if ( ent_door_step( brush(m).ofs, home, trig(k).speed * dt ) ) then
                                trig(k).state = ENT_TRIG_READY
                            end if
                        end if
                end select
            case ENT_TRIG_EXIT
                if ( trig(k).state = ENT_TRIG_READY ) then
                    if ( ent_box_touched( g, trig(k).mins, trig(k).maxs, 0.0 ) ) then
                        '' the intermission: the map's title stays up
                        ent_say g, trig(k).msg
                        g.fight.msg_until = g.rdr.anim_time + 3600.0
                        g.fight.state = GS_EXIT%
                        trig(k).state = ENT_TRIG_DONE
                    end if
                end if
            case ENT_TRIG_ONCE, ENT_TRIG_MULTI, ENT_TRIG_SHOOT, ENT_TRIG_SECRET
                select case trig(k).state
                    case ENT_TRIG_READY
                        if ( trig(k).kind <> ENT_TRIG_SHOOT ) then
                            if ( ent_box_touched( g, trig(k).mins, trig(k).maxs, 0.0 ) ) then
                                ent_trig_fire g, k, door(), trig()
                            end if
                        end if
                    case ENT_TRIG_HELD
                        trig(k).wait_left = trig(k).wait_left - dt
                        if ( trig(k).wait_left <= 0.0 ) then trig(k).state = ENT_TRIG_READY
                end select
        end select
    next k
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
            qglMousePos (g.env.scr_x_res-1) * tele(i).yaw/360.0, 110

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
    top = plat(p).maxs.z + brush( plat(p).model ).ofs.z

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

        was = brush(m).ofs.z

        if ( brush(m).ofs.z < goal ) then
            step_z = plat(p).speed * dt
            brush(m).ofs.z = brush(m).ofs.z + step_z
            if ( brush(m).ofs.z > goal ) then brush(m).ofs.z = goal
        elseif ( brush(m).ofs.z > goal ) then
            step_z = plat(p).speed * dt
            brush(m).ofs.z = brush(m).ofs.z - step_z
            if ( brush(m).ofs.z < goal ) then brush(m).ofs.z = goal
        end if

        moved = brush(m).ofs.z - was

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

    x0 = models(m).mins.x + brush(m).ofs.x
    x1 = models(m).maxs.x + brush(m).ofs.x
    y0 = models(m).mins.y + brush(m).ofs.y
    y1 = models(m).maxs.y + brush(m).ofs.y
    z0 = models(m).mins.z + brush(m).ofs.z
    z1 = models(m).maxs.z + brush(m).ofs.z

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
