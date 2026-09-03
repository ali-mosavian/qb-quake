#ifndef __SB_BUILD_H__
#define __SB_BUILD_H__

#include "renderer.h"
#include "world.h"
#include "sc.h"
#include "ls.h"

/* The parameter block uglBuildSurf reads back out of a packed far
   pointer, not a BASIC-to-C call parameter itself -- see
   uglpatch.h's own uglBuildSurf. */
typedef struct {
    long  lmptr;
    long  lm_stride;
    long  cmap_ptr;
    long  au0;
    long  av0;
    long  du;
    long  dv;
    short sw;
    short sh;
    short lmw;
    short lmh;
    short shft;
    short msk;
} SurfBuild;

/*
 * name: sb_build
 * desc: Composites one face's texture and lightmap into a cache DC
 *       (dc, already sc_alloc'd/sc_find's own view, aimed at the
 *       surface's bytes). Sets up an SBPARM and hands the texel loop
 *       to uglBuildSurf -- what stays here is per face, not per texel:
 *       the light table, the resampling steps, and normalising the
 *       luxel pointer. gv is the face's already-fetched geometry
 *       record (d_poly's own scratch -- the caller's, not World's).
 */
void sb_build( SurfCache far *sc, World *world, Renderer *rdr, LightStyles *ls,
               PDC dc, PDC tex, short face, short mip, short sw, short sh,
               short far *gv );

#endif
