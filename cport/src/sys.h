#ifndef __SYS_H__
#define __SYS_H__

/*
 * sys.h -- argv parsing and the shared fatal-error path. C port of
 * sys.bas's own slice, minus what already moved elsewhere: the frame
 * clock is sys_time.h's, stuff.ini is config.h's.
 */

/*
 * name: sys_error
 * desc: Writes msg to error.log FIRST, before anything else -- once
 *       uglRestore has left a graphics mode, a message drawn any other
 *       way is pixels, not text: not in a text buffer, not on
 *       redirected stdout, gone the instant the program ends. A failed
 *       run then looks exactly like a slow one from outside, which
 *       cost real debugging time in this project before error.log
 *       existed. Every fatal path in cport/ (mod.c/assets.c/
 *       mod_tex.c/config.c's own *_fatal helpers) should call this
 *       instead of writing to stderr on its own -- one fact in one
 *       place, and the one place that gets it right. Exits with
 *       status 1 and never returns.
 */
void sys_error( char *msg );

/* Parsed command-line flags. Narrower than the original's Env: only
   what has a real reader in cport/ today (see qmain.c's own call
   site for how each one is applied) -- not_yet_ported flags
   (-spandraw, -dumptex, -dumpsurf, -benchsecs) are parsed and
   silently ignored rather than rejected, matching how an unrecognised
   flag has always behaved here (there's no "unknown flag" error in
   the original either). */
typedef struct {
    char  map_name[64];
    long  bench_ticks;      /* -ticks N; 0 = unbounded (main.bas default) */
    short at_set;
    float at_x, at_y, at_z; /* -at X Y Z */
    short yaw_set;
    float yaw;               /* -yaw D, wrapped into [0,360) */
    short pitch_set;
    float pitch;             /* -pitch D: 0 straight up, 90 the horizon,
                                180 straight down. The camera reads its
                                angle off the mouse, so this is a mouse
                                row -- and without it a headless run can
                                only ever photograph one pitch, which is
                                half of aiming a camera at a bug. */
    short walk, jump, strafe; /* -walk/-jump/-strafe: hold the input */
    short no_stats;
    short stats;             /* -stats: the overlay is OFF by default now,
                                so -nostats is accepted and redundant */          /* -nostats */
    short no_draw;           /* -nodraw (implies no_stats, the overlay
                                 rasterises too) */
    short no_cull;           /* -nocull */
    short no_z;               /* -noz */
    short no_portal;          /* -noportal */
    short no_ents;            /* -noents */
    short no_items;           /* -noitems: the reference frame for the pickups */
    short no_mdl;             /* -nomdl: and for the monsters */
    short bad_order;          /* -badorder */
    short comp;                /* -comp */
    short use_lm;              /* -lm */
    short ptwire;              /* -ptwire */
    char  record_name[64];     /* -record F: log real input to F, one
                                   fixed-size record a frame */
    char  play_name[64];       /* -play F: replace real input with F's
                                   recorded frames, for a deterministic
                                   repro of a live session -- ends the
                                   run (sets esc) at F's last frame */
} RunArgs;

/*
 * name: sys_parse_args
 * desc: Reads the command line straight out of the DOS PSP (offset
 *       0x80: a length byte then the raw tail) rather than through
 *       main(argc, argv). Not a style choice: bcpp31's own bcc emits
 *       an implicit call to its SETARGV wildcard-expansion helper the
 *       moment main() is declared taking argc/argv, and that helper
 *       wants __C0argc/__C0argv -- symbols bcpp31's OWN startup object
 *       would define, but cport/ links tc201's C0M.OBJ instead
 *       (bcpp31 ships no medium-model C0/CM pair at all). The two
 *       don't agree, and TLINK reports it as an unresolved external
 *       naming a module ("SETARGV") that looks unrelated to anything
 *       this file does. _psp itself is declared identically in both
 *       toolchains' own headers (stdlib.h/dos.h) and is what any DOS
 *       C startup sets regardless, so reading through it sidesteps
 *       the mismatch entirely.
 *
 *       Not COMMAND$, so no uppercasing to work around either --
 *       that was a VBDOS runtime quirk, not a property of the command
 *       line itself; flags are matched case-insensitively anyway,
 *       matching the original's own lcase$ compares. The first token
 *       is the map name; prints a usage line and exits if the command
 *       line is empty, matching the original's own behaviour.
 *       Unrecognised flags are ignored.
 */
void sys_parse_args( RunArgs *args );

#endif
