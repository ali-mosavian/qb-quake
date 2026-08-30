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

''
'' Where a frame's time actually goes, not just how long the whole of it
'' took -- ft above answers "is a frame slow," this answers "which part."
'' sum/max per phase rather than min: a phase's best case is not
'' actionable the way its typical and worst cases are, and FrameTimes'
'' own min is used for exactly the frame-level version of that same call.
''
'' No count of its own: every phase is gated on the SAME condition
'' FrameTimes' own accumulation already uses (past the load-tail warmup),
'' so ft.n is exactly how many samples each sum below represents too --
'' keeping a second counter in lockstep with it would just be one more
'' place for the two to drift apart.
''
'' tick, cull, draw, hud and present are each measured exactly once per
'' rendered frame -- host_advance may run several simulation steps inside
'' "tick," but the phase is timed as the one call that runs them all, not
'' per step.
''
'' Deliberately not everything in the frame: uglClear, sys_frame_time's
'' own read, screenshot-key polling and scr_count_frame's bookkeeping are
'' all cheap enough that timing them would cost more than they take.
''
type PhaseTimes
    tick_sum    as single     '' host_advance: simulation
    tick_max    as single
    cull_sum    as single     '' r_set_frustum + r_draw_world: BSP walk
    cull_max    as single
    draw_sum    as single     '' d_draw_faces: cache lookup, builds, AND
    draw_max    as single     '' raster together -- see raster_sum below
    hud_sum     as single     '' scr_draw_hud: the stats overlay
    hud_max     as single
    present_sum as single     '' vid_update: blit to the screen
    present_max as single

    ''
    '' Nested inside draw, not subtracted from it: draw_sum is measured by
    '' sys_now around the whole of d_draw_faces, on the same ~144 Hz clock
    '' as every other phase here, so every phase's mean stays comparable
    '' against ft_mean. raster_sum is measured by sys_rdtsc, per face,
    '' summed across the frame -- the individual calls are far under that
    '' clock's ~6.9ms resolution, which is the whole reason it needs
    '' RDTSC rather than reusing sys_now here too. draw_sum - raster_sum
    '' is everything else in d_draw_faces: cache lookup and, on a miss,
    '' sb_build.
    ''
    raster_sum  as single
    raster_max  as single

    ''
    '' Nested inside raster, not subtracted from it: mod_tex_shaded's own
    '' uglSetView call, when the atlas cell it wants is not the one its
    '' view is already aimed at -- the one place in the raster loop that
    '' touches the atlas's EMS mapping rather than drawing pixels. Most
    '' calls are a no-op (same cell as last face), so like raster and
    '' build this needs sys_rdtsc, not sys_now. raster_sum - aim_sum is
    '' the triangle mappers themselves.
    ''
    aim_sum     as single
    aim_max     as single

    ''
    '' Also nested inside draw, sibling to raster_sum: sc_alloc plus, on a
    '' miss, sb_build -- the rebuild path sc_find's own lookup skips. Only
    '' a few faces rebuild in a given frame, so like raster this needs
    '' sys_rdtsc rather than sys_now: most frames' build cost is a small
    '' fraction of one ~6.9ms tick. draw_sum - raster_sum - build_sum is
    '' what is left: sc_held/sc_find lookups and per-face UV setup.
    ''
    build_sum   as single
    build_max   as single

    ''
    '' Also nested inside draw, but NOT real draw work: r_span.c, an
    '' investigative prototype that resolves the same frame's polygons
    '' into a Quake-style global edge list -> sorted span list,
    '' alongside the real raster path, purely to measure the cost -- it
    '' draws nothing and changes nothing about what is drawn. emit_sum
    '' is r_span_emit_poly, called once per face like aim/build above;
    '' span_sum is r_span_flush, called once per frame after the loop.
    '' Both run inside d_draw_faces, so draw_sum's own wall clock
    '' already includes them the same way it includes raster/build/aim
    '' -- which means anyone computing "what draw_sum spends outside
    '' raster/build/aim" has to subtract these two as well, or that
    '' residual reads as inflated by a prototype that is not part of
    '' the real frame at all. Likewise for ft_mean against a build that
    '' predates this file.
    ''
    emit_sum    as single
    emit_max    as single
    span_sum    as single
    span_max    as single

    ''
    '' Nested inside cull, not subtracted from it, same reasoning as
    '' draw/raster above: cull_sum times r_set_frustum plus the whole of
    '' r_draw_world, and these two time r_draw_world's own two phases on
    '' the same sys_now clock, so they read directly against cull_sum.
    '' mark is r_mark_leaves (PVS extract -- usually one exit test, a
    '' real cost only the frame the camera crosses into a new leaf); walk
    '' is r_recursive_world_node, the tree traversal, which runs in full
    '' every frame regardless. cull_sum - mark_sum - walk_sum is frustum
    '' extraction and the two lookat/concat matrix builds.
    ''
    mark_sum    as single
    mark_max    as single
    walk_sum    as single
    walk_max    as single
end type

'' The path itself stays loose: arrays cannot be TYPE members.

''
'' screen.bas. Declared here: these name ScreenState and friends.
''

''
'' Procedures whose signatures can be read from here.
''
