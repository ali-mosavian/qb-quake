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

declare function rb_dbg_camleaf ( ) as integer

declare function dbg_lm_want ( ) as integer
declare function dbg_lm_fall ( ) as integer
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
'' r_span.c investigative prototype (see its own file for what it is).
declare function r_span_overflow_count ( ) as integer
declare function r_span_resolved_pixels ( ) as long
declare function r_span_naive_pixels ( ) as long
declare function r_span_bucket_cycles ( ) as long
declare function r_span_merge_cycles ( ) as long
declare function r_span_sweep_cycles ( ) as long
declare function r_span_step_cycles ( ) as long
declare function r_span_edges_total ( ) as long
declare function r_span_rows_total ( ) as long
declare function r_span_cross_total ( ) as long
declare function r_span_spans_total ( ) as long
declare function r_span_begins_total ( ) as long
declare function r_span_draw_cycles ( ) as long
declare function r_span_poly_peak ( ) as integer
declare function r_span_edge_peak ( ) as integer
declare function r_span_ael_peak ( ) as integer
declare function sys_tick_hz ( ) as single
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
        ''
        '' r_span.c investigative prototype -- see PhaseTimes in
        '' q_scr.bi. Nested inside pt_draw the same way pt_raster and
        '' pt_build are, but this work is not in the real draw path at
        '' all: it runs alongside it, resolving the same polygons into
        '' a Quake-style global edge list -> sorted span list purely to
        '' measure the cost. r_span_overflow_count non-zero means a
        '' static bound was hit and these numbers are a truncated
        '' frame's, not the whole one's.
        ''
        print #benchf, "pt_emit_mean " + ltrim$(str$( (g.pt.emit_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_emit_max " + ltrim$(str$( g.pt.emit_max * 1000.0 ))
        print #benchf, "pt_span_mean " + ltrim$(str$( (g.pt.span_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_span_max " + ltrim$(str$( g.pt.span_max * 1000.0 ))
        print #benchf, "r_span_overflow " + ltrim$(str$( r_span_overflow_count() ))
        '' naive/resolved is the overdraw factor -- a property of the
        '' map, not of r_span.c. See its own comment.
        print #benchf, "span_resolved_pixels " + ltrim$(str$( r_span_resolved_pixels() ))
        print #benchf, "span_naive_pixels " + ltrim$(str$( r_span_naive_pixels() ))
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
        '' r_span_flush's own four phases, same conversion as above --
        '' see r_span.c's own comment on what each one covers and why
        '' they should together read close to
        '' pt_span_mean * frames.
        print #benchf, "span_bucket_ms " + ltrim$(str$( r_span_bucket_cycles() * qr_ms_per_cyc ))
        print #benchf, "span_merge_ms " + ltrim$(str$( r_span_merge_cycles() * qr_ms_per_cyc ))
        print #benchf, "span_sweep_ms " + ltrim$(str$( r_span_sweep_cycles() * qr_ms_per_cyc ))
        print #benchf, "span_step_ms " + ltrim$(str$( r_span_step_cycles() * qr_ms_per_cyc ))
        print #benchf, "span_draw_ms " + ltrim$(str$( r_span_draw_cycles() * qr_ms_per_cyc ))
        '' Counts, not timings -- what the loops above actually iterate
        '' over. cross/rows is the mean active edge list.
        print #benchf, "span_edges_total " + ltrim$(str$( r_span_edges_total() ))
        print #benchf, "span_rows_total " + ltrim$(str$( r_span_rows_total() ))
        print #benchf, "span_cross_total " + ltrim$(str$( r_span_cross_total() ))
        print #benchf, "span_spans_total " + ltrim$(str$( r_span_spans_total() ))
        print #benchf, "span_begins_total " + ltrim$(str$( r_span_begins_total() ))
        print #benchf, "span_poly_peak " + ltrim$(str$( r_span_poly_peak() ))
        print #benchf, "span_edge_peak " + ltrim$(str$( r_span_edge_peak() ))
        print #benchf, "span_ael_peak " + ltrim$(str$( r_span_ael_peak() ))
        ''
        '' Nested inside pt_cull, not subtracted from it -- see PhaseTimes
        '' in q_scr.bi. pt_cull_mean minus these two is frustum extraction
        '' and the two lookat/concat matrix builds.
        ''
        print #benchf, "pt_mark_mean " + ltrim$(str$( (g.pt.mark_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_mark_max " + ltrim$(str$( g.pt.mark_max * 1000.0 ))
        print #benchf, "pt_walk_mean " + ltrim$(str$( (g.pt.walk_sum / g.ft.n) * 1000.0 ))
        print #benchf, "pt_walk_max " + ltrim$(str$( g.pt.walk_max * 1000.0 ))
    end if
    print #benchf, "polys " + ltrim$(str$( g.rdr.polys ))
    print #benchf, "tris " + ltrim$(str$( g.rdr.tris ))
    print #benchf, "cam_leaf " + ltrim$(str$( rb_dbg_camleaf ))
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
    print #benchf, "mem_avail " + ltrim$(str$( memAvail& ))
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
    if ( g.plat_count > 0 ) then
        print #benchf, "plat_zofs " + ltrim$(str$( brush( plat(0).model ).zofs ))
        print #benchf, "plat_state " + ltrim$(str$( plat(0).state ))
    end if
    close #benchf

end sub

