#ifndef __PL_TRACE_H__
#define __PL_TRACE_H__

#include "renderer.h"
#include "world.h"
#include "pl_move.h"    /* TraceResult */

/*
 * name: pl_trace
 * desc: Sweeps the player hull from start to fin, against the world
 *       and every solid brush entity, leaving the closest hit in tr.
 */
void pl_trace( World *world, Vec3 *start, Vec3 *fin, TraceResult *tr );

#endif
