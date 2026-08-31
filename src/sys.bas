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
declare sub sys_parse_args ( _
    g as Game _
)
declare sub sys_init_tables ( _
    g as Game, _
    bit_array() as integer, _
    frustum() as DiskPlane _
)
declare sub sys_time_init ( )
declare function sys_frame_time ( _
    g as Game _
) as single
declare function sys_tick_hz ( ) as single
declare function sys_now ( ) as single
declare function sys_rdtsc ( ) as long
declare function sys_rdtsc_hz ( ) as single
declare function sys_mem_count ( ) as integer
declare function sys_mem_tag ( byval i as integer ) as string
declare function sys_mem_val ( byval i as integer ) as long
declare function sys_mem_fre ( byval i as integer ) as long

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare sub com_parse_config ( _
    g as Game, _
    filename as string _
)
declare sub host_shutdown ( )
'' for sys_raw_dt: the benchmark's unclamped frame delta lives in /scr_s/

''
'' Frame timing. A 1 kHz uGL timer, read once a frame.
''
'' DOS's own TIMER ticks 18.2 times a second -- 55ms, which is longer than
'' a frame at any framerate this renderer reaches, so it cannot measure one.
'' A TMR can: tmrInit is running by the time the frame loop starts, even
'' though it is not during doInit, which is why the load profiler had to
'' use TIMER instead.
''
'$static
''
'' THE MEMORY TRACE. Owned here: sys_mem_mark is the only writer, and
'' main.bas reads it back through the four accessors below rather than
'' indexing the arrays itself. See MEM_MARKS in q_map.bi.
''
dim shared mem_val() as long
dim shared mem_fre() as long
dim shared mem_tag() as string * 12
dim shared mem_n as integer

dim shared frame_tmr as TMR
dim shared last_tick as long
dim shared timing_on as integer
dim shared tick_hz as single
dim shared rdtsc_hz as single    '' cycles/sec, calibrated the same way
dim shared cyc_per_us as long    '' rdtsc_hz / 1e6, as a whole number --
                                  '' see sys_rdtsc for why it has to be one
'$dynamic

'$dynamic




''::::::::::
'' name: sys_parse_args
'' desc: A map on the command line, and the ini beside it.
''::::::::::
sub sys_parse_args ( _
    g as Game _
)
    dim argv(16) as string
    dim argc as integer
    dim cl as string
    dim i as integer

    cl = rtrim$(ltrim$( command$ ))
    if ( cl = "" ) then
        print "Usage: qrender mapname.bsp [-bench N]"
        print "  -bench N      render N frames, write bench.bmp and bench.txt, exit"
        print "  -benchsecs N  run for N real seconds, then report, exit"
        print "  -lm           composite lightmaps via the surface cache"
        print "Copyleft Blitz, july/2003"
        host_shutdown
    end if

    ''
    '' The map used to be command$ itself, passed raw to OPEN. Splitting it
    '' off is what lets anything else share the command line.
    ''
    com_tokenize argv(), argc, " ", cl
    g.env.map_name = argv(0)
    g.env.bench_frames = 0

    for  i = 1 to argc-1
        if ( lcase$(argv(i)) = "-bench" and i+1 <= argc-1 ) then
            g.env.bench_frames = val( argv(i+1) )
        end if
        if ( lcase$(argv(i)) = "-walk" ) then
            g.env.bench_walk = true
        end if
        if ( lcase$(argv(i)) = "-jump" ) then
            g.env.bench_jump = true
        end if
        if ( lcase$(argv(i)) = "-strafe" ) then
            g.env.bench_strafe = true
        end if
        if ( lcase$(argv(i)) = "-at" and i+3 <= argc-1 ) then
            g.env.start_x   = val( argv(i+1) )
            g.env.start_y   = val( argv(i+2) )
            g.env.start_z   = val( argv(i+3) )
            g.env.start_set = true
        end if
        if ( lcase$(argv(i)) = "-noents" ) then
            g.env.no_ents = true
        end if
        if ( lcase$(argv(i)) = "-badorder" ) then
            g.env.bad_order = true
        end if
        if ( lcase$(argv(i)) = "-polytp" ) then
            g.env.poly_tp = true
        end if
        if ( lcase$(argv(i)) = "-noz" ) then
            g.env.no_z = true
        end if
        if ( lcase$(argv(i)) = "-spandraw" ) then
            g.env.span_draw = true
        end if
        if ( lcase$(argv(i)) = "-nostats" ) then
            g.env.no_stats = true
        end if
        if ( lcase$(argv(i)) = "-campath" ) then
            g.env.cam_path = true
        end if
        if ( lcase$(argv(i)) = "-nodraw" ) then
            g.env.no_draw  = true
            g.env.no_stats = true     '' the overlay is rasterising too
        end if
        if ( lcase$(argv(i)) = "-yaw" and i+1 <= argc-1 ) then
            g.env.start_yaw = val( argv(i+1) )
            g.env.yaw_set   = true
        end if
        if ( lcase$(argv(i)) = "-ticks" and i+1 <= argc-1 ) then
            g.env.bench_ticks = val( argv(i+1) )
        end if
        if ( lcase$(argv(i)) = "-dumptex" ) then
            g.env.dump_tex = true
        end if
        if ( lcase$(argv(i)) = "-lm" ) then
            g.env.use_lm = true
        end if
        if ( lcase$(argv(i)) = "-benchsecs" and i+1 <= argc-1 ) then
            g.env.bench_secs = val( argv(i+1) )
        end if
        if ( lcase$(argv(i)) = "-dumpsurf" and i+2 <= argc-1 ) then
            g.env.dump_set  = true
            g.env.dump_face = val( argv(i+1) )
            g.env.dump_mip  = val( argv(i+2) )
            g.env.use_lm    = true        '' the surface cache is the point
        end if
    next i

    if ( (dir$( rtrim$(g.env.map_name) ) = "") ) then
        print "File " + lcase$(rtrim$(g.env.map_name)) + " could not be found"
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
sub sys_init_tables ( _
    g as Game, _
    bit_array() as integer, _
    frustum() as DiskPlane _
)
    ''
    '' bitarray and frustum are COMMON now, and COMMON can only declare an
    '' array as name() -- with no elements. Both carried a real bound in their
    '' DIM, so they must be sized here or the first write is out of range.
    ''
    redim bit_array( 15 ) as integer
    redim frustum( 5 ) as DiskPlane

    dim i as integer

    com_parse_config g, "stuff.ini"
    
    for  i = 0 to 15
        bit_array(i) = clng(2^i)
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



''::::::::::
'' name: sys_time_init
'' desc: Starts the frame clock. Must run after tmrInit, which in_init does.
''::::::::::
sub sys_time_init
    dim hz as long
    dim t0 as single, elapsed as single
    dim c0 as long, c1 as long
    dim r0 as long, r1 as long

    hz = tmrMs2Freq&( 1 )
    tmrNew frame_tmr, TMR.AUTOINIT, hz

    ''
    '' Calibrate rather than trust the requested rate. Asking for 1 kHz and
    '' dividing by 1000 gave a dt about seven times too small, so the physics
    '' ran correctly but in slow motion: every speed in the game was in units
    '' per seven seconds. What the timer actually delivers depends on uGL and
    '' on the emulator underneath it, so measure it against the one clock DOS
    '' guarantees.
    ''
    '' TIMER is only accurate to 55ms, which is useless for a frame and ample
    '' over a quarter of a second.
    ''
    ''
    '' Align to a TIMER edge before starting, so the window begins on a tick
    '' rather than part way through one. It ends on a tick too, because the
    '' loop below exits the moment one lands -- which makes elapsed an exact
    '' multiple of the 55ms period instead of that plus an unknown fraction.
    '' Without this the same binary measured 142.9 Hz on one run and 148.1 on
    '' the next, and the game ran 4% faster on one of them.
    ''
    t0 = timer
    do
    loop until ( timer <> t0 )

    t0 = timer
    c0 = frame_tmr.counter
    r0 = sndDebugStat&( 6 )

    do
    loop until ( timer - t0 >= 0.5 )

    elapsed = timer - t0
    c1 = frame_tmr.counter
    r1 = sndDebugStat&( 6 )

    ''
    '' sndDebugStat(6) is __snd_tsc -- RDTSC, already declared in snd.bi
    '' and already linked (the mixer profiles itself with it), so this
    '' costs nothing new to the library. Calibrated in the SAME window as
    '' tick_hz, against the SAME TIMER-aligned reference, for the same
    '' reason: DOSBox ties RDTSC to cycles actually executed under the
    '' pinned `cycles=` setting, not wall-clock time, which is far more
    '' reproducible run to run than a real timer -- but "cycles per
    '' second" still depends on the emulator underneath, and asking would
    '' be the same mistake sys_frame_time's own note describes.
    ''
    if ( elapsed > 0.0 and r1 > r0 ) then
        rdtsc_hz = (r1 - r0) / elapsed
    else
        rdtsc_hz = 1.0
    end if

    ''
    '' A whole number, not a float division at read time. sys_rdtsc
    '' divides the raw counter by this with \, not /, so two calls a few
    '' hundred cycles apart give an EXACT microsecond delta -- no
    '' single-precision rounding on either reading to subtract away. It
    '' also shrinks the counter about 76x before anything is ever
    '' subtracted, which is most of the headroom that turns a ~28-second
    '' wraparound window into a ~35-minute one.
    ''
    cyc_per_us = clng( rdtsc_hz / 1000000.0 )
    if ( cyc_per_us < 1 ) then cyc_per_us = 1

    if ( elapsed > 0.0 and c1 > c0 ) then
        tick_hz = (c1 - c0) / elapsed
    else
        tick_hz = 1000.0
    end if

    last_tick = frame_tmr.counter
    timing_on = true

end sub




''::::::::::
'' name: sys_frame_time
'' desc: Seconds since the previous call. This is the step every time-dependent
''       update multiplies by, so that the game runs the same whatever the
''       framerate.
''
''       Clamped at both ends. Zero would freeze physics on a frame that
''       completed inside one tick; a large value would let one slow frame --
''       the first after loading, say -- move the player far enough to pass
''       through a wall, since the sweep is only as long as dt makes it.
''::::::::::
function sys_frame_time ( _
    g as Game _
) as single
    dim tick as long
    dim dt as single

    if ( timing_on = false ) then
        sys_frame_time = 1.0 / 60.0
        exit function
    end if

    tick = frame_tmr.counter
    dt  = (tick - last_tick) / tick_hz
    last_tick = tick

    if ( dt < 0.0    ) then dt = 1.0 / 60.0      '' counter wrapped

    ''
    '' The UNCLAMPED delta, for the benchmark. The clamps below exist to
    '' keep the simulation stable -- a 0.1s cap stops a long frame turning
    '' into a physics explosion -- but they destroy the measurement: every
    '' frame slower than 10fps reads as exactly 10fps, so the reported
    '' worst frame is the clamp rather than the renderer, and the reported
    '' best is one timer tick. Record the truth before flattening it.
    ''
    g.ft.raw_dt = dt

    if ( dt < 0.001  ) then dt = 0.001
    if ( dt > 0.1    ) then dt = 0.1

    sys_frame_time = dt

end function



''::::::::::
'' name: sys_tick_hz
'' desc: The measured tick rate, for the benchmark to report.
''::::::::::
function sys_tick_hz ( ) as single
    sys_tick_hz = tick_hz
end function

''::::::::::
'' name: sys_now
'' desc: Seconds on the same clock sys_frame_time reads, for timing a
''       PART of a frame rather than the whole of it -- take it before and
''       after, subtract. Not an absolute time (the epoch is whenever
''       sys_time_init ran) and not meant to be one; only deltas are ever
''       valid, and only ones short enough that frame_tmr.counter cannot
''       have wrapped, which at ~144 Hz on a long is effectively forever
''       for anything measured within one frame.
''::::::::::
function sys_now ( ) as single
    sys_now = frame_tmr.counter / tick_hz
end function

''::::::::::
'' name: sys_rdtsc
'' desc: Microseconds on the RDTSC clock, via sndDebugStat(6) -- NOT raw
''       cycles. The raw counter measured at ~76 million a second on this
''       machine, not "a few million" as first assumed, which wraps a
''       signed 32-bit long in about 28 seconds; a run that long or
''       longer under host contention (this project's own benchmarks
''       regularly run that long) hit it in practice, as a huge negative
''       delta the moment two readings straddled the sign bit. Dividing
''       by cyc_per_us -- calibrated once, alongside rdtsc_hz -- before
''       ever returning a value moves that wraparound out to roughly half
''       an hour, which nothing here runs anywhere near.
''
''       A separate, rarer glitch survives this: on a long run the raw
''       counter itself has been observed reading back near zero for one
''       call, unrelated to the sign wrap -- likely the dynamic core's own
''       RDTSC virtualization resetting on some internal event, not
''       anything BASIC-side arithmetic can correct. A caller taking a
''       difference between two calls must treat a negative or
''       wildly-oversized delta as a glitched sample and discard it,
''       exactly as sys_frame_time already does for frame_tmr wrapping.
''
''       Like sys_now, only ever meaningful as a difference between two
''       calls, never as a value on its own -- and like sys_now, calling
''       it before sys_time_init has calibrated cyc_per_us would divide
''       by whatever a fresh dim shared long defaults to, which the
''       clamp in sys_time_init exists specifically to keep off zero.
''::::::::::
function sys_rdtsc ( ) as long
    sys_rdtsc = sndDebugStat&( 6 ) \ cyc_per_us
end function

''::::::::::
'' name: sys_rdtsc_hz
'' desc: The calibrated rate sys_rdtsc counts at, for converting a delta
''       to seconds -- or for reporting cycles alongside milliseconds
''       without silently mixing units.
''::::::::::
function sys_rdtsc_hz ( ) as single
    sys_rdtsc_hz = rdtsc_hz
end function


''::::::::::
'' name: sys_mem_mark
'' desc: Records memAvail under a name. Called at each point in startup
''       that takes a bite out of conventional memory, so the bench report
''       can show what each one actually cost rather than what its struct
''       sizes suggest it should have.
''::::::::::
sub sys_mem_mark ( tag as string )
    if ( mem_n = 0 ) then
        redim mem_val( MEM_MARKS ) as long
        redim mem_fre( MEM_MARKS ) as long
        redim mem_tag( MEM_MARKS ) as string * 12
    end if
    if ( mem_n > MEM_MARKS ) then exit sub
    mem_tag( mem_n ) = tag
    mem_val( mem_n ) = memAvail&
    mem_fre( mem_n ) = fre( -1 )
    mem_n = mem_n + 1

    ''
    '' Also write it out NOW, opened and closed per mark.
    ''
    '' The array is dumped by host_bench_report at the end of a run, which
    '' is no use for the one question this trace exists to answer: where
    '' did the memory go when startup ran out of it? An OOM never reaches
    '' the report, and the handler cannot write one either -- it needs the
    '' memory it has just run out of. Both ERRMEM.TXT and ERROR.LOG come
    '' back zero bytes from a failed e1m1 load.
    ''
    '' A line per mark, flushed by the close, survives that. It costs an
    '' open and close per mark and there are twenty of them, all during
    '' startup, so nothing measurable.
    ''
    dim mf as integer
    mf = freefile
    open "memtrace.txt" for append as #mf
    print #mf, tag + " " + ltrim$(str$( mem_val( mem_n-1 ) )) + _
               " " + ltrim$(str$( mem_fre( mem_n-1 ) ))
    close #mf
end sub


'' How many memory marks have been taken.
function sys_mem_count ( ) as integer
    sys_mem_count = mem_n
end function

'' The label of mark i.
function sys_mem_tag ( byval i as integer ) as string
    sys_mem_tag = rtrim$( mem_tag( i ) )
end function

'' memAvail at mark i -- the largest free DOS block.
function sys_mem_val ( byval i as integer ) as long
    sys_mem_val = mem_val( i )
end function

'' FRE(-1) at mark i -- the far heap's largest free block, which fails first.
function sys_mem_fre ( byval i as integer ) as long
    sys_mem_fre = mem_fre( i )
end function
