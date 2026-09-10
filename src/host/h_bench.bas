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

declare function rb_dbg_camleaf ( ) as integer
declare function rb_dbg_pvscnt ( ) as integer

declare function dbg_lm_want ( ) as integer
declare function dbg_lm_fall ( ) as integer
declare function dbg_qgl_faces ( ) as integer
declare function dbg_qgl_drop ( ) as integer
declare function dbg_keys ( byval which as integer ) as long

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
'' drawPoly_tp2d QR_PROFILE counters (uglplxtp.asm). All five read 0
'' in a uglv.lib that was not built with QR_PROFILE defined.
declare function qrProfRdAccess ( ) as long
declare function qrProfWrBegin ( ) as long
declare function qrProfWSwitchSum ( ) as long
declare function qrProfWSwitchCnt ( ) as long
declare function qrProfPolyCnt ( ) as long
declare function qrProfFillSum ( ) as long
declare function qrProfScanCnt ( ) as long
declare function qrProfOuterSum ( ) as long
declare function qrProfZSetSum ( ) as long
declare function qrProfEdgeSum ( ) as long
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
    byval host_ticks as long _
)
    dim scs as CacheStats
    dim dv as long
    dim df as long
    dim ddv as long
    dim ddf as long
    dim mi as integer
    dim benchf as integer
    dim qr_hz as single, qr_ms_per_cyc as single

    scr_screenshot g, "bench.bmp", h_dst_dc

    benchf = freefile
    open "bench.txt" for output as #benchf
    print #benchf, "frames " + ltrim$(str$( frame_no ))
    print #benchf, "seconds " + ltrim$(str$( g.scr.bench_secs ))
    print #benchf, "last_fps " + ltrim$(str$( g.scr.fps ))
    print #benchf, "peak_fps " + ltrim$(str$( g.scr.fps_peak ))
    print #benchf, "low_fps " + ltrim$(str$( g.ft.fps_low ))
    print #benchf, "cp_pts " + ltrim$(str$( g.cp.n ))
    ''
    '' Frame times in milliseconds, and the rates they imply. These are the
    '' numbers to compare: fastest frame, slowest frame, mean over the run.
    ''
    if ( g.ft.n > 0 ) then
        print #benchf, "ft_min " + ltrim$(str$( g.ft.min * 1000.0 ))
        print #benchf, "ft_max " + ltrim$(str$( g.ft.max * 1000.0 ))
        print #benchf, "ft_mean " + ltrim$(str$( (g.ft.sum / g.ft.n) * 1000.0 ))
        print #benchf, "ft_n " + ltrim$(str$( g.ft.n ))
        if ( g.ft.min > 0.0 ) then _
            print #benchf, "fps_best " + ltrim$(str$( 1.0 / g.ft.min ))
        if ( g.ft.max > 0.0 ) then _
            print #benchf, "fps_worst " + ltrim$(str$( 1.0 / g.ft.max ))
        if ( g.ft.sum > 0.0 ) then _
            print #benchf, "fps_mean " + ltrim$(str$( g.ft.n / g.ft.sum ))
        ''
        '' Where the frame above actually went. Same milliseconds, same
        '' g.ft.n sample count -- pt_tick_mean + pt_cull_mean + pt_draw_mean
        '' + pt_hud_mean + pt_present_mean should land close to ft_mean;
        '' the gap is whatever this pass did not bother to time (see
        '' PhaseTimes in q_scr.bi for exactly what that is).
        ''
        print #benchf, "pt_tick_mean " + ltrim$(str$( (g.pt.tick_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_tick_max " + ltrim$(str$( g.pt.tick_max * 1000.0 ))
        print #benchf, "pt_cull_mean " + ltrim$(str$( (g.pt.cull_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_cull_max " + ltrim$(str$( g.pt.cull_max * 1000.0 ))
        print #benchf, "pt_draw_mean " + ltrim$(str$( (g.pt.draw_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_draw_max " + ltrim$(str$( g.pt.draw_max * 1000.0 ))
        print #benchf, "pt_hud_mean " + ltrim$(str$( (g.pt.hud_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_hud_max " + ltrim$(str$( g.pt.hud_max * 1000.0 ))
        print #benchf, "pt_present_mean " + ltrim$(str$( (g.pt.present_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_present_max " + ltrim$(str$( g.pt.present_max * 1000.0 ))
        ''
        '' Nested inside pt_draw, not subtracted from it -- see PhaseTimes
        '' in q_scr.bi. pt_draw_mean minus these two is cache lookup and
        '' per-face UV setup: whatever neither rebuilding nor rasterising
        '' accounts for.
        ''
        print #benchf, "pt_raster_mean " + ltrim$(str$( (g.pt.raster_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_raster_max " + ltrim$(str$( g.pt.raster_max * 1000.0 ))
        ''
        '' Nested inside pt_raster, not subtracted from it -- see
        '' PhaseTimes. pt_raster_mean minus this is the triangle mappers.
        ''
        print #benchf, "pt_aim_mean " + ltrim$(str$( (g.pt.aim_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_aim_max " + ltrim$(str$( g.pt.aim_max * 1000.0 ))
        print #benchf, "pt_build_mean " + ltrim$(str$( (g.pt.build_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_build_max " + ltrim$(str$( g.pt.build_max * 1000.0 ))
        qr_hz = sys_rdtsc_hz()
        print #benchf, "rdtsc_hz " + ltrim$(str$( qr_hz ))
        ''
        '' QR_PROFILE: raw TSC cycle sums from inside drawPoly_tp2d itself
        '' (see uglplxtp.asm), converted here the same way sys_rdtsc's own
        '' callers do -- there is no cyc_per_us inside the assembly, only
        '' the raw counter, so the division happens once, on the way out,
        '' against this same run's own rdtsc_hz. All five read 0 in a
        '' uglv.lib that was not built with QR_PROFILE defined.
        ''
        if ( qr_hz > 0.0 ) then
            qr_ms_per_cyc = 1000.0 / qr_hz
        else
            qr_ms_per_cyc = 0.0
        end if
        print #benchf, "qr_poly_cnt " + ltrim$(str$( qrProfPolyCnt() ))
        print #benchf, "qr_rdaccess_ms " + ltrim$(str$( qrProfRdAccess() * qr_ms_per_cyc ))
        print #benchf, "qr_wrbegin_ms " + ltrim$(str$( qrProfWrBegin() * qr_ms_per_cyc ))
        print #benchf, "qr_wswitch_ms " + ltrim$(str$( qrProfWSwitchSum() * qr_ms_per_cyc ))
        print #benchf, "qr_wswitch_cnt " + ltrim$(str$( qrProfWSwitchCnt() ))
        print #benchf, "qr_fill_ms " + ltrim$(str$( qrProfFillSum() * qr_ms_per_cyc ))
        print #benchf, "qr_scan_cnt " + ltrim$(str$( qrProfScanCnt() ))
        print #benchf, "qr_outer_ms " + ltrim$(str$( qrProfOuterSum() * qr_ms_per_cyc ))
        print #benchf, "qr_zset_ms " + ltrim$(str$( qrProfZSetSum() * qr_ms_per_cyc ))
        print #benchf, "qr_edge_ms " + ltrim$(str$( qrProfEdgeSum() * qr_ms_per_cyc ))
        ''
        '' Nested inside pt_cull, not subtracted from it -- see PhaseTimes
        '' in q_scr.bi. pt_cull_mean minus these two is frustum extraction
        '' and the two lookat/concat matrix builds.
        ''
        print #benchf, "pt_mark_mean " + ltrim$(str$( (g.pt.mark_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_mark_max " + ltrim$(str$( g.pt.mark_max * 1000.0 ))
        print #benchf, "portal_culled " + ltrim$(str$( g.vis.pt_culled ))
        print #benchf, "pt_walk_mean " + ltrim$(str$( (g.pt.walk_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_walk_max " + ltrim$(str$( g.pt.walk_max * 1000.0 ))
        print #benchf, "pt_mdl_mean " + ltrim$(str$( (g.pt.mdl_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_mdl_max " + ltrim$(str$( g.pt.mdl_max * 1000.0 ))
        print #benchf, "pt_loop_mean " + ltrim$(str$( (g.pt.loop_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_loop_max " + ltrim$(str$( g.pt.loop_max * 1000.0 ))
        print #benchf, "mtri_per_frame " + ltrim$(str$( g.pt.mtri_n / g.ft.n ))
    end if
    print #benchf, "polys " + ltrim$(str$( g.rdr.polys ))
    print #benchf, "mdl_drawn " + ltrim$(str$( g.mdl.drawn ))
    print #benchf, "vmdl_loaded " + ltrim$(str$( g.vmdl.loaded ))
    print #benchf, "kmdl_loaded " + ltrim$(str$( g.kmdl.loaded ))
    print #benchf, "pl_health " + ltrim$(str$( g.fight.health ))
    print #benchf, "pl_kills " + ltrim$(str$( g.fight.kills ))
    print #benchf, "pl_deaths " + ltrim$(str$( g.fight.deaths ))
    '' the crowd, one line each: kind state hunting frame x y z
    for mi = 0 to g.mdl_count - 1
        print #benchf, "ent" + ltrim$(str$( mi )) + " " + ltrim$(str$( mdl_ent(mi).kind )) + " " + ltrim$(str$( mdl_ent(mi).state )) + " " + _
            ltrim$(str$( mdl_ent(mi).hunting )) + " " + ltrim$(str$( mdl_ent(mi).anim_frame )) + " " + _
            ltrim$(str$( mdl_ent(mi).pos.x )) + " " + ltrim$(str$( mdl_ent(mi).pos.y )) + " " + ltrim$(str$( mdl_ent(mi).pos.z ))
    next mi
    print #benchf, "tris " + ltrim$(str$( g.rdr.tris ))
    print #benchf, "qgl_faces " + ltrim$(str$( dbg_qgl_faces() ))
    print #benchf, "qgl_drop " + ltrim$(str$( dbg_qgl_drop() ))
    print #benchf, "cam_leaf " + ltrim$(str$( rb_dbg_camleaf ))
    print #benchf, "pvs_count " + ltrim$(str$( rb_dbg_pvscnt ))
    print #benchf, "lm_want " + ltrim$(str$( dbg_lm_want ))
    print #benchf, "lm_fallback " + ltrim$(str$( dbg_lm_fall ))
    print #benchf, "k_mip " + ltrim$(str$( dbg_keys(0) ))
    print #benchf, "k_sw " + ltrim$(str$( dbg_keys(1) ))
    print #benchf, "k_sh " + ltrim$(str$( dbg_keys(2) ))
    print #benchf, "k_stag " + ltrim$(str$( dbg_keys(3) ))
    print #benchf, "k_n " + ltrim$(str$( dbg_keys(4) ))
    print #benchf, "k_hdr " + ltrim$(str$( dbg_keys(5) ))
    print #benchf, "k_ext " + ltrim$(str$( dbg_keys(6) ))
    print #benchf, "k_v0 " + ltrim$(str$( dbg_keys(7) ))
    print #benchf, "k_lm " + ltrim$(str$( dbg_keys(8) ))
    print #benchf, "px " + ltrim$(str$( g.pl.pos.x ))
    print #benchf, "py " + ltrim$(str$( g.pl.pos.y ))
    print #benchf, "pz " + ltrim$(str$( g.pl.pos.z ))
    print #benchf, "on_ground " + ltrim$(str$( g.pl.on_ground ))
    print #benchf, "vz " + ltrim$(str$( g.pl.vel.z ))
    print #benchf, "dt " + ltrim$(str$( g.scr.frame_time ))
    print #benchf, "tick_hz " + ltrim$(str$( sys_tick_hz ))
    '' Asked of DOS, not BASIC: mgl's memAvail returned MAX(largest free
    '' block, BASIC's far-heap SIZE), a heap's extent rather than its free
    '' space -- a live MCB walk once found 9,312 bytes free where it said
    '' ~260,000. qgl_avail is what an allocation can actually get;
    '' qgl_free_sum is every free block added up, so the gap between the
    '' two is the fragmentation.
    print #benchf, "qgl_avail " + ltrim$(str$( qglMemAvail&( QGL_MEM_LARGEST ) ))
    print #benchf, "qgl_free_sum " + ltrim$(str$( qglMemAvail&( QGL_MEM_TOTAL ) ))
    print #benchf, "lm_size " + ltrim$(str$( mod_lm_bytes( g ) ))
    print #benchf, "lm_read " + ltrim$(str$( mod_lm_got( g ) ))
    print #benchf, "geom_rows " + ltrim$(str$( mod_geom_rows( g ) ))
    print #benchf, "cm_size " + ltrim$(str$( mod_cm_bytes( g ) ))
        sc_stats scs
    print #benchf, "sc_made " + ltrim$(str$( scs.made ))
    print #benchf, "sc_ems " + ltrim$(str$( scs.peak ))
    ''
    '' Cache behaviour. scworst is the most surfaces built in any ONE
    '' frame, which is what a hitch is made of -- a run-wide total says
    '' nothing about whether they arrived together or spread out.
    ''
    print #benchf, "sc_built " + ltrim$(str$( scs.total_builds ))
    print #benchf, "sc_dlit " + ltrim$(str$( scs.dlit ))
    print #benchf, "sc_worst " + ltrim$(str$( scs.bpeak ))
    print #benchf, "sc_live " + ltrim$(str$( scs.live ))
    print #benchf, "sc_evict " + ltrim$(str$( scs.evict ))
    print #benchf, "sc_flush " + ltrim$(str$( scs.flushes ))
    print #benchf, "sc_test " + ltrim$(str$( sc_selftest( g ) ))
    print #benchf, "ls_test " + ltrim$(str$( ls_selftest() ))
    print #benchf, "peak_z " + ltrim$(str$( g.pl.peak_z ))
    print #benchf, "ticks " + ltrim$(str$( host_ticks ))
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
    print #benchf, "clp_rec " + ltrim$(str$( pl_hull_rec ))
    print #benchf, "clp_cnt " + ltrim$(str$( g.wld.count.clips ))
    print #benchf, "water_level " + ltrim$(str$( g.pl.water_level ))
    print #benchf, "water_type " + ltrim$(str$( g.pl.water_type ))
    print #benchf, "anim_time " + ltrim$(str$( g.rdr.anim_time ))
    print #benchf, "door_count " + ltrim$(str$( g.door_count ))
    for  mi = 0 to g.door_count-1
        print #benchf, "door_" + ltrim$(str$( mi )) + " " + ltrim$(str$( door(mi).model )) + " " + _
            ltrim$(str$( door(mi).state )) + " " + ltrim$(str$( brush( door(mi).model ).ofs.x )) + " " + _
            ltrim$(str$( brush( door(mi).model ).ofs.y )) + " " + ltrim$(str$( brush( door(mi).model ).ofs.z ))
    next mi
    print #benchf, "trig_count " + ltrim$(str$( g.trig_count ))
    for  mi = 0 to g.trig_count-1
        print #benchf, "trig_" + ltrim$(str$( mi )) + " " + ltrim$(str$( trig(mi).model )) + " " + _
            ltrim$(str$( trig(mi).kind )) + " " + ltrim$(str$( trig(mi).state )) + " " + ltrim$(str$( trig(mi).left ))
    next mi
    if ( g.plat_count > 0 ) then
        print #benchf, "plat_zofs " + ltrim$(str$( brush( plat(0).model ).ofs.z ))
        print #benchf, "plat_state " + ltrim$(str$( plat(0).state ))
    end if
    close #benchf

end sub

