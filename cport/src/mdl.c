/*
 * mdl.c -- loading alias models and the monsters that stand on them.
 * d_mdl.bas's mdl_load, and ent.bas's monster records.
 *
 * A model costs the far heap nothing: 32K of an EMS handle holds every
 * frame's vertices on page 0 and the triangles on page 1, and the skin
 * is its own EMS surface. That budget is what fixes the frame count --
 * the dog's 236 vertices leave room for 23 frames -- and mkassets.py
 * picks the frame sets to match, so the container's .geo header is the
 * statement of what arrived.
 *
 * No AI. A monster stands where the map put it, facing the map's way,
 * on the first frame of its stand set.
 */

#include <mem.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "mdl.h"
#include "ent.h"
#include "assets.h"
#include "qgl.h"

#define PAGE_SLOT 2     /* shared with nodes, leaves, the lightmap */

static char *mdl_name[MDL_KINDS] = {
    "soldier", "knight", "dog", "ogre", "demon", "zombie", "wizard", "shambler"
};

void mdl_load( MdlState *m, char *name )
{
    char  path[24];
    MdlHead h;
    short fh, page;
    long  n, bytes;
    float ex, ey;

    m->loaded = 0;
    m->vtx_hnd = 0;
    m->skin = 0;

    sprintf( path, "%s.geo", name );
    fh = asset_seek( path, &n );
    if ( qglFileRead( fh, (long) (void far *) &h, (long) sizeof(h) ) != (long) sizeof(h) ) {
        fprintf( stderr, "%s: header short read\n", path );
        return;
    }
    m->ntri = h.ntri; m->nvert = h.nvert; m->nframe = h.nframe;
    m->scale = h.scale; m->origin = h.origin;
    m->nstand = h.nstand; m->nrun = h.nrun;
    m->ndeath = h.ndeath; m->npain = h.npain; m->natk = h.natk;

    /* Vertex bytes span 0..255, so this is the box every frame fits in;
       the yaw turns about the origin, so the horizontal reach is a
       radius. What the visibility test asks about instead of 170
       vertices. */
    ex = (float) fabs( m->origin.x );
    if ( (float) fabs( m->origin.x + 255.0f * m->scale.x ) > ex )
        ex = (float) fabs( m->origin.x + 255.0f * m->scale.x );
    ey = (float) fabs( m->origin.y );
    if ( (float) fabs( m->origin.y + 255.0f * m->scale.y ) > ey )
        ey = (float) fabs( m->origin.y + 255.0f * m->scale.y );
    m->radius = (float) sqrt( ex * ex + ey * ey );
    m->zlo = m->origin.z;
    m->zhi = m->origin.z + 255.0f * m->scale.z;

    if ( m->nvert > MDL_MAXV + 1 || m->ntri < 1 || m->nvert < 1 || m->nframe < 1 ) {
        fprintf( stderr, "%s: %d verts %d tris %d frames -- will not fit\n",
                 path, m->nvert, m->ntri, m->nframe );
        return;
    }
    bytes = (long) m->ntri * MDL_TRI_BYTES;
    if ( bytes > 16384L ) { fprintf( stderr, "%s: triangles past one page\n", path ); return; }

    /* two pages of one handle: 0 the vertices, 1 the triangles */
    m->vtx_hnd = qglGemAlloc( 32768L );
    if ( !m->vtx_hnd ) { fprintf( stderr, "%s: no EMS for the vertices\n", path ); return; }

    /* the triangles, from where the header left the handle */
    page = qglGemMap( m->vtx_hnd, 1, PAGE_SLOT );
    if ( !page || qglFileRead( fh, (long) page << 16, bytes ) != bytes ) {
        fprintf( stderr, "%s: triangles would not load\n", path );
        qglGemFree( m->vtx_hnd ); m->vtx_hnd = 0; return;
    }

    sprintf( path, "%s.vtx", name );
    fh = asset_seek( path, &n );
    bytes = (long) m->nframe * m->nvert * 3;
    page = qglGemMap( m->vtx_hnd, 0, PAGE_SLOT );
    if ( !page || qglFileRead( fh, (long) page << 16, bytes ) != bytes ) {
        fprintf( stderr, "%s: vertices would not load\n", path );
        qglGemFree( m->vtx_hnd ); m->vtx_hnd = 0; return;
    }

    /* The skin: one EMS page at most, because qglRsPoly refuses a
       texture crossing two -- the texel base is an immediate the filler
       patches into itself and never remaps mid-polygon. mkmdl.py's
       resample keeps it true and writes the size it chose into the
       header, so the two cannot drift. */
    sprintf( path, "%s.skn", name );
    fh = asset_seek( path, &n );
    m->skin = qglSfNew( h.skin_w, h.skin_h, QGL_SURF_EMS );
    if ( !m->skin || !qglSfLoadFh( m->skin, fh ) ) {
        fprintf( stderr, "%s: skin would not load\n", path );
        if ( m->skin ) { qglSfFree( m->skin ); m->skin = 0; }
        qglGemFree( m->vtx_hnd ); m->vtx_hnd = 0; return;
    }

    m->loaded = 1;
}

MdlState *mdl_of( World *world, short kind )
{
    if ( kind < 0 || kind >= MDL_KINDS ) return 0;
    if ( !world->mdl[kind].loaded ) return 0;
    return &world->mdl[kind];
}

void mdl_load_monsters( World *world, unsigned char far *buf, long *ofs, short count )
{
    short i, kinds[MDL_KINDS];

    for ( i = 0; i < MDL_KINDS; i++ ) { kinds[i] = 0; world->mdl[i].loaded = 0; }

    world->mon_count = count;
    world->mon = (MdlEnt far *) qglMemAlloc( (long) ( count ? count : 1 ) * sizeof(MdlEnt) );
    if ( !world->mon ) { fprintf( stderr, "ents.bin: out of memory for %d monsters\n", (int) count ); exit( 1 ); }

    for ( i = 0; i < count; i++ ) {
        EntsMon mr;
        MdlEnt far *e = &world->mon[i];

        _fmemcpy( &mr, buf + *ofs, sizeof(EntsMon) ); *ofs += sizeof(EntsMon);

        e->kind  = mr.kind;
        e->pos   = mr.org;
        e->yaw   = mr.angle;    /* a model's yaw is Quake's, CCW from +x: no mirror */
        e->frame = 0;
        if ( mr.kind >= 0 && mr.kind < MDL_KINDS ) kinds[ mr.kind ] = 1;
    }

    /* Only the kinds this map spawns: a model the map has none of is
       32K of EMS and a skin for nothing, and mkassets ships only these
       in the container anyway. */
    for ( i = 0; i < MDL_KINDS; i++ )
        if ( kinds[i] ) mdl_load( &world->mdl[i], mdl_name[i] );
}
