/*
 * config.c -- see config.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#include "config.h"
#include "sys.h"   /* sys_error */

#define CFG_MAXLINE 256

typedef enum { K_SHORT, K_FLOAT, K_BOOL, K_STRING, K_CAMMODE } CfgKind;

typedef struct {
    char   *name;
    CfgKind kind;
    size_t  offset;
    long    flag;
    short   required;
} CfgField;

/* One bit per required key, same shape as com_parse_config's own
   xres_flag/yres_flag/... -- checked against ALL_REQUIRED once the
   file is read, matching the original's "every key present" rule. */
#define F_XRES   0x0001L
#define F_YRES   0x0002L
#define F_ZN     0x0004L
#define F_ZF     0x0008L
#define F_CMSCR  0x0010L
#define F_CLEAR  0x0080L
#define F_CMINP  0x0100L
#define F_CMMDE  0x0200L
#define F_FOV    0x0400L
/* display.pages, display.usepaging and sound.enabled are gone from
   stuff.ini: paging was mgl's and needed mgl to own the mode, and there
   is no sound here. A key this list demands and the file no longer
   carries is "Incorrect ini file..." and nothing else -- the message
   names neither the key nor the line. */
#define ALL_REQUIRED (F_XRES|F_YRES|F_ZN|F_ZF|F_CMSCR|F_CLEAR|F_CMINP|F_CMMDE|F_FOV)

static CfgField fields[] = {
    { "display.xres",       K_SHORT,   offsetof(Config, scr_x_res),  F_XRES,  1 },
    { "display.yres",       K_SHORT,   offsetof(Config, scr_y_res),  F_YRES,  1 },
    { "render.xres",        K_SHORT,   offsetof(Config, x_res),      0,       0 },
    { "render.yres",        K_SHORT,   offsetof(Config, y_res),      0,       0 },
    { "display.clear",      K_BOOL,    offsetof(Config, clear_screen), F_CLEAR, 1 },
    { "world.frustum.zn",   K_FLOAT,   offsetof(Config, z_near),     F_ZN,    1 },
    { "world.frustum.zf",   K_FLOAT,   offsetof(Config, z_far),      F_ZF,    1 },
    { "world.camera.script",K_STRING,  offsetof(Config, cam_script), F_CMSCR, 1 },
    { "world.camera.interp",K_SHORT,   offsetof(Config, cam_interp), F_CMINP, 1 },
    { "world.camera.mode",  K_CAMMODE, offsetof(Config, cam_mode),   F_CMMDE, 1 },
    { "world.camera.fov",   K_FLOAT,   offsetof(Config, cam_fov),    F_FOV,   1 }
};
#define NFIELDS (sizeof(fields)/sizeof(fields[0]))

static char *cfg_trim( char *s )
{
    char *end;
    while ( *s == ' ' || *s == '\t' ) s++;
    end = s + strlen( s );
    while ( end > s && ( end[-1] == ' ' || end[-1] == '\t' ||
                          end[-1] == '\r' || end[-1] == '\n' ) ) end--;
    *end = '\0';
    return s;
}

static short cfg_yesno( char *v, int line_num )
{
    char msg[64];
    if ( strcmp( v, "yes" ) == 0 || strcmp( v, "true" ) == 0 ) return -1;
    if ( strcmp( v, "no" ) == 0 || strcmp( v, "false" ) == 0 ) return 0;
    sprintf( msg, "Expected yes/no at line #%d", line_num );
    sys_error( msg );
    return 0;
}

/*
 * name: config_load
 * desc: One pass over flname: split key/value on '=', strip a
 *       trailing "// comment", dispatch through the table above. A
 *       whole-line "//" comment or a blank line is skipped outright.
 *       Reads the WHOLE file rather than stopping once every required
 *       key has been seen -- matching the original's own fix for a
 *       line after the last one going unchecked.
 */
void config_load( Config *cfg, char *flname )
{
    FILE *f;
    char  line[CFG_MAXLINE];
    int   line_num = 0;
    long  flags = 0;
    char *eq, *key, *val, *cmt;
    size_t i;

    f = fopen( flname, "r" );
    if ( !f ) {
        char msg[80];
        sprintf( msg, "%s: could not open", flname );
        sys_error( msg );
    }

    memset( cfg, 0, sizeof(*cfg) );

    while ( fgets( line, sizeof(line), f ) ) {
        line_num++;

        cmt = strstr( line, "//" );
        if ( cmt ) *cmt = '\0';

        key = cfg_trim( line );
        if ( *key == '\0' ) continue;   /* blank, or a whole-line comment */

        eq = strchr( key, '=' );
        if ( !eq ) {
            char msg[64];
            sprintf( msg, "Unknown syntax at line #%d", line_num );
            sys_error( msg );
        }
        *eq = '\0';
        val = cfg_trim( eq + 1 );
        key = cfg_trim( key );

        for ( i = 0; i < NFIELDS; i++ ) {
            if ( strcmp( key, fields[i].name ) != 0 ) continue;

            switch ( fields[i].kind ) {
            case K_SHORT:
                *(short *) ( (char *) cfg + fields[i].offset ) = (short) atoi( val );
                break;
            case K_FLOAT:
                *(float *) ( (char *) cfg + fields[i].offset ) = (float) atof( val );
                break;
            case K_BOOL:
                *(short *) ( (char *) cfg + fields[i].offset ) = cfg_yesno( val, line_num );
                break;
            case K_STRING:
                strncpy( (char *) cfg + fields[i].offset, val, 63 );
                ( (char *) cfg + fields[i].offset )[63] = '\0';
                break;
            case K_CAMMODE:
                if ( strcmp( val, "freelook" ) == 0 )
                    *(short *) ( (char *) cfg + fields[i].offset ) = 0;
                else if ( strcmp( val, "script_play" ) == 0 )
                    *(short *) ( (char *) cfg + fields[i].offset ) = 1;
                else if ( strcmp( val, "script_edit" ) == 0 )
                    *(short *) ( (char *) cfg + fields[i].offset ) = 2;
                else {
                    char msg[64];
                    sprintf( msg, "Unknown syntax at line #%d", line_num );
                    sys_error( msg );
                }
                break;
            }

            flags |= fields[i].flag;
            break;
        }

        if ( i == NFIELDS ) {
            char msg[80];
            sprintf( msg, "Unknown command, %s", key );
            sys_error( msg );
        }
    }

    fclose( f );

    if ( ( flags & ALL_REQUIRED ) != ALL_REQUIRED ) sys_error( "Incorrect ini file..." );

    /* A view no bigger than the screen, centred on it -- render.xres/
       yres are optional and default to filling the screen. */
    if ( cfg->x_res <= 0 ) cfg->x_res = cfg->scr_x_res;
    if ( cfg->y_res <= 0 ) cfg->y_res = cfg->scr_y_res;
    if ( cfg->x_res > cfg->scr_x_res ) cfg->x_res = cfg->scr_x_res;
    if ( cfg->y_res > cfg->scr_y_res ) cfg->y_res = cfg->scr_y_res;

    /* The largest whole-number multiple of the backbuffer that still
       fits the screen on both axes. */
    cfg->view_scale = (short) ( cfg->scr_x_res / cfg->x_res );
    if ( (short) ( cfg->scr_y_res / cfg->y_res ) < cfg->view_scale )
        cfg->view_scale = (short) ( cfg->scr_y_res / cfg->y_res );
    if ( cfg->view_scale < 1 ) cfg->view_scale = 1;

    cfg->view_w = (short) ( cfg->x_res * cfg->view_scale );
    cfg->view_h = (short) ( cfg->y_res * cfg->view_scale );
    cfg->view_x = (short) ( ( cfg->scr_x_res - cfg->view_w ) / 2 );
    cfg->view_y = (short) ( ( cfg->scr_y_res - cfg->view_h ) / 2 );
}
