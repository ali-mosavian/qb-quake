#ifndef __VIDEO_H__
#define __VIDEO_H__

#include "qgl.h"

/*
 * Video -- open mode, backbuffer, page-flip state. Owned by whoever
 * calls v_init (main(), eventually), passed explicitly everywhere it's
 * needed. No global; no Env to reach into.
 *
 * DC handles are QSurf (ugl.h: far *DC), mgl's own real type, not a bare
 * long -- BASIC's "Byval ... As Long" and this are the same four bytes
 * on the stack, but QSurf is what the C API actually declares, so it's
 * what avoids a cast at every call site.
 */
typedef struct {
    QSurf   h_video_dc;
    QSurf   h_comp_dc;
    QSurf   h_back_bdc;
    short x_res, y_res;
    short scr_x_res, scr_y_res;
    short view_x, view_y, view_scale;
    short c_fmt;
    short comp;
} Video;

void  v_init_ugl( void );
void  v_init( Video *v, long pal );
short v_present( Video *v, QSurf h_dst_dc, short page );

#endif
