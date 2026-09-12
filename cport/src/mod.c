/*
 * mod.c -- reading the map into World. C port of model.bas.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mod.h"
#include "bsphdr.h"
#include "assets.h"
#include "qgl.h"
#include "qglsurf.h"   /* qglNewView/qglSetView -- not used here, but
                            ugl.h alone (below) already brings QSurf/qglNew */
#include "qgl.h"
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

void mod_open( char *qmp, World *world, MapCounts *counts )
{
    QmapCounts far *qc;

    (void) qmp;     /* main opened the container: the font wants it first */
    qc = (QmapCounts far *) asset_load( "counts.bin",
                                         (long) sizeof(QmapCounts) );

    world->face_count  = (short) qc->faces;
    world->vert_count  = (short) qc->verts;
    world->edge_count  = (short) qc->edges;
    world->leaf_count  = (short) qc->leaves;
    world->node_count  = (short) qc->nodes;
    world->model_count = qc->models;

    counts->faces           = qc->faces;
    counts->verts           = qc->verts;
    counts->edges           = qc->edges;
    counts->ledges          = qc->ledges;
    counts->leaves          = qc->leaves;
    counts->planes          = qc->planes;
    counts->nodes           = qc->nodes;
    counts->tex_infos       = qc->tex_infos;
    counts->clips           = qc->clips;
    counts->textures        = qc->textures;
    counts->face_lump_bytes = qc->face_lump_bytes;

    qglMemFree( (long) qc );
}


/*
 * name: mod_load_faces
 * desc: MEM: the draw path reads a face for every face drawn, and a
 *       windowed store would cost a remap each time.
 */
static void mod_load_faces( World *world )
{
    world->faces = (Face far *) asset_load( "faces.pag",
                                             (long) world->face_count * sizeof(Face) );
}

/*
 * name: mod_load_colormap
 * desc: The 64-shade table the builder shades through. EMS, not
 *       qglMemAlloc: by the time this loads, conventional memory no
 *       longer has 16K contiguous to spare.
 */
void mod_load_colormap( World *world )
{
    short fh;
    unsigned char far *p;

    world->cmap_dc   = 0;
    world->cmap_size = 0;

    fh = asset_seek( "colmap.bin", 0 );

    world->cmap_dc = qglSfNew( 16384, 1, QGL_SURF_EMS );
    if ( world->cmap_dc ) {
        p = (unsigned char far *) qglSfAccessRdEx( world->cmap_dc, 0, 3 /* CM_SLOT */ );
        if ( p && qglFileRead( fh, (long) p, 16384L ) == 16384L ) world->cmap_size = 16384;
    }

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
    world->light_atlas = 0;
    world->light_size  = 0;

    world->light_atlas = qgl_surf_from_member( "lm.bin", LM_ATLAS_W,
                                             QGL_SURF_EMS, &world->light_size );
    world->light_loaded = world->light_atlas ? world->light_size : 0;
}

/*
 * name: mod_load_facevtx
 * desc: Read straight into the mapped window, a row at a time -- no
 *       conventional-memory staging buffer anywhere here.
 */
static void mod_load_facevtx( World *world )
{
    short fh;
    /* volatile against a MASM `uses` omission, which is a class of
       bug and not one library's instance: Borland C treats SI/DI/BP as
       preserved across ANY call when deciding what to keep live, so a
       reader that clobbers SI silently corrupts the loop counter here.
       mgl's uarReadH did exactly that and cost a session; qgl.inc makes
       the rule explicit for qgl, but the cost of the defence is zero
       and the failure is invisible. */
    volatile short y;
    unsigned char far *p;
    long n, want;

    fh = asset_seek( "fgeom.bin", &n );

    world->geom_rows = (short) ( (n + GEOM_W - 1) / GEOM_W );
    world->geom_dc = qglSfNew( (short) GEOM_W, world->geom_rows, QGL_SURF_EMS );
    if ( !world->geom_dc ) mod_fatal( "no EMS for the geometry store" );

    for ( y = 0; y < world->geom_rows; y++ ) {
        p = (unsigned char far *) qglSfAccessRdEx( world->geom_dc, y, PAGE_SLOT );
        if ( !p ) mod_fatal( "geometry store will not map" );
        /* The last row may be short: the member is not padded up to a
           whole row, and the handle is the container's, so a full-row
           read would take the bytes of whatever member follows. */
        want = ( n - (long) y * GEOM_W < GEOM_W ) ? n - (long) y * GEOM_W : GEOM_W;
        if ( qglFileRead( fh, (long) p, want ) != want ) mod_fatal( "fgeom.bin short read" );
    }
}

static void mod_load_nodes( World *world, MapCounts *counts )
{
    world->nodes = (Node far *) asset_load( "nodes.pag",
                                             counts->nodes * (long) sizeof(Node) );
}

static void mod_load_planes( World *world, MapCounts *counts )
{
    world->planes = (Plane far *) asset_load( "planes.bld",
                                               counts->planes * (long) sizeof(Plane) );
}

static void mod_load_submodels( World *world )
{
    world->models = (Submodel far *) asset_load( "models.bld",
                                                  (long) world->model_count * sizeof(Submodel) );
}

/* qglMemAlloc'd rather than a uGL store: r_bsp reaches it as a plain far
   pointer plus a byte offset (leaf.vis_list), never as an array. */
static void mod_load_visibility( World *world )
{
    long n;
    world->pvs_data = asset_load_whole( "pvs.bin", &n );
}

void mod_load_world( World *world, Renderer *rdr, Camera *cam, Fight *fight, char *map_name, MapCounts *counts )
{
    memset( counts, 0, sizeof(*counts) );
    mod_open( map_name, world, counts );

    r_alloc_scratch( rdr, world->face_count, (short) counts->nodes, world->leaf_count );

    mod_load_faces( world );
    mod_load_lightmaps( world );

    mod_load_facevtx( world );
    r_load_leaves( world );
    r_load_lfaces( world, counts->face_lump_bytes );
    r_load_portals( world, counts->leaves );
    mod_load_nodes( world, counts );
    mod_load_planes( world, counts );
    mod_load_submodels( world );
    mod_load_visibility( world );
    pl_load_hulls( world, (short) counts->clips );

    ent_load_spawn( world, cam, fight );
    ent_load_teleports( world );
    fight->secret_total = ent_secret_total( world );
}

unsigned char far *mod_lm_map( World *world, short row )
{
    return (unsigned char far *) qglSfAccessRdEx( world->light_atlas, row, PAGE_SLOT );
}

unsigned char far *mod_cm_map( World *world )
{
    return (unsigned char far *) qglSfAccessRdEx( world->cmap_dc, 0, 3 /* CM_SLOT */ );
}

unsigned char far *mod_geom_map( World *world, short row )
{
    return (unsigned char far *) qglSfAccessRdEx( world->geom_dc, row, PAGE_SLOT );
}
