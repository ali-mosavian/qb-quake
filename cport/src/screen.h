#ifndef __SCREEN_H__
#define __SCREEN_H__

#include "world.h"
#include "renderer.h"
#include "hud.h"
#include "sc.h"
#include "ugl.h"

/*
 * screen.h -- the overlay. C port of a slice of screen.bas: the
 * bitmap font, the stats panels, the screenshot writer. The loading
 * screen is loadscr.h's, not this file's. Note this header used to
 * claim it had been cut because "loads happen before any video mode
 * exists to show one on" -- that was simply wrong. v_init opens the
 * mode long before mod_load_world runs, so the whole map load spent
 * its time painting nothing to a live screen. Not ported: the VU
 * meters (hud_vu,
 * sndMasterGetVU) -- sound is dropped project-wide, see this
 * project's own notes on why.
 */

/*
 * name: font_load
 * desc: Reads flname (base.dat::font/4x6.fnt's own format: a 4-byte
 *       "font" id, then 256 glyphs of 4 words / 8 bytes each) straight
 *       into font->glyph, no uGL DC involved at all -- see hud.h's own
 *       note on why draw_load_font's 256-masked-DC approach doesn't
 *       carry over. Fatal (via asset_load_whole's own sys_error) on a
 *       missing file or a short read, matching draw_init_font's own
 *       "could not load font" fatal one level up in the original.
 */
void font_load( Font far *font, char *flname );

/* Text in a chosen colour -- the original's draw_string always drew
   in the one colour draw_load_font baked the glyphs at (LP_TEXT, 254);
   nothing here needs a baked font, so every caller just names its own
   colour instead, folding hud_num's own "any colour" case into the
   same function. 4 pixels advance per character, matching the font's
   own 4-wide glyphs. */
void draw_string( Hud far *hud, PDC dc, short x, short y, char *text, long col );

/* Right-aligned against x -- x is the text's own right edge. */
void draw_string_r( Hud far *hud, PDC dc, short x, short y, char *text, long col );

/* A number at sc pixels per glyph-pixel, with a one-pixel shadow so it
   sits on the slab instead of floating -- hud_panel's own big fps
   counter is the only caller that wants this over plain draw_string. */
void hud_num( Hud far *hud, PDC dc, short x, short y, short sc, char *txt, long col );

/*
 * name: scr_hud_colors
 * desc: Best-fits the overlay's colours against whatever palette is
 *       currently installed. Call once, after the game palette is
 *       live (qmain.c's own uglPalSet, right after mod_load_textures).
 */
void scr_hud_colors( Hud far *hud );

/* Tinted glass: darkens the scene under a rect through Quake's own
   colormap (uglShadeRect), or falls back to an opaque slab when
   world's colormap never loaded -- the overlay never depends on -lm's
   data being there. */
void hud_shade( World *world, Hud far *hud, PDC dc, short x0, short y0, short x1, short y1, short rw );

void hud_panel( World *world, Hud far *hud, PDC dc, short x, short y, short w, short h, char *title );
void hud_row( Hud far *hud, PDC dc, short x, short w, short y, char *label, char *value );
void hud_bar( Hud far *hud, PDC dc, short x, short y, short w, short h, float percent );

/* One pixel column per remembered frame, oldest at the left; buf is
   one of Hud's own GRAPH_N-sized rings (g_bld/g_fps). */
void hud_graph( Hud far *hud, PDC dc, short x, short y, short h, short *buf, short mx );

/* Sound VU bars, the statistics overlay and the watermark -- minus
   the VU bars themselves (see this file's own header note on why).
   cam/player are both here only for the always-drawn viewpoint line:
   the look direction comes from cam, the printed position from
   player->pos (pl.pos, not cam.pos -- -at takes the hull origin, and
   the eye sits PL_EYE above it, matching the original's own note). */
void scr_draw_hud( World *world, Renderer *rdr, Camera *cam, Player *player,
                    SurfCache far *sc, Hud far *hud, PDC h_dst_dc, short w, short h );

/* Rolls fps once a second (off SysClock's own frame_dt rather than a
   dedicated hardware timer channel -- see hud.h's own note) and
   clears the per-frame poly/tri counters the next frame accumulates
   into. Call once per frame, after presenting it. */
void scr_count_frame( Hud far *hud, Renderer *rdr, SurfCache far *sc, float frame_dt );

/* Writes an 8-bit BMP of dc's own w by h pixels, in the currently
   installed palette, to flname. */
void scr_screenshot( char *flname, PDC dc, short w, short h );

#endif
