/*
 * assets.c -- see assets.h.
 */

#include <stdio.h>
#include <stdlib.h>

#include "qgl.h"    /* qglFileOpen/qglFileRead/qglFileSize/qglFileClose */
#include "assets.h" /* F4READ */
#include "sys.h"    /* sys_error */

static void asset_fatal( char *flname, char *why )
{
    char msg[128];
    sprintf( msg, "%s: %s", flname, why );
    sys_error( msg );
}

unsigned char far *asset_load( char *flname, long bytes )
{
    short fh;
    unsigned char far *p;

    if ( !( fh = qglFileOpen( flname ) ) ) asset_fatal( flname, "missing" );

    p = (unsigned char far *) qglMemAlloc( bytes );
    if ( !p ) { qglFileClose( fh ); asset_fatal( flname, "out of memory" ); }

    if ( qglFileRead( fh, (long) p, bytes ) != bytes ) {
        qglFileClose( fh );
        qglMemFree( (long) p );
        asset_fatal( flname, "short read" );
    }

    qglFileClose( fh );
    return p;
}

unsigned char far *asset_load_whole( char *flname, long *out_bytes )
{
    short fh;
    long n;
    unsigned char far *p;

    if ( !( fh = qglFileOpen( flname ) ) ) asset_fatal( flname, "missing" );

    n = qglFileSize( fh );
    p = (unsigned char far *) qglMemAlloc( n );
    if ( !p ) { qglFileClose( fh ); asset_fatal( flname, "out of memory" ); }

    if ( qglFileRead( fh, (long) p, n ) != n ) {
        qglFileClose( fh );
        qglMemFree( (long) p );
        asset_fatal( flname, "short read" );
    }

    qglFileClose( fh );
    if ( out_bytes ) *out_bytes = n;
    return p;
}
