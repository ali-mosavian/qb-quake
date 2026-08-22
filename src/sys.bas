option explicit
''
'' sys.bas -- the platform edges: the command line, stuff.ini, the
''            lookup tables, and the fatal-error path.
''
''            This was sys_init.bas and held five subsystems' worth of
''            initialisation. Sound went to snd.bas, input to
''            in_main.bas, the font and loading screen to screen.bas.
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




''::::::::::
'' name: sys_parse_args
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
        if ( lcase$(argv(i)) = "-walk" ) then
            env.bench_walk = true
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
'' name: sys_init_tables
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




''::::
sub sys_error ( msg as string )
    ''
    '' Record the message before touching the video mode.
    ''
    '' Everything below draws to the screen, and if uglRestore leaves a
    '' graphics mode the message is rendered as pixels: not in the text
    '' buffer, not on redirected stdout, and gone the moment the program
    '' ends. A failed run then looks exactly like a slow one from outside.
    ''
    dim errf as integer
    errf = freefile
    open "error.log" for output as #errf
    print #errf, msg
    close #errf

    ''
    '' Restore video mode and end UGL
    ''
    uglRestore
    uglEnd
    
    ''
    '' Print msg and quit program
    ''
    screen 0
    width 80, 25
    print "Error: " + msg
    sleep
    end
end sub
