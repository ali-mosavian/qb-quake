''
'' The overlay: what the HUD reports.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' The simulation runs at a fixed rate no matter what the renderer manages.
'' 60 Hz is Quake's, and small enough that a 270 unit jump is not resolved
'' into a handful of coarse hops.
''
const HOST_DT#       = 0.0166666

''
'' The most steps one frame may run. Without a cap, a frame that took
'' longer than HOST_DT to draw asks for more than one step, those steps
'' make the next frame slower still, and the accumulator runs away -- the
'' spiral of death. At the cap the simulation simply runs slow, which is
'' survivable, instead of stopping altogether, which is not.
''
const HOST_MAXSTEPS  = 5

type ScreenState
    fps         as integer      '' last completed second's frame count
    stats       as integer      '' overlay toggle
    bench_secs  as integer      '' seconds elapsed, for -bench
    frame_time  as single       '' seconds the last frame took; the physics
                                '' step. Derived from fps, so it self-tunes
                                '' and does not need a finer clock than DOS
                                '' has -- TIMER only ticks every 55ms, which
                                '' is coarser than a frame.
end type

common shared /scr_s/ scr as ScreenState
