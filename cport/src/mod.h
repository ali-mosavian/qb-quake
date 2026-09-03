#ifndef __MOD_H__
#define __MOD_H__

#include <stdio.h>

#include "renderer.h"
#include "world.h"

/*
 * mod.h -- reading the map into World. C port of model.bas.
 *
 * Nearly everything here reads a pre-processed assets.zip member
 * (mkassets.py's own output, already in the exact runtime record
 * shape World's fields want -- see bsphdr.h's own note) rather than
 * parsing the raw .bsp lumps directly; the raw file is opened only
 * for its header, to derive the counts that size each read.
 */

/* MapCount, mod_open's own derived lump counts -- transient, unlike
   World's model_count/face_count/leaf_count: nothing outside the
   loading sequence itself reads a node/plane/tex_info/clip count, so
   these don't belong on World, just threaded through mod_load_world's
   own sub-loaders. */
typedef struct {
    long faces, verts, edges, ledges, leaves, planes, nodes, tex_infos, clips, textures;
    long face_lump_bytes;   /* r_load_lfaces' own read size */
    long mip_tex_offs;      /* mod_tex.h's own seek base -- every texture
                                offset and header is relative to this */
} MapCounts;

/*
 * name: mod_open
 * desc: Opens map_name, reads the header, derives every lump count.
 *       Sets world->model_count/face_count/leaf_count (the counts real
 *       per-frame readers need); everything else comes back through
 *       *counts for mod_load_world's own use. Returns the open FILE*
 *       (mod_close's own parameter) -- fatal if the map won't open.
 */
FILE *mod_open( char *map_name, World *world, MapCounts *counts );

/* Releases the map file. */
void mod_close( FILE *f );

/*
 * name: mod_load_world
 * desc: Every lump of the map, in the order they depend on each
 *       other, EXCEPT textures -- mod_tex.h owns those, its own load
 *       phase, timed separately. Matches main.bas's own real call
 *       order: mod_open, mod_load_world, THEN mod_tex.h's
 *       mod_load_texinfo/mod_load_textures (both still want the file
 *       counts.textures pass), and only then mod_close -- so this
 *       does NOT close the file itself. *counts and the returned
 *       FILE* are both the caller's to hand to mod_tex.h's loaders
 *       and to mod_close when textures are done.
 */
FILE *mod_load_world( World *world, Renderer *rdr, Camera *cam, char *map_name, MapCounts *counts );

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
