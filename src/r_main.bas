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
sub camUpdate ( pa as integer, crrPnt as integer, cntPnts as integer, _
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
        
        camPos.x = ppos(pa).x
        camPos.y = ppos(pa).y
        camPos.z = ppos(pa).z        
        camLookAt.x = camPos.x+plok(pa).x
        camLookAt.y = camPos.y+plok(pa).y
        camLookAt.z = camPos.z+plok(pa).z
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
        
        camLookAt.x = cos( theta! ) * sin( phi! )
        camLookAt.y = cos( phi! )
        camLookAt.z = sin( theta! ) * sin( phi! )
        

        if ( env.mouse.left  ) then 
            camPosC.x = camPos.x + CamLookAt.x*3
            camPosC.y = camPos.y + CamLookAt.y*3
            camPosC.z = camPos.z + CamLookAt.z*3

    		camPos.x = camPosC.x
    		camPos.y = camPosC.y
    		camPos.z = camPosC.z
        end if
                    
        if ( env.mouse.right ) then
            camPosC.x = camPos.x - CamLookAt.x*3
            camPosC.y = camPos.y - CamLookAt.y*3
            camPosC.z = camPos.z - CamLookAt.z*3                
            
    		camPos.x = camPosC.x
    		camPos.y = camPosC.y
    		camPos.z = camPosC.z
        end if            
        
        if ( env.keyboard.n and env.cammode = 2 ) then
            print #1, camPos.x, camPos.y, camPos.z
            print #1, camLookAt.x, camLookAt.y, camLookAt.z
            
            while ( env.keyboard.n )
            wend
        end if
        
        camLookAt.x = camLookAt.x + camPos.x 
        camLookAt.y = camLookAt.y + camPos.y 
        camLookAt.z = camLookAt.z + camPos.z
    end if
end sub



''::::::::::
'' name: inputToggles
'' desc: The function-key toggles. Each waits for the key to come back
''       up so one press is one toggle.
''::::::::::
defint a-z
sub inputToggles

	''
	'' Toggle mipmaps
	''
    if ( env.keyboard.f1 ) then
        usemips = not usemips
        do 
        loop while ( env.keyboard.f1 )
    end if            

	''
	'' Toggle perspective/affine/wireframe
	''        
    if ( env.keyboard.f2 ) then
        rendmode = (rendmode + 1) mod 3
        do 
        loop while ( env.keyboard.f2 )
    end if                    

	''
	'' Toggle cam/birdseye
	''        
    if ( env.keyboard.f3 ) then
        fpsview = not fpsview
        do 
        loop while ( env.keyboard.f3 )
    end if            
    
	''
	'' Toggle stats
	''        
    if ( env.keyboard.f12 ) then
        stats = not stats
        do 
        loop while ( env.keyboard.f12 )
    end if                    
    
	''
	'' Toggle backface culling
	''        
    if ( env.keyboard.b ) then
        backface = not backface
        do 
        loop while ( env.keyboard.b )
    end if
    
end sub
