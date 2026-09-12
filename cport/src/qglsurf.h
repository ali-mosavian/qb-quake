#ifndef __QGLSURF_H__
#define __QGLSURF_H__

#include "qgl.h"

/* mkassets.py's own packing width, for both atlases. It owns the
   layout; these say what it chose, they do not decide it. */
#define TEX_ATLAS_W 8192
#define LM_ATLAS_W  8192

/*
 * qgl_surf_from_file -- open, size, make, fill, close.
 *
 * qgl ships this as qglSfFromFileBas, gated on __BASIC__ because BASIC
 * cannot hand over an asciiz path. C can, so this is the same five
 * steps against the public entries.
 *
 * THE HEIGHT COMES FROM THE FILE, exactly as qgl's own does: the
 * alternative is for the caller to re-derive mkassets.py's packing
 * (textures x mips x cell area, rounded to the atlas width) to know how
 * tall its own atlas is, and mkassets owns that. A file whose length is
 * not a whole number of rows is refused rather than rounded.
 *
 * The file is a flat byte stream, not a BMP: qgl has no image decoder
 * and does not want one -- the atlas was never an image, only a
 * container for the run of cells the fillers walk.
 */
QSurf qgl_surf_from_file( const char far *path, short wide, short whr,
                          long *out_bytes );

#endif
