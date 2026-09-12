/*
 * sys.c -- see sys.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mem.h>   /* _fmemcpy */

#include "sys.h"
#include "qgl.h"

/* Borland/tc201 both provide this from their own C startup regardless
   of which C0*.OBJ is linked -- see sys.h's own note on why that
   matters here. Not declared through <dos.h>/<stdlib.h>: mgl ships
   its own "dos.h" (qglMemAlloc/qglMemCopy) that bcc.sh's include order
   resolves first, so the real one never gets included. */
extern unsigned _psp;

void sys_error( char *msg )
{
    FILE *errf = fopen( "error.log", "w" );
    if ( errf ) { fprintf( errf, "%s\n", msg ); fclose( errf ); }

    qglVgaShutdown();
    qglMemShutdown();

    fprintf( stderr, "Error: %s\n", msg );
    exit( 1 );
}

#define MAX_ARGS 16
static char cmdbuf[128];

void sys_parse_args( RunArgs *args )
{
    unsigned char far *tail;
    unsigned char len;
    char *argv[MAX_ARGS];
    int argc = 0;
    int i, in_tok;

    memset( args, 0, sizeof(*args) );

    /* PSP:0x80 is the DOS command tail -- a length byte, then that
       many raw characters, no null terminator of its own. */
    tail = (unsigned char far *) ( ( (unsigned long) _psp << 16 ) | 0x80L );
    len = tail[0];
    if ( len > sizeof(cmdbuf) - 1 ) len = sizeof(cmdbuf) - 1;
    _fmemcpy( cmdbuf, (char far *) (tail + 1), len );
    cmdbuf[len] = '\0';

    in_tok = 0;
    for ( i = 0; i < (int) len && argc < MAX_ARGS; i++ ) {
        if ( cmdbuf[i] == ' ' || cmdbuf[i] == '\t' ) {
            cmdbuf[i] = '\0';
            in_tok = 0;
        } else if ( !in_tok ) {
            argv[argc++] = &cmdbuf[i];
            in_tok = 1;
        }
    }

    if ( argc < 1 ) {
        printf( "Usage: qcport mapname.qmp [-ticks N]\n" );
        printf( "  -ticks N      run N simulation ticks, then write bench.bmp/bench.txt, exit\n" );
        printf( "  -lm           composite lightmaps via the surface cache\n" );
        exit( 0 );
    }

    strncpy( args->map_name, argv[0], sizeof(args->map_name) - 1 );

    for ( i = 1; i < argc; i++ ) {
        if      ( stricmp( argv[i], "-walk" )    == 0 ) args->walk = -1;
        else if ( stricmp( argv[i], "-jump" )    == 0 ) args->jump = -1;
        else if ( stricmp( argv[i], "-strafe" )  == 0 ) args->strafe = -1;
        else if ( stricmp( argv[i], "-noents" )  == 0 ) args->no_ents = -1;
        else if ( stricmp( argv[i], "-noitems" ) == 0 ) args->no_items = -1;
        else if ( stricmp( argv[i], "-badorder" )== 0 ) args->bad_order = -1;
        else if ( stricmp( argv[i], "-noz" )     == 0 ) args->no_z = -1;
        else if ( stricmp( argv[i], "-nocull" )  == 0 ) args->no_cull = -1;
        else if ( stricmp( argv[i], "-noportal" )== 0 ) args->no_portal = -1;
        else if ( stricmp( argv[i], "-comp" )    == 0 ) args->comp = -1;
        else if ( stricmp( argv[i], "-ptwire" )  == 0 ) args->ptwire = -1;
        else if ( stricmp( argv[i], "-nostats" ) == 0 ) args->no_stats = -1;
        else if ( stricmp( argv[i], "-stats" )   == 0 ) args->stats = -1;
        else if ( stricmp( argv[i], "-nodraw" )  == 0 ) { args->no_draw = -1; args->no_stats = -1; }
        else if ( stricmp( argv[i], "-lm" )      == 0 ) args->use_lm = -1;
        else if ( stricmp( argv[i], "-at" ) == 0 && i + 3 < argc ) {
            args->at_x = (float) atof( argv[i+1] );
            args->at_y = (float) atof( argv[i+2] );
            args->at_z = (float) atof( argv[i+3] );
            args->at_set = -1;
            i += 3;
        }
        else if ( stricmp( argv[i], "-yaw" ) == 0 && i + 1 < argc ) {
            args->yaw = (float) atof( argv[i+1] );
            while ( args->yaw < 0.0f ) args->yaw += 360.0f;
            args->yaw_set = -1;
            i++;
        }
        else if ( stricmp( argv[i], "-pitch" ) == 0 && i + 1 < argc ) {
            args->pitch = (float) atof( argv[i+1] );
            if ( args->pitch < 0.0f )   args->pitch = 0.0f;
            if ( args->pitch > 180.0f ) args->pitch = 180.0f;
            args->pitch_set = -1;
            i++;
        }
        else if ( stricmp( argv[i], "-ticks" ) == 0 && i + 1 < argc ) {
            args->bench_ticks = atol( argv[i+1] );
            i++;
        }
        else if ( stricmp( argv[i], "-record" ) == 0 && i + 1 < argc ) {
            strncpy( args->record_name, argv[i+1], sizeof(args->record_name) - 1 );
            i++;
        }
        else if ( stricmp( argv[i], "-play" ) == 0 && i + 1 < argc ) {
            strncpy( args->play_name, argv[i+1], sizeof(args->play_name) - 1 );
            i++;
        }
        /* else: unrecognised, ignored -- matching the original, which
           has no "unknown flag" error either. */
    }
}
