#ifndef __QGLSURF_H__
#define __QGLSURF_H__

#include "qgl.h"

/* mkassets.py's own packing width, for both atlases. It owns the
   layout; these say what it chose, they do not decide it. */
#define TEX_ATLAS_W 8192
#define LM_ATLAS_W  8192

/*
 * qgl_surf_from_member -- seek, size, make, fill. No open and no close:
 * the map container is open for the whole run and the surface is one
 * member of it, so this is qglFileSeek and qglSfLoadFh, which is the
 * handle-taking half qglSfLoad wraps in an open/close pair.
 *
 * THE HEIGHT COMES FROM THE MEMBER, exactly as qgl's own does: the
 * alternative is for the caller to re-derive mkassets.py's packing
 * (textures x mips x cell area, rounded to the atlas width) to know how
 * tall its own atlas is, and mkassets owns that. A member whose length
 * is not a whole number of rows is refused rather than rounded.
 *
 * The member is a flat byte stream, not a BMP: qgl has no image decoder
 * and does not want one -- the atlas was never an image, only a
 * container for the run of cells the fillers walk.
 */
QSurf qgl_surf_from_member( char *member, short wide, short whr,
                            long *out_bytes );

#endif
