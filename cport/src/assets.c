/*
 * assets.c -- see assets.h.
 */

#include <stdio.h>
#include <stdlib.h>

#include "dos.h"    /* memAlloc/memFree, and arch.h's own UAR needs
                        dos.h's DOSFILE included first */
#include "arch.h"   /* UAR, uarOpen/uarRead/uarReadH/uarSize/uarClose */
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
    UAR u;
    unsigned char far *p;

    if ( !uarOpen( &u, flname, F4READ ) ) asset_fatal( flname, "missing" );

    p = (unsigned char far *) memAlloc( bytes );
    if ( !p ) { uarClose( &u ); asset_fatal( flname, "out of memory" ); }

    if ( uarReadH( &u, (void far *) p, bytes ) != bytes ) {
        uarClose( &u );
        memFree( (void far *) p );
        asset_fatal( flname, "short read" );
    }

    uarClose( &u );
    return p;
}

unsigned char far *asset_load_whole( char *flname, long *out_bytes )
{
    UAR u;
    long n;
    unsigned char far *p;

    if ( !uarOpen( &u, flname, F4READ ) ) asset_fatal( flname, "missing" );

    n = uarSize( &u );
    p = (unsigned char far *) memAlloc( n );
    if ( !p ) { uarClose( &u ); asset_fatal( flname, "out of memory" ); }

    if ( uarReadH( &u, (void far *) p, n ) != n ) {
        uarClose( &u );
        memFree( (void far *) p );
        asset_fatal( flname, "short read" );
    }

    uarClose( &u );
    if ( out_bytes ) *out_bytes = n;
    return p;
}
