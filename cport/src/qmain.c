/*
 * qmain.c -- foundation probe for the standalone C port of qrender.
 *
 * Proves two things now: a bcc-only EXE links mgl WITHOUT the BASIC
 * runtime (the original point of this file), and that vid.c/d_poly.c
 * -- genuine ports of the old vid.bas/d_poly.bas, no BASIC glue left
 * in either -- link and run together in that EXE.
 *
 * The graphics layer is qgl, whose C binding (qgl.h) is generated
 * by tools/mkqglh.py from the asm itself -- parameters from the
 * `proc` directives, return types from the signature comments --
 * so a drifted declare fails the build instead of miscompiling.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>   /* atan2 -- -record's diagnostic yaw */
#include <mem.h>    /* _fmemset */
#include "qgl.h"
#include "pal.h"
#include "video.h"
#include "d_poly.h"
#include "ls.h"
#include "sc.h"
#include "sys_time.h"
#include "mod.h"
#include "mod_tex.h"
#include "pl_move.h"
#include "input.h"
#include "fight.h"
#include "assets.h"
#include "mdl.h"
#include "mdl_ai.h"
#include "sbar.h"
#include "item.h"
#include "gstate.h"
#include "snd.h"
#include "h_frame.h"
#include "screen.h"
#include "config.h"
#include "sys.h"
#include "loadscr.h"
#include "r_portal.h"   /* r_portal_stats -- the flood totals in bench.txt */

/* Step log: opened and closed per mark so it survives a fault that
   never returns -- the technique this project records for exactly
   this case. */
/* Borland's own stack-size knob, and it is not optional here.
   QCPORT.MAP showed _STACK at 0x80 bytes with _stklen never set, while
   crash dumps put SP over a ~2.4 KB range: r_walk's BSP recursion plus
   d_faces' frame is already deep, and medium model puts the stack in
   DGROUP alongside every near global, so an overflow silently eats
   data instead of faulting. On top of that mgl's mouse handler
   (mdmouse.asm) fires asynchronously and does a `pushad` on whatever
   stack it interrupted -- so the deeper the renderer is when a real
   mouse interrupt lands, the further past the end it writes. That is
   exactly the observed failure: crashes only while the mouse is
   actually moving, never on a replay of the identical camera path
   (which generates no interrupts), and never at a repeatable frame.

   And it has a ceiling: near data plus this must fit one 64K DGROUP
   with room left for the near heap, or the startup aborts before main
   and prints to a stderr DOS does not redirect. It was 32768, which
   left -22 bytes. tools/dgroup-check.sh fails the link instead now. */
extern unsigned _stklen;
unsigned _stklen = 24576U;

/* Stack low-water probe -- see the paint loop in main(). */
#define PAINT_BYTE  0xA5
#define PROBE_BYTES 8192U

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
    {   /* Is _stklen actually honoured? The EXE header still says
           SP=0x80, so this reads the real thing rather than trusting
           it: SP here is the stack top minus main's own frame. */
        char sbuf[64];
        unsigned sp_now, ss_now;
        _asm { mov sp_now, sp }
        _asm { mov ss_now, ss }
        sprintf( sbuf, "stack ss=%u sp=%u stklen=%u", ss_now, sp_now, _stklen );
        mark( sbuf );

        /* Stack low-water probe. Paint the unused stack below SP with
           a pattern; whatever is still PAINT_BYTE afterwards was never
           touched, so the lowest disturbed address is the deepest the
           stack (renderer recursion + any interrupt that landed on top
           of it) actually reached. Read it back with the debugger's
           mem_dump over the linear range marked below -- the point is
           to MEASURE the depth rather than keep assuming an overflow.

           Deliberately conservative: the deepest SP seen in any crash
           dump so far is ~2.4 KB below the top, so 4 KB covers it with
           margin. Painting further risks writing into _BSS if the real
           reserved stack is small -- which is itself the open question,
           so it is not something to find out by corrupting globals. */
        {
            unsigned lo = sp_now - PROBE_BYTES;
            unsigned hi = sp_now - 256;   /* clear of the current frame */
            unsigned char *p;
            for ( p = (unsigned char *) lo; p < (unsigned char *) hi; p++ )
                *p = PAINT_BYTE;
            sprintf( sbuf, "probe linear=%lu len=%u",
                     (unsigned long) ss_now * 16UL + lo, (unsigned)(hi - lo) );
            mark( sbuf );
        }
    }

    sys_parse_args( &args );
    mark( "sys_parse_args ok" );

    config_load( &cfg, "stuff.ini" );
    mark( "config_load ok" );

    v_init_ugl();
    mark( "v_init_ugl ok" );
    {   /* One EMS surface, asked for at init.

           qglNew's `typ` is the dispatch-table OFFSET, not the SURF_
           kind; SURF_EMS is 2 and SF_EMS is 2*64, so qglNew( SURF_EMS,
           ... ) indexes into the conventional-memory entry and every
           EMS surface came back null. SURF_CMEM is 0 either way, so the
           back buffer worked and nothing said otherwise until three
           loaders later, as "no EMS for the geometry store". qglSfNew
           is the boundary that converts, and this is the smallest
           question that distinguishes the two. */
        char  gb[64];
        QSurf probe = qglSfNew( 64, 4, QGL_SURF_EMS );

        sprintf( gb, "ems frame=%04X probe=%ld", qglGemFrame(), probe );
        mark( gb );
        if ( !probe ) sys_error( "EMS is up but qglSfNew(SURF_EMS) returned null" );
        qglSfFree( probe );
    }

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
       uglPalSet/qglMemFree link and don't fault on a degenerate call;
       the real palette loader is a later module. */
    pal = 0;
    v_init( &v, pal );
    mark( "v_init ok" );
    {
        char buf[48];
        long raw = (long) (void far *) v.h_comp_dc;
        sprintf( buf, "h_comp_dc seg=%ld ofs=%ld", raw >> 16, raw & 0xFFFFL );
        mark( buf );
    }

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
           this measures rather than trusts the requested rate. qglTmrInit
           needs no mouse/keyboard (in_init's other half), just the
           timer. */
        SysClock clk;
        float n0, n1;
        char buf[64];
        qglTmrInit( 1000 );
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
        Fight      fight;
        Input      input;
        Hud far   *hud;
        LightStyles ls;
        SurfCache far *sc;
        SysClock   sysclk;
        HostClock  clock;
        PhaseTimes pt;
        MapCounts  counts;
        PalRgb far *       tex_pal;
        Mat4    mtx_prj;
        Vec3 cam_up;
        QSurf        z_dc, h_dst_dc;
        LoadScreen ldr;
        char       buf[96];
        short      frame;

        memset( &world, 0, sizeof(world) );
        memset( &fight, 0, sizeof(fight) );
        /* what a level starts with: PlayerCombat's own, not zero */
        fight.health  = PL_HEALTH;
        fight.shells  = PL_SHELLS;
        fight.items   = PL_IT_SHOTGUN;
        fight.weapon  = PL_IT_SHOTGUN;
        fight.state   = GS_PLAY;
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
        hud = (Hud far *) qglMemAlloc( (long) sizeof(Hud) );
        if ( !hud ) sys_error( "out of far memory for Hud" );
        _fmemset( hud, 0, sizeof(*hud) );

        /* The font comes up here, before any map data: base.dat is not
           the map's, so nothing below it is needed to read the glyphs,
           and the loading screen wants them. It used to sit after the
           textures, which is the only reason it was ever "too late" to
           label a load. */
        /* The container, before anything asks it for a member -- the
           font is the first, and it is not the map's. */
        asset_map( args.map_name );
        /* by name: a changelevel's second leg is a second run in the
           same log, and which container it opened is the whole claim */
        sprintf( buf, "asset_map ok %s", args.map_name );
        mark( buf );

        font_load( &hud->font, "font.fnt" );
        mark( "font_load ok" );

        scr_sbar_load();
        mark( "scr_sbar_load ok" );

        /* Six ld_step calls follow -- keep this in step with them, or
           the bar simply stops short of (or runs past) the end. */
        ld_begin( &ldr, v.h_video_dc, hud, 6, v.scr_x_res, v.scr_y_res );

        ld_stage( &ldr, v.h_video_dc, hud, "loading map" );
        mod_load_world( &world, &rdr, &cam, &fight, args.map_name, &counts );
        ld_step( &ldr, v.h_video_dc, hud );

        sprintf( buf, "mod_load_world ok faces=%d leaves=%d models=%d tele=%d plat=%d item=%d mon=%d",
                 world.face_count, world.leaf_count, world.model_count,
                 world.tele_count, world.plat_count, world.item_count, world.mon_count );
        mark( buf );
        {   /* which models actually arrived: a monster record loads
               whatever the map says, and the model behind it is a
               separate file that may not have. */
            short k; char *p = buf;
            strcpy( buf, "models" );
            p = buf + 6;
            for ( k = 0; k < MDL_KINDS; k++ )
                if ( world.mdl[k].loaded ) {
                    sprintf( p, " %d:%dv/%dt/%df", (int) k, world.mdl[k].nvert,
                             world.mdl[k].ntri, world.mdl[k].nframe );
                    p += strlen( p );
                }
            mark( buf );
        }

        sprintf( buf, "spawn=%ld,%ld,%ld angle=%ld",
                 (long) cam.pos.x, (long) cam.pos.y, (long) cam.pos.z,
                 (long) cam.start_angle );
        mark( buf );

        ld_stage( &ldr, v.h_video_dc, hud, "loading textures" );
        tex_pal = mod_load_textures( &world, &counts );
        ld_step( &ldr, v.h_video_dc, hud );

        sprintf( buf, "mod_load_textures ok textures=%ld pal=%ld tex_raw=%ld tex_shaded=%ld",
                 counts.textures, (long) (void far *) tex_pal,
                 (long) world.tex_raw, (long) world.tex_shaded );
        mark( buf );

        /* The map's palette is NOT installed here, though this is where
           the data for it arrives: installing it would repaint the
           loading screen's own ramps out from under it mid-load. It
           goes in below, once there is nothing left to show. Nothing
           between here and there reads the palette -- the surface
           builder shades through the colormap, not it -- except
           scr_hud_colors, which moves down with it. */

        /* mod_load_colormap is main()'s own call, not mod_load_world's
           -- see mod.h's own note on why (a contiguous 16K EMS page,
           wanted before other map data has used up the room). */
        ld_stage( &ldr, v.h_video_dc, hud, "loading colormap" );
        mod_load_colormap( &world );
        mark( "mod_load_colormap ok" );

        /* after the map: its ambient_* points were recorded by the ent
           loader and this is what starts them */
        snd_init( args.no_sound );
        {   short st, lp, un;
            snd_stats( &st, &lp, &un );
            sprintf( buf, "snd loops=%d", (int) lp );
            mark( buf );
        }
        if ( args.sndsum ) {
            sprintf( buf, "snd_sum=%08lX", snd_sum() );
            mark( buf );
        }
        ld_step( &ldr, v.h_video_dc, hud );

        ld_stage( &ldr, v.h_video_dc, hud, "surface cache" );
        sc = (SurfCache far *) qglMemAlloc( (long) sizeof(SurfCache) );
        if ( !sc || !sc_init( sc, world.face_count ) ) {
            mark( "sc_init FAILED" );
        } else {
            mark( "sc_init ok" );
        }
        ld_step( &ldr, v.h_video_dc, hud );

        ld_stage( &ldr, v.h_video_dc, hud, "light styles" );
        ls_init( &ls );
        ld_step( &ldr, v.h_video_dc, hud );

        ld_stage( &ldr, v.h_video_dc, hud, "input" );
        in_init( &input, v.h_video_dc );
        ld_step( &ldr, v.h_video_dc, hud );

        /* Loading is over, so the map's own palette can go in without
           repainting the screen it would have wrecked. scr_hud_colors
           best-fits the overlay's colours against whatever palette is
           live, so it has to follow this, not precede it. */
        if ( tex_pal ) {
            pal_install( (PalRgb far *) tex_pal );
            qglMemFree( (long) tex_pal );
        }
        scr_hud_colors( hud );
        mark( "scr_hud_colors ok" );

        /* -at X Y Z: BSP-space (Z-up), used AS-IS -- the same space
           pl.pos already lives in, matching pl_init's own ELSE branch
           this replaces (which instead swaps cam.pos's Y-up down to
           Z-up). */
        if ( args.at_set ) {
            BspVec3 start;
            start.x = args.at_x; start.y = args.at_y; start.z = args.at_z;
            pl_init( &player, &cam, &start );
        } else {
            pl_init( &player, &cam, 0 );
        }
        /* where a respawn puts them back: wherever this run started,
           so -at is the spawn for a headless run too */
        fight.spawn = player.pos;

        /* the kit the last map ended with, over the starting one --
           marked, because the end-of-run counters are what the NEXT
           map did to it and cannot say what arrived */
        if ( args.carry ) {
            pl_carry_load( &fight );
            sprintf( buf, "carry health %d shells %d nails %d rockets %d armor %d items %ld weapon %d",
                     fight.health, fight.shells, fight.nails, fight.rockets,
                     fight.armor, fight.items, fight.weapon );
            mark( buf );
        }

        /* what the next map's process is told about this run: the
           flags that describe HOW it runs, never where it started --
           -at and -yaw belong to this map's geometry and would aim the
           next one's camera into a wall. */
        {   char *nf = fight.next_flags;
            nf[0] = '\0';
            if ( args.use_lm )   strcat( nf, " -lm" );
            if ( args.no_stats ) strcat( nf, " -nostats" );
            if ( args.no_ai )    strcat( nf, " -noai" );
            if ( args.no_mdl )   strcat( nf, " -nomdl" );
            if ( args.no_items ) strcat( nf, " -noitems" );
            if ( args.no_view )  strcat( nf, " -noview" );
            if ( args.no_sound ) strcat( nf, " -nosound" );
            if ( args.comp )     strcat( nf, " -comp" );
            if ( args.fire )     strcat( nf, " -fire" );
            if ( args.bench_ticks > 0 )
                sprintf( nf + strlen( nf ), " -ticks %ld", args.bench_ticks );
        }

        /* -yaw overrides the spawn's own angle, wrapped into [0,360)
           already by sys_parse_args -- same reasoning as
           ent_check_teleport's own mousePos trick: aiming the camera
           IS moving the mouse. */
        if ( args.yaw_set ) cam.start_angle = args.yaw;

        /* Seeds the mouse position from the spawn yaw -- the camera
           reads its angle from the mouse, so the mouse is what has to
           move, the same trick a teleport uses (ent_check_teleport). */
        {   /* v_update_camera reads phi as PI*(mouse.y+2)/y_res, so a
               pitch in degrees is that inverted. 110 is the default and
               is not the horizon -- it is 100.8 degrees, a little below
               it, which is what every headless shot has always used. */
            short my = 110;
            if ( args.pitch_set ) {
                my = (short) ( v.scr_y_res * args.pitch / 180.0f - 2.0f );
                if ( my < 0 ) my = 0;
                if ( my > v.scr_y_res - 1 ) my = (short) ( v.scr_y_res - 1 );
            }
            qglMousePos( (short) ( (v.scr_x_res - 1) * cam.start_angle / 360.0f ), my );
        }

        /* -walk/-jump/-strafe hold an input the way a real keypress
           would -- there is no real keyboard under a headless run, so
           spoofing the Keys fields v_update_camera already reads is
           simpler than threading a second, parallel set of "held"
           flags through it the way the original's own g.env.bench_walk
           does. */
        if ( args.walk )   input.keyboard.k[KEY_W] = -1;
        if ( args.jump )   input.keyboard.k[KEY_SPCBAR] = -1;
        if ( args.strafe ) input.keyboard.k[KEY_A] = -1;
        if ( args.fire )   input.mouse.left = -1;

        cam.fps_view = -1;
        cam_up.x = 0.0f; cam_up.y = 1.0f; cam_up.z = 0.0f;

        rdr.use_mips = -1;
        rdr.no_subvis = args.no_subvis;
        rdr.lightmap = args.use_lm;   /* the starting state of the 'L'
                                          toggle (in_handle_toggles) --
                                          dp->use_lm (h_frame.c) is the
                                          separate, static "is there
                                          data to toggle" gate */
        rdr.rend_mode = 0;
        rdr.backface = (short) ( args.no_cull ? 0 : -1 );
        rdr.portal   = (short) ( args.no_portal ? 0 : -1 );
        rdr.no_ents   = args.no_ents;
        rdr.no_items  = args.no_items;
        rdr.no_mdl    = args.no_mdl;
        rdr.no_view   = args.no_view;
        rdr.no_ai     = args.no_ai;
        rdr.bad_order = args.bad_order;
        hud->portal_wire = args.ptwire;
        /* Off unless asked for. F12 still toggles it; -nostats stays
           accepted so every A/B recipe that passes it keeps working. */
        hud->stats       = (short) ( args.stats && !args.no_stats ? -1 : 0 );

        /* bspfile.bi's DISPLAY_W/DISPLAY_H (4.0/3.0): VGA mode 13h's
           pixels are not square, so a square render target would
           still come out stretched on screen without this correction
           -- see main.bas's own note on why it's view_w/view_h (the
           SCALED size), not x_res/y_res, that has to cancel back
           against scr_x_res/scr_y_res. */
        {
            float aspect = ( (float) cfg.view_w * cfg.scr_y_res * 4.0f )
                          / ( (float) cfg.view_h * cfg.scr_x_res * 3.0f );
            qglM4Persp( &mtx_prj, cfg.cam_fov, aspect, cfg.z_near, cfg.z_far );
        }

        h_dst_dc = v.h_back_bdc;

        z_dc = 0;
        if ( !args.no_z ) {
            z_dc = qglSfZNew( h_dst_dc, QGL_SURF_EMS );
            if ( z_dc ) {
                /* qgl binds the depth buffer to the surface it was made
                   for, so there is no separate "current z" to set. */
                qglZScale( 65535.0f * cfg.z_near );
            }
        }

        sys_time_init( &sysclk );
        /* 0 (no -ticks given) is host_advance's own "unbounded" --
           matching main.bas's real default, which only ever stops on
           ESC. -ticks N is what makes a run a bounded benchmark;
           tools/run.sh's own headless invocations pass it explicitly
           so an unattended run still terminates. */
        clock.bench_ticks = args.bench_ticks;
        pt.n = 0;                  /* armed per frame below, once the warm-up
                                       is past: the first frames build every
                                       surface in the view and no later frame
                                       repeats it, so counting them puts most
                                       of pt_build into a mean that then
                                       describes no frame that ran. n is both
                                       the count and every bracket's "armed"
                                       test (dp->prof too). */

        /* Real per-frame timing, matching h_bench.bas's own ft_min/max/sum/n:
           the first few frames carry the tail of loading and the first
           surface builds, which no later frame repeats, so they're skipped
           rather than let them set a misleadingly high ft_max. */
        {
            float ft_min = 0.0f, ft_max = 0.0f, ft_sum = 0.0f;
            long  ft_n = 0;
            long  poly_sum = 0, tri_sum = 0, mdl_sum = 0;
            long  pt_poly_sum = 0;   /* the same, over the profiled frames alone */
            float raw_dt, frame_dt;
            float t_frame = 0.0f, t_ph;      /* the frame's own boundary, and one phase's */
            FILE *bf;

            /* -record/-play: one fixed-size record a frame -- x,y,
               left,right (mouse), w,a,s,d,spcbar (keyboard), all as
               shorts, THEN cam.pos.x/y/z and a derived yaw as floats
               (written after host_advance, once the frame's own move
               has actually happened) -- diagnostic only, -play reads
               back just the input half and ignores the rest.
               Frame-granular, not tick-granular: host_advance already
               reads input once per call and spends it across however
               many fixed ticks that frame runs, so a live session
               never saw input change mid-frame either -- this is not
               an approximation of what -record captures, it is
               exactly it. -play replaces the real (here, absent --
               headless has no hardware mouse/keyboard) input with the
               recording, frame for frame, so a live-session crash
               reproduces without a person driving it again.

               Two earlier versions wrote to disk -- every frame, then
               batched every REC_FLUSH frames -- and both were measured
               live to change whether the crash reproduces at all: file
               I/O the original run never spent, perturbing the very
               timing this bug depends on. No disk I/O during the run
               at all now: one far-allocated buffer, one write into it
               a frame, nothing else. Its far pointer and REC_MAX are
               logged once via mark() (see below), so a crash -- which
               never reaches the code that would flush it -- still
               leaves every frame recorded exactly where the log says
               to find it: read straight out of guest memory with the
               debugger (dosbox_mem_read), not the file. A clean exit
               writes it to disk too, as a convenience for -play. */
/* far, not huge: a single object must stay under 64K, so REC_MAX*34 (+2
   for count) has to fit -- 1900*34+2 = 64,602 bytes is the room used. */
#define REC_MAX 1900
            typedef struct { short in[9]; float px, py, pz, yaw; } RecEntry;
            typedef struct { short count; RecEntry e[REC_MAX]; } RecBuf;
            RecBuf far *rec_buf = 0;
            RecEntry rec;
            FILE *rf = 0;
            short play_drift = 0;   /* reported once, then stop checking */

            if ( args.record_name[0] ) {
                rec_buf = (RecBuf far *) qglMemAlloc( (long) sizeof(RecBuf) );
                if ( !rec_buf ) sys_error( "out of far memory for -record buffer" );
                rec_buf->count = 0;
                {
                    char mbuf[64];
                    long raw = (long) (void far *) rec_buf;
                    sprintf( mbuf, "rec_buf seg=%ld ofs=%ld max=%d",
                             raw >> 16, raw & 0xFFFFL, REC_MAX );
                    mark( mbuf );
                }
            } else if ( args.play_name[0] ) {
                rf = fopen( args.play_name, "rb" );
                if ( !rf ) sys_error( "could not open -play file" );
            }

            frame = 0;
            while ( ( clock.bench_ticks == 0 || clock.ticks < clock.bench_ticks )
                    && !input.keyboard.k[KEY_ESC] && fight.state != GS_NEXT ) {
                frame_dt = sys_frame_time( &sysclk, &raw_dt );

                if ( args.play_name[0] && rf ) {
                    /* The input queue: one frame's real mouse and key
                       state, fed in where the drivers would have put
                       it. host_advance then derives the camera from it
                       exactly as it did live -- same code path, no
                       position override -- which is what makes this a
                       test of the run rather than a re-enactment of
                       its camera track. rec.px/py/pz ride along as the
                       recorded ANSWER, checked against the replayed
                       one below, so a divergence is reported rather
                       than papered over. */
                    if ( fread( &rec, sizeof(rec), 1, rf ) != 1 ) {
                        input.keyboard.k[KEY_ESC] = -1;   /* recording ended: stop here, same as the live run did */
                        continue;
                    }
                    input.mouse.x       = rec.in[0];
                    input.mouse.y       = rec.in[1];
                    input.mouse.left    = rec.in[2];
                    input.mouse.right   = rec.in[3];
                    input.keyboard.k[KEY_W]      = rec.in[4];
                    input.keyboard.k[KEY_A]      = rec.in[5];
                    input.keyboard.k[KEY_S]      = rec.in[6];
                    input.keyboard.k[KEY_D]      = rec.in[7];
                    input.keyboard.k[KEY_SPCBAR] = rec.in[8];
                } else if ( args.record_name[0] ) {
                    /* NOT gated on rf: recording goes to the far buffer,
                       and rf is deliberately 0 here. It used to read
                       `&& rf`, which silently never ran -- every in[]
                       came back zero and the first replays reproduced
                       nothing, which read as "input does not describe
                       the run" when it was only ever this. */
                    rec.in[0] = (short) input.mouse.x;
                    rec.in[1] = (short) input.mouse.y;
                    rec.in[2] = (short) input.mouse.left;
                    rec.in[3] = (short) input.mouse.right;
                    rec.in[4] = (short) input.keyboard.k[KEY_W];
                    rec.in[5] = (short) input.keyboard.k[KEY_A];
                    rec.in[6] = (short) input.keyboard.k[KEY_S];
                    rec.in[7] = (short) input.keyboard.k[KEY_D];
                    rec.in[8] = (short) input.keyboard.k[KEY_SPCBAR];
                }

                if ( frame > 3 && raw_dt > 0.0f ) {
                    if ( ft_n == 0 ) { ft_min = raw_dt; ft_max = raw_dt; }
                    else {
                        if ( raw_dt < ft_min ) ft_min = raw_dt;
                        if ( raw_dt > ft_max ) ft_max = raw_dt;
                    }
                    ft_sum += raw_dt;
                    ft_n++;
                }
                /* The same predicate as ft_* above, so pt_frames and ft_n
                   are the same frames and pt_other_mean is a residual of
                   one number and not of two populations. t_frame is the
                   frame's own boundary rather than raw_dt, which is the
                   PREVIOUS frame's length -- subtracting phases from that
                   would leave a residual off by a whole frame's shift. */
                if ( frame > 3 ) {
                    /* The walk's counters are means over the PROFILED
                       frames, so they start where pt.n does. Summed from
                       frame 0 and divided by pt.n they read differently
                       on two arms that rendered a different number of
                       frames over the same ticks -- which is every A/B
                       where one arm is faster, i.e. all of them. */
                    if ( pt.n == 0 ) {
                        rdr.nd_seen = rdr.lf_seen = 0;
                        rdr.mk_faces = rdr.ord_sum = 0;
                    }
                    pt.n++;
                    t_frame = sys_now( &sysclk );
                }

                host_advance( &world, &player, &cam, &rdr, &input, hud, &ls, &fight,
                               &sysclk, &clock, &pt, frame_dt, v.scr_x_res, v.scr_y_res );

                /* Between the tick and the render, where nothing else
                   holds an EMS window -- the mixer takes PAGE_SLOT. It
                   runs every frame whatever is playing: the DMA never
                   stops, so what is not repainted is played again. */
                t_ph = sys_now( &sysclk );
                snd_frame( &player, frame_dt );
                if ( pt.n > 0 ) pt.sound_sum += sys_now( &sysclk ) - t_ph;

                if ( args.play_name[0] && rf && !play_drift ) {
                    /* The camera is NOT pinned: host_advance just
                       derived it from the queued input, and this only
                       checks that against where the live run actually
                       was. First frame past a unit of drift is
                       reported once and then left alone -- a replay
                       that has diverged is still worth watching, but
                       it is no longer the same run and must not be
                       quoted as one. */
                    float dx = cam.pos.x - rec.px;
                    float dy = cam.pos.y - rec.py;
                    float dz = cam.pos.z - rec.pz;
                    if ( dx*dx + dy*dy + dz*dz > 1.0f ) {
                        sprintf( buf, "play DIVERGED at frame %d: got %ld,%ld,%ld want %ld,%ld,%ld",
                                 frame, (long) cam.pos.x, (long) cam.pos.y, (long) cam.pos.z,
                                 (long) rec.px, (long) rec.py, (long) rec.pz );
                        mark( buf );
                        play_drift = 1;
                    }
                }

                if ( args.record_name[0] ) {
                    /* atan2(-dz, dx), mirrored the same as -yaw's own
                       convention (view.c's freelook math), degrees to
                       match the HUD's own display. */
                    rec.px  = cam.pos.x;
                    rec.py  = cam.pos.y;
                    rec.pz  = cam.pos.z;
                    rec.yaw = (float) ( atan2( -(double)(cam.look_at.z - cam.pos.z),
                                                 (double)(cam.look_at.x - cam.pos.x) ) * 57.29578 );
                    /* Only a new slot if position actually moved --
                       a static spawn-camping stretch (measured: at
                       least 1900 frames of it, standing still, before
                       one crash) would otherwise burn the whole buffer
                       on one point and lose everything closer to the
                       actual fault. */
                    if ( rec_buf->count < REC_MAX &&
                         ( rec_buf->count == 0 ||
                           rec_buf->e[rec_buf->count-1].px != rec.px ||
                           rec_buf->e[rec_buf->count-1].py != rec.py ||
                           rec_buf->e[rec_buf->count-1].pz != rec.pz ) ) {
                        rec_buf->e[ rec_buf->count ] = rec;
                        rec_buf->count++;
                    }
                }

                qglDrFill( h_dst_dc, 0, 0, (short)(v.x_res - 1), (short)(v.y_res - 1), 0 );
                host_render( &world, &rdr, &cam, &player, sc, &ls, hud, &fight, &pt, &sysclk,
                              h_dst_dc, &mtx_prj, (float) v.x_res / 2.0f, (float) v.y_res / 2.0f,
                              cfg.z_near, cfg.z_far,
                              &cam_up, z_dc, v.comp, args.no_draw,
                              v.x_res, v.y_res );
                in_screenshot_key( &input, h_dst_dc, v.x_res, v.y_res );
                t_ph = sys_now( &sysclk );
                v_present( &v, h_dst_dc, 0 );

                /* -comp: v_present has already scaled the 3D view into
                   the composite (v.h_comp_dc, screen-mode sized) and
                   left the screen itself untouched -- host_render's
                   own scr_draw_hud call was skipped for exactly this
                   case. Draw the overlay onto the composite now, at
                   the mode's own resolution (not the small render
                   target the panels were clipping against), then one
                   qglDrBlit carries the whole thing to video. Drawing it
                   onto live video memory after a present instead would
                   be a second pass over VRAM -- it tears, and VRAM is
                   slow enough to cost frames (matches main.bas's own
                   reasoning for doing it this way). */
                if ( v.comp ) {
                    scr_sbar_draw( &fight, v.h_comp_dc, v.scr_x_res, v.scr_y_res );
                    scr_draw_hud( &world, &rdr, &cam, &player, sc, hud,
                                  v.h_comp_dc, v.scr_x_res, v.scr_y_res );
                    scr_draw_msg( hud, &world, &fight, &rdr, v.h_comp_dc, v.scr_x_res, v.scr_y_res );
                    qglDrBlit( v.h_video_dc, 0, 0, v.h_comp_dc );
                }
                if ( pt.n > 0 ) pt.present_sum += sys_now( &sysclk ) - t_ph;

                /* Read rdr.polys/tris BEFORE scr_count_frame, which
                   resets them for the next frame (screen.bas's own
                   job, real now) -- rdr's own fields are short and
                   would overflow negative over a long run at ~150
                   polys/frame if left to accumulate across the whole
                   session instead, so the real running total lives
                   in these longs here. */
                poly_sum += rdr.polys;
                if ( pt.n > 0 ) pt_poly_sum += rdr.polys;
                tri_sum  += rdr.tris;
                mdl_sum  += rdr.mdl_drawn;
                scr_count_frame( hud, &rdr, sc, frame_dt );
                if ( pt.n > 0 ) {
                    float dt = sys_now( &sysclk ) - t_frame;
                    pt.frame_sum += dt;
                    if ( dt > pt.frame_max ) pt.frame_max = dt;
                }
                frame++;
            }

            if ( rf ) fclose( rf );
            if ( rec_buf && rec_buf->count > 0 ) {   /* clean exit: dump the whole buffer once, for -play */
                FILE *wf = fopen( args.record_name, "wb" );
                if ( wf ) { fwrite( rec_buf->e, sizeof(RecEntry), rec_buf->count, wf ); fclose( wf ); }
            }

            sprintf( buf, "frames=%d polys=%ld tris=%ld mdl=%ld pos=%ld,%ld,%ld",
                     frame, poly_sum, tri_sum, mdl_sum,
                     (long) cam.pos.x, (long) cam.pos.y, (long) cam.pos.z );
            mark( buf );

            /* what the player is carrying when the run ends: the only
               headless view of a pickup actually happening */
            {   short mon_hunt, mon_moved;
                mdl_ai_stats( &world, &mon_hunt, &mon_moved );
                sprintf( buf, "ai hunting=%d moved=%d leaps=%d",
                         (int) mon_hunt, (int) mon_moved, (int) fight.leaps );
                mark( buf );
            }

            {   short st, lp, un;
                snd_stats( &st, &lp, &un );
                sprintf( buf, "snd started=%d loops=%d under=%d", (int) st, (int) lp, (int) un );
                mark( buf );
            }

            sprintf( buf, "gs_state %d map %s next %s secrets %d/%d",
                     (int) fight.state, args.map_name, fight.next_map,
                     (int) fight.secrets, (int) fight.secret_total );
            mark( buf );

            sprintf( buf, "fight=health %d shells %d nails %d rockets %d armor %d items %ld took %d kills %d booms %d deaths %d",
                     fight.health, fight.shells, fight.nails, fight.rockets,
                     fight.armor, fight.items, item_taken( &world ), fight.kills, fight.booms, fight.deaths );
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
                    /* The phase sums below cover EVERY frame; ft_* skip the
                       warm-up ones. Print both counts rather than leave a
                       reader to wonder how a phase mean can exceed the frame
                       mean -- it did, by exactly the ratio of these two. */
                    fprintf( bf, "pt_frames %ld\n", pt.n );
                    fprintf( bf, "fps_mean %ld.%02ld\n", (long) (ft_n/ft_sum), (long) ((ft_n/ft_sum)*100) % 100 );
                    if ( pt.n > 0 ) {
                        /* ms a frame over the frames profiled, which are ft_n's
                           own. pt_other is what the brackets do not reach --
                           the backbuffer clear, the input read, screen.bas's
                           counters, and any pass added without one. */
                        float ph[9];
                        char *nm[9];
                        short i;

                        ph[0] = pt.frame_sum;   nm[0] = "frame";
                        ph[1] = pt.tick_sum;    nm[1] = "tick";
                        ph[2] = pt.cull_sum;    nm[2] = "cull";
                        ph[3] = pt.draw_sum;    nm[3] = "draw";
                        ph[4] = pt.alias_sum;   nm[4] = "alias";
                        ph[5] = pt.hud_sum;     nm[5] = "hud";
                        ph[6] = pt.sound_sum;   nm[6] = "sound";
                        ph[7] = pt.present_sum; nm[7] = "present";
                        ph[8] = pt.frame_sum - ( pt.tick_sum + pt.cull_sum + pt.draw_sum +
                                                 pt.alias_sum + pt.hud_sum + pt.sound_sum +
                                                 pt.present_sum );
                        nm[8] = "other";
                        for ( i = 0; i < 9; i++ ) {
                            float ms = ph[i] / pt.n * 1000.0f;
                            short neg = (short) ( ms < 0.0f );
                            long  us = (long) ( ( neg ? -ms : ms ) * 1000.0f + 0.5f );
                            fprintf( bf, "pt_%s_mean %s%ld.%03ld\n", nm[i],
                                     neg ? "-" : "", us / 1000, us % 1000 );
                        }
                        /* build and raster are INSIDE draw, so they are printed
                           apart from the sum above rather than beside it. */
                        fprintf( bf, "pt_build_mean %ld.%03ld\n",
                                 (long) ((pt.build_sum/pt.n)*1000), (long) ((pt.build_sum/pt.n)*1000000) % 1000 );
                        fprintf( bf, "pt_raster_mean %ld.%03ld\n",
                                 (long) ((pt.raster_sum/pt.n)*1000), (long) ((pt.raster_sum/pt.n)*1000000) % 1000 );
                        fprintf( bf, "pt_frame_max %ld.%03ld\n",
                                 (long) (pt.frame_max*1000), (long) (pt.frame_max*1000000) % 1000 );
                        /* the walk alone, inside cull, and what it walked */
                        fprintf( bf, "pt_walk_mean %ld.%03ld\n",
                                 (long) ((pt.walk_sum/pt.n)*1000), (long) ((pt.walk_sum/pt.n)*1000000) % 1000 );
                        fprintf( bf, "pt_nodes %ld\n", rdr.nd_seen / pt.n );
                        fprintf( bf, "pt_leaves %ld\n", rdr.lf_seen / pt.n );
                        fprintf( bf, "pt_marked %ld\n", rdr.mk_faces / pt.n );
                        fprintf( bf, "pt_polys %ld\n", pt_poly_sum / pt.n );
                        fprintf( bf, "pt_vis_leaves %d\n", rdr.vis_leaves );
                        fprintf( bf, "pt_vis_nodes %d\n", rdr.vis_nodes );
                        fprintf( bf, "pt_ord %ld\n", rdr.ord_sum / pt.n );
                    }
                    {   /* The portal flood's own work, so a cull cost can be
                           divided by something real instead of guessed at. */
                        long pops, projs, pushes;
                        r_portal_stats( &pops, &projs, &pushes );
                        fprintf( bf, "pt_pops %ld\n", pops );
                        fprintf( bf, "pt_projs %ld\n", projs );
                        fprintf( bf, "pt_pushes %ld\n", pushes );
                    }
                }
                fclose( bf );
            }
        }
    }

    if ( v.h_back_bdc ) qglSfFree( v.h_back_bdc );
    /* The ISRs come out FIRST, and this is not tidiness: INT 8 and
       INT 9 point into this program, and DOS does not restore a vector
       when a program ends. A second run in the same session -- which
       is what a changelevel is -- then installed its own timer over a
       dead handler and chained to it, so the BIOS tick stopped
       advancing and sys_time_init spun in its tick-edge wait for ever,
       two marks into the load. It never showed while one run was the
       whole session. */
    snd_shutdown();
    qglTmrShutdown();
    qglKbdShutdown();
    qglMouseShutdown();
    qglVgaShutdown();
    qglMemShutdown();
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
