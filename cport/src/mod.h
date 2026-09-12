#ifndef __MOD_H__
#define __MOD_H__

#include "renderer.h"
#include "world.h"
#include "fight.h"

/*
 * mod.h -- reading the map into World. C port of model.bas.
 *
 * Everything here reads a member of the map's own .qmp (mkassets.py's
 * own output, already in the exact runtime record shape World's
 * fields want). The raw .bsp is not opened at all any more: the lump
 * counts and the miptex headers it used to be read for are members
 * too, so a map is one file and the run takes its name.
 */

/* mkassets.py's counts.bin, which is what mod_open used to derive from
   the .bsp header. Field order is the writer's; the guard below is the
   other half of it. */
typedef struct {
    long faces, verts, edges, ledges, leaves, planes, nodes;
    long tex_infos, clips, textures, face_lump_bytes;
    short models;
} QmapCounts;

#define REC_QMAPCOUNTS 46
typedef char rec_qmapcounts_ok[ sizeof(QmapCounts) == REC_QMAPCOUNTS ? 1 : -1 ];

/* MapCount, mod_open's own derived lump counts -- transient, unlike
   World's model_count/face_count/leaf_count: nothing outside the
   loading sequence itself reads a node/plane/tex_info/clip count, so
   these don't belong on World, just threaded through mod_load_world's
   own sub-loaders. */
typedef struct {
    long faces, verts, edges, ledges, leaves, planes, nodes, tex_infos, clips, textures;
    long face_lump_bytes;   /* r_load_lfaces' own read size */
} MapCounts;

/*
 * name: mod_open
 * desc: Names the map container for every later read and takes its
 *       counts.bin. Sets world->model_count/face_count/leaf_count (the
 *       counts real per-frame readers need); everything else comes
 *       back through *counts for mod_load_world's own use.
 */
void mod_open( char *qmp, World *world, MapCounts *counts );

/*
 * name: mod_load_world
 * desc: Every lump of the map, in the order they depend on each
 *       other, EXCEPT textures -- mod_tex.h owns those, its own load
 *       phase, timed separately. main.bas's own call order:
 *       mod_open, mod_load_world, then mod_load_textures.
 */
void mod_load_world( World *world, Renderer *rdr, Camera *cam, Fight *fight, char *map_name, MapCounts *counts );

/*
 * name: mod_load_colormap
 * desc: The 64-shade table the builder shades through. NOT called from
 *       mod_load_world -- matches the original, where this was
 *       main.bas's own call, made after vid_init: the colormap needs a
 *       contiguous 16K EMS page, and by the time other map data has
 *       loaded, conventional memory (where an earlier attempt tried to
 *       fit it as a BASIC array) no longer has that much to spare.
 *       main() (not yet written) is this function's real caller.
 */
void mod_load_colormap( World *world );

/* One scanline of the luxel atlas, mapped, as a far pointer. The
   packer keeps a face's whole rect inside one scanline, so a single
   mapping reaches all of it. */
unsigned char far *mod_lm_map( World *world, short row );

/* The colormap, mapped, as a far pointer. Mapped per call and never
   held: CM_SLOT is the depth buffer's, so anything that touched depth
   in between has already taken it back. */
unsigned char far *mod_cm_map( World *world );

/* One row of the geometry store, mapped, as a far pointer. The
   builder keeps a face's whole record inside one row, so the row end
   is also the end of the mapped window. */
unsigned char far *mod_geom_map( World *world, short row );

#endif
