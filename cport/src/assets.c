/*
 * assets.c -- see assets.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "qgl.h"    /* qglFileOpen/qglFileSeek/qglFileRead/qglMemAlloc */
#include "assets.h"
#include "sys.h"    /* sys_error */

static short   asset_fh = 0;
static QmapEnt asset_dir[QMAP_MAX];
static short   asset_n  = 0;

static void asset_fatal( char *flname, char *why )
{
    char msg[128];
    sprintf( msg, "%s: %s", flname, why );
    sys_error( msg );
}

void asset_map( char *qmp )
{
    /* the header, in the writer's own field order */
    struct {
        long  sig, ver;
        short ndir;
        long  dirofs, sum;
        char  name[QMAP_NAME];
    } head;

    if ( !( asset_fh = qglFileOpen( qmp ) ) ) asset_fatal( qmp, "would not open" );

    if ( qglFileRead( asset_fh, (long) (void far *) &head, (long) sizeof(head) )
             != (long) sizeof(head) )
        asset_fatal( qmp, "header short read" );
    if ( head.sig != QMAP_SIG ) asset_fatal( qmp, "not a map container" );
    if ( head.ver != QMAP_VER ) asset_fatal( qmp, "a map container this build does not read" );
    if ( head.ndir < 1 || head.ndir > QMAP_MAX ) asset_fatal( qmp, "directory out of range" );

    asset_n = head.ndir;
    if ( !qglFileSeek( asset_fh, head.dirofs ) ) asset_fatal( qmp, "directory seek failed" );
    if ( qglFileRead( asset_fh, (long) (void far *) asset_dir,
                       (long) asset_n * QMAP_ENT ) != (long) asset_n * QMAP_ENT )
        asset_fatal( qmp, "directory short read" );
}

short asset_seek( char *member, long *out_bytes )
{
    short i;

    if ( !asset_fh ) asset_fatal( member, "no map container is open" );
    for ( i = 0; i < asset_n; i++ ) {
        /* the name is NUL padded to the field on disk, so strncmp over
           the whole field is exact and needs no length */
        if ( strncmp( asset_dir[i].name, member, QMAP_NAME ) == 0 ) {
            if ( !qglFileSeek( asset_fh, asset_dir[i].ofs ) )
                asset_fatal( member, "seek failed" );
            if ( out_bytes ) *out_bytes = asset_dir[i].size;
            return asset_fh;
        }
    }
    asset_fatal( member, "no such member" );
    return 0;
}

short asset_has( char *member )
{
    short i;

    for ( i = 0; i < asset_n; i++ )
        if ( strncmp( asset_dir[i].name, member, QMAP_NAME ) == 0 ) return -1;
    return 0;
}

unsigned char far *asset_load( char *member, long bytes )
{
    unsigned char far *p;
    short fh = asset_seek( member, 0 );

    p = (unsigned char far *) qglMemAlloc( bytes );
    if ( !p ) asset_fatal( member, "out of memory" );

    if ( qglFileRead( fh, (long) p, bytes ) != bytes ) {
        qglMemFree( (long) p );
        asset_fatal( member, "short read" );
    }
    return p;
}

unsigned char far *asset_load_whole( char *member, long *out_bytes )
{
    long n;
    unsigned char far *p;

    asset_seek( member, &n );
    p = asset_load( member, n );        /* seeks again; the directory is in memory */
    if ( out_bytes ) *out_bytes = n;
    return p;
}
