/*
 * sb_build.c -- composites one face's texture and lightmap into a
 * cache DC. C port of d_surf.bas's sb_build, adapted from the
 * BASIC-linked build's own src/sb_build.c (BASARRAY descriptors and
 * "g as Game" -> World-/Renderer-/LightStyles-/SurfCache-taking).
 *
 * mod_lm_map/mod_cm_map (model.bas, not yet ported into cport/) are
 * declared here with the signature they SHOULD have once they exist --
 * a genuine `unsigned char far *` to the mapped EMS window, not
 * BASIC's packed long + DEF SEG/PEEK. That's what lets this file use
 * ordinary pointer arithmetic throughout instead of sb_seg's segment
 * reconstruction, which the old BASIC needed and this doesn't.
 *
 * KNOWN BUG, NOT YET FIXED HERE: srow is computed ONCE from
 * mod_lm_map(world, lmy) and then walked across lmh rows by
 * `srow += sb_pot(lmw)`, exactly as the original did. That's the same
 * shape as the qglSbBuild destination-pointer bug already fixed in
 * mgl (src/ugl/uglsurf.asm, commit b0abc01): an EMS page window mapped
 * once and read across multiple rows is only valid until the NEXT
 * acquire evicts it, and nothing here holds a lock across the loop.
 * An earlier session attempted the obvious fix -- call mod_lm_map
 * again per row instead of walking the pointer -- against the
 * BASIC-linked build and hit a confirmed crash (INT6, invalid opcode)
 * whose root cause was never isolated; the fix was reverted rather
 * than landed unverified. It is not re-attempted here for the same
 * reason: mod_lm_map doesn't exist yet in cport/ to test against, and
 * the crash needs a working build to diagnose, not a guess. Fix this
 * once model.bas's own mod_lm_map is real, with a churn test
 * (tools/check.sh --churn's own method: same camera, two runs, diff
 * the picture) as the gate -- exactly how the qglSbBuild fix was
 * verified.
 */

#include <mem.h>

#include "sb_build.h"
#include "dl.h"
#include "qgl.h"   /* qglSbBuild, qglSfSize */

#define GEOM_LMOFS 1
#define LS_NEUTRAL 120

/* model.bas, not yet ported -- see this file's own header for the
   signature these should have once they exist. */
extern unsigned char far *mod_lm_map( World *world, short row );
extern unsigned char far *mod_cm_map( World *world );

/* v rounded up to a power of two. Luxel grids top out at 17, so the
   loop runs at most five times and only once per surface build. */
static short sb_pot( short v )
{
    short p = 1;
    while ( p < v ) p *= 2;
    return p;
}

/* Private to this file, same as the BASIC-linked build's own version:
   confirmed by grep, nothing else reads either. lm_flat's one byte is
   BASIC's own zero-initialised default for an unread integer array
   element, so an unlit face's one flat luxel is byte 0 here too. */
static unsigned char ls_scratch_c[1024];
static unsigned char lm_flat_c = 0;

/* R_BuildLightMap's sum into the scratch: each style's plane scaled by
   its value, the planes stacked lmh rows apart in the face's slot. */
static void sb_sum_styles( LightStyles *ls, unsigned char far *srow,
                           short lmw, short lmh, short s01, short s23, short nst )
{
    short sval[4], k, x, y;
    long  stride = sb_pot( lmw ), v;
    unsigned char *dst = ls_scratch_c;

    for ( k = 0; k < nst; k++ ) sval[k] = ls_value( ls, ls_face_style( s01, s23, k ) );
    for ( y = 0; y < lmh; y++ )
        for ( x = 0; x < lmw; x++ ) {
            v = 0;
            for ( k = 0; k < nst; k++ )
                v += (long) srow[ ( (long) k * lmh + y ) * stride + x ] * sval[k];
            v /= LS_NEUTRAL;
            *dst++ = (unsigned char) ( v > 255 ? 255 : v );
        }
}

void sb_build( SurfCache far *sc, World *world, Renderer *rdr, LightStyles *ls,
               QSurf dc, QSurf tex, short face, short mip, short sw, short sh,
               short far *gv, unsigned long dlbits )
{
    Face    far *f  = &world->faces[face];
    TexInfo far *ti = &world->texinfo[ f->tex_info_id ];

    long  au, av, du, dv;
    short cw, ch, umsk, vmsk;
    short lmw, lmh;
    long  lmx; short lmy;
    short tms, tmt;
    short mi; float recip;
    SurfBuild sbp;
    unsigned char far *srow;
    unsigned char far *lrow;
    short style, sval; short scaled = 0;
    short li, nst; long lv;

    sc_note_build( sc );

    mi = ti->mip_tex;

    /* Out of the VIEW, not out of mip: a cell is the texture's own
       power-of-two size now, a level too small to be worth its own copy
       shares the level above, and an animated face is aimed at a frame
       whose id is not ti->mip_tex. mod_tex already shaped the view to
       the cell, so the view is the one place that knows. */
    cw = qglSfSize( tex, 0 );
    ch = qglSfSize( tex, 1 );
    umsk = cw - 1;
    vmsk = ch - 1;

    /*
     * Out of the record d_draw_faces already fetched, NOT out of the
     * window it came from -- something between the fetch and here
     * remaps PAGE_SLOT, and the header would read back as zeros
     * against a 0x0 luxel grid.
     */
    lmy = gv[GEOM_LMOFS];
    lmx = (long) (unsigned short) gv[GEOM_LMOFS + 1];
    tms = gv[GEOM_LMOFS + 2];
    tmt = gv[GEOM_LMOFS + 3];
    lmw = gv[GEOM_LMOFS + 4];
    lmh = gv[GEOM_LMOFS + 5];

    if ( lmy < 0 ) {
        srow = &lm_flat_c;
        lmw = 1;
        lmh = 1;
    } else {
        srow = mod_lm_map( world, lmy ) + lmx;

        style = gv[GEOM_LMOFS + 6] & 255;
        sval  = ls_value( ls, style );
        nst   = ls_face_styles( gv[GEOM_LMOFS + 6], gv[GEOM_LMOFS + 7] );

        if ( dlbits ) sc_note_dlit( sc );

        /* The product alone does not bound the copy: a NEGATIVE lmw
           passes `lmw * lmh <= 1024` and then `(size_t) lmw` is nearly
           64K, so one row of a 1024-byte buffer is a rep movsw through
           BSS and the stack into _fmemcpy's own return address. That is
           what the e1m1 freeze was, with lmw -4077 out of a record read
           through a stale EMS window. The window is fixed in dctems, so
           nothing should reach here with a negative width again -- bound
           the components anyway, because the cost is two compares and
           the failure is the whole process. */
        if ( (sval != LS_NEUTRAL || nst > 1 || dlbits) &&
             lmw > 0 && lmh > 0 && (long) lmw * lmh <= 1024L ) {
            if ( nst > 1 ) {
                sb_sum_styles( ls, srow, lmw, lmh, gv[GEOM_LMOFS + 6],
                               gv[GEOM_LMOFS + 7], nst );
            } else {
                lrow = ls_scratch_c;
                for ( li = 0; li < lmh; li++ ) {
                    _fmemcpy( lrow, srow, (size_t) lmw );
                    srow += sb_pot( lmw );   /* see this file's own header:
                                                 the known, not-yet-fixed bug */
                    lrow += lmw;
                }
                if ( sval != LS_NEUTRAL )
                    for ( li = 0; li < lmw * lmh; li++ ) {
                        lv = ls_scale_byte( ls_scratch_c[li], sval );
                        ls_scratch_c[li] = (unsigned char) lv;
                    }
            }
            if ( dlbits )
                dl_add_luxels( rdr, dlbits, &world->planes[ f->plane_id ], ti,
                               tms, tmt, ls_scratch_c, lmw, lmh );
            srow = ls_scratch_c;
            scaled = 1;
        }
    }

    /* atlas texels per MIP-0 texel, 16.16. wdth/hght are already 1/origW. */
    recip = world->miptex[mi].wdth;
    du = (long) ( cw * 65536.0 * recip );
    recip = world->miptex[mi].hght;
    dv = (long) ( ch * 65536.0 * recip );

    au = (long) tms * du;
    av = (long) tmt * dv;

    /* and per SURFACE texel, which is 1<<mip of them */
    du <<= mip;
    dv <<= mip;

    sbp.lmptr     = (long) (void far *) srow;
    sbp.lm_stride = scaled ? (long) lmw : (long) sb_pot( lmw );
    sbp.cmap_ptr  = (long) (void far *) mod_cm_map( world );
    sbp.au0 = au;
    sbp.av0 = av;
    sbp.du  = du;
    sbp.dv  = dv;
    sbp.sw  = sw;
    sbp.sh  = sh;
    sbp.lmw = lmw;
    sbp.lmh = lmh;
    sbp.shft = 4 - mip;
    sbp.msk  = umsk;
    sbp.vmsk = vmsk;

    /* refused -- a luxel grid past sb$lgrid, or a destination not in one
       window: forget the block, or a variant would keep it */
    if ( !qglSbBuild( dc, tex, (long) (void far *) &sbp ) ) sc_forget( sc, face );
}
