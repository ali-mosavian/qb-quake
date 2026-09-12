#ifndef __MOD_TEX_H__
#define __MOD_TEX_H__

#include <stdio.h>

#include "world.h"
#include "mod.h"
#include "qgl.h"   /* PalRgb far * */

/*
 * mod_tex.h -- texture headers and the preprocessed atlas bitmaps. C
 * port of mod_tex.bas, mod_load_texinfo and mod_load_textures merged
 * into one function: main.bas always called them back to back (no
 * other caller ever wanted just one), and BASIC only split them for
 * two separate scr_load_stage banners -- a loading-screen UI detail
 * screen.bas doesn't have here yet.
 *
 * Must run with the SAME open FILE* mod_load_world's own mod_open
 * returned, and BEFORE mod_close: this reads texture headers straight
 * out of the raw .bsp (see bsphdr.h's own note on why), not from
 * assets.zip.
 */

/*
 * name: mod_load_textures
 * desc: Builds world->texinfo (assets.zip::texinf.bld) and
 *       world->miptex (per-texture width/height/liquid/animation,
 *       read from the raw file's own miptex directory), then the two
 *       texture atlases and their per-mip views, then links +N-prefixed
 *       texture names into animation chains. Returns the loaded game
 *       palette (uglPalLoad's own result, possibly NULL -- the
 *       original never checked it either); the caller owns installing
 *       and freeing it (vid.c's v_init).
 */
PalRgb far * mod_load_textures( World *world, MapCounts *counts );

/* Cell k of mip level mip, as a dc. Re-aims a view rather than owning
   one per texture. */
QSurf mod_tex_raw( World *world, short k, short mip );
QSurf mod_tex_shaded( World *world, short k, short mip );

/* world->tex_ofs as a far pointer, packed into a long -- DrawParams'
   own tex_ofs_ptr field (d_faces.c, not yet ported) carries every far
   pointer this way, matching the rest of that struct. */
long world_tex_ofs_ptr( World *world );

#endif
