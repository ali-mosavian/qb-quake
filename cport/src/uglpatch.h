#ifndef __UGLPATCH_H__
#define __UGLPATCH_H__

/*
 * uglpatch.h -- the small set of uGL entry points genuinely missing
 * from mgl's own shipped inc/*.h, which this project includes directly
 * for everything else (UAR, u3dVector3f, u3dMtrx, MOUSEINF, TKBD, TMR,
 * RGB -- all real, all accurate, no reason to hand-transcribe them).
 *
 * Confirmed missing by grep against ~/work/badlogic/mgl/inc/*.h, not
 * assumed: uglPolyTP, uglBuildSurf, uglNewView, uglSetView, uglZMode,
 * uglClearZ, uglMapEx. These are the newer entries the shipped headers
 * haven't caught up to yet. Signatures cross-checked against the asm
 * `proc` directives themselves (tools/apicheck.py, main project), not
 * just the BASIC .bi declares -- see that tool's own note on why: the
 * assembler derives stack offsets from `proc`, so it cannot drift the
 * way a hand-written header can.
 *
 * uglArrNew/uglArrMap/uglArrLoad are NOT here, deliberately: ugl.bi
 * declares them, but they exist to rebind a BASIC array's own runtime
 * descriptor (AD_hData/AD_oAdjusted -- see src/ugl/uglarr.asm's own
 * header in the mgl checkout) so arr(i) indexing keeps working after
 * the array's bytes move somewhere BASIC doesn't own. C has no array
 * descriptor to rebind -- a far pointer already IS the binding -- so
 * calling these from here would walk memory at whatever address gets
 * passed as if it held one, corrupting it. Every load site that used
 * them in the original goes through assets.h's asset_load (a MEM
 * block: memAlloc + a flat read, no windowing) or a direct
 * uglNew+uglMapEx pair (an EMS store, mod.c's own colormap/lightmap/
 * geometry-store loads) instead.
 */

#include "ugl.h"

/* uGL's own per-vertex record for uglPolyTP -- x y z u v r g b, eight
   floats. Also missing from the shipped headers. */
typedef struct {
    float x, y, z, u, v, r, g, b;
} uglvtx;

/* pal.h's RGB/PRGB/PAL_RGB/uglPalSet/uglPalGet/uglPalLoad, hand-copied
   rather than #included: pal.h itself has a genuine syntax bug (not
   staleness) -- uglPalFadeIn/uglPalFadeOut each have a stray "_"
   BASIC-style line-continuation character left over from generating
   the .h out of the .bi, which isn't a comment or an identifier
   boundary in C and breaks parsing of the whole file. Neither fade
   function is used here; this avoids pal.h entirely rather than
   depend on a file that won't parse under bcc as shipped. */
typedef struct { char red, green, blue; } RGB;
typedef RGB far *PRGB;
#define PAL_RGB 0
void pascal far uglPalSet( short idx, short entries, RGB far *pal );
void pascal far uglPalGet( short idx, short entries, RGB far *pal );
PRGB pascal far uglPalLoad( char far *fname, short fmt );
short pascal far uglPalBestFit( RGB far *pal, short r, short g, short b );

short pascal far uglBuildSurf( PDC dstDc, PDC texDc, long parm );
void  pascal far uglClearZ( PDC zdc, short value );
long  pascal far uglMapEx( PDC dc, short y, short slot );
PDC   pascal far uglNewView( PDC src, long ofs, short xRes, short yRes );
void  pascal far uglPolyTP( PDC dstDC, uglvtx far *vtx, short vtxCnt, short masking, PDC srcDC );
short pascal far uglSetView( PDC dc, long ofs );
short pascal far uglZMode( short mode );

/* uglShadeRect (mgl's own "darken through the colormap" primitive,
   hud_shade's whole job) -- missing from ugl.h; uglPSet (initially
   assumed missing too, alongside uglPGet's own neighbours) turned out
   to be real and already declared there -- checked by grep, not
   assumed, after bcc reported a redeclaration mismatch against this
   file's own now-removed duplicate. */
void  pascal far uglShadeRect( PDC dc, short x0, short y0, short x1, short y1,
                                long cmap, short rw );

/* uglz.asm's -- the depth buffer, same "confirmed missing by grep"
   status as everything else above. NULL turns depth off outright, so
   uglSetZ takes no return and a 0 zdc is a legal argument. */
PDC   pascal far uglNewZ( PDC dc, short typ );
void  pascal far uglSetZ( PDC zdc );
long  pascal far uglZScale( float scale );

#endif
