/*
 * mod.c -- reading the map into World. C port of model.bas.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mod.h"
#include "bsphdr.h"
#include "assets.h"
#include "dos.h"        /* memAlloc, and arch.h's DOSFILE */
#include "arch.h"       /* UAR */
#include "uglpatch.h"   /* uglNewView/uglSetView -- not used here, but
                            ugl.h alone (below) already brings PDC/uglNew */
#include "ugl.h"
#include "r_bsp.h"       /* r_load_leaves/r_load_lfaces/r_load_portals/r_alloc_scratch */
#include "pl_move.h"     /* pl_load_hulls */
#include "ent.h"         /* ent_load_spawn/ent_load_teleports */
#include "sys.h"         /* sys_error */

/* q_map.bi's own constants -- project-specific, not mgl's. */
#define PAGE_SLOT 2
#define GEOM_W    8192L

static void mod_fatal( char *what )
{
    sys_error( what );
}

FILE *mod_open( char *map_name, World *world, MapCounts *counts )
{
    FILE *f;
    BspHeader head;
    long tex_count;

    f = fopen( map_name, "rb" );
    if ( !f ) mod_fatal( "map file would not open" );

    if ( fread( &head, sizeof(BspHeader), 1, f ) != 1 ) mod_fatal( "map header short read" );

    world->face_count  = (short) ( head.faces.size  / DISKFACE_SIZE );
    counts->verts       = head.vertices.size / DISKVERTEX_SIZE;
    world->vert_count  = (short) counts->verts;
    counts->edges       = head.edges.size    / DISKEDGE_SIZE;
    world->edge_count  = (short) counts->edges;
    counts->ledges       = head.ledges.size   / DISKLEDGE_SIZE;
    world->leaf_count  = (short) ( head.leaves.size / DISKLEAF_SIZE );
    counts->planes      = head.planes.size    / DISKPLANE_SIZE;
    counts->nodes       = head.nodes.size     / DISKNODE_SIZE;
    world->node_count  = (short) counts->nodes;
    world->model_count = (short) ( head.models.size / sizeof(Submodel) );
    counts->tex_infos    = head.tex_info.size  / DISKTEXINFO_SIZE;
    counts->clips        = head.clip_node.size / DISKCLIPNODE_SIZE;
    counts->face_lump_bytes = head.lface.size;

    counts->mip_tex_offs = head.mip_tex.offs;
    if ( fseek( f, head.mip_tex.offs, SEEK_SET) != 0 ) mod_fatal( "mip_tex lump seek failed" );
    if ( fread( &tex_count, sizeof(long), 1, f ) != 1 ) mod_fatal( "mip_tex header short read" );
    counts->textures = tex_count;
    counts->faces = world->face_count;
    counts->leaves = world->leaf_count;

    return f;
}

void mod_close( FILE *f )
{
    fclose( f );
}

/*
 * name: mod_load_faces
 * desc: MEM: the draw path reads a face for every face drawn, and a
 *       windowed store would cost a remap each time.
 */
static void mod_load_faces( World *world )
{
    world->faces = (Face far *) asset_load( "assets.zip::faces.pag",
                                             (long) world->face_count * sizeof(Face) );
}

/*
 * name: mod_load_colormap
 * desc: The 64-shade table the builder shades through. EMS, not
 *       memAlloc: by the time this loads, conventional memory no
 *       longer has 16K contiguous to spare.
 */
void mod_load_colormap( World *world )
{
    UAR u;
    unsigned char far *p;

    world->cmap_dc   = 0;
    world->cmap_size = 0;

    if ( !uarOpen( &u, "assets.zip::colmap.bin", F4READ ) ) return;

    world->cmap_dc = uglNew( UGL_EMS, UGL_8BIT, 16384, 1 );
    if ( world->cmap_dc ) {
        p = (unsigned char far *) uglMapEx( world->cmap_dc, 0, 3 /* CM_SLOT */ );
        if ( p && uarReadH( &u, (void far *) p, 16384 ) == 16384 ) world->cmap_size = 16384;
    }

    uarClose( &u );

    if ( world->cmap_size == 0 ) mod_fatal( "colormap would not load" );
}

/*
 * name: mod_load_lightmaps
 * desc: Every luxel in the map, as one 8-bit EMS dc built straight
 *       from a BMP -- the same path mod_tex.bas takes for the
 *       textures. BMP_OPT_NO332: these bytes are luxel values, not
 *       colours for uGL to remap through its own palette.
 */
static void mod_load_lightmaps( World *world )
{
    UAR u;

    world->light_atlas = 0;
    world->light_size  = 0;

    if ( uarOpen( &u, "assets.zip::lm.bmp", F4READ ) ) {
        world->light_size = uarSize( &u );
        uarClose( &u );
    }
    world->light_atlas = uglNewBMPEx( UGL_EMS, UGL_8BIT, "assets.zip::lm.bmp", BMP_OPT_NO332 );
    world->light_loaded = world->light_atlas ? world->light_size : 0;
}

/*
 * name: mod_load_facevtx
 * desc: Read straight into the mapped window, a row at a time -- no
 *       conventional-memory staging buffer anywhere here.
 */
static void mod_load_facevtx( World *world )
{
    UAR u;
    /* volatile, defensively: mgl's own uarReadH (src/mods/mdarch.asm)
       used to clobber SI without listing it in its `uses` clause, and
       Borland C's optimizer treats SI/DI/BP as preserved across ANY
       call when deciding what is safe to keep live in a register --
       so a plain `short y` here (and, independently, a fresh read of
       world->geom_rows right after the call) both came back wrong,
       exactly matching whatever the DEFLATE decoder's own internal
       byte count happened to leave in SI. Fixed at the source (`si`
       added to uarReadH's own `uses` clause, __CMP__=BC's UGLV.LIB
       rebuilt) -- see [[masm-uses-missing-si]] -- so this is no
       longer strictly needed, but costs nothing and stays as a second
       line of defence against ever linking a stale library again. */
    volatile short y;
    unsigned char far *p;

    if ( !uarOpen( &u, "assets.zip::fgeom.bin", F4READ ) ) mod_fatal( "fgeom.bin missing" );

    world->geom_rows = (short) ( (uarSize( &u ) + GEOM_W - 1) / GEOM_W );
    world->geom_dc = uglNew( UGL_EMS, UGL_8BIT, (int) GEOM_W, world->geom_rows );
    if ( !world->geom_dc ) mod_fatal( "no EMS for the geometry store" );

    for ( y = 0; y < world->geom_rows; y++ ) {
        p = (unsigned char far *) uglMapEx( world->geom_dc, y, PAGE_SLOT );
        if ( !p ) mod_fatal( "geometry store will not map" );
        if ( uarReadH( &u, (void far *) p, GEOM_W ) != GEOM_W ) mod_fatal( "fgeom.bin short read" );
    }

    uarClose( &u );
}

static void mod_load_nodes( World *world, MapCounts *counts )
{
    world->nodes = (Node far *) asset_load( "assets.zip::nodes.pag",
                                             counts->nodes * (long) sizeof(Node) );
}

static void mod_load_planes( World *world, MapCounts *counts )
{
    world->planes = (Plane far *) asset_load( "assets.zip::planes.bld",
                                               counts->planes * (long) sizeof(Plane) );
}

static void mod_load_submodels( World *world )
{
    world->models = (Submodel far *) asset_load( "assets.zip::models.bld",
                                                  (long) world->model_count * sizeof(Submodel) );
}

/* memAlloc'd rather than a uGL store: r_bsp reaches it as a plain far
   pointer plus a byte offset (leaf.vis_list), never as an array. */
static void mod_load_visibility( World *world )
{
    long n;
    world->pvs_data = asset_load_whole( "assets.zip::pvs.bin", &n );
}

FILE *mod_load_world( World *world, Renderer *rdr, Camera *cam, char *map_name, MapCounts *counts )
{
    FILE *f;

    memset( counts, 0, sizeof(*counts) );
    f = mod_open( map_name, world, counts );

    r_alloc_scratch( rdr, world->face_count, (short) counts->nodes, world->leaf_count );

    mod_load_faces( world );
    mod_load_lightmaps( world );

    mod_load_facevtx( world );
    r_load_leaves( world );
    r_load_lfaces( world, counts->face_lump_bytes );
    mod_load_nodes( world, counts );
    mod_load_planes( world, counts );
    mod_load_submodels( world );
    mod_load_visibility( world );
    pl_load_hulls( world, (short) counts->clips );

    ent_load_spawn( world, cam );
    ent_load_teleports( world );

    return f;   /* still open -- mod_tex.h's loaders want it next, then
                   the caller closes it (mod_close) */
}

unsigned char far *mod_lm_map( World *world, short row )
{
    return (unsigned char far *) uglMapEx( world->light_atlas, row, PAGE_SLOT );
}

unsigned char far *mod_cm_map( World *world )
{
    return (unsigned char far *) uglMapEx( world->cmap_dc, 0, 3 /* CM_SLOT */ );
}

unsigned char far *mod_geom_map( World *world, short row )
{
    return (unsigned char far *) uglMapEx( world->geom_dc, row, PAGE_SLOT );
}
