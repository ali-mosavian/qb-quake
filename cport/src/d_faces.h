#ifndef __D_FACES_H__
#define __D_FACES_H__

#include "renderer.h"
#include "world.h"
#include "sc.h"
#include "ls.h"
#include "sys_time.h"

/*
 * d_faces.h -- d_draw_faces, the whole per-frame face loop. C port of
 * the existing BASIC-linked src/d_faces.c, adapted the same way
 * pl_trace.c/r_walk.c/r_portal.c/sb_build.c already were: the dozen
 * BASARRAY descriptors it used to take (tri/texinf/gv/facemdl/brush/
 * planes/nodes/mipinf/order/pflag) collapse to World-/Renderer-taking
 * parameters, since
 * every one of those arrays already lives on one or the other.
 *
 * ONE call per frame -- that's the entire point of the original file,
 * see its own header for the measurement that established it, and
 * nothing here changes that shape.
 */
void d_draw_faces( World *world, Renderer *rdr, SurfCache far *sc, LightStyles *ls,
                    DrawParams *dp, u3dMtrx *mtx, u3dVector3f *campos, SysClock *sysclk );

#endif
