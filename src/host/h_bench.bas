option explicit
''
'' host_bench.bas -- writes bench.bmp/bench.txt at the end of a -bench
'' run. Split out of main.bas, which was chronically at BC's own
'' compile-time memory ceiling ("0 Bytes Free" on every successful
'' build, per its own "BC : Out of memory" trap documented in
'' CLAUDE.md) -- every diagnostic line added there was one line from
'' BCFAIL. Same fix as that file's own history: split on how rarely a
'' routine runs, not how it happens to relate to what stayed behind.
''
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'
'$include: 'qgl.bi'

declare sub host_kv ( _
    byval f as integer, _
    nm as string, _
    v as string _
)
declare function host_fmt3 ( byval v as single ) as string
declare sub host_pt_put ( _
    byval f as integer, _
    nm as string, _
    byval mn as single, _
    byval sum as single, _
    byval mx as single, _
    byval n as long, _
    byval scale as single _
)
declare function ent_place_stale ( _
    byval model_count as integer, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane, _
    brush() as BrushModel _
) as integer


declare function dbg_qgl_faces ( ) as integer
declare function dbg_qgl_drop ( ) as integer

'' scr_screenshot comes from q_game.bi above; everything below is
'' declared here rather than in a shared header because this is the
'' only caller of each -- narrowest scope, per this project's own rule.
declare function sc_selftest ( g as Game ) as integer
declare function ls_selftest () as integer
declare function sys_mem_count ( ) as integer
declare function sys_mem_fre ( byval i as integer ) as long
declare function sys_mem_tag ( byval i as integer ) as string
declare function sys_mem_val ( byval i as integer ) as long
declare function pl_hull_rec ( ) as integer
declare function sys_rdtsc_hz ( ) as single
declare function sys_tick_hz ( ) as single
'' qgl/mem.asm -- DOS's own numbers, not BASIC's. See the use site.
declare function qglMemAvail ( byval what as integer ) as long
declare function mod_cm_bytes ( g as Game ) as long
declare function mod_geom_rows ( g as Game ) as integer
declare function mod_lm_bytes ( g as Game ) as long
declare function mod_lm_got ( g as Game ) as long


''::::::::::
'' name: host_bench_report
'' desc: Writes bench.bmp and bench.txt at the end of a -bench run.
''
''       Called before vid_update, so the counters are still the frame's
''       own -- scr_count_frame clears them -- and h_dst_dc still holds
''       the finished image.
''::::::::::
sub host_bench_report ( _
    g as Game, _
    frame_no as long, _
    h_dst_dc as long, _
    brush() as BrushModel, _
    plat() as PlatEnt, _
    door() as DoorEnt, _
    trig() as TrigEnt, _
    mdl_ent() as MdlEnt, _
    byval host_ticks as long, _
    mon() as MdlState, _
    models() as Submodel, _
    nodes() as Node, _
    planes() as Plane _
)
    dim scs as CacheStats
    dim dv as long
    dim df as long
    dim ddv as long
    dim ddf as long
    dim mi as integer
    dim benchf as integer

    scr_screenshot g, "bench.bmp", h_dst_dc

    benchf = freefile
    open "bench.txt" for output as #benchf
    host_kv benchf, "frames", str$( frame_no )
    host_kv benchf, "seconds", str$( g.scr.bench_secs )
    host_kv benchf, "last_fps", str$( g.scr.fps )
    host_kv benchf, "peak_fps", str$( g.scr.fps_peak )
    host_kv benchf, "low_fps", str$( g.ft.fps_low )
    host_kv benchf, "cp_pts", str$( g.cp.n )
    ''
    '' Frame times in milliseconds, and the rates they imply. These are the
    '' numbers to compare: fastest frame, slowest frame, mean over the run.
    ''
    if ( g.ft.n > 0 ) then
        print #benchf, "ft_min " + host_fmt3( g.ft.min * 1000.0 )
        print #benchf, "ft_max " + host_fmt3( g.ft.max * 1000.0 )
        print #benchf, "ft_mean " + host_fmt3( (g.ft.sum / g.ft.n) * 1000.0 )
        host_kv benchf, "ft_n", str$( g.ft.n )
        if ( g.ft.min > 0.0 ) then _
            print #benchf, "fps_best " + host_fmt3( 1.0 / g.ft.min )
        if ( g.ft.max > 0.0 ) then _
            print #benchf, "fps_worst " + host_fmt3( 1.0 / g.ft.max )
        if ( g.ft.sum > 0.0 ) then _
            print #benchf, "fps_mean " + host_fmt3( g.ft.n / g.ft.sum )
        ''
        '' Where the frame went: min, mean and max in ms a frame, one line
        '' each. pt_tk_* are host_tick's calls in ms a TICK, over the ticks
        '' timed. PhaseTimes in q_scr.bi says what each phase covers.
        ''
        host_pt_put benchf, "pt_tick", g.pt.tick_min, g.pt.tick_sum, g.pt.tick_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_cull", g.pt.cull_min, g.pt.cull_sum, g.pt.cull_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_draw", g.pt.draw_min, g.pt.draw_sum, g.pt.draw_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_build", g.pt.build_min, g.pt.build_sum, g.pt.build_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_hud", g.pt.hud_min, g.pt.hud_sum, g.pt.hud_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_present", g.pt.present_min, g.pt.present_sum, g.pt.present_max, g.pt.present_n, 1000.0
        host_pt_put benchf, "pt_mark", g.pt.mark_min, g.pt.mark_sum, g.pt.mark_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_walk", g.pt.walk_min, g.pt.walk_sum, g.pt.walk_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_mdl", g.pt.mdl_min, g.pt.mdl_sum, g.pt.mdl_max, g.ft.n, 1000.0
        host_pt_put benchf, "pt_loop", g.pt.loop_min, g.pt.loop_sum, g.pt.loop_max, g.pt.loop_n, 1000.0
        host_kv benchf, "rdtsc_hz", str$( sys_rdtsc_hz() )
        host_kv benchf, "portal_culled", str$( g.vis.pt_culled )
        print #benchf, "mtri_per_frame " + host_fmt3( g.pt.mtri_n / g.ft.n )
        host_pt_put benchf, "pt_tk_cam", g.pt.tk_cam.lo, g.pt.tk_cam.sum, g.pt.tk_cam.hi, g.pt.tk_cam.n, 0.001
        host_pt_put benchf, "pt_tk_fire", g.pt.tk_fire.lo, g.pt.tk_fire.sum, g.pt.tk_fire.hi, g.pt.tk_fire.n, 0.001
        host_pt_put benchf, "pt_tk_nails", g.pt.tk_nails.lo, g.pt.tk_nails.sum, g.pt.tk_nails.hi, g.pt.tk_nails.n, 0.001
        host_pt_put benchf, "pt_tk_items", g.pt.tk_items.lo, g.pt.tk_items.sum, g.pt.tk_items.hi, g.pt.tk_items.n, 0.001
        host_pt_put benchf, "pt_tk_think", g.pt.tk_think.lo, g.pt.tk_think.sum, g.pt.tk_think.hi, g.pt.tk_think.n, 0.001
        host_pt_put benchf, "pt_tk_tele", g.pt.tk_tele.lo, g.pt.tk_tele.sum, g.pt.tk_tele.hi, g.pt.tk_tele.n, 0.001
        host_pt_put benchf, "pt_tk_plats", g.pt.tk_plats.lo, g.pt.tk_plats.sum, g.pt.tk_plats.hi, g.pt.tk_plats.n, 0.001
        host_pt_put benchf, "pt_tk_doors", g.pt.tk_doors.lo, g.pt.tk_doors.sum, g.pt.tk_doors.hi, g.pt.tk_doors.n, 0.001
        host_pt_put benchf, "pt_tk_trigs", g.pt.tk_trigs.lo, g.pt.tk_trigs.sum, g.pt.tk_trigs.hi, g.pt.tk_trigs.n, 0.001
        host_pt_put benchf, "pt_tk_traps", g.pt.tk_traps.lo, g.pt.tk_traps.sum, g.pt.tk_traps.hi, g.pt.tk_traps.n, 0.001
        host_pt_put benchf, "pt_tk_ls", g.pt.tk_ls.lo, g.pt.tk_ls.sum, g.pt.tk_ls.hi, g.pt.tk_ls.n, 0.001
        host_pt_put benchf, "pt_md_mon", g.pt.md_mon.lo, g.pt.md_mon.sum, g.pt.md_mon.hi, g.pt.md_mon.n, 0.001
        host_pt_put benchf, "pt_md_item", g.pt.md_item.lo, g.pt.md_item.sum, g.pt.md_item.hi, g.pt.md_item.n, 0.001
        host_pt_put benchf, "pt_md_nail", g.pt.md_nail.lo, g.pt.md_nail.sum, g.pt.md_nail.hi, g.pt.md_nail.n, 0.001
        host_pt_put benchf, "pt_md_view", g.pt.md_view.lo, g.pt.md_view.sum, g.pt.md_view.hi, g.pt.md_view.n, 0.001
        host_pt_put benchf, "pt_d_geom", g.pt.d_geom.lo, g.pt.d_geom.sum, g.pt.d_geom.hi, g.pt.d_geom.n, 0.001
        host_pt_put benchf, "pt_d_xf", g.pt.d_xf.lo, g.pt.d_xf.sum, g.pt.d_xf.hi, g.pt.d_xf.n, 0.001
        host_pt_put benchf, "pt_d_lm", g.pt.d_lm.lo, g.pt.d_lm.sum, g.pt.d_lm.hi, g.pt.d_lm.n, 0.001
        host_pt_put benchf, "pt_d_tex", g.pt.d_tex.lo, g.pt.d_tex.sum, g.pt.d_tex.hi, g.pt.d_tex.n, 0.001
        host_pt_put benchf, "pt_d_rast", g.pt.d_rast.lo, g.pt.d_rast.sum, g.pt.d_rast.hi, g.pt.d_rast.n, 0.001
    end if
    g.pt.place_stale = ent_place_stale( g.wld.count.models, models(), nodes(), planes(), brush() )
    host_kv benchf, "place_stale", str$( g.pt.place_stale )
    host_kv benchf, "polys", str$( g.rdr.polys )
    host_kv benchf, "mdl_drawn", str$( g.mdl_drawn )
    print #benchf, "map " + lcase$( rtrim$( g.env.map_name ) )
    host_kv benchf, "gs_state", str$( g.fight.state )
    host_kv benchf, "pl_health", str$( g.fight.health )
    host_kv benchf, "pl_shells", str$( g.fight.shells )
    host_kv benchf, "pl_kills", str$( g.fight.kills )
    host_kv benchf, "pl_leaps", str$( g.fight.leaps )
    host_kv benchf, "pl_secrets", str$( g.fight.secrets )
    host_kv benchf, "pl_armor", str$( g.fight.armor )
    host_kv benchf, "pl_weapon", str$( g.fight.weapon )
    host_kv benchf, "pl_items", str$( g.fight.items )
    host_kv benchf, "pl_nails", str$( g.fight.nails )
    host_kv benchf, "pl_rockets", str$( g.fight.rockets )
    host_kv benchf, "pl_quad_left", str$( g.fight.quad_until - g.rdr.anim_time )
    host_kv benchf, "pl_pent_left", str$( g.fight.pent_until - g.rdr.anim_time )
    host_kv benchf, "pl_booms", str$( g.fight.booms )
    host_kv benchf, "snd_loops", str$( g.snd.loops )
    host_kv benchf, "pl_deaths", str$( g.fight.deaths )
    '' the crowd, one line each: kind state hunting frame x y z
    for mi = 0 to g.mdl_count - 1
        print #benchf, "ent" + ltrim$(str$( mi )) + " " + ltrim$(str$( mdl_ent(mi).kind )) + " " + ltrim$(str$( mdl_ent(mi).state )) + " " + _
            ltrim$(str$( mdl_ent(mi).hunting )) + " " + ltrim$(str$( mdl_ent(mi).anim_frame )) + " " + _
            ltrim$(str$( mdl_ent(mi).pos.x )) + " " + ltrim$(str$( mdl_ent(mi).pos.y )) + " " + ltrim$(str$( mdl_ent(mi).pos.z ))
    next mi
    host_kv benchf, "tris", str$( g.rdr.tris )
    host_kv benchf, "qgl_faces", str$( dbg_qgl_faces() )
    host_kv benchf, "qgl_drop", str$( dbg_qgl_drop() )
    host_kv benchf, "px", str$( g.pl.pos.x )
    host_kv benchf, "py", str$( g.pl.pos.y )
    host_kv benchf, "pz", str$( g.pl.pos.z )
    host_kv benchf, "on_ground", str$( g.pl.on_ground )
    host_kv benchf, "vz", str$( g.pl.vel.z )
    host_kv benchf, "dt", str$( g.scr.frame_time )
    host_kv benchf, "tick_hz", str$( sys_tick_hz )
    '' Asked of DOS, not BASIC: mgl's memAvail returned MAX(largest free
    '' block, BASIC's far-heap SIZE), a heap's extent rather than its free
    '' space -- a live MCB walk once found 9,312 bytes free where it said
    '' ~260,000. qgl_avail is what an allocation can actually get;
    '' qgl_free_sum is every free block added up, so the gap between the
    '' two is the fragmentation.
    host_kv benchf, "qgl_avail", str$( qglMemAvail&( QGL_MEM_LARGEST ) )
    host_kv benchf, "qgl_free_sum", str$( qglMemAvail&( QGL_MEM_TOTAL ) )
    host_kv benchf, "lm_size", str$( mod_lm_bytes( g ) )
    host_kv benchf, "lm_read", str$( mod_lm_got( g ) )
    host_kv benchf, "geom_rows", str$( mod_geom_rows( g ) )
    host_kv benchf, "cm_size", str$( mod_cm_bytes( g ) )
        sc_stats scs
    host_kv benchf, "sc_made", str$( scs.made )
    host_kv benchf, "sc_ems", str$( scs.peak )
    ''
    '' Cache behaviour. scworst is the most surfaces built in any ONE
    '' frame, which is what a hitch is made of -- a run-wide total says
    '' nothing about whether they arrived together or spread out.
    ''
    host_kv benchf, "sc_built", str$( scs.total_builds )
    host_kv benchf, "sc_dlit", str$( scs.dlit )
    host_kv benchf, "sc_worst", str$( scs.bpeak )
    host_kv benchf, "sc_live", str$( scs.live )
    host_kv benchf, "sc_evict", str$( scs.evict )
    host_kv benchf, "sc_flush", str$( scs.flushes )
    host_kv benchf, "sc_test", str$( sc_selftest( g ) )
    host_kv benchf, "ls_test", str$( ls_selftest() )
    host_kv benchf, "peak_z", str$( g.pl.peak_z )
    host_kv benchf, "ticks", str$( host_ticks )
    ''
    '' Where conventional memory went. Deltas, not absolutes: what matters
    '' is which stage took the bite, and a running total drifts with DOS's
    '' own overhead between the marks.
    ''
    for mi = 0 to sys_mem_count-1
        dv = sys_mem_val(mi)
        df = sys_mem_fre(mi)
        if ( mi = 0 ) then
            ddv = 0
            ddf = 0
        else
            ddv = sys_mem_val(mi-1) - dv
            ddf = sys_mem_fre(mi-1) - df
        end if
        print #benchf, "mem " + sys_mem_tag(mi) + _
                       " " + ltrim$(str$( dv )) + " " + ltrim$(str$( ddv )) + _
                       " " + ltrim$(str$( df )) + " " + ltrim$(str$( ddf ))
    next mi
    host_kv benchf, "clp_rec", str$( pl_hull_rec )
    host_kv benchf, "clp_cnt", str$( g.wld.count.clips )
    host_kv benchf, "water_level", str$( g.pl.water_level )
    host_kv benchf, "water_type", str$( g.pl.water_type )
    host_kv benchf, "anim_time", str$( g.rdr.anim_time )
    host_kv benchf, "door_count", str$( g.door_count )
    for  mi = 0 to g.door_count-1
        print #benchf, "door_" + ltrim$(str$( mi )) + " " + ltrim$(str$( door(mi).model )) + " " + _
            ltrim$(str$( door(mi).state )) + " " + ltrim$(str$( brush( door(mi).model ).ofs.x )) + " " + _
            ltrim$(str$( brush( door(mi).model ).ofs.y )) + " " + ltrim$(str$( brush( door(mi).model ).ofs.z ))
    next mi
    host_kv benchf, "trig_count", str$( g.trig_count )
    for  mi = 0 to g.trig_count-1
        print #benchf, "trig_" + ltrim$(str$( mi )) + " " + ltrim$(str$( trig(mi).model )) + " " + _
            ltrim$(str$( trig(mi).kind )) + " " + ltrim$(str$( trig(mi).state )) + " " + ltrim$(str$( trig(mi).left ))
    next mi
    if ( g.plat_count > 0 ) then
        host_kv benchf, "plat_zofs", str$( brush( plat(0).model ).ofs.z )
        host_kv benchf, "plat_state", str$( plat(0).state )
    end if
    for  mi = 0 to g.plat_count-1
        print #benchf, "plat_" + ltrim$(str$( mi )) + " " + ltrim$(str$( plat(mi).model )) + " " + _
            ltrim$(str$( plat(mi).kind )) + " " + ltrim$(str$( plat(mi).state )) + " " + _
            ltrim$(str$( brush( plat(mi).model ).ofs.x )) + " " + ltrim$(str$( brush( plat(mi).model ).ofs.y )) + " " + _
            ltrim$(str$( brush( plat(mi).model ).ofs.z ))
    next mi
    close #benchf

end sub


'' The first timed frame: every min starts past anything a timer reads.
sub host_pt_init ( g as Game )
    g.pt.tick_min = 1E+09
    g.pt.cull_min = 1E+09
    g.pt.draw_min = 1E+09
    g.pt.hud_min = 1E+09
    g.pt.mdl_min = 1E+09
    g.pt.loop_min = 1E+09
    g.pt.build_min = 1E+09
    g.pt.present_min = 1E+09
    g.pt.mark_min = 1E+09
    g.pt.walk_min = 1E+09
    g.pt.tk_cam.lo = 1E+09
    g.pt.tk_fire.lo = 1E+09
    g.pt.tk_nails.lo = 1E+09
    g.pt.tk_items.lo = 1E+09
    g.pt.tk_think.lo = 1E+09
    g.pt.tk_tele.lo = 1E+09
    g.pt.tk_plats.lo = 1E+09
    g.pt.tk_doors.lo = 1E+09
    g.pt.tk_trigs.lo = 1E+09
    g.pt.tk_traps.lo = 1E+09
    g.pt.tk_ls.lo = 1E+09
    g.pt.md_mon.lo = 1E+09
    g.pt.md_item.lo = 1E+09
    g.pt.md_nail.lo = 1E+09
    g.pt.md_view.lo = 1E+09
    g.pt.d_geom.lo = 1E+09
    g.pt.d_xf.lo = 1E+09
    g.pt.d_lm.lo = 1E+09
    g.pt.d_tex.lo = 1E+09
    g.pt.d_rast.lo = 1E+09
end sub

'' One 'name value' line. The caller's str$ keeps each type's own format.
sub host_kv ( _
    byval f as integer, _
    nm as string, _
    v as string _
)
    print #f, nm + " " + ltrim$( v )
end sub

'' v rounded to three decimals at most, as text.
function host_fmt3 ( byval v as single ) as string
    dim r as long, s as string
    r = clng( abs( v ) * 1000.0 )
    s = ltrim$( str$( r \ 1000 ) ) + "." + right$( "00" + ltrim$( str$( r mod 1000 ) ), 3 )
    if ( v < 0.0 and r > 0 ) then s = "-" + s
    host_fmt3 = s
end function

'' One timer's line: name, then min, mean and max, each times scale. A
'' min never sampled still holds host_pt_init's sentinel and reads 0.
sub host_pt_put ( _
    byval f as integer, _
    nm as string, _
    byval mn as single, _
    byval sum as single, _
    byval mx as single, _
    byval n as long, _
    byval scale as single _
)
    if ( n < 1 ) then n = 1
    if ( mn >= 1E+09 ) then mn = 0.0
    print #f, nm + " " + host_fmt3( mn * scale ) + " " + host_fmt3( sum / n * scale ) + " " + host_fmt3( mx * scale )
end sub
