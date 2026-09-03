/*
 * qmain.c -- foundation probe for the standalone C port of qrender.
 *
 * Proves two things now: a bcc-only EXE links mgl WITHOUT the BASIC
 * runtime (the original point of this file), and that vid.c/d_poly.c
 * -- genuine ports of the old vid.bas/d_poly.bas, no BASIC glue left
 * in either -- link and run together in that EXE.
 *
 * Uses mgl's own shipped inc/*.h directly (via uglpatch.h, which
 * #includes ugl.h) rather than a generated header: they're accurate
 * for everything except a handful of newer entries -- uglpatch.h
 * supplies just those (uglPolyTP/uglBuildSurf/uglNewView/uglSetView/
 * uglZMode/uglClearZ), confirmed missing by grep, not assumed.
 */

#include <stdio.h>
#include <string.h>
#include <alloc.h>  /* farmalloc */
#include <mem.h>    /* _fmemset */
#include "dos.h"    /* memFree */
#include "uglpatch.h"
#include "video.h"
#include "d_poly.h"
#include "ls.h"
#include "sc.h"
#include "sys_time.h"
#include "tmr.h"
#include "mod.h"
#include "mod_tex.h"
#include "pl_move.h"
#include "input.h"
#include "h_frame.h"
#include "screen.h"
#include "config.h"
#include "sys.h"

/* Step log: opened and closed per mark so it survives a fault that
   never returns -- the technique this project records for exactly
   this case. */
static void mark( char *what )
{
    FILE *m = fopen( "cstep.txt", "a" );
    if ( m ) { fprintf( m, "%s\n", what ); fclose( m ); }
}

int main( void )
{
    Video   v;
    Config  cfg;
    RunArgs args;
    long    pal;

    mark( "start" );

    sys_parse_args( &args );
    mark( "sys_parse_args ok" );

    config_load( &cfg, "stuff.ini" );
    mark( "config_load ok" );

    v_init_ugl();
    mark( "v_init_ugl ok" );

    v.use_paging = cfg.use_paging;
    v.pages      = cfg.pages;
    v.c_fmt      = 0;      /* UGL.8BIT% */
    v.scr_x_res  = cfg.scr_x_res;
    v.scr_y_res  = cfg.scr_y_res;
    v.x_res      = cfg.x_res;
    v.y_res      = cfg.y_res;
    v.comp       = args.comp;
    v.view_x     = cfg.view_x;
    v.view_y     = cfg.view_y;
    v.view_scale = cfg.view_scale;

    /* No real palette load yet -- a null handle is enough to prove
       uglPalSet/memFree link and don't fault on a degenerate call;
       the real palette loader is a later module. */
    pal = 0;
    v_init( &v, pal );
    mark( "v_init ok" );

    d_init_turb();
    mark( "d_init_turb ok" );

    {
        short lsr = ls_selftest();
        char buf[32];
        sprintf( buf, "ls_selftest %d", lsr );
        mark( buf );
    }
    {
        short scr = sc_selftest();
        char buf[32];
        sprintf( buf, "sc_selftest %d", scr );
        mark( buf );
    }
    {
        /* sys_time.c's own calibration: tick_hz should land near 144
           (this project's own measured range on this toolchain/
           emulator, ~142-148), not the 1000 sys_time_init would fall
           back to uncalibrated -- that fallback silently ran the whole
           game 7x too slow once already, which is the entire reason
           this measures rather than trusts the requested rate. tmrInit
           needs no mouse/keyboard (in_init's other half), just the
           timer. */
        SysClock clk;
        float n0, n1;
        char buf[64];
        tmrInit();
        sys_time_init( &clk );
        n0 = sys_now( &clk );
        n1 = sys_now( &clk );
        sprintf( buf, "sys_time tick_hz=%ld.%02d now0=%ld now1=%ld",
                 (long) clk.tick_hz, (int) ( (clk.tick_hz - (long) clk.tick_hz) * 100 ),
                 (long) (n0 * 1000), (long) (n1 * 1000) );
        mark( buf );
    }

    {
        /* Phase 4's own end-to-end proof: load a real map and draw
           real frames through it -- host_advance/host_tick/
           host_render, exactly the loop main() (not yet written)
           will run every frame. Everything below this point is new
           with d_faces.c/view.c/screen.c; the map-loading block above
           it is unchanged from the previous milestone. */
        World      world;
        Renderer   rdr;
        Camera     cam;
        Player     player;
        Input      input;
        Hud far   *hud;
        LightStyles ls;
        SurfCache far *sc;
        SysClock   sysclk;
        HostClock  clock;
        PhaseTimes pt;
        MapCounts  counts;
        FILE      *mapf;
        PRGB       tex_pal;
        u3dMtrx    mtx_prj;
        u3dVector3f cam_up;
        PDC        z_dc, h_dst_dc;
        char       buf[96];
        short      frame;

        memset( &world, 0, sizeof(world) );
        memset( &rdr, 0, sizeof(rdr) );
        memset( &cam, 0, sizeof(cam) );
        memset( &player, 0, sizeof(player) );
        memset( &input, 0, sizeof(input) );
        memset( &clock, 0, sizeof(clock) );
        memset( &pt, 0, sizeof(pt) );

        /* far-allocated, not a stack local: Hud embeds Font (a 2 KB
           glyph table) and two GRAPH_N history rings, ~2.3 KB total --
           squarely the same "too big for DGROUP" case SurfCache
           already is. Kept as a stack local it silently corrupted a
           NEIGHBOURING local (HostClock's own ticks came back reading
           15401199, not 0) rather than faulting outright, which is
           what made this worth writing down: medium model's DGROUP
           holds the stack too, so a large-enough local overruns
           whatever the compiler happened to place next to it, not a
           guard page. */
        hud = (Hud far *) farmalloc( sizeof(Hud) );
        if ( !hud ) sys_error( "out of far memory for Hud" );
        _fmemset( hud, 0, sizeof(*hud) );

        mapf = mod_load_world( &world, &rdr, &cam, args.map_name, &counts );

        sprintf( buf, "mod_load_world ok faces=%d leaves=%d models=%d tele=%d plat=%d",
                 world.face_count, world.leaf_count, world.model_count,
                 world.tele_count, world.plat_count );
        mark( buf );
        sprintf( buf, "spawn=%ld,%ld,%ld angle=%ld",
                 (long) cam.pos.x, (long) cam.pos.y, (long) cam.pos.z,
                 (long) cam.start_angle );
        mark( buf );

        /* mod_tex.c's own proof: textures, still on the same open file,
           matching main.bas's real order (mod_open, mod_load_world,
           mod_load_texinfo/mod_load_textures, THEN mod_close). */
        tex_pal = mod_load_textures( &world, mapf, &counts );
        mod_close( mapf );

        sprintf( buf, "mod_load_textures ok textures=%ld pal=%ld tex_raw=%ld tex_shaded=%ld",
                 counts.textures, (long) (void far *) tex_pal,
                 (long) world.tex_raw, (long) world.tex_shaded );
        mark( buf );

        /* The real game palette, installed now rather than at v_init
           (which ran before any map data existed to supply one). */
        if ( tex_pal ) {
            uglPalSet( 0, 256, (RGB far *) tex_pal );
            memFree( (void far *) tex_pal );
        }

        /* scr_hud_colors best-fits the overlay's own colours against
           whatever palette is live -- has to run AFTER the real one
           is installed, or every hc_* index would be chosen against
           whatever uGL's own default happened to be. */
        scr_hud_colors( hud );
        mark( "scr_hud_colors ok" );

        font_load( &hud->font, "base.dat::font/4x6.fnt" );
        mark( "font_load ok" );

        /* mod_load_colormap is main()'s own call, not mod_load_world's
           -- see mod.h's own note on why (a contiguous 16K EMS page,
           wanted before other map data has used up the room). */
        mod_load_colormap( &world );
        mark( "mod_load_colormap ok" );

        sc = (SurfCache far *) farmalloc( sizeof(SurfCache) );
        if ( !sc || !sc_init( sc, world.face_count ) ) {
            mark( "sc_init FAILED" );
        } else {
            mark( "sc_init ok" );
        }
        ls_init( &ls );

        in_init( &input, v.h_video_dc );

        /* -at X Y Z: BSP-space (Z-up), used AS-IS -- the same space
           pl.pos already lives in, matching pl_init's own ELSE branch
           this replaces (which instead swaps cam.pos's Y-up down to
           Z-up). */
        if ( args.at_set ) {
            Vec3 start;
            start.x = args.at_x; start.y = args.at_y; start.z = args.at_z;
            pl_init( &player, &cam, &start );
        } else {
            pl_init( &player, &cam, 0 );
        }

        /* -yaw overrides the spawn's own angle, wrapped into [0,360)
           already by sys_parse_args -- same reasoning as
           ent_check_teleport's own mousePos trick: aiming the camera
           IS moving the mouse. */
        if ( args.yaw_set ) cam.start_angle = args.yaw;

        /* Seeds the mouse position from the spawn yaw -- the camera
           reads its angle from the mouse, so the mouse is what has to
           move, the same trick a teleport uses (ent_check_teleport). */
        mousePos( (short) ( (v.scr_x_res - 1) * cam.start_angle / 360.0f ), 110 );

        /* -walk/-jump/-strafe hold an input the way a real keypress
           would -- there is no real keyboard under a headless run, so
           spoofing the KBD fields v_update_camera already reads is
           simpler than threading a second, parallel set of "held"
           flags through it the way the original's own g.env.bench_walk
           does. */
        if ( args.walk )   input.keyboard.w = -1;
        if ( args.jump )   input.keyboard.spcbar = -1;
        if ( args.strafe ) input.keyboard.a = -1;

        cam.fps_view = -1;
        cam_up.x = 0.0f; cam_up.y = 1.0f; cam_up.z = 0.0f;

        rdr.use_mips = -1;
        rdr.lightmap = args.use_lm;   /* the starting state of the 'L'
                                          toggle (in_handle_toggles) --
                                          dp->use_lm (h_frame.c) is the
                                          separate, static "is there
                                          data to toggle" gate */
        rdr.rend_mode = 0;
        rdr.backface = (short) ( args.no_cull ? 0 : -1 );
        rdr.portal   = (short) ( args.no_portal ? 0 : -1 );
        rdr.no_ents   = args.no_ents;
        rdr.bad_order = args.bad_order;
        hud->portal_wire = args.ptwire;
        hud->stats       = (short) ( args.no_stats ? 0 : -1 );

        /* bspfile.bi's DISPLAY_W/DISPLAY_H (4.0/3.0): VGA mode 13h's
           pixels are not square, so a square render target would
           still come out stretched on screen without this correction
           -- see main.bas's own note on why it's view_w/view_h (the
           SCALED size), not x_res/y_res, that has to cancel back
           against scr_x_res/scr_y_res. */
        {
            float aspect = ( (float) cfg.view_w * cfg.scr_y_res * 4.0f )
                          / ( (float) cfg.view_h * cfg.scr_x_res * 3.0f );
            u3dMtrxPersp( &mtx_prj, cfg.cam_fov, aspect, cfg.z_near, cfg.z_far );
        }

        h_dst_dc = v.h_back_bdc;

        z_dc = 0;
        if ( !args.no_z ) {
            z_dc = uglNewZ( h_dst_dc, UGL_EMS );
            if ( z_dc ) {
                uglSetZ( z_dc );
                uglZScale( 65535.0f * cfg.z_near );
            }
        }

        sys_time_init( &sysclk );
        /* 0 (no -ticks given) is host_advance's own "unbounded" --
           matching main.bas's real default, which only ever stops on
           ESC. -ticks N is what makes a run a bounded benchmark;
           tools/run.sh's own headless invocations pass it explicitly
           so an unattended run still terminates. */
        clock.bench_ticks = args.bench_ticks;
        pt.n = 1;                  /* profiling armed: dp->prof, and the
                                       pt_tick/cull/draw/hud brackets, run for
                                       real rather than reading 0 */

        /* Real per-frame timing, matching h_bench.bas's own ft_min/max/sum/n:
           the first few frames carry the tail of loading and the first
           surface builds, which no later frame repeats, so they're skipped
           rather than let them set a misleadingly high ft_max. */
        {
            float ft_min = 0.0f, ft_max = 0.0f, ft_sum = 0.0f;
            long  ft_n = 0;
            long  poly_sum = 0, tri_sum = 0;
            float raw_dt, frame_dt;
            FILE *bf;

            frame = 0;
            while ( ( clock.bench_ticks == 0 || clock.ticks < clock.bench_ticks )
                    && !input.keyboard.esc ) {
                frame_dt = sys_frame_time( &sysclk, &raw_dt );

                if ( frame > 3 && raw_dt > 0.0f ) {
                    if ( ft_n == 0 ) { ft_min = raw_dt; ft_max = raw_dt; }
                    else {
                        if ( raw_dt < ft_min ) ft_min = raw_dt;
                        if ( raw_dt > ft_max ) ft_max = raw_dt;
                    }
                    ft_sum += raw_dt;
                    ft_n++;
                }

                host_advance( &world, &player, &cam, &rdr, &input, hud, &ls, &sysclk,
                               &clock, &pt, frame_dt, v.scr_x_res, v.scr_y_res );

                uglClear( h_dst_dc, 0 );
                host_render( &world, &rdr, &cam, &player, sc, &ls, hud, &pt, &sysclk,
                              h_dst_dc, &mtx_prj, (float) v.x_res / 2.0f, (float) v.y_res / 2.0f,
                              cfg.z_near, cfg.z_far,
                              &cam_up, z_dc, v.comp, args.no_draw,
                              v.x_res, v.y_res );
                in_screenshot_key( &input, h_dst_dc, v.x_res, v.y_res );
                v_present( &v, h_dst_dc, 0 );

                /* -comp: v_present has already scaled the 3D view into
                   the composite (v.h_comp_dc, screen-mode sized) and
                   left the screen itself untouched -- host_render's
                   own scr_draw_hud call was skipped for exactly this
                   case. Draw the overlay onto the composite now, at
                   the mode's own resolution (not the small render
                   target the panels were clipping against), then one
                   uglPut carries the whole thing to video. Drawing it
                   onto live video memory after a present instead would
                   be a second pass over VRAM -- it tears, and VRAM is
                   slow enough to cost frames (matches main.bas's own
                   reasoning for doing it this way). */
                if ( v.comp ) {
                    scr_draw_hud( &world, &rdr, &cam, &player, sc, hud,
                                  v.h_comp_dc, v.scr_x_res, v.scr_y_res );
                    uglPut( v.h_video_dc, 0, 0, v.h_comp_dc );
                }

                /* Read rdr.polys/tris BEFORE scr_count_frame, which
                   resets them for the next frame (screen.bas's own
                   job, real now) -- rdr's own fields are short and
                   would overflow negative over a long run at ~150
                   polys/frame if left to accumulate across the whole
                   session instead, so the real running total lives
                   in these longs here. */
                poly_sum += rdr.polys;
                tri_sum  += rdr.tris;
                scr_count_frame( hud, &rdr, sc, frame_dt );
                frame++;
            }

            sprintf( buf, "frames=%d polys=%ld tris=%ld pos=%ld,%ld,%ld",
                     frame, poly_sum, tri_sum,
                     (long) cam.pos.x, (long) cam.pos.y, (long) cam.pos.z );
            mark( buf );

            if ( ft_n > 0 ) {
                sprintf( buf, "ft_mean=%ld.%02dms fps_mean=%ld.%02d ft_min=%ldms ft_max=%ldms n=%ld",
                         (long) ( (ft_sum/ft_n) * 1000.0f ),
                         (int) ( ( (ft_sum/ft_n) * 1000.0f - (long) ( (ft_sum/ft_n) * 1000.0f ) ) * 100 ),
                         (long) ( ft_n / ft_sum ),
                         (int) ( ( (float) ft_n / ft_sum - (long) ( (float) ft_n / ft_sum ) ) * 100 ),
                         (long) ( ft_min * 1000.0f ), (long) ( ft_max * 1000.0f ), ft_n );
                mark( buf );
            }

            /* Under -comp the composited frame (3D view + HUD, both at
               the mode's own resolution) lives in h_comp_dc, not the
               small render target h_dst_dc stays pointed at -- see
               the -comp block above. */
            if ( v.comp )
                scr_screenshot( "bench.bmp", v.h_comp_dc, v.scr_x_res, v.scr_y_res );
            else
                scr_screenshot( "bench.bmp", h_dst_dc, v.x_res, v.y_res );
            mark( "scr_screenshot ok" );

            bf = fopen( "bench.txt", "w" );
            if ( bf ) {
                fprintf( bf, "frames %d\n", frame );
                fprintf( bf, "polys %ld\n", poly_sum );
                fprintf( bf, "tris %ld\n", tri_sum );
                if ( ft_n > 0 ) {
                    fprintf( bf, "ft_min %ld.%03ld\n", (long) (ft_min*1000), (long) (ft_min*1000000) % 1000 );
                    fprintf( bf, "ft_max %ld.%03ld\n", (long) (ft_max*1000), (long) (ft_max*1000000) % 1000 );
                    fprintf( bf, "ft_mean %ld.%03ld\n", (long) ((ft_sum/ft_n)*1000), (long) ((ft_sum/ft_n)*1000000) % 1000 );
                    fprintf( bf, "ft_n %ld\n", ft_n );
                    fprintf( bf, "fps_mean %ld.%02ld\n", (long) (ft_n/ft_sum), (long) ((ft_n/ft_sum)*100) % 100 );
                    fprintf( bf, "pt_tick_mean %ld.%03ld\n",
                             (long) ((pt.tick_sum/ft_n)*1000), (long) ((pt.tick_sum/ft_n)*1000000) % 1000 );
                    fprintf( bf, "pt_cull_mean %ld.%03ld\n",
                             (long) ((pt.cull_sum/ft_n)*1000), (long) ((pt.cull_sum/ft_n)*1000000) % 1000 );
                    fprintf( bf, "pt_draw_mean %ld.%03ld\n",
                             (long) ((pt.draw_sum/ft_n)*1000), (long) ((pt.draw_sum/ft_n)*1000000) % 1000 );
                    fprintf( bf, "pt_build_mean %ld.%03ld\n",
                             (long) ((pt.build_sum/ft_n)*1000), (long) ((pt.build_sum/ft_n)*1000000) % 1000 );
                    fprintf( bf, "pt_raster_mean %ld.%03ld\n",
                             (long) ((pt.raster_sum/ft_n)*1000), (long) ((pt.raster_sum/ft_n)*1000000) % 1000 );
                }
                fclose( bf );
            }
        }
    }

    if ( v.h_back_bdc ) uglDel( &v.h_back_bdc );
    uglRestore();
    uglEnd();
    mark( "restored" );

    {
        FILE *f = fopen( "cport.txt", "w" );
        if ( f ) {
            /* turb_table()[0] is always 0.0 (sin of angle 0) -- a fixed
               sentinel proves the table built and the far pointer
               reads back correctly, compared without a float-to-long
               cast (avoids F_FTOL@, resolved since -- bcpp31's own
               MATHC.LIB -- but this check needs no cast either way). */
            fprintf( f, "OK vdc=%ld bdc=%ld turb0_is_zero=%d\n",
                     v.h_video_dc, v.h_back_bdc, ( d_turb_table()[0] == 0.0f ) );
            fclose( f );
        }
    }
    return 0;
}
