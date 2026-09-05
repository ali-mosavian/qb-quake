/*
 * d_faces.c -- d_draw_faces, the whole per-frame face loop, in C.
 *
 * ONE call per frame. That is the entire point of this file, and it is
 * the lesson an earlier attempt paid for: a first port moved only the
 * per-face MATH into C and called it once per face. Measured on e1m7,
 * six interleaved pairs, medians -- setup 38.773ms before, 38.672ms
 * after. A tenth of a millisecond out of 38.7. The arithmetic was never
 * the cost; the crossing was. 497 far calls a frame gave back whatever
 * the C won.
 *
 * So the loop itself lives here now: face iteration, backface cull, the
 * geometry copy, texture and lightmap selection, mip choice, the
 * surface-cache decision, and every uGL draw call. BASIC crosses the
 * boundary once per frame.
 *
 * uGL is called DIRECTLY from here. Its declares are all "seg" (see
 * ugl.bi -- `seg vtx As TriType`), which is exactly the raw far pointer
 * a C callee needs; that is the one interop direction r_walk.c's header
 * says is reliable. So uglPolyTP/uglTriTP/uglTriT/uglTriF/uglLine and
 * uglZMode need no BASIC round-trip.
 *
 * What still crosses per face, and why it is next rather than now: the
 * surface cache (sc_find/sc_held/sc_mipfloor/sc_shift/sc_alloc/
 * sc_view_ofs), ls_epoch, mod_geom_map and mod_tex_shaded all live in
 * BASIC and keep their own state. Moving them means moving d_surf.bas's
 * cache with them -- a second stage, with sb_build.c as precedent for
 * the subsystem already being half here.
 *
 * Two costs this removes outright, both found by measurement and
 * neither addressed by the earlier port:
 *   - the per-face rdtsc brackets. sys_rdtsc is sndDebugStat&(6) divided
 *     by cyc_per_us: a far call plus a 32-bit divide, 4 to 6 times per
 *     face, purely to measure. Only the BUILD bracket survives here,
 *     because a build is rare (a cache miss) and its cost is worth
 *     knowing; raster/aim/emit are gone and report 0.
 *   - `2 ^ n`. BASIC's ^ is B$POW4, i.e. exp(n*log 2) in software, and
 *     the surface-cache path asked for it seven times on every lit face.
 *     Here it is 1L << n.
 *
 * Interop follows r_walk.c: medium model, array parameters arrive as a
 * NEAR pointer to a BASARRAY whose farptr names the data; plain byref
 * UDTs (g, dp, mtx, campos) arrive as near pointers too.
 */

#include "qcshared.h"

/* q_map.bi's -- must not drift from it. */
#define GEOM_W       8192
#define GEOM_LMOFS   1
#define GEOM_VTX0    9
#define GEOM_MAXVTX  33
#define GEOM_MAXREC  (18 + GEOM_MAXVTX * 6)

/* bspfile.bi's vertex2 is Q13.3. A multiply, not a divide. */
#define VTX_UNSCALE  0.125

/* q_draw.bi's. The turbulence TABLE is d_init_turb's, reached through
   dp->turb_ptr rather than rebuilt here: computing it needs sine, which
   drags in Borland's MATHC.LIB and collides with the BASIC runtime
   (__8087 unresolved, __nfile defined twice). The table already exists;
   borrowing it keeps libm out of the link entirely. */
#define TURB_FREQ    326.0
#define TURB_RATE    40.74

/* ugl.bi's UGL.Z.* */
#define UGL_Z_OFF    0
#define UGL_Z_WRITE  1
#define UGL_Z_TEST   2

/* The clipper adds at most one vertex per plane, so input + 2 suffices;
   the slack is headroom, not a limit worth policing. */
#define MAXV (GEOM_MAXVTX + 8)

/* ugl.bi's vector3f: x y z u v r g b. uglPolyTP and TriType are built
   out of it, so the stride matters and the unused three still occupy
   space. */
typedef struct { float x, y, z, u, v, r, g, b; } UglVtx;
typedef struct { UglVtx v1, v2, v3; } UglTri;

extern void  pascal far uglPolyTP( long dst, UglVtx far *vtx, short cnt, short mask, long src );
extern void  pascal far uglTriTP ( long dst, UglTri far *vtx, short mask, long src );
extern void  pascal far uglTriT  ( long dst, UglTri far *vtx, short mask, long src );
extern void  pascal far uglTriF  ( long dc,  UglTri far *vtx, long col );
extern void  pascal far uglLine  ( long dc, short x1, short y1, short x2, short y2, long clr );
extern short pascal far uglZMode ( short mode );

/* BASIC-side, all byval scalars or g byref -- the shapes sb_build.c
   already proved callable from here. */
extern long  pascal far mod_geom_map   ( void *g, short row );
extern long  pascal far mod_tex_raw    ( void *g, short k, short mip );
extern long  pascal far mod_tex_shaded ( void *g, short k, short mip );
extern short pascal far host_z_on      ( void );
extern short pascal far sc_ready       ( void );
extern short pascal far sc_mipfloor    ( short extw, short exth );
extern short pascal far sc_held        ( short face );
extern short pascal far sc_shift       ( short v );
extern long  pascal far sc_find        ( short face, short mip, short w, short h, short stag );
extern long  pascal far sc_alloc       ( void *g, short face, short mip, short w, short h,
                                         short fw, short fh, short stag );
extern long  pascal far sc_view_ofs    ( void );
extern short pascal far ls_epoch       ( short style );
extern long  pascal far sys_rdtsc      ( void );

extern void pascal far sb_build( void *g, long lm_dc, long tex_dc, short face, short mip,
                                 short pw, short ph,
                                 BASARRAY *tri, BASARRAY *texinf, BASARRAY *gv,
                                 BASARRAY *mip_inf, BASARRAY *planes );

/* r_span.c's prototype path, behind -spandraw. */
extern void pascal far r_span_emit_ptr( short cnt, float far *vx, float far *vy,
                                        float far *vu, float far *vv, float far *vw,
                                        long src_dc, long tex_ofs );
extern void pascal far r_span_draw_to ( long dst );
extern short pascal far r_span_flush  ( short w, short h );

/* Per-face scratch. Static, not automatic: the medium model's stack is
   not where a dozen MAXV float arrays belong. */
static float near vt_x[MAXV], vt_y[MAXV], vt_z[MAXV], vt_w[MAXV];
static float near vt_u[MAXV], vt_v[MAXV];
static float near cl_x[MAXV], cl_y[MAXV], cl_z[MAXV], cl_w[MAXV];
static float near cl_u[MAXV], cl_v[MAXV];
static float near px[MAXV], py[MAXV], pw[MAXV], pu[MAXV], pv[MAXV];
static UglVtx near pvtx[16];
static UglTri near tri1;


/* BASIC's int() is FLOOR, not truncation -- they differ by one for a
   negative argument, and the turbulence index goes negative. */
static long near ifloor( float x )
{
    long t = (long)x;
    if ( x < 0.0 && (float)t != x ) t--;
    return t;
}


/*
 * Signed distance from a point to a plane, with the swap the renderer's
 * Y-up convention needs.
 *
 * pl is FAR and must stay far. Taking it as a near Plane* compiles
 * silently, drops the segment, and reads whatever sits at that offset in
 * DS -- which made the backface test reject nearly every face: 22 polygons
 * drawn where the control drew 153. Reimplemented rather than called back into
 * BASIC for the reason r_walk.c gives: its declare passes pt/pl as plain
 * byref UDTs, which a foreign pascal-convention C caller has no reliable
 * way to reproduce.
 */
static float near cam_plane_dist( Vec3f *pt, Plane far *pl )
{
    return pt->x * pl->norm.x + pt->y * pl->norm.z + pt->z * pl->norm.y - pl->dist;
}

/* Sutherland-Hodgman on w against one bound. keep_ge selects the side:
   near keeps w >= bound, far keeps w <= bound. z rides along without
   being interpolated, exactly as d_clip_z did. */
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

void pascal far d_draw_faces(
    void        *g,
    DrawParams  *dp,
    float       *m,          /* u3dMtrx, 16 floats */
    Vec3f       *campos,
    BASARRAY    *a_tri,
    BASARRAY    *a_texinf,
    BASARRAY    *a_gv,
    BASARRAY    *a_facemdl,
    BASARRAY    *a_brush,
    BASARRAY    *a_planes,
    BASARRAY    *a_nodes,
    BASARRAY    *a_mipinf,
    BASARRAY    *a_order,
    BASARRAY    *a_pflag )
{
    Face       far *tri     = (Face       far *)a_tri->farptr;
    TexInfo    far *texinf  = (TexInfo    far *)a_texinf->farptr;
    short      far *facemdl = (short      far *)a_facemdl->farptr;
    BrushModel far *brush   = (BrushModel far *)a_brush->farptr;
    Plane      far *planes  = (Plane      far *)a_planes->farptr;
    Node       far *nodes   = (Node       far *)a_nodes->farptr;
    MipTex     far *mipinf  = (MipTex     far *)a_mipinf->farptr;
    short      far *order   = (short      far *)a_order->farptr;
    short      far *pflag   = (short      far *)a_pflag->farptr;
    long       far *tex_ofs = (long       far *)dp->tex_ofs_ptr;

    short mi, m_node, ti, i, j, v0, gn, vcnt, cnt;
    short tex, tex_id, draw_mip, mip_level, liquid;
    short z_want, z_have = -1, z_avail, lm_use, lm_on;
    short lm_tms, lm_tmt, lm_extw, lm_exth, lm_stag;
    short lm_mip, lm_floor, lm_sw, lm_sh, lm_fw, lm_fh, lm_cm;
    short leaf_indx, leaf_end, p2, p3;
    long  gp, lm_dc, src_dc, tex_dc, texofs;
    long  bt0, bface, build_cyc = 0;
    float su0, su1, su2, su3, sv0, sv1, sv2, sv3;
    float tw, th, zofs, dp_dist, turbph, zl, zsum;
    float vx, vy, vz, tu, tv, rw, lm_su, lm_sv;
    float dl_pdist;
    Plane far *pl;
    short far *gv;
    float far *turb_sin = (float far *)dp->turb_ptr;

    dp->polys = 0;
    dp->tris  = 0;
    dp->lm_want = 0;
    dp->lm_fallback = 0;
    dp->k_mip = 0; dp->k_sw = 0; dp->k_sh = 0; dp->k_stag = 0; dp->k_n = 0; dp->k_hdr = 0; dp->k_ext = 0; dp->k_v0 = 0; dp->k_lm = 0;
    dp->build_us = 0;

    /* Asked once: whether a depth buffer exists cannot change inside a
       frame. */
    z_avail = host_z_on();
    turbph  = dp->anim_time * (float)TURB_RATE;

    /* The flag says the data was loaded; the toggle says whether to use
       it now. Clearing this makes every face below a plain textured one. */
    lm_use = ( dp->use_lm && dp->lightmap && sc_ready() != 0 );

    for ( mi = 0; mi < dp->ord_count; mi++ ) {
        m_node    = order[mi];
        leaf_indx = nodes[m_node].lface_id;
        leaf_end  = leaf_indx + nodes[m_node].lface_num - 1;

        for ( ti = leaf_indx; ti <= leaf_end; ti++ ) {
            i = ti;

            if ( pflag[i] != dp->frame_stamp ) continue;

            /*
             * Backface cull. Signed distance to the face's plane with
             * the face's side folded into the sign: side 0 points along
             * the normal, side 1 against it, and a face is only ever
             * visible from its own front.
             */
            pl = &planes[ tri[i].plane_id ];
            dp_dist = cam_plane_dist( campos, pl );
            if ( tri[i].side ) dp_dist = -dp_dist;
            if ( dp->backface != 0 && dp_dist <= 0.01 ) continue;

            /* Counted HERE, not at the draw: BASIC incremented g.rdr.polys
               after its `if poly_cnt > 2` block, so a face that cleared the
               two guards and then clipped away still counted. Counting at
               the draw instead read 111 where the original read 153, with
               tris identical at 365 -- the same geometry, a different
               tally. */
            dp->polys++;

            /*
             * This face's corners, out of the geometry store. Copied
             * inline rather than through a library call: that was one
             * more far call per face, and per-face calls are the thing
             * this file exists to delete. Copy up to
             * the end of the row and no further: a record sits inside one
             * row, so the row end is also the end of the mapped EMS
             * window and a fixed-size copy near it would read off the
             * page.
             *
             * The destination pointer is taken PER FACE. gv here is our
             * own static, so it cannot be relocated by the BASIC far
             * heap the way gv_buf could -- that bug (a hoisted gv_dst
             * going stale mid-frame, every face then sharing one cached
             * surface and drawing flat black) cannot recur in this form.
             * Still taken per face rather than hoisted, because it costs
             * nothing and the invariant is worth keeping local.
             */
            gv = (short far *)a_gv->farptr;
            gp = mod_geom_map( g, tri[i].geom_row );
            gn = GEOM_MAXREC;
            if ( tri[i].geom_ofs + gn > GEOM_W ) gn = GEOM_W - tri[i].geom_ofs;
            {
                /*
                 * Destination is BASIC's gv_buf, NOT a private buffer:
                 * sb_build reads the lightmap header (lmw/lmh/tms/tmt)
                 * straight out of this same array. Copying into a static
                 * of our own left gv_buf stale, sb_build sized a surface
                 * from garbage, and uglBuildSurf span forever on it --
                 * which is where the debugger found the hang
                 * (UGLBUILDSURF+0x118).
                 *
                 * farptr is re-read PER FACE rather than hoisted: gv_buf
                 * is a far-heap array and sc_alloc can relocate the heap
                 * mid-frame. The BASIC original took VARSEG/VARPTR per
                 * face for exactly this reason, and hoisting it is the
                 * bug that once made every face share one cached surface.
                 */
                char far *src = (char far *)( gp + (long)tri[i].geom_ofs );
                char far *dst = (char far *)gv;
                for ( j = 0; j < gn; j++ ) dst[j] = src[j];
            }

            vcnt   = gv[0];
            tex    = tri[i].tex_info_id;
            tex_id = texinf[tex].mip_tex;
            liquid = mipinf[tex_id].liquid;
            zofs   = brush[ facemdl[i] ].zofs;

            /*
             * NO early reject here. BASIC had no such guard: a face with a
             * degenerate vertex count flowed on to the clipper and was
             * dropped there, and on the way it still passed through the
             * lightmap gate. Skipping it early drew the same picture --
             * which is why a lightmaps-off comparison stayed byte-identical
             * and hid this entirely -- but reached sc_find for ~5 fewer
             * faces a frame, so the surface cache diverged. Clamp for the
             * buffer's sake, do not skip.
             */
            if ( vcnt > GEOM_MAXVTX ) vcnt = GEOM_MAXVTX;
            if ( vcnt < 0 ) vcnt = 0;

            /*
             * Depth mode follows what the face belongs to. The world only
             * writes -- it arrives front to back, so a test could never
             * reject what the order already settled, and rejecting costs
             * a compare per pixel for nothing. Brush entities test,
             * because a door swinging through a doorway has no such
             * guarantee. Switched only on change: faces arrive in long
             * runs from one model.
             */
            if ( z_avail != 0 ) {
                z_want = ( facemdl[i] == 0 ) ? UGL_Z_WRITE : UGL_Z_TEST;
                if ( z_want != z_have ) z_have = uglZMode( z_want );
            }

            tw = mipinf[tex_id].wdth;
            th = mipinf[tex_id].hght;

            /*
             * Surface-cache candidate? It needs a lightmap (ofs_hi -1
             * marks one without), and must be neither liquid -- those
             * perturb per vertex -- nor animated, which would rebuild
             * every time the frame index moved.
             */
            lm_on = 0;
            lm_stag = 0;
            lm_extw = lm_exth = 0;
            lm_tms = lm_tmt = 0;
            dp->k_v0 += vcnt;
            dp->k_lm += gv[GEOM_LMOFS];

            if ( lm_use && liquid == 0 && mipinf[tex_id].anim_count <= 1 ) {
                if ( gv[GEOM_LMOFS] >= 0 ) {
                    dp->k_hdr++;
                    lm_tms  = gv[GEOM_LMOFS + 2];
                    lm_tmt  = gv[GEOM_LMOFS + 3];
                    lm_extw = ( gv[GEOM_LMOFS + 4] - 1 ) * 16;
                    lm_exth = ( gv[GEOM_LMOFS + 5] - 1 ) * 16;
                    if ( lm_extw > 0 && lm_exth > 0 ) { lm_on = 1; dp->lm_want++; dp->k_ext++; }

                    lm_stag = ls_epoch( gv[GEOM_LMOFS + 6] & 255 );

                    /*
                     * A face the dynamic light reaches must rebuild every
                     * frame it stays in range, and once more the frame
                     * after it leaves to wash the glow out. Forcing -1
                     * here -- a value ls_epoch never returns -- makes the
                     * miss happen before sc_find ever runs, so a plain
                     * epoch match cannot paper over it.
                     */
                    dl_pdist = dp->dl_x * pl->norm.x
                             + dp->dl_y * pl->norm.y
                             + dp->dl_z * pl->norm.z - pl->dist;
                    if ( dl_pdist < 0 ) dl_pdist = -dl_pdist;
                    if ( dl_pdist < dp->dl_radius ) lm_stag = -1;
                }
            }

            /*
             * A cached face keeps ORIGINAL TEXEL units -- the surface is
             * a piece of the texture, so the shift to surface-local space
             * needs the unscaled value and cannot be applied until the
             * mip is known. Everything else normalises against the atlas
             * here.
             */
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

            /* Animation swaps which image is sampled; index arithmetic
               only, once per face. */
            if ( mipinf[tex_id].anim_count > 1 )
                tex_id = mipinf[tex_id].anim_base
                       + ( ifloor( dp->anim_time * 5.0f ) % mipinf[tex_id].anim_count );

            for ( j = 0; j < vcnt; j++ ) {
                v0 = j*3 + GEOM_VTX0;
                vx = gv[v0    ] * (float)VTX_UNSCALE;
                vy = gv[v0 + 1] * (float)VTX_UNSCALE;
                vz = gv[v0 + 2] * (float)VTX_UNSCALE;

                /* BSP is Z-up, renderer is Y-up: y and z swap, and the
                   brush entity's offset rides on renderer y. */
                vt_x[j] = vx;
                vt_y[j] = vz + zofs;
                vt_z[j] = vy;

                tu = su0*vx + su1*vy + su2*vz + su3;
                tv = sv0*vx + sv1*vy + sv2*vz + sv3;

                if ( liquid ) {
                    vt_u[j] = tu + turb_sin[ (short)( ifloor( tv*(float)TURB_FREQ + turbph ) & 255 ) ];
                    vt_v[j] = tv + turb_sin[ (short)( ifloor( tu*(float)TURB_FREQ + turbph ) & 255 ) ];
                } else {
                    vt_u[j] = tu;
                    vt_v[j] = tv;
                }
            }

            /* Transform. Row-vector times a 4x4 with w = 1, matching
               u3dMtrxByVec4's macro (NOT its header comment, which states
               the transpose -- the macro is the authority). */
            for ( j = 0; j < vcnt; j++ ) {
                vx = vt_x[j]; vy = vt_y[j]; vz = vt_z[j];
                vt_x[j] = vx*m[0] + vy*m[4] + vz*m[ 8] + m[12];
                vt_y[j] = vx*m[1] + vy*m[5] + vz*m[ 9] + m[13];
                vt_z[j] = vx*m[2] + vy*m[6] + vz*m[10] + m[14];
                vt_w[j] = vx*m[3] + vy*m[7] + vz*m[11] + m[15];
            }

            cnt = clip_w( vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, vcnt,
                          cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, dp->z_near, 1 );
            if ( cnt < 3 ) continue;
            cnt = clip_w( cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, cnt,
                          vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, dp->z_far, 0 );
            if ( cnt < 3 ) continue;

            /*
             * Project once per vertex, not once per fan triangle. Vertex
             * 0 is in every triangle and interior vertices in two, so a
             * 7-gon paid 15 reciprocals where 7 do.
             */
            zsum = 0.0;
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

            /*
             * Mip per surface, never per triangle: every fan triangle
             * includes the pivot, so two halves of a quad could straddle
             * a threshold and land on different mips, and the seam shows
             * as the texture stepping along the fan diagonal.
             */
            if      ( zl >= 1400.0 ) mip_level = 3;
            else if ( zl >=  560.0 ) mip_level = 2;
            else if ( zl >=  280.0 ) mip_level = 1;
            else                     mip_level = 0;

            draw_mip = dp->use_mips ? mip_level : 0;

            src_dc = 0;
            texofs = 0;

            if ( lm_on ) {
                lm_mip   = dp->use_mips ? mip_level : 0;
                lm_floor = sc_mipfloor( lm_extw, lm_exth );
                if ( lm_mip < lm_floor ) lm_mip = lm_floor;

                /*
                 * Sticky mip. zl is the average w over the CLIPPED
                 * vertices, so it moves when the camera merely rotates; a
                 * face near a threshold would flip mip every few frames
                 * and every flip is a full rebuild, since sc_find keys on
                 * the mip. One mip of error is not visible; the rebuild
                 * it saves is milliseconds. The generation has to match
                 * too, or a stale tag from before a flush pins the mip to
                 * a surface that is no longer there.
                 */
                lm_cm = sc_held( i );
                if ( lm_cm >= 0 ) {
                    short d = lm_mip - lm_cm;
                    if ( d < 0 ) d = -d;
                    if ( d <= 1 ) lm_mip = lm_cm;
                    if ( lm_mip < lm_floor ) lm_mip = lm_floor;
                }

                /* 1L << n, where BASIC wrote 2 ^ n and paid B$POW4. */
                lm_sw = lm_extw >> lm_mip;   if ( lm_sw < 1 ) lm_sw = 1;
                lm_sh = lm_exth >> lm_mip;   if ( lm_sh < 1 ) lm_sh = 1;
                lm_fw = lm_extw >> lm_floor; if ( lm_fw < 1 ) lm_fw = 1;
                lm_fh = lm_exth >> lm_floor; if ( lm_fh < 1 ) lm_fh = 1;

                dp->k_mip  += lm_mip;
                dp->k_sw   += lm_sw;
                dp->k_sh   += lm_sh;
                dp->k_stag += lm_stag;
                dp->k_n++;

                lm_dc = sc_find( i, lm_mip, lm_sw, lm_sh, lm_stag );
                if ( lm_dc == 0 ) {
                    bt0 = dp->prof ? sys_rdtsc() : 0;
                    lm_dc = sc_alloc( g, i, lm_mip, lm_sw, lm_sh, lm_fw, lm_fh, lm_stag );
                    if ( lm_dc != 0 ) {
                        /*
                         * Build the DC's WHOLE padded extent, not just sw
                         * by sh: the face's far edge lands exactly on
                         * texel sw, one past the last one a sw-wide fill
                         * writes, so every face used to draw a black seam
                         * of recycled DC along two of its sides.
                         */
                        tex_dc = mod_tex_raw( g, tex_id, lm_mip );
                        sb_build( g, lm_dc, tex_dc, i, lm_mip,
                                  (short)(1 << sc_shift( lm_sw )),
                                  (short)(1 << sc_shift( lm_sh )),
                                  a_tri, a_texinf, a_gv, a_mipinf, a_planes );
                    }
                    if ( dp->prof ) {
                        bface = sys_rdtsc() - bt0;
                        if ( bface >= 0 && bface <= 1000000L ) build_cyc += bface;
                    }
                }

                if ( lm_dc != 0 ) {
                    /*
                     * Texel units -> surface-local, normalised against the
                     * DC's padded size. In perspective mode the
                     * coordinates are already over w, so the origin has to
                     * be scaled by w to match.
                     */
                    lm_su = 1.0f / (float)( (1L << lm_mip) * (1L << sc_shift( lm_sw )) );
                    lm_sv = 1.0f / (float)( (1L << lm_mip) * (1L << sc_shift( lm_sh )) );
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
                    texofs = sc_view_ofs();
                } else {
                    /* The class was exhausted or the DC would not fit.
                       Coordinates are still in texel units, so put them
                       back on the atlas scale. */
                    for ( j = 0; j < cnt; j++ ) { pu[j] *= tw; pv[j] *= th; }
                    lm_on = 0;
                    dp->lm_fallback++;
                }
            }

            if ( lm_on == 0 ) {
                src_dc = mod_tex_shaded( g, tex_id, draw_mip );
                /* ofs is [id*4 + level]. Getting this pair backwards aims
                   the view at another cell entirely -- coherent geometry
                   wearing noise. */
                texofs = tex_ofs[ tex_id*4 + draw_mip ];
            }

            if ( dp->span_draw ) {
                r_span_emit_ptr( cnt, px, py, pu, pv, pw, src_dc, texofs );
                continue;
            }

            /*
             * One convex polygon, one call -- no fan pivot, so no
             * internal edges for the rasteriser to seam along. Wireframe
             * still fans; it wants the triangles.
             */
            if ( dp->poly_tp && cnt <= 12 && dp->rend_mode != 2 ) {
                for ( j = 0; j < cnt; j++ ) {
                    pvtx[j].x = px[j]; pvtx[j].y = py[j]; pvtx[j].z = pw[j];
                    pvtx[j].u = pu[j]; pvtx[j].v = pv[j];
                }
                uglPolyTP( dp->h_dst_dc, (UglVtx far *)pvtx, cnt, 0, src_dc );
                dp->tris += cnt - 2;
                continue;
            }

            for ( j = 0; j <= cnt - 3; j++ ) {
                p2 = j + 1;
                p3 = j + 2;

                tri1.v1.z = pw[0];  tri1.v2.z = pw[p2]; tri1.v3.z = pw[p3];
                tri1.v1.x = px[0];  tri1.v1.y = py[0];
                tri1.v2.x = px[p2]; tri1.v2.y = py[p2];
                tri1.v3.x = px[p3]; tri1.v3.y = py[p3];

                if ( dp->rend_mode == 2 ) {
                    uglTriF( dp->h_dst_dc, (UglTri far *)&tri1, 200 );
                    uglLine( dp->h_dst_dc, (short)tri1.v1.x, (short)tri1.v1.y,
                                           (short)tri1.v2.x, (short)tri1.v2.y, 0 );
                    uglLine( dp->h_dst_dc, (short)tri1.v2.x, (short)tri1.v2.y,
                                           (short)tri1.v3.x, (short)tri1.v3.y, 0 );
                    uglLine( dp->h_dst_dc, (short)tri1.v3.x, (short)tri1.v3.y,
                                           (short)tri1.v1.x, (short)tri1.v1.y, 0 );
                } else {
                    tri1.v1.u = pu[0];  tri1.v1.v = pv[0];
                    tri1.v2.u = pu[p2]; tri1.v2.v = pv[p2];
                    tri1.v3.u = pu[p3]; tri1.v3.v = pv[p3];

                    if ( dp->rend_mode == 0 )
                        uglTriTP( dp->h_dst_dc, (UglTri far *)&tri1, 0, src_dc );
                    else
                        uglTriT ( dp->h_dst_dc, (UglTri far *)&tri1, 0, src_dc );
                }
                dp->tris++;
            }

        }
    }

    if ( dp->span_draw ) {
        r_span_draw_to( dp->h_dst_dc );
        r_span_flush( dp->x_res, dp->y_res );
    }

    dp->build_us = build_cyc;
}
