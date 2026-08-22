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
dim shared dest_org( ENT_MAXTELE ) as vec3
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
function ent_value ( strm() as string, byval strm_cnt as integer, kname as string ) as string
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
sub ent_vec ( strm() as string, byval strm_cnt as integer, kname as string, v as vec3 )
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
sub ent_load_teleports
    dim entity as string
    dim strm(50) as string
    dim strm_cnt as integer
    dim ch as string, blk as string
    dim inblk as integer, fchar as integer
    dim i as integer, j as integer, k as integer
    dim s as string
    dim mdlnum as integer

    redim tele( ENT_MAXTELE ) as Teleporter
    redim mdl_draw( 63 ) as integer

    tele_count = 0
    dest_count = 0
    trig_count = 0

    '' every submodel draws unless something claims it as a trigger
    for  i = 0 to 63
        mdl_draw(i) = true
    next i

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

            elseif ( s$ = "trigger_teleport" and trig_count < ENT_MAXTELE ) then
                trig_target( trig_count ) = ent_value( strm(), strm_cnt, "target" )

                ''
                '' "model" "*1" -- the star is not decoration, it says the
                '' number is a submodel rather than a file name.
                ''
                s$ = ent_value( strm(), strm_cnt, "model" )
                if ( left$( s$, 1 ) = "*" ) then
                    trig_model( trig_count ) = val( mid$( s$, 2 ) )
                    mdl_draw( trig_model( trig_count ) ) = false
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
                    tele( tele_count ).mins = mdl_buffer(mdlnum).mins
                    tele( tele_count ).maxs = mdl_buffer(mdlnum).maxs
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
sub ent_check_teleport
    dim i as integer
    dim pmin as vec3, pmax as vec3

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
