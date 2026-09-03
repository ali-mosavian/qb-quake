#ifndef __LS_H__
#define __LS_H__

/*
 * ls.h -- light styles. C port of d_surf.bas's ls_* slice: Quake's
 * animated lighting (torches flickering, strobes, etc), keyed by a
 * style id 0..LS_MAXSTYLE that a face's lightmap carries and every
 * texel scales against.
 *
 * Own module (not folded into Renderer): d_surf.bas is two genuinely
 * separate subsystems sharing one BASIC file for no reason but where
 * QuickBASIC happened to put them -- light styles and the surface
 * cache never call each other. The port plan's own architecture table
 * already names this LightStyles, distinct from SurfCache.
 */

#define LS_MAXSTYLE 63
#define LS_RATE     10.0f   /* Quake's own rate: ten steps a second */
#define LS_NEUTRAL  120     /* ls_lchar('m')'s value -- the intensity the
                                compiler assumed while baking, so a style
                                sitting exactly here needs no scaling */

typedef struct {
    char  pattern[33];  /* q_surf.bi's `string * 32`, null-terminated here
                            instead of space-padded */
    short length;
    short frame;
    short value;         /* current intensity: (pattern[c]-'a') * 10 */
    short epoch;          /* bumped whenever value actually changes */
} LightStyleEntry;

typedef struct {
    LightStyleEntry tab[LS_MAXSTYLE + 1];
    float last;    /* anim_time ls_animate last ran at */
} LightStyles;

/*
 * name: ls_init
 * desc: Style 0 is steady, and everything not given a pattern here
 *       defaults to steady too -- Quake's own fallback for an id no
 *       pattern was ever assigned to.
 */
void ls_init( LightStyles *ls );

/*
 * name: ls_animate
 * desc: Called once a tick with the map's own running clock, so style
 *       animation is exactly as deterministic as physics -- the fixed
 *       10 Hz rate, not wall-clock time or framerate.
 */
void ls_animate( LightStyles *ls, float anim_time );

/* The value sc_find/sc_alloc key a cached surface's lighting on.
   Out-of-range clamps to style 0 (steady) rather than faulting. */
short ls_epoch( LightStyles *ls, short style );

/* The intensity sb_build scales a face's luxels against. Same
   out-of-range clamp as ls_epoch, and for the same reason. */
short ls_value( LightStyles *ls, short style );

/* One luxel, scaled from the compiler's assumed LS_NEUTRAL to the
   style's current value. */
short ls_scale_byte( short raw, short sval );

/* One luxel, brightened by a dynamic light. pdist/ts/tt are all
   texel-unit distances -- perpendicular to the face's plane, and the
   two lateral ones, from the light's projection to this luxel. */
short ls_add_dlight( short raw, float pdist, float ts, float tt, float radius );

/* Proves the animation loop, not any real map's data -- see ls.c's own
   header on ls_selftest for what each check establishes. Returns 1 on
   success, a negative code naming which check failed. */
short ls_selftest( void );

#endif
