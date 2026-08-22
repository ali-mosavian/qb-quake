option explicit
''
'' sys_init.bas -- one-shot startup: the command line, stuff.ini, sound,
''                the bitmap font, and input. Quake's Host_Init is the same
''                shape: a thin orchestrator in host.c that calls a sequence
''                of *_Init routines defined elsewhere. main.bas is that
''                orchestrator here; every routine below is one of the steps
''                it calls exactly once.
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
'$include: 'q_snd.bi'

'$dynamic
dim shared loadmod as UGMMOD



'' :::::::::::
'' name: getSBSettings
'' desc: Parse the BLASTER enviroment variable
''
'' :::::::::::
sub s_get_blaster  ( port as integer, irq as integer, ldma as integer, _    
                     hdma as integer )
    
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
'' name: checkCommandLine
'' desc: A map on the command line, and the ini beside it.
''::::::::::
sub sys_parse_args
    dim argv(16) as string
    dim argc as integer
    dim cl as string
    dim i as integer

    cl = rtrim$(ltrim$( command$ ))
    if ( cl = "" ) then
        print "Usage: qrender mapname.bsp [-bench N]"
        print "  -bench N   render N frames, write bench.bmp and bench.txt, exit"
        print "Copyleft Blitz, july/2003"
        host_shutdown
    end if

    ''
    '' The map used to be command$ itself, passed raw to OPEN. Splitting it
    '' off is what lets anything else share the command line.
    ''
    com_tokenize argv(), argc, " ", cl
    env.map_name = argv(0)
    env.bench_frames = 0

    for  i = 1 to argc-1
        if ( lcase$(argv(i)) = "-bench" and i+1 <= argc-1 ) then
            env.bench_frames = val( argv(i+1) )
        end if
    next i

    if ( (dir$( rtrim$(env.map_name) ) = "") ) then
        print "File " + lcase$(rtrim$(env.map_name)) + " could not be found"
        host_shutdown
    end if
    
    if ( (dir$( "stuff.ini" ) = "") ) then
        print "Ini file could not be found"
        host_shutdown
    end if    

end sub




''::::::::::
'' name: initTables
'' desc: Reads stuff.ini and builds the bit mask table the PVS decoder indexes.
''::::::::::
sub sys_init_tables
    ''
    '' bitarray and frustum are COMMON now, and COMMON can only declare an
    '' array as name() -- with no elements. Both carried a real bound in their
    '' DIM, so they must be sized here or the first write is out of range.
    ''
    redim bitarray( 15 ) as integer
    redim frustum( 5 ) as plane

    dim i as integer

    com_parse_config "stuff.ini"    
    
    for  i = 0 to 15
        bitarray(i) = clng(2^i)
    next i    

end sub




''::::::::::
'' name: soundOpen
'' desc: Autodetects an SB16, falls back to the BLASTER variable.
''::::::::::
sub s_init
    dim port as integer
    dim irq as integer
    dim ldma as integer
    dim hdma as integer

    if ( env.sound = true ) then
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
'' name: musicStart
'' desc: Starts the module that plays over the loading screen.
''::::::::::
sub s_start_music
    if ( env.sound = true ) then
        if ( modInit = false ) then
            sys_error "0x1004, Could not init mod module..."
        end if
        
        ''
        '' Load mod
        ''    
        if ( modNew( loadmod, mod.ems, "base.dat::mods/flim.mod" ) = false ) then
            sys_error "0x1005, Could not load mod..."
        end if
            
        if ( modNew( mymod, mod.ems, "base.dat::mods/mainfrm.mod" ) = false ) then
            sys_error "0x1005, Could not load mod..."
        end if
        
       
        ''
        '' Loading music
        ''
        modPlay loadmod
    end if

end sub




''::::::::::
'' name: fontOpen
''::::::::::
sub draw_init_font
    if ( not draw_load_font( "base.dat::font/4x6.fnt", 254 ) ) then
        sys_error "0x0000, Could not load font..."
    end if    

end sub




''::::::::::
'' name: loadScreenOpen
'' desc: Mode 13h for the duration of loading only.
''::::::::::
sub scr_begin_loading
    ldr.dc = uglSetVideoDC( UGL.8BIT, 320, 200, 1 )
    if ( ldr.dc = false ) then
        sys_error "0x3001, Could not set loading video mode"
    end if
    
    scr_load_tick    

end sub




''::::::::::
'' name: inputOpen
'' desc: Mouse, keyboard and the one second timer.
''::::::::::
sub in_init
    if ( mouseInit( env.h_video_dc, env.mouse ) = FALSE ) then
        sys_error "0x0006, Could not init mouse..."
    end if  
    
    ''
    '' Init keyboard
    ''
    kbdInit env.keyboard
    
    ''
    '' Init timer
    ''
    tmrInit

end sub




''::::::::::
'' name: musicStopLoading
''::::::::::
sub s_stop_music
    if ( env.sound = true ) then
        modStop
        modDel loadmod
    end if

end sub
