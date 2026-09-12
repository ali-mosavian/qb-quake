#ifndef __SBAR_H__
#define __SBAR_H__

#include "qgltypes.h"
#include "fight.h"

/*
 * sbar.h -- Quake's own status bar, out of gfx.wad.
 *
 * Everything lives in ONE EMS surface, 512 wide because an EMS row has
 * to divide 16K: the untouched bar in rows 0..23, the twenty-one cells
 * side by side in 24..47, and the composed bar in 48..71, which a
 * 320-wide view is aimed at and the blit reads. The far-heap tables
 * this replaces -- rows, cells, spans -- were 28K, which e1m1 does not
 * have.
 *
 * A qpic's 255 is transparent and stays that way: the bar under the
 * number slots is textured and differs slot to slot, so nothing can be
 * composited offline.
 */
#define SBARC_W       320
#define SBARC_H       24
#define SBARC_EMS_W   512
#define SBARC_CELL_Y  24      /* band holding the cells */
#define SBARC_WORK_Y  48      /* band the blit reads, composed per paint */
#define SBARC_EMS_H   72
#define SBARC_CELL    24
#define SBARC_CELLS   21
#define SBARC_ICON    11      /* SB_SHELLS */
#define SBARC_FACE    12      /* FACE1, the healthy one; FACE5 is +4 */
#define SBARC_ARMOR   17      /* SB_ARMOR1, green; yellow is +1 */
#define SBARC_NAILS   19
#define SBARC_ROCKETS 20

/*
 * name: scr_sbar_load
 * desc: sbar.raw into the surface's top band and sbnum.raw's cells into
 *       the middle one, both straight out of the map container.
 */
void scr_sbar_load( void );

/*
 * name: scr_sbar_draw
 * desc: The bar along the bottom of dst, scaled to its width. Repaints
 *       only when a number on it changed.
 */
void scr_sbar_draw( Fight *fight, QSurf dst, short w, short h );

#endif
