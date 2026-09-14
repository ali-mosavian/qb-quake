/*
 * d_faces.c -- d_draw_faces, the whole per-frame face loop, in C.
 *
 * C port of the BASIC-linked build's own src/d_faces.c (see that
 * file's own header for why this is ONE call per frame, not a
 * per-face crossing). Adapted the same way pl_trace.c/r_walk.c/
 * r_portal.c/sb_build.c already were: World-/Renderer-taking
 * parameters replace the dozen BASARRAY descriptors, since every
 * array they named already lives on one or the other. The per-face
 * MATH itself, and the
 * comments explaining each non-obvious step, are carried over
 * unchanged -- this is a calling-convention adaptation, not a rewrite.
 *
 * Not ported: the -spandraw prototype path (r_span.c). It is a
 * measurement rasteriser that draws nothing unless explicitly asked
 * and shares no state with the real per-face loop below -- see
 * renderer.h's own note on DrawParams for why dropping it is a
 * deliberate scope cut.
 */

#include <string.h>

#include "qrcfg.h"
#include "d_faces.h"
#include "d_poly.h"
#include "qgl.h"
#include "mod.h"
#include "mod_tex.h"
#include "r_bsp.h"
#include "dl.h"

/* q_map.bi's -- must not drift from it (mod.c has its own copy, in a
   separate translation unit; not shared on purpose, see World's own
   note on why the geometry store's shape isn't in a header). */
#define GEOM_W       8192
#define GEOM_LMOFS   1
#define GEOM_VTX0    9
#define GEOM_MAXVTX  33
#define GEOM_MAXREC  (18 + GEOM_MAXVTX * 6)

/* bspfile.bi's vertex2 is Q13.3. A multiply, not a divide. */
#define VTX_UNSCALE  0.125f

/* q_draw.bi's. */
#define TURB_FREQ    326.0f
#define TURB_RATE    40.74f

/* ugl.bi's UGL.Z.* */
#define QGL_Z_OFF    0
#define QGL_Z_SET  1
#define QGL_Z_TEST   2

/* The clipper adds at most one vertex per plane, so input + 2 suffices. */
#define MAXV (GEOM_MAXVTX + 8)

extern void pascal far r_vxfrm(
    short far *gv, short vcnt, float *ofs, float *suv, float *m,
    float *vt_x, float *vt_y, float *vt_z, float *vt_w,
    float *vt_u, float *vt_v );

extern void pascal far r_gvcpy( char far *src, char far *dst, short gn );

/* Per-face scratch. Static, not automatic: the medium model's stack is
   not where a dozen MAXV float arrays belong. */
static float near vt_x[MAXV], vt_y[MAXV], vt_z[MAXV], vt_w[MAXV];
static float near vt_u[MAXV], vt_v[MAXV];
static float near cl_x[MAXV], cl_y[MAXV], cl_z[MAXV], cl_w[MAXV];
static float near cl_u[MAXV], cl_v[MAXV];
static float near px[MAXV], py[MAXV], pw[MAXV], pu[MAXV], pv[MAXV];
static QVert near pvtx[MAXV];

/* d_surf.bas's old gv_buf: one face's geometry record, fetched fresh
   every face (see the copy site below for why it is never hoisted).
   near: r_gvcpy/sb_build both want it far, which a near->far cast
   supplies safely (adds DS) -- the dangerous direction is the other
   way, see this project's own notes on why. Sized to the original's
   own redim bound (0..108, 109 shorts = 218 bytes), comfortably past
   GEOM_MAXREC's 216-byte worst case. */
static short near gv_buf[109];

/* BASIC's int() is FLOOR, not truncation -- they differ by one for a
   negative argument, and the turbulence index goes negative. */
static long near ifloor( float x )
{
    long t = (long) x;
    if ( x < 0.0f && (float) t != x ) t--;
    return t;
}

/* Sutherland-Hodgman on w against one bound. keep_ge selects the side:
   near keeps w >= bound, far keeps w <= bound. z rides along without
   being interpolated. */
static short near clip_w(
    float *ix, float *iy, float *iz, float *iw, float *iu, float *iv, short icnt,
    float *ox, float *oy, float *oz, float *ow, float *ou, float *ov,
    float bound, short keep_ge )
{
    short n, s1, s2, dst = 0, in1, in2;
    float scl;

    for ( n = 0; n < icnt; n++ ) {
        s1 = n;
        s2 = ( n + 1 == icnt ) ? 0 : n + 1;

        in1 = keep_ge ? ( iw[s1] >= bound ) : ( iw[s1] <= bound );
        in2 = keep_ge ? ( iw[s2] >= bound ) : ( iw[s2] <= bound );

        if ( in1 ) {
            ox[dst] = ix[s1]; oy[dst] = iy[s1];
            oz[dst] = iz[s1]; ow[dst] = iw[s1];
            ou[dst] = iu[s1]; ov[dst] = iv[s1];
            dst++;
            if ( in2 ) continue;
        } else {
            if ( !in2 ) continue;
        }

        scl = ( bound - iw[s1] ) / ( iw[s2] - iw[s1] );
        ox[dst] = ix[s1] + ( ix[s2] - ix[s1] ) * scl;
        oy[dst] = iy[s1] + ( iy[s2] - iy[s1] ) * scl;
        oz[dst] = iz[s1];
        ow[dst] = bound;
        ou[dst] = iu[s1] + ( iu[s2] - iu[s1] ) * scl;
        ov[dst] = iv[s1] + ( iv[s2] - iv[s1] ) * scl;
        dst++;
        if ( dst >= MAXV ) break;
    }
    return dst;
}

/* 1 / 2^n for n = mip + SC_SHIFT, at most 3 + 8: the lightmap scale
   without two long shifts, a long multiply and two divides a face. */
static const float lm_recip[12] = {
    1.0f, 0.5f, 0.25f, 0.125f, 0.0625f, 0.03125f, 0.015625f, 0.0078125f,
    0.00390625f, 0.001953125f, 0.0009765625f, 0.00048828125f
};

void d_draw_faces( World *world, Renderer *rdr, SurfCache far *sc, LightStyles *ls,
                    DrawParams *dp, Mat4 *m, Vec3 *campos, SysClock *sysclk )
{
    Face       far *tri     = world->faces;
    TexInfo    far *texinf  = world->texinfo;
    BrushModel far *brush   = world->brush;
    Plane      far *planes  = world->planes;
    Node       far *nodes   = world->nodes;
    MipTex     far *mipinf  = world->miptex;
    short      far *order   = rdr->ord;
    short      fmdl;
    unsigned char far *pflag = rdr->pflag;
    long       far *tex_ofs = (long far *) dp->tex_ofs_ptr;

    short mi, m_node, ti, i, j, v0, gn, vcnt, cnt;
    short all_in;
    float zn, zf;
    short tex, tex_id, draw_mip, mip_level, liquid;
    short z_want, z_have = -1, lm_use, lm_on;
    short lm_tms, lm_tmt, lm_extw, lm_exth;
    long  lm_stag;
    short lm_mip, lm_floor, lm_sw, lm_sh, lm_fw, lm_fh, lm_cm;
    short leaf_indx, leaf_end, p2;
    long  aim_ofs, lm_dc, src_dc, tex_dc, texofs;
#if QR_PROF
    long  bt0, bface, build_cyc = 0;
    long  rt0, raster_cyc = 0;
#endif
    float su0, su1, su2, su3, sv0, sv1, sv2, sv3;
    float suv[8];
    float tw, th, dp_dist, turbph, zl, zsum;
    float ofs3[3];          /* the owning submodel's offset, BSP-space */
    float vx, vy, vz, tu, tv, rw, lm_su, lm_sv;
    unsigned long dl_bits;
    unsigned long dl_on = dl_live( rdr );
    Plane far *pl;
    short far *gv;
    float far *turb_sin = (float far *) dp->turb_ptr;

    dp->polys = 0;
    dp->tris  = 0;
#if QR_PROF
    dp->lm_want = 0;
    dp->lm_fallback = 0;
    dp->k_mip = 0; dp->k_sw = 0; dp->k_sh = 0; dp->k_stag = 0; dp->k_n = 0;
    dp->k_hdr = 0; dp->k_ext = 0; dp->k_v0 = 0; dp->k_lm = 0;
#endif
    dp->build_us = 0;
    dp->raster_us = 0;

    turbph = dp->anim_time * TURB_RATE;

    /* The flag says the data was loaded; the toggle says whether to
       use it now. Clearing this makes every face below a plain
       textured one. */
    lm_use = ( dp->use_lm && dp->lightmap && sc_ready( sc ) != 0 );

    for ( mi = 0; mi < dp->ord_count; mi++ ) {
        m_node    = order[mi];
        leaf_indx = nodes[m_node].lface_id;
        leaf_end  = leaf_indx + nodes[m_node].lface_num - 1;

        for ( ti = leaf_indx; ti <= leaf_end; ti++ ) {
            i = ti;

            if ( !( pflag[i >> 3] & ( 1 << (i & 7) ) ) ) continue;

            /* Backface cull: side 0 points along the normal, side 1
               against it, and a face is only ever visible from its
               own front. */
            pl = &planes[ tri[i].plane_id ];
            dp_dist = r_cam_plane_dist( campos, pl );
            if ( tri[i].side & 1 ) dp_dist = -dp_dist;
            if ( dp->backface != 0 && dp_dist <= 0.01f ) continue;

            dp->polys++;

            /* This face's corners, out of the geometry store. The
               destination pointer is taken PER FACE -- gv_buf is our
               own static, never relocated by anything, but the source
               (mod_geom_map's EMS window) can move on the next
               unrelated map, so re-mapping it fresh every face costs
               nothing and keeps the invariant local rather than
               assumed. */
            gv = gv_buf;
            gn = GEOM_MAXREC;
            if ( tri[i].geom_ofs + gn > GEOM_W ) gn = (short)( GEOM_W - tri[i].geom_ofs );
            {
                char far *src = (char far *) mod_geom_map( world, tri[i].geom_row ) + tri[i].geom_ofs;
                char far *dst = (char far *) gv;
                r_gvcpy( src, dst, gn );
            }

            vcnt   = gv[0];
            tex    = tri[i].tex_info_id;
            tex_id = texinf[tex].mip_tex;
            liquid = mipinf[tex_id].liquid;
            fmdl = (short) ( tri[i].side >> 1 );
            ofs3[0] = brush[fmdl].ofs.x;
            ofs3[1] = brush[fmdl].ofs.y;
            ofs3[2] = brush[fmdl].ofs.z;

            /* No early reject on vcnt: a degenerate face still passes
               through the lightmap gate below in the original, and
               skipping it early would starve sc_find of calls it
               should see. Clamp for the buffer's sake, do not skip. */
            if ( vcnt > GEOM_MAXVTX ) vcnt = GEOM_MAXVTX;
            if ( vcnt < 0 ) vcnt = 0;

            /* Depth mode follows what the face belongs to: the world
               only writes (the walk hands it over in order), a brush
               entity tests -- nothing guarantees its own order against
               the world's. */
            if ( dp->z_avail ) {
                z_want = ( fmdl == 0 ) ? QGL_Z_SET : QGL_Z_TEST;
                if ( z_want != z_have ) {
                    /* qglSfZMode returns the mode it REPLACED, so assigning
                       its result left z_have one call behind and the next
                       face of the same kind called again for nothing. */
                    qglSfZMode( dp->h_dst_dc, z_want );
                    z_have = z_want;
                }
            }

            tw = mipinf[tex_id].wdth;
            th = mipinf[tex_id].hght;

            /* Surface-cache candidate? Needs a lightmap, and must be
               neither liquid (perturbed per vertex) nor animated
               (would rebuild every time the frame index moved). */
            lm_on = 0;
            lm_stag = 0;
            dl_bits = 0;
            lm_extw = lm_exth = 0;
            lm_tms = lm_tmt = 0;
#if QR_PROF
            dp->k_v0 += vcnt;
            dp->k_lm += gv[GEOM_LMOFS];
#endif

            if ( lm_use && liquid == 0 && mipinf[tex_id].anim_count <= 1 ) {
                if ( gv[GEOM_LMOFS] >= 0 ) {
#if QR_PROF
                    dp->k_hdr++;
#endif
                    lm_tms  = gv[GEOM_LMOFS + 2];
                    lm_tmt  = gv[GEOM_LMOFS + 3];
                    lm_extw = (short)( ( gv[GEOM_LMOFS + 4] - 1 ) * 16 );
                    lm_exth = (short)( ( gv[GEOM_LMOFS + 5] - 1 ) * 16 );
                    if ( lm_extw > 0 && lm_exth > 0 ) lm_on = 1;

                    {
                        short s01 = gv[GEOM_LMOFS + 6], s23 = gv[GEOM_LMOFS + 7];
                        lm_stag = LS_FACE_KEY( ls, s01, s23 );
                    }

                    /* D_CacheSurface's cache->dlight: a lit face
                       rebuilds while lit and once after. A constant
                       stag here hit on the second lit frame, and the
                       glow froze at its first build. */
                    dl_bits = dl_mark( rdr, dl_on, pl, &texinf[tex], lm_tms, lm_tmt,
                                       lm_extw, lm_exth );
                    if ( dl_bits ) lm_stag = dl_stag( rdr );
                }
            }

            /* A cached face keeps ORIGINAL TEXEL units -- the shift
               to surface-local space needs the unscaled value and
               cannot be applied until the mip is known. Everything
               else normalises against the atlas here. */
            if ( lm_on ) {
                su0 = texinf[tex].vecs[0]; su1 = texinf[tex].vecs[1];
                su2 = texinf[tex].vecs[2]; su3 = texinf[tex].vecs[3];
                sv0 = texinf[tex].vect[0]; sv1 = texinf[tex].vect[1];
                sv2 = texinf[tex].vect[2]; sv3 = texinf[tex].vect[3];
            } else {
                su0 = texinf[tex].vecs[0]*tw; su1 = texinf[tex].vecs[1]*tw;
                su2 = texinf[tex].vecs[2]*tw; su3 = texinf[tex].vecs[3]*tw;
                sv0 = texinf[tex].vect[0]*th; sv1 = texinf[tex].vect[1]*th;
                sv2 = texinf[tex].vect[2]*th; sv3 = texinf[tex].vect[3]*th;
            }

            /* Animation swaps which image is sampled; index
               arithmetic only, once per face. */
            if ( mipinf[tex_id].anim_count > 1 )
                tex_id = world->anim_tab[ mipinf[tex_id].anim_base
                       + ( ifloor( dp->anim_time * 5.0f ) % mipinf[tex_id].anim_count ) ];

            if ( liquid ) {
                for ( j = 0; j < vcnt; j++ ) {
                    v0 = (short)( j*3 + GEOM_VTX0 );
                    vx = gv[v0    ] * VTX_UNSCALE;
                    vy = gv[v0 + 1] * VTX_UNSCALE;
                    vz = gv[v0 + 2] * VTX_UNSCALE;

                    /* BSP is Z-up, renderer is Y-up: y and z swap, and
                       the brush entity's offset swaps with them. A door
                       slides along whichever axis its movedir names. */
                    vt_x[j] = vx + ofs3[0];
                    vt_y[j] = vz + ofs3[2];
                    vt_z[j] = vy + ofs3[1];

                    tu = su0*vx + su1*vy + su2*vz + su3;
                    tv = sv0*vx + sv1*vy + sv2*vz + sv3;

                    vt_u[j] = tu + turb_sin[ (short)( ifloor( tv*TURB_FREQ + turbph ) & 255 ) ];
                    vt_v[j] = tv + turb_sin[ (short)( ifloor( tu*TURB_FREQ + turbph ) & 255 ) ];
                }

                /* Row-vector times a 4x4 with w = 1. Mat4's fields
                   (m11..m44) are a row-major flatten with no padding,
                   same layout the original read through a flat
                   float[16] -- m[0]=m11 .. m[15]=m44 -- so indexing
                   named fields here is the same arithmetic, not a
                   reinterpretation. */
                for ( j = 0; j < vcnt; j++ ) {
                    vx = vt_x[j]; vy = vt_y[j]; vz = vt_z[j];
                    vt_x[j] = vx*m->m11 + vy*m->m21 + vz*m->m31 + m->m41;
                    vt_y[j] = vx*m->m12 + vy*m->m22 + vz*m->m32 + m->m42;
                    vt_z[j] = vx*m->m13 + vy*m->m23 + vz*m->m33 + m->m43;
                    vt_w[j] = vx*m->m14 + vy*m->m24 + vz*m->m34 + m->m44;
                }
            } else {
                /* r_vxfrm.asm: unpack, UV, transform, one pass. */
                suv[0] = su0; suv[1] = su1; suv[2] = su2; suv[3] = su3;
                suv[4] = sv0; suv[5] = sv1; suv[6] = sv2; suv[7] = sv3;
                r_vxfrm( gv, vcnt, ofs3, suv, (float *) m,
                         vt_x, vt_y, vt_z, vt_w, vt_u, vt_v );
            }

            /* Test first: a face wholly between near and far -- the
               common case -- skips both clip calls outright. The test
               is one compare per vertex against the same two bounds
               clip_w itself would use, so the answer is identical by
               construction. */
            zn = dp->z_near;
            zf = dp->z_far;
            all_in = 1;
            for ( j = 0; j < vcnt; j++ ) {
                if ( vt_w[j] < zn || vt_w[j] > zf ) { all_in = 0; break; }
            }

            if ( all_in ) {
                cnt = vcnt;
            } else {
                cnt = clip_w( vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, vcnt,
                              cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, zn, 1 );
                if ( cnt >= 3 )
                    cnt = clip_w( cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, cnt,
                                  vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, zf, 0 );
            }
            if ( cnt < 3 ) continue;

            /* Project once per vertex, not once per fan triangle. */
            zsum = 0.0f;
            for ( j = 0; j < cnt; j++ ) {
                rw = 1.0f / vt_w[j];
                px[j] = dp->xresh + vt_x[j]*rw*dp->xresh;
                py[j] = dp->yresh - vt_y[j]*rw*dp->yresh;
                pw[j] = rw;
                if ( dp->rend_mode == 0 ) { pu[j] = vt_u[j]*rw; pv[j] = vt_v[j]*rw; }
                else                      { pu[j] = vt_u[j];    pv[j] = vt_v[j];    }
                zsum += vt_w[j];
            }
            zl = zsum / cnt;

            /* Mip per surface, never per triangle. */
            if      ( zl >= 1400.0f ) mip_level = 3;
            else if ( zl >=  560.0f ) mip_level = 2;
            else if ( zl >=  280.0f ) mip_level = 1;
            else                      mip_level = 0;

            draw_mip = dp->use_mips ? mip_level : 0;

            src_dc = 0;
            texofs = 0;

            if ( lm_on ) {
                lm_mip   = dp->use_mips ? mip_level : 0;
                lm_floor = SC_SHIFT( lm_extw ) + SC_SHIFT( lm_exth ) <= SC_MAXSUM
                         ? 0 : sc_mipfloor( lm_extw, lm_exth );
                if ( lm_mip < lm_floor ) lm_mip = lm_floor;

                /* Sticky mip: zl moves when the camera merely rotates,
                   so a face near a threshold would flip mip -- and
                   rebuild -- every few frames. One mip of error is
                   invisible; the rebuild it saves is milliseconds.
                   The generation has to match too, or a stale tag
                   from before a flush pins the mip to a gone surface. */
                lm_cm = sc_held( sc, i );
                if ( lm_cm >= 0 ) {
                    short d = (short)( lm_mip - lm_cm );
                    if ( d < 0 ) d = (short) -d;
                    if ( d <= 1 ) lm_mip = lm_cm;
                    if ( lm_mip < lm_floor ) lm_mip = lm_floor;
                }

                lm_sw = (short)( lm_extw >> lm_mip );   if ( lm_sw < 1 ) lm_sw = 1;
                lm_sh = (short)( lm_exth >> lm_mip );   if ( lm_sh < 1 ) lm_sh = 1;
                lm_fw = (short)( lm_extw >> lm_floor ); if ( lm_fw < 1 ) lm_fw = 1;
                lm_fh = (short)( lm_exth >> lm_floor ); if ( lm_fh < 1 ) lm_fh = 1;

                lm_dc = (long) (void far *) sc_find( sc, i, lm_mip, lm_sw, lm_sh, lm_stag, &aim_ofs );
                if ( lm_dc == 0 ) {
#if QR_PROF
                    bt0 = dp->prof ? sys_rdtsc( sysclk ) : 0;
#endif
                    lm_dc = (long) (void far *) sc_alloc( sc, i, lm_mip, lm_sw, lm_sh, lm_fw, lm_fh,
                                                           lm_stag, world->face_count, &aim_ofs );
                    if ( lm_dc != 0 ) {
                        /* Build the DC's WHOLE padded extent, not just
                           sw by sh: the face's far edge lands exactly
                           on texel sw, one past the last one a sw-wide
                           fill writes, so a narrower build leaves a
                           black seam of recycled DC along two sides. */
                        tex_dc = (long) (void far *) mod_tex_raw( world, tex_id, lm_mip );
                        sb_build( sc, world, rdr, ls, (QSurf) lm_dc, (QSurf) tex_dc, i, lm_mip,
                                  (short)( 1 << SC_SHIFT( lm_sw ) ),
                                  (short)( 1 << SC_SHIFT( lm_sh ) ), gv, dl_bits );
                    }
#if QR_PROF
                    if ( dp->prof ) {
                        bface = sys_rdtsc( sysclk ) - bt0;
                        if ( bface >= 0 && bface <= 1000000L ) build_cyc += bface;
                    }
#endif
                }

                if ( lm_dc != 0 ) {
                    /* Texel units -> surface-local, normalised against
                       the DC's padded size. In perspective mode the
                       coordinates are already over w, so the origin
                       has to be scaled by w to match. */
                    lm_su = lm_recip[ lm_mip + SC_SHIFT( lm_sw ) ];
                    lm_sv = lm_recip[ lm_mip + SC_SHIFT( lm_sh ) ];
                    if ( dp->rend_mode == 0 ) {
                        for ( j = 0; j < cnt; j++ ) {
                            pu[j] = ( pu[j] - lm_tms*pw[j] ) * lm_su;
                            pv[j] = ( pv[j] - lm_tmt*pw[j] ) * lm_sv;
                        }
                    } else {
                        for ( j = 0; j < cnt; j++ ) {
                            pu[j] = ( pu[j] - lm_tms ) * lm_su;
                            pv[j] = ( pv[j] - lm_tmt ) * lm_sv;
                        }
                    }
                    src_dc = lm_dc;
                    texofs = aim_ofs;
                } else {
                    /* The class was exhausted or the DC would not
                       fit. Coordinates are still in texel units, so
                       put them back on the atlas scale. */
                    for ( j = 0; j < cnt; j++ ) { pu[j] *= tw; pv[j] *= th; }
                    lm_on = 0;
#if QR_PROF
                    dp->lm_fallback++;
#endif
                }
            }

            if ( lm_on == 0 ) {
                src_dc = (long) (void far *) mod_tex_shaded( world, tex_id, draw_mip );
                /* ofs is [id*4 + level]. Getting this pair backwards
                   aims the view at another cell entirely -- coherent
                   geometry wearing noise. */
                texofs = tex_ofs[ tex_id*4 + draw_mip ];
            }

            /* One convex polygon, one call -- no fan pivot, so no
               internal edges to seam along. cnt > MAXV cannot reach
               qglRsPoly -- its own ceiling -- so it is turned away
               here instead of relying on the library's silent
               refusal. */
            if ( cnt > MAXV ) continue;

#if QR_PROF
            rt0 = dp->prof ? sys_rdtsc( sysclk ) : 0;
#endif

            for ( j = 0; j < cnt; j++ ) {
                pvtx[j].x = px[j]; pvtx[j].y = py[j]; pvtx[j].z = pw[j];
                pvtx[j].u = pu[j]; pvtx[j].v = pv[j];
            }

            if ( dp->rend_mode == 2 ) {
                /* Wireframe: the polygon's own boundary, not a fan's
                   internal diagonals. */
                for ( j = 0; j < cnt; j++ ) {
                    p2 = (short)( ( j + 1 == cnt ) ? 0 : j + 1 );
                    qglDrLine( dp->h_dst_dc, (short) px[j], (short) py[j],
                                           (short) px[p2], (short) py[p2], 0 );
                }
            } else {
                /* pu/pv are u/z and pw is 1/z in perspective mode, which
                   is the convention the perspective filler wants; the
                   other mode hands it plain u and v. Nothing is
                   converted here -- only the mode differs. */
                qglRsPoly( dp->h_dst_dc, (QVert far *) pvtx, cnt,
                           dp->rend_mode == 0 ? QGL_M_PTEX : QGL_M_TEX,
                           src_dc );
            }
            dp->tris = (short)( dp->tris + cnt - 2 );

#if QR_PROF
            if ( dp->prof ) {
                bface = sys_rdtsc( sysclk ) - rt0;
                if ( bface >= 0 && bface <= 1000000L ) raster_cyc += bface;
            }
#endif
        }
    }

#if QR_PROF
    dp->build_us = build_cyc;
    dp->raster_us = raster_cyc;
#else
    dp->build_us = 0;
    dp->raster_us = 0;
#endif
}
