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
