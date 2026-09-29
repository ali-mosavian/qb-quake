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
 * sc_view_ofs), ls_value, mod_geom_map and mod_tex_shaded all live in
 * BASIC and keep their own state. Moving them means moving d_surf.bas's
 * cache with them -- a second stage, with sb_build.c as precedent for
 * the subsystem already being half here.
 *
 * Two costs this removes outright, both found by measurement and
 * neither addressed by the earlier port:
 *   - the per-face rdtsc brackets. sys_rdtsc is qglTmrCycles divided
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

/* qgl.inc's QGL_Z_*, which are mgl's UGL.Z.* renumbered by nothing --
   OFF/SET/TEST against OFF/WRITE/TEST, same three values. */
#define QGL_Z_OFF    0
#define QGL_Z_SET    1
#define QGL_Z_TEST   2

/* The clipper adds at most one vertex per plane, so input + 2 suffices;
   the slack is headroom, not a limit worth policing. */
#define MAXV (GEOM_MAXVTX + 8)

/* The wireframe fan's own triangle, in floats. No mgl call reads it any
   more, so the three unused colour fields mgl's vector3f carried are
   gone with them. */

/* qgl. A Surface is never spelled here -- the destination arrives as an
   mgl DC, which is the same struct; the vertex is spelled here because
   qglRsPoly takes an array of them and C cannot be handed one otherwise.

   THE MODE CONSTANTS ARE A SECOND COPY of src/qgl/qgl.inc's, and the
   only one with no generator watching it -- qgl.bi is generated for
   BASIC and there is no C equivalent yet. That is exactly the drift
   that made QGL_SURF_EMS mean 10 on one side and 2 on the other, so it
   is written down here rather than left as a bare 2 and 3. */
#define QGL_M_WIRE  0
#define QGL_M_FLAT  1
#define QGL_M_TEX   2
#define QGL_M_PTEX  3
#define QGL_M_ATEX  4

typedef struct { float x, y, z, u, v; } QglVtx;

extern void  pascal far qglClRect    ( short x0, short y0, short x1, short y1 );
/* Every draw parameter, every call: no texture, mode or depth is
   installed beforehand. src is the texture Surface when mode is
   QGL_M_TEX/PTEX and the colour when it is QGL_M_FLAT -- mgl's own
   overload of uglPolyTP's srcDC against uglPolyF's col. Returns the
   scanlines covered, 0 for a face clipped away, -1 for a refusal. */
extern short pascal far qglRsPoly    ( long dst, void far *v, short cnt,
                                       short mode, long src );
extern short pascal far qglRsPolyBound( long dst, void far *v, short cnt,
                                        short mode, long src, short uw, short vh );
/* Depth is not an argument: it belongs to the destination. Refuses -- and
   leaves the surface with depth OFF -- when the surface has no depth
   buffer, which is what -noz produces, so this may be called blind. */
extern short pascal far qglSfZMode   ( long surf, short mode );
/* The perspective scan skips what the rows already cover. Clear once at
   the top of a front-to-back pass; qglRsCover says whether the polygons
   that follow take part, and never forgets what is already claimed.
   Coverage never decides what is visible, only what is worth iterating
   -- depth decides, which is why neither may run without it. */
extern void  pascal far qglRsCoverClear ( void );
extern void  pascal far qglRsCover   ( short on );
extern void  pascal far qglDrLine    ( long d, short x0, short y0,
                                       short x1, short y1, short col );

/* BASIC-side, all byval scalars or g byref -- the shapes sb_build.c
   already proved callable from here. */
extern long  pascal far mod_geom_map   ( void *g, short row );
extern long  pascal far mod_tex_raw    ( void *g, short k, short mip );
extern long  pascal far mod_tex_shaded ( void *g, short k, short mip );
extern short pascal far sc_ready       ( void );
extern short pascal far sc_held        ( short face );
extern long  pascal far sc_find        ( short face, short mip, short a, short b, long stag );
extern long  pascal far sc_alloc       ( void *g, short face, short mip, short w, short h,
                                         short fw, short fh, long stag );
extern long  pascal far sc_view_ofs    ( void );
extern short pascal far ls_value       ( short style );
#define LS_UNSET 116
extern long  pascal far sys_rdtsc      ( void );
extern long  pascal far qglTmrCycles   ( void );

/* A section's cycles since the last lap, when the frame is timed: one far
   call and no divide, so five a face cost about 1% of the draw. */
#define CY_LAP( acc ) do { if ( dp->prof ) { unsigned long t_ = qglTmrCycles(); \
                               dp->acc += (long) ( t_ - cy_t ); cy_t = t_; } } while ( 0 )

extern void pascal far sb_build( void *g, long lm_dc, long tex_dc, short face, short mip,
                                 short pw, short ph,
                                 BASARRAY *tri, BASARRAY *texinf, BASARRAY *gv,
                                 BASARRAY *mip_inf, BASARRAY *planes );

/*
 * DrawParams is declared twice -- q_draw.bi for BASIC, qcshared.h for
 * this file -- and nothing made the two agree. Removing three dead
 * fields from the BASIC side shifted every field after them here: the
 * frame came back with polys 0 and no picture, because ord_count and
 * x_res were being read out of the wrong words.
 *
 * Checked at startup the way r_walk.c's GAME_VIS_OFFSET is. Size alone
 * would miss a reorder of two shorts, so the last field's offset goes
 * with it; the two together catch an added, removed or moved field.
 */
short pascal far d_faces_layout_ok( long sz, long drop_off )
{
    return (short) ( sz == (long) sizeof( DrawParams ) &&
                     drop_off == (long) &( (DrawParams near *) 0 )->qgl_drop );
}

/* Per-face scratch. Static, not automatic: the medium model's stack is
   not where a dozen MAXV float arrays belong. */
static float near vt_x[MAXV], vt_y[MAXV], vt_z[MAXV], vt_w[MAXV];
static float near vt_u[MAXV], vt_v[MAXV];
static float near cl_x[MAXV], cl_y[MAXV], cl_z[MAXV], cl_w[MAXV];
static float near cl_u[MAXV], cl_v[MAXV];
static float near px[MAXV], py[MAXV], pw[MAXV], pu[MAXV], pv[MAXV];
/* MAXV, not 16: the old bound matched the qgl fast path's retired
   cnt <= 12 gate with a little slack, but a lit face's qgl draw is now
   mandatory (see the polygon-draw dispatch below) and must never
   truncate a real, larger convex face. */
static QglVtx near qvtx[MAXV];

/* TEMPORARY, -qglface. One real post-clip face, frozen so the same
   record can be replayed into isolated buffers by both rasterisers and
   an exact oracle. Removed once the divergence is localised. */
static short fp_cnt = 0;
static float near fp_area = 0.0f;
static QglVtx near fp_v[MAXV];
static long  fp_tex = 0;
/* The view's aim, not just the view. fp_tex points at a view that every
   later face re-aims, so replaying the freeze reads whichever cell ran
   last. Captured here and restored before the replay. */
static long  fp_ofs = 0;

short pascal far qglFaceCnt( void ) { return fp_cnt; }
long  pascal far qglFaceTex( void ) { return fp_tex; }
long  pascal far qglFaceOfs( void ) { return fp_ofs; }

void pascal far qglFaceFetch( QglVtx far *dst )
{
    short i;
    for ( i = 0; i < fp_cnt; i++ ) dst[i] = fp_v[i];
}


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
/* d_surf.bas's sc_shift and sc_mipfloor, which stay there for its own
   callers: pure integer functions, so asked here without a BASIC call --
   sc_mipfloor paid two B$POW4 and two nested calls a step, every lit
   face. The class bounds are d_surf.bas's SC_MINSH/SC_MAXSH/SC_MAXSUM. */
#define SC_MINSH  4
#define SC_MAXSH  8
#define SC_MAXSUM 14

static short near sc_shift_c( short v )
{
    short s = SC_MINSH, p = 16;

    while ( p < v && s < SC_MAXSH ) { p <<= 1; s++; }
    return s;
}

static short near sc_mipfloor_c( short extw, short exth )
{
    short m, w, h;

    for ( m = 0; m <= 3; m++ ) {
        w = extw >> m; if ( w < 1 ) w = 1;
        h = exth >> m; if ( h < 1 ) h = 1;
        if ( sc_shift_c( w ) + sc_shift_c( h ) <= SC_MAXSUM ) return m;
    }
    return 3;
}

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
    float       *m,          /* Mat4, 16 floats */
    Vec3f       *campos,
    BASARRAY    *a_tri,
    BASARRAY    *a_texinf,
    BASARRAY    *a_gv,
    BASARRAY    *a_brush,
    BASARRAY    *a_planes,
    BASARRAY    *a_nodes,
    BASARRAY    *a_mipinf,
    BASARRAY    *a_order,
    BASARRAY    *a_pflag )
{
    Face       far *tri     = (Face       far *)a_tri->farptr;
    TexInfo    far *texinf  = (TexInfo    far *)a_texinf->farptr;
    BrushModel far *brush   = (BrushModel far *)a_brush->farptr;
    Plane      far *planes  = (Plane      far *)a_planes->farptr;
    Node       far *nodes   = (Node       far *)a_nodes->farptr;
    MipTex     far *mipinf  = (MipTex     far *)a_mipinf->farptr;
    short      far *order   = (short      far *)a_order->farptr;
    short      far *pflag   = (short      far *)a_pflag->farptr;
    /*
     * These nine are BASIC far-heap arrays and the heap compacts under
     * any BASIC call in this loop -- sc_alloc, sb_build, mod_tex_raw --
     * so a pointer taken at entry names freed memory a few faces later.
     * Measured: seven of the nine had moved by frame 7 of a spawn run,
     * and the loop went on reading stamps, order and texinfo from the
     * old addresses. gv below already re-takes its pointer per face for
     * the same reason; this does it for the rest, per face and after
     * each call that can enter BASIC. Nine far loads a face.
     */
#define D_ARRAYS_REFRESH() do { \
        tri     = (Face       far *)a_tri->farptr;     \
        texinf  = (TexInfo    far *)a_texinf->farptr;  \
        brush   = (BrushModel far *)a_brush->farptr;   \
        planes  = (Plane      far *)a_planes->farptr;  \
        nodes   = (Node       far *)a_nodes->farptr;   \
        mipinf  = (MipTex     far *)a_mipinf->farptr;  \
        order   = (short      far *)a_order->farptr;   \
        pflag   = (short      far *)a_pflag->farptr;   \
    } while ( 0 )
    long       far *tex_ofs = (long       far *)dp->tex_ofs_ptr;

    short mi, m_node, ti, i, j, v0, gn, vcnt, cnt;
    short z_have, ord_lo, ord_hi, ord_st, cov_now, is_ent;
    short tex, tex_id, draw_mip, mip_level, liquid;
    short z_mode, lm_use, lm_on;
    long  q_dst;                /* the destination Surface */
    short q_ok = 0;             /* and whether the setup stood up */
    short q_gate = 0;
    short lm_tms, lm_tmt, lm_extw, lm_exth;
    long lm_stag;
    unsigned short s01, s23; short sty[4], k, lv; long ls_key, place;
    short lm_mip, lm_floor, lm_sw, lm_sh, lm_fw, lm_fh, lm_cm, lm_sa, lm_sb;
    short leaf_indx, leaf_end;
    long  gp, lm_dc, src_dc, tex_dc, texofs;
    long  bt0, bface, build_cyc = 0;
    unsigned long cy_t = 0;
    float su0, su1, su2, su3, sv0, sv1, sv2, sv3;
    float tw, th, ox, oy, oz, dp_dist, turbph, zl, zsum;
    float vx, vy, vz, tu, tv, rw, lm_su, lm_sv;
    float dl_pdist;
    Plane far *pl;
    short far *gv;
    float far *turb_sin = (float far *)dp->turb_ptr;

    dp->polys = 0;
    dp->tris  = 0;
    dp->lm_want = 0;
    dp->lm_fallback = 0;
    dp->qgl_faces = 0;
    dp->qgl_drop  = 0;
    /* Per frame. Held across frames, the first frame's biggest face won
       for the whole run: two yaws 34 degrees apart, and frame 1 against
       frame 40, all froze the same face. */
    fp_area = 0.0f;
    dp->cy_geom = 0; dp->cy_xf = 0; dp->cy_lm = 0; dp->cy_tex = 0; dp->cy_rast = 0;
    dp->build_us = 0;

    /* Asked once: which depth buffer, if any, cannot change inside a
       frame. It is handed to every draw -- qgl installs nothing. */
    z_mode  = QGL_Z_OFF;
    turbph  = dp->anim_time * (float)TURB_RATE;

    /* The flag says the data was loaded; the toggle says whether to use
       it now. Clearing this makes every face below a plain textured one. */
    lm_use = ( dp->use_lm && dp->lightmap && sc_ready() != 0 );

    /*
     * The destination DC IS the destination Surface -- one struct, one
     * allocator -- so there is nothing to adopt and nothing to check.
     */
    q_dst = dp->h_dst_dc;
    if ( !q_dst ) dp->qgl_faces = -1;
    else {
        qglClRect( 0, 0, dp->x_res - 1, dp->y_res - 1 );
        q_ok = 1;
    }

    /*
     * FRONT TO BACK, which is the order list read backwards: depth
     * rejects the hidden pixels and coverage stops their spans reaching
     * the filler at all, where painter's order drew every one of them
     * and let the next face paint over it.
     *
     * BOTH OF THOSE ARE DEPTH. Without a buffer -- -noz -- reversing the
     * walk is not an optimisation but the picture inside out, far faces
     * painted over near ones, so the walk goes back to front and the
     * modes go back to what they were. Asked once, here: the answer
     * cannot change inside a frame.
     */
    z_have = q_ok ? qglSfZMode( q_dst, QGL_Z_TEST ) : 0;
    if ( z_have ) { ord_lo = dp->ord_count - 1; ord_hi = -1;            ord_st = -1; }
    else          { ord_lo = 0;                 ord_hi = dp->ord_count; ord_st =  1; }
    cov_now = z_have;
    if ( z_have ) qglRsCoverClear();

    for ( mi = ord_lo; mi != ord_hi; mi += ord_st ) {
        D_ARRAYS_REFRESH();
        m_node    = order[mi];
        leaf_indx = nodes[m_node].lface_id;
        leaf_end  = leaf_indx + nodes[m_node].lface_num - 1;

        for ( ti = leaf_indx; ti <= leaf_end; ti++ ) {
            i = ti;
            D_ARRAYS_REFRESH();

            if ( ( pflag[i >> 4] & ( 1 << ( i & 15 ) ) ) == 0 ) continue;

            /*
             * Backface cull. Signed distance to the face's plane with
             * the face's side folded into the sign: side 0 points along
             * the normal, side 1 against it, and a face is only ever
             * visible from its own front.
             */
            pl = &planes[ tri[i].plane_id ];
            dp_dist = cam_plane_dist( campos, pl );
            if ( tri[i].side >> 1 ) {
                /* A moved brush's plane moved with it; ofs and norm are both BSP space. */
                BrushModel far *bm = &brush[ tri[i].side >> 1 ];
                dp_dist -= bm->ofs.x * pl->norm.x + bm->ofs.y * pl->norm.y + bm->ofs.z * pl->norm.z;
            }
            if ( tri[i].side & 1 ) dp_dist = -dp_dist;
            if ( dp->backface != 0 && dp_dist <= 0.01 ) continue;

            /* Counted HERE, not at the draw: BASIC incremented g.rdr.polys
               after its `if poly_cnt > 2` block, so a face that cleared the
               two guards and then clipped away still counted. Counting at
               the draw instead read 111 where the original read 153, with
               tris identical at 365 -- the same geometry, a different
               tally. */
            dp->polys++;
            if ( dp->prof ) cy_t = qglTmrCycles();

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
                /* The record's own length, header and corners, and a word
                   at a time: a GEOM_MAXREC byte loop moved 216 bytes a
                   face where a quad needs 42. */
                short far *src = (short far *)( gp + (long)tri[i].geom_ofs );
                gn = src[0];
                if ( gn > GEOM_MAXVTX ) gn = GEOM_MAXVTX;
                if ( gn < 0 ) gn = 0;
                gn = GEOM_VTX0 + gn * 3;
                if ( tri[i].geom_ofs + gn * 2 > GEOM_W ) gn = ( GEOM_W - tri[i].geom_ofs ) >> 1;
                for ( j = 0; j < gn; j++ ) gv[j] = src[j];
            }
            CY_LAP( cy_geom );

            vcnt   = gv[0];
            tex    = tri[i].tex_info_id;
            tex_id = texinf[tex].mip_tex;
            liquid = mipinf[tex_id].liquid;
            ox     = brush[ tri[i].side >> 1 ].ofs.x;  /* the owning submodel */
            oy     = brush[ tri[i].side >> 1 ].ofs.y;
            oz     = brush[ tri[i].side >> 1 ].ofs.z;

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
             * Depth mode follows what the face belongs to, and what the
             * walk above decided. Back to front -- which is what -noz
             * leaves -- the world only WRITES, since a test could never
             * reject what the order already settled and rejecting costs
             * a compare per pixel for nothing, while brush entities test
             * because a door swinging through a doorway has no such
             * guarantee. Front to back everything tests.
             *
             * Set per face rather than switched on change. There was a
             * cache here once; it took qglZMode's return, which answered
             * with the mode that WAS in force, so after a run of entity
             * faces it said SET while TEST was live and the next world
             * face was tested against a buffer it was meant to write.
             * qglSfZMode answers only whether it took, so the same
             * mistake has nothing to be built out of.
             *
             * OFF is not a case here: with no depth buffer attached
             * qglSfZMode refuses and leaves the surface OFF, which is
             * exactly what -noz should draw.
             */
            /*
             * TEST for a world face too, once the walk is front to back:
             * the near one is already down and the far one must be
             * asked. Back to front -- -noz -- it is the rule above.
             *
             * AND A BRUSH ENTITY TAKES NO PART IN COVERAGE. Its place in
             * the order is ent_find_node's approximation, not the tree's
             * own answer, so it can be drawn before a world face that is
             * actually in front of it. Depth still settles that; a claim
             * would not, and would take the world face's span away
             * before depth ever saw it.
             */
            is_ent = ( tri[i].side >> 1 ) != 0;
            z_mode = z_have ? QGL_Z_TEST : ( is_ent ? QGL_Z_TEST : QGL_Z_SET );
            if ( z_have && cov_now == is_ent ) {
                cov_now = !is_ent;
                qglRsCover( cov_now );
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
            D_ARRAYS_REFRESH();

            if ( lm_use && liquid == 0 && mipinf[tex_id].anim_count <= 1 ) {
                if ( gv[GEOM_LMOFS] >= 0 ) {
                    lm_tms  = gv[GEOM_LMOFS + 2];
                    lm_tmt  = gv[GEOM_LMOFS + 3];
                    lm_extw = ( gv[GEOM_LMOFS + 4] - 1 ) * 16;
                    lm_exth = ( gv[GEOM_LMOFS + 5] - 1 ) * 16;
                    if ( lm_extw > 0 && lm_exth > 0 ) { lm_on = 1; dp->lm_want++; }

                    /* the styles' VALUES, a base-27 digit each, so a
                       flicker coming back to a value finds its surface:
                       sc keeps a variant per key */
                    s01 = gv[GEOM_LMOFS + 6]; s23 = gv[GEOM_LMOFS + 7];
                    sty[0] = s01 & 255; sty[1] = s01 >> 8;
                    sty[2] = s23 & 255; sty[3] = s23 >> 8;
                    ls_key = 0; place = 1;
                    for ( k = 0; k < 4 && sty[k] != 255; k++ ) {
                        lv = ls_value( sty[k] );
                        ls_key += place * ( lv == LS_UNSET ? 26 : lv / 10 );
                        place *= 27;
                    }
                    lm_stag = ls_key;

                    /*
                     * A face the light reaches is keyed below any style key,
                     * on the light's moves plus the styles': a constant key
                     * froze the glow at its first build. The move after it
                     * leaves misses once more and washes it out. Reached means the plane in range AND the foot
                     * near the luxel rect; the plane alone marks every
                     * coplanar face on the map.
                     */
                    D_ARRAYS_REFRESH();
                    pl = &planes[ tri[i].plane_id ];
                    dl_pdist = dp->dl_x * pl->norm.x
                             + dp->dl_y * pl->norm.y
                             + dp->dl_z * pl->norm.z - pl->dist;
                    if ( dl_pdist < dp->dl_radius && dl_pdist > -dp->dl_radius ) {
                        float fx = dp->dl_x - pl->norm.x * dl_pdist;
                        float fy = dp->dl_y - pl->norm.y * dl_pdist;
                        float fz = dp->dl_z - pl->norm.z * dl_pdist;
                        float r = dp->dl_radius + 1.0f;
                        float ls = fx * texinf[tex].vecs[0] + fy * texinf[tex].vecs[1]
                                 + fz * texinf[tex].vecs[2] + texinf[tex].vecs[3] - lm_tms;
                        float lt = fx * texinf[tex].vect[0] + fy * texinf[tex].vect[1]
                                 + fz * texinf[tex].vect[2] + texinf[tex].vect[3] - lm_tmt;
                        if ( ls >= -r && ls <= lm_extw + r && lt >= -r && lt <= lm_exth + r )
                            lm_stag = -1L - ( ( dp->dl_tick * 531441L + ls_key ) & 0x3FFFFFFFL );
                    }
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
            /* R_TextureAnimation: ten frames a second, walked round the ring
               from this frame's own place in it */
            if ( mipinf[tex_id].anim_count > 1 ) {
                short steps = ( ifloor( dp->anim_time * 10.0f ) % mipinf[tex_id].anim_count
                                - mipinf[tex_id].anim_pos + mipinf[tex_id].anim_count )
                              % mipinf[tex_id].anim_count;
                while ( steps-- > 0 ) tex_id = mipinf[tex_id].anim_next;
            }

            for ( j = 0; j < vcnt; j++ ) {
                v0 = j*3 + GEOM_VTX0;
                vx = gv[v0    ] * (float)VTX_UNSCALE;
                vy = gv[v0 + 1] * (float)VTX_UNSCALE;
                vz = gv[v0 + 2] * (float)VTX_UNSCALE;

                /* BSP is Z-up, renderer is Y-up: y and z swap, the brush
                   entity's offset with them. */
                vt_x[j] = vx + ox;
                vt_y[j] = vz + oz;
                vt_z[j] = vy + oy;

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

            /* Most faces lie between the two planes, and clip_w would copy
               them through twice unchanged. */
            for ( j = 0; j < vcnt; j++ )
                if ( vt_w[j] < dp->z_near || vt_w[j] > dp->z_far ) break;
            cnt = vcnt;
            if ( j < vcnt ) {
                cnt = clip_w( vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, vcnt,
                              cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, dp->z_near, 1 );
                if ( cnt < 3 ) continue;
                cnt = clip_w( cl_x, cl_y, cl_z, cl_w, cl_u, cl_v, cnt,
                              vt_x, vt_y, vt_z, vt_w, vt_u, vt_v, dp->z_far, 0 );
            }
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
                pu[j] = vt_u[j]*rw;
                pv[j] = vt_v[j]*rw;
                zsum += vt_w[j];
            }
            zl = zsum / cnt;
            CY_LAP( cy_xf );

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
                lm_floor = sc_mipfloor_c( lm_extw, lm_exth );
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

                lm_sa = sc_shift_c( lm_sw );
                lm_sb = sc_shift_c( lm_sh );
                lm_dc = sc_find( i, lm_mip, lm_sa, lm_sb, lm_stag );
                if ( lm_dc == 0 ) {
                    bt0 = dp->prof ? sys_rdtsc() : 0;
                    lm_dc = sc_alloc( g, i, lm_mip, lm_sw, lm_sh, lm_fw, lm_fh, lm_stag );
                    if ( lm_dc != 0 ) {
                        /* Quake's exact logical rectangle: the builder
                           copies its far row and column into the cache
                           class's padding, and qglRsPolyBound keeps a
                           perspective span from sampling past them. */
                        tex_dc = mod_tex_raw( g, tex_id, lm_mip );
                        sb_build( g, lm_dc, tex_dc, i, lm_mip,
                                  lm_sw, lm_sh,
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
                    lm_su = 1.0f / (float)( (1L << lm_mip) * (1L << lm_sa) );
                    lm_sv = 1.0f / (float)( (1L << lm_mip) * (1L << lm_sb) );
                    if ( dp->rend_mode != 2 ) {
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
                CY_LAP( cy_lm );
            }

            D_ARRAYS_REFRESH();
            if ( lm_on == 0 ) {
                src_dc = mod_tex_shaded( g, tex_id, draw_mip );
                D_ARRAYS_REFRESH();
                /* ofs is [id*4 + level]. Getting this pair backwards aims
                   the view at another cell entirely -- coherent geometry
                   wearing noise. */
                texofs = tex_ofs[ tex_id*4 + draw_mip ];
                CY_LAP( cy_tex );
            }

            /*
             * ONE PATH. Every texture this loop can name is a qgl
             * Surface -- the atlas (mod_tex.bas) and the surface cache
             * (d_surf.bas) both -- and mgl reads a DC's layout at fixed
             * offsets, so uglPolyTP/uglTriTP/uglTriT handed one of them
             * spin on whatever those offsets happen to hold. There is no
             * mgl fallback left to fall back to, and none is wanted:
             * this is the slice that finishes the textured path.
             *
             * One convex polygon, one call -- no fan pivot, so no
             * internal edges to seam along, and no 12-vertex ceiling:
             * that was mgl's clipper (SH_MAXV, inc/mscshpc.inc), and
             * qgl's is QGL_MAXV, 41, which is exactly MAXV here.
             *
             * Both textured modes carry u/z, v/z and 1/z down the edges;
             * affine divides only at each row's two ends and takes one
             * constant step between them.
             *
             * Wireframe alone still fans below: it wants the triangles
             * and never reads src_dc.
             */
            if ( dp->rend_mode != 2 ) {
                q_gate++;
                if ( q_dst && cnt <= MAXV ) {
                    for ( j = 0; j < cnt; j++ ) {
                        qvtx[j].x = px[j]; qvtx[j].y = py[j]; qvtx[j].z = pw[j];
                        qvtx[j].u = pu[j]; qvtx[j].v = pv[j];
                    }
                    /* Drawn BEFORE the replay capture below, because
                       only the return says whether the texture was
                       accepted, and a refused face must not be latched
                       as the frame's exemplar. */
                    qglSfZMode( q_dst, z_mode );
                    if ( ( lm_on && dp->rend_mode == 0
                           ? qglRsPolyBound( q_dst, (void far *)qvtx, cnt,
                                             QGL_M_PTEX, src_dc, lm_sw, lm_sh )
                           : qglRsPoly( q_dst, (void far *)qvtx, cnt,
                                        dp->rend_mode == 0 ? QGL_M_PTEX
                                                           : QGL_M_ATEX,
                                        src_dc ) ) >= 0 ) {
                        /* The BIGGEST face on screen, not the first. An
                           exact texel test needs a face that is
                           magnified; the first one drawn is typically 6
                           texels to a pixel, where a sub-pixel gradient
                           difference lands anywhere and the comparison
                           decides nothing. Screen area over texel count
                           is the ratio that matters, and area is the
                           half of it that varies. */
                        float ar = 0.0f;
                        short on = 1;
                        for ( j = 0; j < cnt; j++ ) {
                            short k = (short)((j + 1) % cnt);
                            ar += px[j]*py[k] - px[k]*py[j];
                            /* WHOLLY on screen, or the area is the
                               area of a face that mostly is not: the
                               first pick this way was a 22682-pixel
                               polygon of which nothing landed in the
                               replay buffer, and the test passed on
                               zero covered pixels. */
                            if ( px[j] < 0.0f || px[j] > (float)dp->x_res ||
                                 py[j] < 0.0f || py[j] > (float)dp->y_res )
                                on = 0;
                        }
                        if ( ar < 0.0f ) ar = -ar;
                        if ( on && ar > fp_area ) {
                            for ( j = 0; j < cnt; j++ ) fp_v[j] = qvtx[j];
                            fp_cnt  = cnt;
                            fp_tex  = src_dc;
                            fp_ofs  = texofs;
                            fp_area = ar;
                        }
                        if ( dp->qgl_faces < 0 ) dp->qgl_faces = 0;
                        dp->qgl_faces++;
                        dp->tris += cnt - 2;
                        CY_LAP( cy_rast );
                        continue;
                    }
                }
                /* Counted, not silent: a drop here is a texture
                   refusal (padded row, non-power-of-two side, over one
                   16K page) and there is nothing else left to try.
                   A face clipped entirely away answers 0, not -1, and
                   is not counted here -- it drew nothing on purpose. */
                dp->qgl_drop++;
                continue;
            }

            /*
             * Wireframe: the polygon flat-filled, then its outline --
             * QGL_M_WIRE paints the two ends of every span, which for a
             * convex face is its edge, depth-tested like the fill. One
             * call each per POLYGON, the same unit the textured path
             * draws in; it used to fan into triangles and draw each
             * edge through qglDrLine, which cost a call per edge and
             * showed the fan's diagonals, not the face.
             */
            if ( !q_dst ) { dp->qgl_drop++; continue; }
            /* u and v zeroed, not left: a flat fill samples no texture
               but its gradients are still computed, and the overflow
               gate can refuse a polygon on a number that came from
               whichever textured face last wrote here. */
            for ( j = 0; j < cnt; j++ ) {
                qvtx[j].x = px[j]; qvtx[j].y = py[j]; qvtx[j].z = pw[j];
                qvtx[j].u = 0.0f;  qvtx[j].v = 0.0f;
            }
            qglSfZMode( q_dst, z_mode );
            qglRsPoly( q_dst, (void far *)qvtx, cnt, QGL_M_FLAT, 200L );
            /* The outline goes on with depth OFF. It sits exactly on the
               fill it just laid down, so a test rejects it on the tie
               and wireframe loses every edge -- which is what happened
               the moment world faces stopped writing with SET. */
            qglSfZMode( q_dst, QGL_Z_OFF );
            qglRsPoly( q_dst, (void far *)qvtx, cnt, QGL_M_WIRE, 0L );
            dp->tris += cnt - 2;

        }
    }

    qglRsCover( 0 );

    /* Why nothing went through qgl, when the setup itself stood up.
       -5: no face reached the one-call-per-polygon gate at all.
       -6: they reached it and the TEXTURE was refused every time.
           That used to be structural -- the atlas was an mgl EMS DC
           and the bridge took linear memory only, 111 of 111 faces
           measured. The atlas is a qgl Surface now, so a -6 here means
           an actual texture refusal by qglRsPoly (padded row,
           non-power-of-two side, over one 16K page) and is worth
           reading as a fault. */
    if ( dp->qgl_faces == 0 && q_ok ) dp->qgl_faces = q_gate ? -6 : -5;

    dp->build_us = build_cyc;
}
