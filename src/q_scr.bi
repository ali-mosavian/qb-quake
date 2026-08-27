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
    fps_peak    as integer      '' best second seen this run. The LAST
                                '' second is not the interesting one -- a
                                '' bench ends wherever it ends, and the
                                '' figure that characterises a build is the
                                '' best it reached, not where it stopped.
    stats       as integer      '' overlay toggle
    bench_secs  as integer      '' seconds elapsed, for -bench
    frame_time  as single       '' seconds the last frame took; the physics
                                '' step. Derived from fps, so it self-tunes
                                '' and does not need a finer clock than DOS
                                '' has -- TIMER only ticks every 55ms, which
                                '' is coarser than a frame.
end type

common shared /scr_s/ scr as ScreenState

''
'' The benchmark flight path (tools/campath.py, A* over the map's EMPTY
'' leaves -- water, slime and lava excluded). cp_n = 0 means no path.
''
'' cp_t advances a FIXED amount PER FRAME, not per second. That is the
'' whole point: both builds then render the identical sequence of
'' viewpoints, so frame counts, peak and low describe the renderer rather
'' than how far a faster build happened to travel.
''
const CP_MAX  = 512   '' smoothing multiplies the A* waypoints ~4x
''
'' Units travelled per FRAME. A fixed distance, not a fixed fraction of a
'' segment: waypoints are not evenly spaced, so stepping by fraction made
'' the camera crawl through short hops and leap across long ones.
''
'' 6 units, not a running speed. This is per frame and the renderer manages
'' about 15 of them a second, so 24 units/frame was 360 units/sec -- full
'' Quake sprint, sampled 15 times a second. Every visible frame jumped a
'' third of a corridor, which reads as teleporting however smooth the
'' underlying motion is. The camera trace was perfectly even at 24; the
'' problem was never the path.
''
'' Slower also samples better: the same route yields ~400 frames instead
'' of ~100, so the mean frame time rests on four times the evidence.
''
'' How close, horizontally, counts as reaching a waypoint.
''
'' SMALLER than the 32-unit grid the waypoints sit on. At 48 the player
'' could tick off the next waypoint while still well off the route, so it
'' cut corners, drifted into walls and stuck. Following tightly matters
'' more than following smoothly: each segment is verified walkable, the
'' straight line between two distant ones is not.
const CP_REACH = 12.0
''
'' Steer toward a waypoint at least this far ahead, not the next one.
''
'' Aiming at the nearest target is what makes a follower wobble: as you
'' close on a point the bearing to it swings through large angles for
'' small movements, so the facing jitters and the walk weaves. Picking a
'' target further along -- pure pursuit -- gives a bearing that changes
'' slowly and smoothly. 64 units is about two seconds of walking here.
''
const CP_AHEAD = 64.0
''
'' How far ahead the camera looks, in units along the path, and how
'' quickly the view turns toward it.
''
'' Aiming at the NEXT WAYPOINT was what made the flythrough lurch: the
'' waypoints are not evenly spaced -- 8 units in a doorway, 500 across a
'' hall -- so in a tight cluster the aim point changed every frame and the
'' view snapped around, then locked onto something half a room away. A
'' point a fixed distance ahead moves smoothly whatever the spacing, and
'' easing toward it removes what is left.
''
const CP_LOOKAHEAD = 160.0
'' Turn rate PER SECOND, scaled by dt. Per-frame easing meant the camera
'' turned at a rate that depended on the frame rate -- faster where the
'' renderer was quick, slower where it struggled, which is backwards.
const CP_TURN = 4.0
type CamPath
    n           as integer    '' points in the path
    i           as integer    '' the point being walked toward
    t           as single     '' seconds spent on this leg
    dir_x       as single     '' steering direction, carried between ticks
    dir_y       as single
    last_x      as single     '' previous position, for the stuck test
    last_y      as single
    stuck       as integer
    started     as integer
    look_x      as single     '' eased aim point, CP_LOOKAHEAD ahead
    look_y      as single
    done        as integer
end type

''
'' Per-FRAME timing. bench_secs counts whole seconds, so on a 143 frame
'' run it yields ten samples, drops the final partial second, and reports
'' a peak and a low quantised to whatever happened to fall either side of
'' a second boundary. Frame times measure the thing directly.
''
type FrameTimes
    min         as single
    max         as single
    sum         as single
    n           as long
    fps_low     as integer
    raw_dt      as single     '' this frame's dt, before the clamps
end type

'' The path itself stays loose: arrays cannot be TYPE members.
common shared /scr_s/ cp_x() as integer, cp_y() as integer, cp_z() as integer
common shared /scr_s/ cp as CamPath
common shared /scr_s/ ft as FrameTimes

''
'' screen.bas. Declared here: these name ScreenState and friends.
''
declare sub scr_count_frame ( _
    env as Env, _
    scr as ScreenState, _
    rdr as RenderState _
)
declare sub scr_draw_hud ( _
    h_dst_dc as long, _
    env as Env, _
    scr as ScreenState, _
    rdr as RenderState, _
    vis as VisState, _
    wld as World _
)
