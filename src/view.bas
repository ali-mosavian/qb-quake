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
'$include: 'q_draw.bi'
'$include: 'q_vis.bi'
'$include: 'q_map.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
Declare Sub cp_advance ( )

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
sub v_update_camera ( byval dt as single )
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
    if ( env.cam_mode = 1 ) then
        pa = pa + 1
        if ( crr_pnt+3 <= cnt_pnts and last_point=false ) then
            if ( pa > env.cam_interp ) then
                
                        
                ugluCubicBez3D ppos(0), cbzp(crr_pnt), env.cam_interp
                ugluCubicBez3D plok(0), cbzl(crr_pnt), env.cam_interp
                
                pa = 0
                crr_pnt = crr_pnt+3
            end if                
        else
            if ( crr_pnt <> cnt_pnts and (not last_point) ) then
                pa = 0
                last_point = true
                ugluCubicBez3D ppos(0), cbzp(cnt_pnts-4), env.cam_interp
                ugluCubicBez3D plok(0), cbzl(cnt_pnts-4), env.cam_interp
                
            elseif ( pa > env.cam_interp ) then
                crr_pnt = 0
                last_point = false
                env.keyboard.esc = true
            end if                    
        end if                
        
        cam.pos.x = ppos(pa).x
        cam.pos.y = ppos(pa).y
        cam.pos.z = ppos(pa).z        
        cam.look_at.x = cam.pos.x+plok(pa).x
        cam.look_at.y = cam.pos.y+plok(pa).y
        cam.look_at.z = cam.pos.z+plok(pa).z
    end if
    
    
    ''
    '' Mode: freelook or script_edit
    ''
    if ( env.cam_mode = 0 or env.cam_mode = 2 ) then            
        if env.mouse.x < 1 then  mousepos env.x_res-4, env.mouse.y
        if env.mouse.x > env.x_res-3 then  mousepos 1, env.mouse.y
        
        if env.mouse.y < 0        then  mousepos env.mouse.x, 0
        if env.mouse.y > env.y_res then  mousepos env.mouse.x, env.y_res-1
        
        tmx = env.mouse.x + 1
        tmy = env.mouse.y + 2

        theta = 2 * 3.14159 * ((env.x_res-1)-tmx) / env.x_res
        phi = 3.14159 * tmy / env.y_res
        
        cam.look_at.x = cos( theta ) * sin( phi )
        cam.look_at.y = cos( phi )
        cam.look_at.z = sin( theta ) * sin( phi )
        

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

        if ( env.keyboard.w  ) then fwd    = fwd    + 1.0
        if ( env.keyboard.s  ) then fwd    = fwd    - 1.0
        if ( env.keyboard.a  ) then strafe = strafe + 1.0
        if ( env.keyboard.d  ) then strafe = strafe - 1.0

        if ( env.mouse.left  ) then fwd    = fwd    + 1.0
        if ( env.mouse.right ) then fwd    = fwd    - 1.0

        if ( env.bench_walk   ) then fwd    = 1.0
        if ( env.bench_strafe ) then strafe = 1.0

        ''
        '' Pressing both of an opposing pair cancels, which falls out of the
        '' sum above, and holding W with the left button does not double the
        '' speed because pl_move clamps to PL_MAXSPEED.
        ''

        if ( pl.no_clip ) then
            ''
            '' Also per second, not per frame. This used to advance a flat 3
            '' units every frame, so the camera flew at whatever speed the
            '' framerate happened to give it.
            ''
            cam.pos.x = cam.pos.x + cam.look_at.x*PL_NOCLIP#*fwd*dt
            cam.pos.y = cam.pos.y + cam.look_at.y*PL_NOCLIP#*fwd*dt
            cam.pos.z = cam.pos.z + cam.look_at.z*PL_NOCLIP#*fwd*dt

            ''
            '' Keep the player in step with the free camera, so switching
            '' back to walking carries on from here rather than snapping to
            '' wherever physics was last left.
            ''
            pl.pos.x = cam.pos.x
            pl.pos.y = cam.pos.z
            pl.pos.z = cam.pos.y - PL_EYE#
            pl.vel.x = 0.0
            pl.vel.y = 0.0
            pl.vel.z = 0.0
        else
            ''
            '' cam.look_at is still a direction here; it does not become an
            '' absolute point until the bottom of this routine. Only its
            '' horizontal part steers walking, renormalised so that looking at
            '' the floor does not slow the player down.
            ''
            dir_x = cam.look_at.x
            dir_y = cam.look_at.z                    '' renderer z is bsp y
            dir_l = sqr( dir_x*dir_x + dir_y*dir_y )
            if ( dir_l > 0.001 ) then
                dir_x = dir_x / dir_l
                dir_y = dir_y / dir_l
            else
                dir_x = 1.0
                dir_y = 0.0
            end if

            jump = 0
            if ( env.keyboard.spcbar ) then jump = -1
            if ( env.bench_jump       ) then jump = -1

            ''
            '' -campath steers instead of positioning: the direction comes
            '' from the route, the MOVING is pl_move's. Gravity, the hull
            '' and step-up are then the game's, not an approximation, and a
            '' wall stops the walk exactly as it stops a player.
            ''
            if ( env.cam_path ) then
                cp_advance
                if ( cp_dirx <> 0.0 or cp_diry <> 0.0 ) then
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
                    if ( cp_lx = 0.0 and cp_ly = 0.0 ) then
                        cp_lx = cp_dirx
                        cp_ly = cp_diry
                    else
                        '' dt-scaled, clamped: a long frame must not
                        '' overshoot the target direction
                        t = CP_TURN * dt
                        if ( t > 1.0 ) then t = 1.0
                        cp_lx = cp_lx + (cp_dirx - cp_lx) * t
                        cp_ly = cp_ly + (cp_diry - cp_ly) * t
                    end if
                    dir_l = sqr( cp_lx*cp_lx + cp_ly*cp_ly )
                    if ( dir_l > 0.001 ) then
                        cp_lx = cp_lx / dir_l
                        cp_ly = cp_ly / dir_l
                    end if

                    '' renderer z is bsp y, and keep the view level
                    cam.look_at.x = cp_lx
                    cam.look_at.y = 0.0
                    cam.look_at.z = cp_ly

                    dir_x  = cp_lx
                    dir_y  = cp_ly
                    fwd    = 1.0
                    strafe = 0.0
                end if
            end if

            pl_move fwd, strafe, dir_x, dir_y, jump, dt, _
                    pl, cam, wld.mdl_count, mdl_buffer(), brush(), _
                    nds_buffer(), pln_buffer()
        end if
        
        if ( env.keyboard.n and env.cam_mode = 2 ) then
            print #cam.script_file, cam.pos.x, cam.pos.y, cam.pos.z
            print #cam.script_file, cam.look_at.x, cam.look_at.y, cam.look_at.z
            
            while ( env.keyboard.n )
            wend
        end if
        
        cam.look_at.x = cam.look_at.x + cam.pos.x 
        cam.look_at.y = cam.look_at.y + cam.pos.y 
        cam.look_at.z = cam.look_at.z + cam.pos.z
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
sub v_open_script ( )
    dim i as integer

    redim ppos( env.cam_interp ) as PNT3D
    redim plok( env.cam_interp ) as PNT3D
    redim cbzp( 10 ) as PNT3D
    redim cbzl( 10 ) as PNT3D

    if ( env.cam_mode = 1 ) then
        cam.script_file = freefile
        open env.cam_script for input as #cam.script_file
        do
            input #cam.script_file, cbzp(i).x, cbzp(i).y, cbzp(i).z
            input #cam.script_file, cbzl(i).x, cbzl(i).y, cbzl(i).z
            i = i + 1
        loop until ( eof( cam.script_file ) )
        close #cam.script_file
        cam.script_file = 0
        cnt_pnts = i-1

        ugluCubicBez3D ppos(0), cbzp(crr_pnt), env.cam_interp
        ugluCubicBez3D plok(0), cbzl(crr_pnt), env.cam_interp
        crr_pnt = crr_pnt + 3

    elseif ( env.cam_mode = 2 ) then
        cam.script_file = freefile
        open env.cam_script for output as #cam.script_file
    end if

end sub
