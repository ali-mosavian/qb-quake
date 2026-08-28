option explicit
''
'' view.bas -- where the camera is and where it looks. Quake's view.c.
''
''             Was r_main.bas, which also held the render-mode key
''             handling; that is input and now lives in in_main.bas.
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
'' cp_advance lives in main.bas; this is its only caller.
''
declare sub cp_advance ( _
    g as Game, _
    byval dt as single, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer _
)

''
'' This module's own procedures.
''
declare sub v_update_camera ( _
    g as Game, _
    byval dt as single, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node _
)
declare sub v_open_script ( _
    g as Game _
)

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
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

''
'' Camera-script playback state. These were eight parameters threaded from
'' host_main through v_update_camera, which is how the frame loop ended up
'' owning the bezier control points for a camera path. They belong here.
''
'' '$DYNAMIC because ppos and plok are sized from env.caminterp, which is
'' not known until stuff.ini is read. A module-level DIM under '$DYNAMIC
'' never executes outside the main module, so v_open_script REDIMs them.
''
'$dynamic
dim shared ppos() as PNT3D
dim shared plok() as PNT3D
dim shared cbzp() as PNT3D
dim shared cbzl() as PNT3D

'$static
dim shared pa as integer            '' step within the current segment
dim shared crr_pnt as integer       '' control point the path is on
dim shared cnt_pnts as integer      '' how many the script held
dim shared last_point as integer
'$dynamic



'' ==========================================================================
''  FRAME
'' ==========================================================================
''::::::::::
'' name: v_update_camera
'' desc: Advances the camera for one frame -- scripted bezier playback
''       in mode 1, mouse freelook in modes 0 and 2.
''
'' Once per frame, so the call is free. See the note by the shared
'' renderer state for why the draw loop is not carved up the same way.
''::::::::::
sub v_update_camera ( _
    g as Game, _
    byval dt as single, _
    cp_x() as integer, _
    cp_y() as integer, _
    cp_z() as integer, _
    brush() as BrushModel, _
    models() as Submodel, _
    planes() as Plane, _
    nodes() as Node _
)
    dim cam_pos_c as u3dVector3f
    dim tmx as integer, tmy as integer
    dim theta as single, phi as single
    dim fwd as single, strafe as single
    dim dir_x as single, dir_y as single, dir_l as single
    dim jump as integer
    dim t as single

	''
	'' mode script_play run through the bezier curves
	''                
    if ( g.env.cam_mode = 1 ) then
        pa = pa + 1
        if ( crr_pnt+3 <= cnt_pnts and last_point=false ) then
            if ( pa > g.env.cam_interp ) then
                
                        
                ugluCubicBez3D ppos(0), cbzp(crr_pnt), g.env.cam_interp
                ugluCubicBez3D plok(0), cbzl(crr_pnt), g.env.cam_interp
                
                pa = 0
                crr_pnt = crr_pnt+3
            end if                
        else
            if ( crr_pnt <> cnt_pnts and (not last_point) ) then
                pa = 0
                last_point = true
                ugluCubicBez3D ppos(0), cbzp(cnt_pnts-4), g.env.cam_interp
                ugluCubicBez3D plok(0), cbzl(cnt_pnts-4), g.env.cam_interp
                
            elseif ( pa > g.env.cam_interp ) then
                crr_pnt = 0
                last_point = false
                g.env.keyboard.esc = true
            end if                    
        end if                
        
        g.cam.pos.x = ppos(pa).x
        g.cam.pos.y = ppos(pa).y
        g.cam.pos.z = ppos(pa).z        
        g.cam.look_at.x = g.cam.pos.x+plok(pa).x
        g.cam.look_at.y = g.cam.pos.y+plok(pa).y
        g.cam.look_at.z = g.cam.pos.z+plok(pa).z
    end if
    
    
    ''
    '' Mode: freelook or script_edit
    ''
    if ( g.env.cam_mode = 0 or g.env.cam_mode = 2 ) then            
        '' screen coordinates throughout: the mouse spans the MODE, not
        '' the view, so a smaller view must not shrink the look range
        if g.env.mouse.x < 1 then  mousepos g.env.scr_x_res-4, g.env.mouse.y
        if g.env.mouse.x > g.env.scr_x_res-3 then  mousepos 1, g.env.mouse.y
        
        if g.env.mouse.y < 0        then  mousepos g.env.mouse.x, 0
        if g.env.mouse.y > g.env.scr_y_res then  mousepos g.env.mouse.x, g.env.scr_y_res-1
        
        tmx = g.env.mouse.x + 1
        tmy = g.env.mouse.y + 2

        theta = 2 * 3.14159 * ((g.env.scr_x_res-1)-tmx) / g.env.scr_x_res
        phi = 3.14159 * tmy / g.env.scr_y_res
        
        g.cam.look_at.x = cos( theta ) * sin( phi )
        g.cam.look_at.y = cos( phi )
        g.cam.look_at.z = sin( theta ) * sin( phi )
        

        ''
        '' Forward and back on the mouse buttons, as before. What changed is
        '' what they drive: in walk mode the player accelerates and the world
        '' decides where the move actually ends, in noclip they still move the
        '' eye straight along the look vector.
        ''
        ''
        '' WASD, with the mouse buttons kept for forward and back because
        '' that is how this program has always moved.
        ''
        fwd    = 0.0
        strafe = 0.0

        if ( g.env.keyboard.w  ) then fwd    = fwd    + 1.0
        if ( g.env.keyboard.s  ) then fwd    = fwd    - 1.0
        if ( g.env.keyboard.a  ) then strafe = strafe + 1.0
        if ( g.env.keyboard.d  ) then strafe = strafe - 1.0

        if ( g.env.mouse.left  ) then fwd    = fwd    + 1.0
        if ( g.env.mouse.right ) then fwd    = fwd    - 1.0

        if ( g.env.bench_walk   ) then fwd    = 1.0
        if ( g.env.bench_strafe ) then strafe = 1.0

        ''
        '' Pressing both of an opposing pair cancels, which falls out of the
        '' sum above, and holding W with the left button does not double the
        '' speed because pl_move clamps to PL_MAXSPEED.
        ''

        if ( g.pl.no_clip ) then
            ''
            '' Also per second, not per frame. This used to advance a flat 3
            '' units every frame, so the camera flew at whatever speed the
            '' framerate happened to give it.
            ''
            g.cam.pos.x = g.cam.pos.x + g.cam.look_at.x*PL_NOCLIP#*fwd*dt
            g.cam.pos.y = g.cam.pos.y + g.cam.look_at.y*PL_NOCLIP#*fwd*dt
            g.cam.pos.z = g.cam.pos.z + g.cam.look_at.z*PL_NOCLIP#*fwd*dt

            ''
            '' Keep the player in step with the free camera, so switching
            '' back to walking carries on from here rather than snapping to
            '' wherever physics was last left.
            ''
            g.pl.pos.x = g.cam.pos.x
            g.pl.pos.y = g.cam.pos.z
            g.pl.pos.z = g.cam.pos.y - PL_EYE#
            g.pl.vel.x = 0.0
            g.pl.vel.y = 0.0
            g.pl.vel.z = 0.0
        else
            ''
            '' g.cam.look_at is still a direction here; it does not become an
            '' absolute point until the bottom of this routine. Only its
            '' horizontal part steers walking, renormalised so that looking at
            '' the floor does not slow the player down.
            ''
            dir_x = g.cam.look_at.x
            dir_y = g.cam.look_at.z                    '' renderer z is bsp y
            dir_l = sqr( dir_x*dir_x + dir_y*dir_y )
            if ( dir_l > 0.001 ) then
                dir_x = dir_x / dir_l
                dir_y = dir_y / dir_l
            else
                dir_x = 1.0
                dir_y = 0.0
            end if

            jump = 0
            if ( g.env.keyboard.spcbar ) then jump = -1
            if ( g.env.bench_jump       ) then jump = -1

            ''
            '' -campath steers instead of positioning: the direction comes
            '' from the route, the MOVING is pl_move's. Gravity, the hull
            '' and step-up are then the game's, not an approximation, and a
            '' wall stops the walk exactly as it stops a player.
            ''
            if ( g.env.cam_path ) then
                cp_advance g, dt, cp_x(), cp_y(), cp_z()
                if ( g.cp.dir_x <> 0.0 or g.cp.dir_y <> 0.0 ) then
                    ''
                    '' Face the way we are going. The view and the walk
                    '' come from ONE vector -- looking somewhere the player
                    '' is not heading is what made the earlier passes look
                    '' like the camera was sliding sideways through rooms.
                    ''
                    '' Eased rather than snapped, so a corner turns instead
                    '' of cutting; the waypoints are 32 units apart and an
                    '' instant turn at each reads as a flinch.
                    ''
                    if ( g.cp.look_x = 0.0 and g.cp.look_y = 0.0 ) then
                        g.cp.look_x = g.cp.dir_x
                        g.cp.look_y = g.cp.dir_y
                    else
                        '' dt-scaled, clamped: a long frame must not
                        '' overshoot the target direction
                        t = CP_TURN * dt
                        if ( t > 1.0 ) then t = 1.0
                        g.cp.look_x = g.cp.look_x + (g.cp.dir_x - g.cp.look_x) * t
                        g.cp.look_y = g.cp.look_y + (g.cp.dir_y - g.cp.look_y) * t
                    end if
                    dir_l = sqr( g.cp.look_x*g.cp.look_x + g.cp.look_y*g.cp.look_y )
                    if ( dir_l > 0.001 ) then
                        g.cp.look_x = g.cp.look_x / dir_l
                        g.cp.look_y = g.cp.look_y / dir_l
                    end if

                    '' renderer z is bsp y, and keep the view level
                    g.cam.look_at.x = g.cp.look_x
                    g.cam.look_at.y = 0.0
                    g.cam.look_at.z = g.cp.look_y

                    dir_x  = g.cp.look_x
                    dir_y  = g.cp.look_y
                    fwd    = 1.0
                    strafe = 0.0
                end if
            end if

            pl_move g, fwd, strafe, dir_x, dir_y, jump, dt, g.wld.count.models, models(), _
                     brush(), nodes(), planes()
        end if
        
        if ( g.env.keyboard.n and g.env.cam_mode = 2 ) then
            print #g.cam.script_file, g.cam.pos.x, g.cam.pos.y, g.cam.pos.z
            print #g.cam.script_file, g.cam.look_at.x, g.cam.look_at.y, g.cam.look_at.z
            
            while ( g.env.keyboard.n )
            wend
        end if
        
        g.cam.look_at.x = g.cam.look_at.x + g.cam.pos.x 
        g.cam.look_at.y = g.cam.look_at.y + g.cam.pos.y 
        g.cam.look_at.z = g.cam.look_at.z + g.cam.pos.z
    end if
end sub


''::::::::::
'' name: v_open_script
'' desc: Camera-script setup, for both script modes.
''
''       cammode 1 replays a recorded path: read the control points, then
''       expand the first bezier segment. cammode 2 records one, so it only
''       opens the file -- v_update_camera writes to it on each 'n' press.
''
''       This was forty lines inside host_main, which is the frame loop's
''       routine and has no business parsing camera paths. The read loop
''       also terminated on eof(1), a hardcoded handle, while the file was
''       opened on one from freefile -- the same bug the ini parser had.
''::::::::::
sub v_open_script ( _
    g as Game _
)
    dim i as integer

    redim ppos( g.env.cam_interp ) as PNT3D
    redim plok( g.env.cam_interp ) as PNT3D
    redim cbzp( 10 ) as PNT3D
    redim cbzl( 10 ) as PNT3D

    if ( g.env.cam_mode = 1 ) then
        g.cam.script_file = freefile
        open g.env.cam_script for input as #g.cam.script_file
        do
            input #g.cam.script_file, cbzp(i).x, cbzp(i).y, cbzp(i).z
            input #g.cam.script_file, cbzl(i).x, cbzl(i).y, cbzl(i).z
            i = i + 1
        loop until ( eof( g.cam.script_file ) )
        close #g.cam.script_file
        g.cam.script_file = 0
        cnt_pnts = i-1

        ugluCubicBez3D ppos(0), cbzp(crr_pnt), g.env.cam_interp
        ugluCubicBez3D plok(0), cbzl(crr_pnt), g.env.cam_interp
        crr_pnt = crr_pnt + 3

    elseif ( g.env.cam_mode = 2 ) then
        g.cam.script_file = freefile
        open g.env.cam_script for output as #g.cam.script_file
    end if

end sub
