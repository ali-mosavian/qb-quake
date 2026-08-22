option explicit
''
'' r_main.bas -- the camera.
''
'' Mouse look, movement with collision, and the view toggles. Quake's
'' r_main.c is the same layer: it decides where the eye is before r_bsp
'' decides what it can see.
''
defint a-z
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
'$include: 'quakedef.bi'



'' ==========================================================================
''  FRAME
'' ==========================================================================
''::::::::::
'' name: camUpdate
'' desc: Advances the camera for one frame -- scripted bezier playback
''       in mode 1, mouse freelook in modes 0 and 2.
''
'' Once per frame, so the call is free. See the note by the shared
'' renderer state for why the draw loop is not carved up the same way.
''::::::::::
defint a-z
sub v_update_camera ( pa as integer, crrPnt as integer, cntPnts as integer, _
                ppos() as PNT3D, plok() as PNT3D, _
                cbzp() as PNT3D, cbzl() as PNT3D, last_point as integer )
    dim camPosC as u3dVector3f
    dim tmx as integer, tmy as integer
    dim theta as single, phi as single

	''
	'' mode script_play run through the bezier curves
	''                
    if ( env.cammode = 1 ) then
        pa = pa + 1
        if ( crrPnt+3 <= cntPnts and last_point=false ) then
            if ( pa > env.caminterp ) then
                
                        
                ugluCubicBez3D ppos(0), cbzp(crrPnt), env.caminterp
                ugluCubicBez3D plok(0), cbzl(crrPnt), env.caminterp
                
                pa = 0
                crrPnt = crrPnt+3
            end if                
        else
            if ( crrPnt <> cntPnts and (not last_point) ) then
                pa = 0
                last_point = true
                ugluCubicBez3D ppos(0), cbzp(cntPnts-4), env.caminterp
                ugluCubicBez3D plok(0), cbzl(cntPnts-4), env.caminterp
                
            elseif ( pa > env.caminterp ) then
                crrPnt = 0
                last_point = false
                env.keyboard.esc = true
            end if                    
        end if                
        
        cam.pos.x = ppos(pa).x
        cam.pos.y = ppos(pa).y
        cam.pos.z = ppos(pa).z        
        cam.lookAt.x = cam.pos.x+plok(pa).x
        cam.lookAt.y = cam.pos.y+plok(pa).y
        cam.lookAt.z = cam.pos.z+plok(pa).z
    end if
    
    
    ''
    '' Mode: freelook or script_edit
    ''
    if ( env.cammode = 0 or env.cammode = 2 ) then            
        if env.mouse.x < 1 then  mousepos env.xres-4, env.mouse.y
        if env.mouse.x > env.xres-3 then  mousepos 1, env.mouse.y
        
        if env.mouse.y < 0        then  mousepos env.mouse.x, 0
        if env.mouse.y > env.yres then  mousepos env.mouse.x, env.yres-1
        
        tmx = env.mouse.x + 1
        tmy = env.mouse.y + 2

        theta! = 2 * 3.14159 * ((env.xRes-1)-tmx) / env.xRes
        phi! = 3.14159 * tmy / env.yRes
        
        cam.lookAt.x = cos( theta! ) * sin( phi! )
        cam.lookAt.y = cos( phi! )
        cam.lookAt.z = sin( theta! ) * sin( phi! )
        

        if ( env.mouse.left  ) then 
            camPosC.x = cam.pos.x + cam.lookAt.x*3
            camPosC.y = cam.pos.y + cam.lookAt.y*3
            camPosC.z = cam.pos.z + cam.lookAt.z*3

    		cam.pos.x = camPosC.x
    		cam.pos.y = camPosC.y
    		cam.pos.z = camPosC.z
        end if
                    
        if ( env.mouse.right ) then
            camPosC.x = cam.pos.x - cam.lookAt.x*3
            camPosC.y = cam.pos.y - cam.lookAt.y*3
            camPosC.z = cam.pos.z - cam.lookAt.z*3                
            
    		cam.pos.x = camPosC.x
    		cam.pos.y = camPosC.y
    		cam.pos.z = camPosC.z
        end if            
        
        if ( env.keyboard.n and env.cammode = 2 ) then
            print #cam.scriptFile, cam.pos.x, cam.pos.y, cam.pos.z
            print #cam.scriptFile, cam.lookAt.x, cam.lookAt.y, cam.lookAt.z
            
            while ( env.keyboard.n )
            wend
        end if
        
        cam.lookAt.x = cam.lookAt.x + cam.pos.x 
        cam.lookAt.y = cam.lookAt.y + cam.pos.y 
        cam.lookAt.z = cam.lookAt.z + cam.pos.z
    end if
end sub



''::::::::::
'' name: inputToggles
'' desc: The function-key toggles. Each waits for the key to come back
''       up so one press is one toggle.
''::::::::::
defint a-z
sub in_handle_toggles

	''
	'' Toggle mipmaps
	''
    if ( env.keyboard.f1 ) then
        rdr.usemips = not rdr.usemips
        do 
        loop while ( env.keyboard.f1 )
    end if            

	''
	'' Toggle perspective/affine/wireframe
	''        
    if ( env.keyboard.f2 ) then
        rdr.rendmode = (rdr.rendmode + 1) mod 3
        do 
        loop while ( env.keyboard.f2 )
    end if                    

	''
	'' Toggle cam/birdseye
	''        
    if ( env.keyboard.f3 ) then
        cam.fpsview = not cam.fpsview
        do 
        loop while ( env.keyboard.f3 )
    end if            
    
	''
	'' Toggle stats
	''        
    if ( env.keyboard.f12 ) then
        scr.stats = not scr.stats
        do 
        loop while ( env.keyboard.f12 )
    end if                    
    
	''
	'' Toggle backface culling
	''        
    if ( env.keyboard.b ) then
        rdr.backface = not rdr.backface
        do 
        loop while ( env.keyboard.b )
    end if
    
end sub
