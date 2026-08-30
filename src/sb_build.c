/*
 * sb_build.c -- drop-in C replacement for sb_build (src/d_surf.bas).
 *
 * Same interop rules r_walk.c already worked out: array parameters
 * arrive as a near pointer to a BASARRAY descriptor (see BASARRAY
 * below), whose own farptr field is the far pointer to the actual data;
 * g as Game arrives as a near pointer too. ls_value/ls_scale_byte/
 * ls_add_dlight/sb_seg/sb_pot/mod_lm_map/mod_cm_map/memCopy/uglBuildSurf
 * are all called back into unchanged -- every one of them takes only
 * byval scalars (or g byref, already proven), never a plain (non-SEG)
 * byref UDT or array, which is the specific thing that turned out not
 * to be reproducible from a foreign C function (see r_walk.c's header).
 *
 * ls_scratch and lm_flat were BASIC-side scratch private to sb_build
 * alone (nothing else in the codebase reads either -- grepped, not
 * assumed) so they are plain static C buffers here, not a port of
 * BASIC's string type. That sidesteps BASIC string internals entirely:
 * ls_scratch_c is mutated in place, which BASIC's own version could not
 * do (no precedent anywhere in this codebase for LSET-style in-place
 * mid$, per its own comment) and had to work around by rebuilding the
 * whole string through concatenation instead.
 */

#include "qcshared.h"

/* Game.rdr.dlight's own offset, same story as r_walk.c's GAME_VIS_OFFSET:
   measured (varptr(g.rdr.dlight) - varptr(g) = 5006), not derived from
   World/Env/PlayerState/CamState's sizes ahead of it, and asserted at
   startup (see sb_layout_ok) for the same reason. 5022 - 5006 = 16,
   exactly sizeof(DynLight), confirming dlight is RenderState's last
   field with vis immediately following it -- a cheap independent check
   this comment records but does not rely on at run time.
*/
#define GAME_DLIGHT_OFFSET 5006

#define GEOM_LMOFS 1
#define LS_NEUTRAL 120

extern short pascal far ls_value( short style );
extern short pascal far ls_scale_byte( short raw, short sval );
extern short pascal far ls_add_dlight( short raw, float pdist, float ts, float tt, float radius );
extern long  pascal far mod_lm_map( void *g, short row );
extern long  pascal far mod_cm_map( void *g );
extern short pascal far sb_seg( long p );
extern short pascal far sb_pot( short v );
extern void  pascal far memCopy( long dst, long src, long bytes );
extern short pascal far uglBuildSurf( long dstDc, long texDc, long parm );
extern void  pascal far sc_note_build( void );
extern void  pascal far sc_note_dlit( void );

/* Private to this file, same as ls_scratch/lm_flat were private to
   sb_build alone in d_surf.bas -- confirmed by grep, not assumed. 1024
   matches the original's "as string * 1024" bound. lm_flat's one byte
   is BASIC's own zero-initialised default for an unread integer array
   element (never explicitly assigned anywhere in the source it came
   from), so an unlit face's one flat luxel is byte 0 here too. */
static unsigned char ls_scratch_c[1024];
static unsigned char lm_flat_c = 0;

void pascal far sb_build(
    void  *g,
    long   dc,
    long   tex,
    short  face,
    short  mip,
    short  sw,
    short  sh,
    BASARRAY *tri_dsc,
    BASARRAY *texinf_dsc,
    BASARRAY *gv_dsc,
    BASARRAY *miptex_dsc,
    BASARRAY *pln_dsc
)
{
    Face     far *tri    = (Face     far *) tri_dsc->farptr;
    TexInfo  far *texinf = (TexInfo  far *) texinf_dsc->farptr;
    short    far *gv     = (short    far *) gv_dsc->farptr;
    MipTex   far *miptex = (MipTex   far *) miptex_dsc->farptr;
    Plane    far *pln    = (Plane    far *) pln_dsc->farptr;
    DynLight far *dlight = (DynLight far *) ( (char far *) g + GAME_DLIGHT_OFFSET );

    long  au, av, du, dv;
    short aw, msk;
    short lmw, lmh;
    long  lmx; short lmy; long lmp;
    short tms, tmt;
    long  o;
    short mi; float recip;
    SurfBuild sbp;
    short lseg; long lofs16;
    short style, sval; short scaled = 0;
    long  lrow, srow; short li; long lv;
    Plane pl; float pdist; short dlit = 0;
    float impx, impy, impz;
    short tinfo; float locs, loct;
    short lx, ly;
    long ls_far;

    sc_note_build();

    aw = 64 >> mip;
    msk = aw - 1;
    mi = texinf[ tri[face].tex_info_id ].mip_tex;

    /*
     * Out of the record d_draw_faces already fetched, NOT out of the
     * window it came from -- see sb_build's original comment on why
     * (something between the fetch and here remaps PAGE_SLOT, and the
     * header reads back as zeros against a 0x0 luxel grid).
     */
    lmy = gv[GEOM_LMOFS];
    lmx = (long) (unsigned short) gv[GEOM_LMOFS + 1];
    tms = gv[GEOM_LMOFS + 2];
    tmt = gv[GEOM_LMOFS + 3];
    lmw = gv[GEOM_LMOFS + 4];
    lmh = gv[GEOM_LMOFS + 5];

    if ( lmy < 0 ) {
        ls_far = (long) (void far *) &lm_flat_c;
        lseg   = (short) (ls_far >> 16);
        lofs16 = ls_far & 0xFFFFL;
        lmw = 1;
        lmh = 1;
    } else {
        lmp = mod_lm_map( g, lmy );
        lseg   = sb_seg( lmp );
        lofs16 = (lmp & 0xFFFFL) + lmx;

        style = gv[GEOM_LMOFS + 6] & 255;
        sval  = ls_value( style );

        pl = pln[ tri[face].plane_id ];
        pdist = dlight->pos.x * pl.norm.x + dlight->pos.y * pl.norm.y +
                dlight->pos.z * pl.norm.z - pl.dist;
        dlit = ( (pdist < 0.0 ? -pdist : pdist) < dlight->radius );
        if ( dlit ) {
            sc_note_dlit();
            impx = dlight->pos.x - pdist * pl.norm.x;
            impy = dlight->pos.y - pdist * pl.norm.y;
            impz = dlight->pos.z - pdist * pl.norm.z;
            tinfo = tri[face].tex_info_id;
            locs = impx*texinf[tinfo].vecs[0] + impy*texinf[tinfo].vecs[1] +
                   impz*texinf[tinfo].vecs[2] + texinf[tinfo].vecs[3];
            loct = impx*texinf[tinfo].vect[0] + impy*texinf[tinfo].vect[1] +
                   impz*texinf[tinfo].vect[2] + texinf[tinfo].vect[3];
        }

        if ( (sval != LS_NEUTRAL || dlit) && (long) lmw * lmh <= 1024L ) {
            srow = (long) lseg * 65536L + lofs16;
            ls_far = (long) (void far *) ls_scratch_c;
            lrow = ls_far;
            for ( li = 0; li < lmh; li++ ) {
                memCopy( lrow, srow, (long) lmw );
                srow += sb_pot( lmw );
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
                                        dlight->radius );
                }
                ls_scratch_c[li] = (unsigned char) lv;
            }
            lseg   = (short) (ls_far >> 16);
            lofs16 = ls_far & 0xFFFFL;
            scaled = 1;
        }
    }

    /* atlas texels per surface texel, 16.16. wdth/hght are already 1/origW. */
    recip = miptex[mi].wdth;
    du = ( (long) (aw * 65536.0 * recip) ) << mip;
    recip = miptex[mi].hght;
    dv = ( (long) (aw * 65536.0 * recip) ) << mip;

    au = (long) tms * (du >> mip);
    av = (long) tmt * (dv >> mip);

    sbp.lmptr = (long) lseg * 65536L + lofs16;
    sbp.lm_stride = scaled ? (long) lmw : (long) sb_pot( lmw );
    sbp.cmap_ptr = mod_cm_map( g );
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

    o = (long) (void far *) &sbp;
    if ( uglBuildSurf( dc, tex, o ) == 0 ) {
        /* only a luxel grid too big for the builder's stack buffer gets
           here; leave the surface as it is rather than half-composite it */
    }
}

/* Called once at startup (see main.bas) with off = varptr(g.rdr.dlight)
   - varptr(g): fails loud if a field shifts ahead of dlight in Game. */
int pascal far sb_layout_ok( long off )
{
    return ( off == GAME_DLIGHT_OFFSET );
}
