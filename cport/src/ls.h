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
#define LS_UNSET    116     /* a style nothing set: id's 256 where 'm' is
                                264 */

typedef struct {
    const char *pattern;  /* world.qc's, up to 51 characters */
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

/* A face's styles, packed as its geometry record carries them: bytes 0
   and 1 in s01, 2 and 3 in s23, 255 past the last. The k-th, how many,
   and one epoch that moves when any of theirs does. */
/* light_use's lightstyle(style, "m") or "a". */
void ls_switch( LightStyles *ls, short style, short on );

/* Every style at "m", for good: -nostyles, the A/B. */
void ls_hold( LightStyles *ls );

short ls_face_style( short s01, short s23, short k );
short ls_face_styles( short s01, short s23 );
short ls_face_epoch( LightStyles *ls, short s01, short s23 );

/* Proves the animation loop, not any real map's data -- see ls.c's own
   header on ls_selftest for what each check establishes. Returns 1 on
   success, a negative code naming which check failed. */
short ls_selftest( void );

#endif
