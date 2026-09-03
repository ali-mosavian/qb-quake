#ifndef __CONFIG_H__
#define __CONFIG_H__

/*
 * config.h -- stuff.ini, read into one struct. C port of common.bas's
 * com_parse_config slice (the tokenizer/com_tokenize itself isn't
 * needed: BASIC's own array-of-variable-length-strings shape is what
 * forced that design, and C can just split each line on '=' and
 * whitespace directly).
 *
 * Table-driven rather than the thirteen-case SELECT CASE the BASIC
 * has: AGENTS.md's own note on why that table-driven form doesn't pay
 * for the ini parser IN BASIC (a second SELECT CASE to do the
 * assignment, so the branch count doesn't actually drop) is specific
 * to a language with no function pointers and no offsetof -- with
 * both, one loop over a table replaces the branches outright instead
 * of just moving them.
 *
 * Every key in stuff.ini except render.xres/render.yres is required;
 * config_load is fatal (matching the original's own "Incorrect ini
 * file...") if any is missing or malformed, or if the file will not
 * open.
 */

typedef struct {
    short scr_x_res, scr_y_res;   /* display.xres/yres -- the video mode */
    short x_res, y_res;           /* render.xres/yres -- optional, defaults
                                      to the screen size */
    short clear_screen;           /* display.clear */
    short pages;                  /* display.pages */
    short use_paging;             /* display.usepaging */
    float z_near, z_far;          /* world.frustum.zn/zf */
    char  cam_script[64];         /* world.camera.script */
    short cam_interp;             /* world.camera.interp */
    short cam_mode;                /* world.camera.mode: 0 freelook,
                                       1 script_play, 2 script_edit */
    float cam_fov;                /* world.camera.fov */
    short sound;                  /* sound.enabled -- parsed for stuff.ini
                                      compatibility; nothing in cport/ reads
                                      it, sound is dropped project-wide */

    /* Derived by config_load itself, same formulas as the original's
       own tail end: the largest whole-number backbuffer scale that
       still fits the screen, and where the (possibly smaller, scaled)
       view lands on it. */
    short view_scale;
    short view_w, view_h;
    short view_x, view_y;
} Config;

/* Reads flname (stuff.ini's own path), fatal (prints to stderr and
   exits) on a missing file, a missing required key, or a malformed
   line -- matching the original's own all-required, no-partial-config
   behaviour. */
void config_load( Config *cfg, char *flname );

#endif
