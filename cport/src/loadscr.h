#ifndef __LOADSCR_H__
#define __LOADSCR_H__

#include "qgl.h"    /* QSurf */
#include "hud.h"    /* Hud, for the glyphs draw_string reads */

/*
 * loadscr.h -- the loading screen. C port of screen.bas's scr_load_*
 * family, which screen.h had recorded as a deliberate scope cut on the
 * grounds that "loads happen before any video mode exists to show one
 * on". That was wrong about cport: v_init opens the mode well before
 * mod_load_world runs, so the whole map load was drawing nothing to a
 * live 320x200 screen -- black until the first frame.
 *
 * Its own module rather than more of screen.c: one module, one
 * subsystem, and this one only exists between v_init and the first
 * frame. Everything here is ld_*.
 *
 * What is NOT ported, and it is a scope cut this time rather than a
 * mistaken premise: the decorative chrome (draw_logo, bg_band's wall
 * speckle, rivet, draw_spinner). Those are ~200 lines of BASIC drawing
 * a Quake-menu pastiche; the panel, the trough, the amber bar and the
 * stage line are what actually tell you the load is progressing.
 */

/* screen.bas's own ramp layout, kept so the colours match the original:
   four ramps packed into the low half of the palette, each one warm --
   nothing here is a clean grey, which is what stops it reading as a
   generic dark UI. */
#define LP_STN0   1     /* 48-step stone, near black -> mid brown */
#define LP_STNN   48
#define LP_BRZ0   49    /* 32-step bronze, the plates */
#define LP_BRZN   32
#define LP_ACC0   81    /* 32-step ember, the bar */
#define LP_ACCN   32
#define LP_NEU0   113   /* 16-step warm neutral, rules and text */
#define LP_NEUN   16

typedef struct {
    float pct;        /* 0..100 */
    short steps;      /* how many ld_step calls make up the whole load */
    short done;       /* steps taken so far */
} LoadScreen;

/*
 * name: ld_begin
 * desc: Installs the loading palette and paints the panel. steps is how
 *       many ld_step calls the caller intends to make, so the bar is
 *       scaled to the real load rather than a constant that drifts
 *       whenever a phase is added. The palette it installs is replaced
 *       wholesale by the map's own later (uglPalSet in main), which is
 *       why this can own the low 128 entries outright.
 */
void ld_begin( LoadScreen *ld, QSurf dc, Hud far *hud, short steps,
                short w, short h );

/*
 * name: ld_stage
 * desc: Names what is loading now, on the line above the bar. Redraws
 *       the bar too, so a caller that only ever calls this still shows
 *       progress.
 */
void ld_stage( LoadScreen *ld, QSurf dc, Hud far *hud, char *what );

/*
 * name: ld_step
 * desc: One phase done. Advances the bar by 1/steps and redraws.
 */
void ld_step( LoadScreen *ld, QSurf dc, Hud far *hud );

#endif
