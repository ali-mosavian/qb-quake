/*
 * qmain.c -- foundation probe for the standalone C port of qrender.
 *
 * Proves the single thing the whole port rests on: a bcc-only EXE that
 * links mgl WITHOUT the BASIC runtime. The library this project links
 * today (uglv.lib, __CMP__=VBD) pulls B$SETM; the same sources built
 * with __CMP__=BC reference no B$ symbol at all, so nothing here needs
 * VBDCL10E.LIB.
 *
 * mglapi.h is generated -- see tools/genhdr.py. mgl's shipped inc/*.h
 * are stale (no uglSetMode, kbdInit's signature wrong, and missing
 * uglPolyTP/uglBuildSurf/uglNewView/uglSetView/uglZMode entirely, all
 * of which this renderer depends on), so they are not used.
 *
 * Draws two rectangles and exits. Nothing here is renderer work; the
 * link is what is under test. It writes cport.txt because a graphics
 * mode leaves nothing on screen to read afterwards.
 */

#include <stdio.h>
#include "mglapi.h"

/* Step log: opened and closed per mark so it survives a fault that never
   returns -- the technique CLAUDE.md records for exactly this case. */
static void mark( char *what )
{
    FILE *m = fopen( "cstep.txt", "a" );
    if ( m ) { fprintf( m, "%s\n", what ); fclose( m ); }
}

static void markv( char *what, long v )
{
    FILE *m = fopen( "cstep.txt", "a" );
    if ( m ) { fprintf( m, "%s=%ld (hi=%u lo=%u)\n", what, v,
                        (unsigned)(v >> 16), (unsigned)(v & 0xFFFFL) ); fclose( m ); }
}

#define UGL_MEM    0        /* DCTSIZE * 0 -- ugl.bi's UGL.MEM  */
#define UGL_8BIT   0        /* FMTSIZE * 0 -- ugl.bi's UGL.8BIT */

int main( void )
{
    long vdc, bdc;
    FILE *f;

    mark( "start" );

    if ( uglInit() == 0 ) {
        f = fopen( "cport.txt", "w" );
        if ( f ) { fprintf( f, "FAIL uglInit\n" ); fclose( f ); }
        return 1;
    }

    mark( "uglInit ok" );

    /* Same call vid.bas makes: format, x, y, pages. */
    vdc = uglSetVideoDC( UGL_8BIT, 320, 200, 1 );
    if ( vdc == 0 ) {
        uglRestore();
        f = fopen( "cport.txt", "w" );
        if ( f ) { fprintf( f, "FAIL uglSetVideoDC\n" ); fclose( f ); }
        return 2;
    }

    markv( "vdc", vdc );

    bdc = uglNew( UGL_MEM, UGL_8BIT, 320, 200 );
    markv( "bdc", bdc );

    uglClear( vdc, 16L );
    mark( "uglClear ok" );
    uglRectF( vdc, 40, 40, 279, 159, 31L );
    mark( "uglRectF ok" );

    mark( "drew" );

    if ( bdc ) uglDel( &bdc );
    uglRestore();
    uglEnd();
    mark( "restored" );

    f = fopen( "cport.txt", "w" );
    if ( f ) {
        fprintf( f, "OK vdc=%ld bdc=%ld\n", vdc, bdc );
        fclose( f );
    }
    return 0;
}
