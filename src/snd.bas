option explicit
''
'' snd.bas -- sound device and the loading music. Split out of sys_init.bas,
''            which was initialising five different subsystems.
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
declare sub s_get_blaster ( _
    port as integer, _
    irq as integer, _
    ldma as integer, _
    hdma as integer _
)
declare sub s_init ( _
    g as Game _
)
declare sub s_start_music ( _
    g as Game _
)
declare sub s_stop_music ( _
    g as Game _
)


'' The loading screen's MOD, private to this module: s_start_music opens
'' it and s_stop_music frees it. The one that plays during the walkthrough
'' is mymod, which main.bas needs, so that one is shared.
dim shared load_mod as UGMMOD





'' :::::::::::
'' name: s_get_blaster
'' desc: Parse the BLASTER enviroment variable
''
'' :::::::::::
sub s_get_blaster ( _
    port as integer, _
    irq as integer, _
    ldma as integer, _
    hdma as integer _
)
    
    dim tmpstr as string
    dim sbvstr as string
    dim strpos as integer
    dim curr_char as string
                         
    port = false
    irq  = false
    ldma = false
    hdma = false
    strpos = 1
    
    ''
    '' Get BLASTER variable
    ''
    sbvstr = environ$( "BLASTER" )
    if ( sbvstr = "" ) then exit sub
    
    
    ''
    '' Parse it
    ''
    while ( strpos <= len( sbvstr ) )
    
        curr_char = mid$( sbvstr, strpos, 1 )              
        
        select case ( curr_char )            
            case "A", "a"
                tmpstr = "&h" + mid$( sbvstr, strpos+1, 3 )
                port = val( tmpstr )
                strpos = strpos + 4
                
            case "I", "i"
                tmpstr = mid$( sbvstr, strpos+1, 2 )
                irq = val( tmpstr )
                strpos = strpos + 2
                
            case "D", "d"
                tmpstr = mid$( sbvstr, strpos+1, 1 )
                ldma = val( tmpstr )
                strpos = strpos + 2
                
            case "H", "h"
                tmpstr = mid$( sbvstr, strpos+1, 1 )
                hdma = val( tmpstr )
                strpos = strpos + 2                
            
            case else
                strpos = strpos + 1
        end select        
    wend   
    
end sub






''::::::::::
'' name: s_init
'' desc: Autodetects an SB16, falls back to the BLASTER variable.
''::::::::::
sub s_init ( _
    g as Game _
)
    dim port as integer
    dim irq as integer
    dim ldma as integer
    dim hdma as integer

    if ( g.env.sound = true ) then
        if ( sndInit( false, false, false, false ) = false ) then
            
            s_get_blaster port, irq, ldma, hdma
            if ( (port = false) or (irq = false) or (ldma = false ) ) then
                sys_error "0x0001, No sound blaster or compatible detected..."
            end if
          
            if ( sndInit( port, irq, ldma, hdma ) = false ) then
                sys_error "0x0002, Could not init sound module..."
            end if
            
        end if
        
        ''
        '' Try to open sound output with a update rate of
        '' 50 times per second.
        ''
        '' SB 1.0 - 2.0:    8 bit, mono, 4000Hz-23000Hz
        '' SB 2.01:         8 bit, mono, 4000Hz-44100Hz
        '' SB Pro:          8 bit, mono, 4000Hz-44100Hz
        ''                  8 bit, stereo, 11025Hz-22050Hz
        '' SB 16:           8/16 bit, mono/stereo, 5000Hz-44100Hz
        ''        
        if ( sndOpenOutput( snd.s16.stereo, 44100, 50 ) = false ) then
            if ( sndOpenOutput( snd.s8.stereo, 22050, 50 ) = false ) then
                if ( sndOpenOutput( snd.s8.mono, 22050, 50 ) = false ) then
                    sys_error "0x1003, Could not open sound output..."
                end if
            end if        
        end if

    end if
end sub






''::::::::::
'' name: s_start_music
'' desc: Starts the module that plays over the loading screen.
''::::::::::
sub s_start_music ( _
    g as Game _
)
    if ( g.env.sound = true ) then
        if ( modInit = false ) then
            sys_error "0x1004, Could not init mod module..."
        end if
        
        ''
        '' Load mod
        ''    
        if ( modNew( load_mod, mod.ems, "base.dat::mods/flim.mod" ) = false ) then
            sys_error "0x1005, Could not load mod..."
        end if
            
        if ( modNew( g.mymod, mod.ems, "base.dat::mods/mainfrm.mod" ) = false ) then
            sys_error "0x1005, Could not load mod..."
        end if
        
       
        ''
        '' Loading music
        ''
        modPlay load_mod
    end if

end sub






''::::::::::
'' name: s_stop_music
''::::::::::
sub s_stop_music ( _
    g as Game _
)
    if ( g.env.sound = true ) then
        modStop
        modDel load_mod
    end if

end sub
