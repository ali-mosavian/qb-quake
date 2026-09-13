#ifndef __HUD_H__
#define __HUD_H__

/*
 * Hud -- the overlay's own state. C port of screen.bas's 26 dim shared,
 * folded into one struct the way d_surf.bas's own globals became
 * SurfCache/LightStyles.
 */

/* How many frames of history hud_graph keeps -- one pixel column each,
   so this is also their width. */
#define GRAPH_N 64

/*
 * Font -- the 4x6 bitmap font, as loaded straight from base.dat's own
 * file, NOT baked into 256 uGL-managed DCs the way the original's
 * draw_load_font does. uglNewMult (the call that would fill an array
 * of DC handles) takes a `QSurf ARRAY *` -- mgl's own BASIC-array-
 * descriptor type, the identical incompatibility qgl.h's own note
 * already covers for qglArNew/qglArWin/qglArLoad: C has no
 * descriptor for it to fill. There is also no reason to want one here
 * -- draw_string is called a handful of times a frame, not per pixel,
 * so a direct bit-test against a 2 KB buffer plus qglSfPset costs
 * nothing worth avoiding, and it is simpler than baking 256 masked
 * DCs (a real conventional-memory cost the atlas work elsewhere in
 * this project fought hard to avoid) just to call uglPutMsk.
 *
 * glyph[c][0..3] are the raw 16-bit words exactly as the .fnt file
 * stores them -- see font_bit's own comment for the bit order, ported
 * verbatim from draw_load_font rather than re-derived, since getting
 * the bit order wrong would silently swap which pixels are set.
 */
typedef struct {
    unsigned short glyph[256][4];
} Font;

typedef struct {
    short stats;
    short portal_wire;
    short bench;         /* a -ticks run: the frame is going to be captured */

    /* scr_count_frame's own state: fps rolls over once a second, off
       the same SysClock frame_dt every tick already uses rather than
       a dedicated hardware timer channel (the original's own
       g.env.sec_timer, TMR.AUTOINIT) -- one less thing to init, and
       "once a second" needs no more precision than that. */
    short fps;
    short fps_peak;
    short frame_count;   /* fps1: this second's running tally */
    float fps_accum;     /* seconds since the last rollover */

    /* hud_graph's own history, one ring shared by both buffers */
    short g_bld[GRAPH_N];
    short g_fps[GRAPH_N];
    short g_head;

    /* the surface-cache panel's warning flash */
    short hud_flash;
    long  hud_pevict;
    long  hud_pflush;

    /* scr_hud_colors' own: best-fit against whatever palette is live,
       so the overlay shares the game's own material language instead
       of assuming fixed indices. hc_text stands in for the original's
       LP_TEXT (a fixed index, 254, the loading screen's own palette
       set to a deliberate near-white) -- the game palette has no such
       reservation, so this is best-fit the same way as every other
       hc_* entry, against a warm near-white target, rather than
       assumed to land anywhere in particular. */
    short hc_bg, hc_slab, hc_slabhi, hc_slablo;
    short hc_hist, hc_peak, hc_meter;
    short hc_good, hc_warn, hc_bad;
    short hc_text;

    Font font;   /* font_load is fatal on failure (asset_load_whole's own
                    sys_error), so nothing here needs a "did it load" flag
                    -- draw_string et al. can assume a real font once
                    font_load has returned at all */
} Hud;

#endif
