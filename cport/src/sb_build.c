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
#include "qgl.h"   /* qglSbBuild */

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

void sb_build( SurfCache far *sc, World *world, Renderer *rdr, LightStyles *ls,
               QSurf dc, QSurf tex, short face, short mip, short sw, short sh,
               short far *gv )
{
    Face    far *f  = &world->faces[face];
    TexInfo far *ti = &world->texinfo[ f->tex_info_id ];

    long  au, av, du, dv;
    short aw, msk;
    short lmw, lmh;
    long  lmx; short lmy;
    short tms, tmt;
    short mi; float recip;
    SurfBuild sbp;
    unsigned char far *srow;
    unsigned char far *lrow;
    short style, sval; short scaled = 0;
    short li; long lv;
    Plane pl; float pdist; short dlit = 0;
    float impx, impy, impz;
    float locs, loct;
    short lx, ly;

    sc_note_build( sc );

    aw = 64 >> mip;
    msk = aw - 1;
    mi = ti->mip_tex;

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

        pl = world->planes[ f->plane_id ];
        pdist = rdr->dlight.pos.x * pl.norm.x + rdr->dlight.pos.y * pl.norm.y +
                rdr->dlight.pos.z * pl.norm.z - pl.dist;
        dlit = ( (pdist < 0.0f ? -pdist : pdist) < rdr->dlight.radius );
        if ( dlit ) {
            sc_note_dlit( sc );
            impx = rdr->dlight.pos.x - pdist * pl.norm.x;
            impy = rdr->dlight.pos.y - pdist * pl.norm.y;
            impz = rdr->dlight.pos.z - pdist * pl.norm.z;
            locs = impx*ti->vecs[0] + impy*ti->vecs[1] + impz*ti->vecs[2] + ti->vecs[3];
            loct = impx*ti->vect[0] + impy*ti->vect[1] + impz*ti->vect[2] + ti->vect[3];
        }

        if ( (sval != LS_NEUTRAL || dlit) && (long) lmw * lmh <= 1024L ) {
            lrow = ls_scratch_c;
            for ( li = 0; li < lmh; li++ ) {
                _fmemcpy( lrow, srow, (size_t) lmw );
                srow += sb_pot( lmw );   /* see this file's own header:
                                             the known, not-yet-fixed bug */
                lrow += lmw;
            }
            for ( li = 0; li < lmw * lmh; li++ ) {
                lv = ls_scratch_c[li];
                if ( sval != LS_NEUTRAL ) lv = ls_scale_byte( (short) lv, sval );
                if ( dlit ) {
                    lx = li % lmw;
                    ly = li / lmw;
                    lv = ls_add_dlight( (short) lv, pdist,
                                        locs - (tms + lx*16 + 8),
                                        loct - (tmt + ly*16 + 8),
                                        rdr->dlight.radius );
                }
                ls_scratch_c[li] = (unsigned char) lv;
            }
            srow = ls_scratch_c;
            scaled = 1;
        }
    }

    /* atlas texels per surface texel, 16.16. wdth/hght are already 1/origW. */
    recip = world->miptex[mi].wdth;
    du = ( (long) (aw * 65536.0 * recip) ) << mip;
    recip = world->miptex[mi].hght;
    dv = ( (long) (aw * 65536.0 * recip) ) << mip;

    au = (long) tms * (du >> mip);
    av = (long) tmt * (dv >> mip);

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
    sbp.msk  = msk;

    if ( !qglSbBuild( dc, tex, (long) (void far *) &sbp ) ) {
        /* only a luxel grid too big for the builder's stack buffer
           gets here; leave the surface as it is rather than
           half-composite it */
    }
}
