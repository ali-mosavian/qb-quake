/*
 * d_alias.c -- one alias model's triangles, in one call.
 *
 * The BASIC loop this replaces cost 19.5 ms a frame for two models in
 * view -- 60 us a triangle for a five-plane clip, six UV converts and a
 * projection, against 15 us for the rasteriser it fed. Same arithmetic,
 * same order, so the picture is the one d_mdl.bas drew; d_faces.c is
 * the precedent for the world's faces.
 *
 * Every vertex of the frame is rotated by the yaw and transformed
 * through mtx_fin, then each triangle is clipped in CLIP space against
 * w >= z_near, |x| <= w and |y| <= w -- the view rectangle before the
 * divide, which is what bounds a projected corner to the viewport
 * (AGENTS.md, the wandering streaks) -- projected, backface-tested and
 * handed to qglRsPoly affine. Returns the triangles handed over.
 */

#include "qcshared.h"

extern short pascal far qglRsPoly  ( long dst, void far *v, short cnt,
                                     short mode, long src );
extern short pascal far qglSfZMode ( long surf, short mode );
extern short pascal far qglGemMap  ( short h, short pg, short slot );
extern long  pascal far mod_tex_shaded ( void *g, short k, short mip );

#define QGL_M_TEX    2
#define QGL_M_FLAT  1
#define QGL_Z_TEST   2
#define PAGE_SLOT    2          /* q_map.bi: shared with nodes, leaves, lightmap */
#define CM_SLOT      3          /* model.bas: the colormap's, idle while a model draws */
#define MDL_MAXV     236        /* d_mdl.bas; the dog has 236 */
#define MDL_CLIPV    9          /* five planes add at most one corner each */
#define MDL_UV_SCALE 32767.0f

typedef struct { float x, y, z, u, v; } QglVtx;
typedef struct { short a, b, c, u1, v1, u2, v2, u3, v3; } MdlTri;

/* Near, in DGROUP, like d_faces.c's scratch: 3 KB. Far statics here
   made bcc emit es:okv[bx], which TASM 4.1 rejects. */
static float near vx[MDL_MAXV + 1];
static float near vy[MDL_MAXV + 1];
static float near vw[MDL_MAXV + 1];
static char  near okv[MDL_MAXV + 1];    /* in front of the near plane */
/* Inside all five planes, and if so its projection, once per vertex
   rather than once per corner of every triangle that shares it. A
   triangle whose three corners are all inside skips the clip outright,
   which is nearly every triangle of a model that is on screen. */
static char  near inv[MDL_MAXV + 1];
static float near sx[MDL_MAXV + 1];
static float near sy[MDL_MAXV + 1];
static float near srw[MDL_MAXV + 1];

/* The ping-pong clip rings and the projected polygon. */
static float near cbx[2][MDL_CLIPV], cby[2][MDL_CLIPV], cbw[2][MDL_CLIPV];
static float near cbu[2][MDL_CLIPV], cbv[2][MDL_CLIPV];
static float near cd[MDL_CLIPV];
static QglVtx near qv[MDL_CLIPV];

short pascal far mdl_draw_tris(
    short     ntri,
    short     nvert,
    short     frame,
    Vec3     *org,              /* ent.pos, BSP space, Z up */
    float     cyaw,             /* cos and sin of the yaw, from BASIC */
    float     syaw,
    float     cpitch,           /* and of the pitch, positive nose down */
    float     spitch,
    Vec3     *scale,            /* vertex byte -> model unit */
    Vec3     *origin,
    short     vtx_hnd,
    long      skin,
    float    *m,                /* Mat4, 16 floats */
    float     xresh,
    float     yresh,
    float     z_near,
    long      dst,
    short     zmode )           /* QGL_Z_TEST for a soldier, OFF for the view weapon */
{
    MdlTri far *tri;
    unsigned char far *vb;
    short v, j, k, k2, cp, nin, nout, sbuf, dbuf, drawn = 0;
    short ia[3], cn[2];
    float rx, ry, rz, wx, wy, wz, rw, f, area, px, pz;

    /* The frame's vertices: three bytes each, frames contiguous in the
       one EMS page. qglGemMap's own record makes this free when nobody
       else has taken the slot since the last model. */
    vb = (unsigned char far *) ((unsigned long) qglGemMap( vtx_hnd, 0, PAGE_SLOT ) << 16);
    vb += (long) frame * nvert * 3;
    /* The triangles: page 1 of the same handle, through the colormap's
       slot -- nothing maps that while a model draws, and the next
       surface build re-maps it for itself. */
    tri = (MdlTri far *) ((unsigned long) qglGemMap( vtx_hnd, 1, CM_SLOT ) << 16);

    for ( v = 0; v < nvert; v++ ) {
        rx = (float) vb[v*3]     * scale->x + origin->x;
        ry = (float) vb[v*3 + 1] * scale->y + origin->y;
        rz = (float) vb[v*3 + 2] * scale->z + origin->z;
        /* pitch about the model's own y, then yaw about the world's z */
        px = rx * cpitch + rz * spitch;
        pz = rz * cpitch - rx * spitch;
        wx = org->x + ( px * cyaw - ry * syaw );
        wy = org->y + ( px * syaw + ry * cyaw );
        wz = org->z + pz;

        /* Renderer space is Y up: x unchanged, z becomes y -- the same
           swap d_faces.c makes reading a raw BSP vertex. */
        rx = wx; ry = wz; rz = wy;

        /* No divide here: a corner a hair in front of the near plane has
           a colossal 1/w. Keep w and clip against it first. */
        vw[v] = rx*m[3] + ry*m[7] + rz*m[11] + m[15];
        vx[v] = rx*m[0] + ry*m[4] + rz*m[ 8] + m[12];
        vy[v] = rx*m[1] + ry*m[5] + rz*m[ 9] + m[13];
        okv[v] = ( vw[v] >= z_near );
        inv[v] = okv[v] && vw[v] - vx[v] >= 0.0f && vw[v] + vx[v] >= 0.0f
                        && vw[v] - vy[v] >= 0.0f && vw[v] + vy[v] >= 0.0f;
        if ( inv[v] ) {
            /* The same expressions the clipped path evaluates, so the
               two agree to the bit on a corner that needs no clip. */
            rw = 1.0f / vw[v];
            sx[v] = xresh + vx[v] * rw * xresh;
            sy[v] = yresh - vy[v] * rw * yresh;
            srw[v] = rw;
        }
    }

    /* A model tests depth, never merely writes it: it comes after the
       world, which the BSP order put in front of it where it belongs.
       Off for us by qglSfZMode itself when dst has no depth buffer. */
    qglSfZMode( dst, zmode );

    for ( j = 0; j < ntri; j++ ) {
        ia[0] = tri[j].a; ia[1] = tri[j].b; ia[2] = tri[j].c;
        if ( !( okv[ia[0]] || okv[ia[1]] || okv[ia[2]] ) ) continue;

        if ( inv[ia[0]] && inv[ia[1]] && inv[ia[2]] ) {
            qv[0].x = sx[ia[0]]; qv[0].y = sy[ia[0]]; qv[0].z = srw[ia[0]];
            qv[1].x = sx[ia[1]]; qv[1].y = sy[ia[1]]; qv[1].z = srw[ia[1]];
            qv[2].x = sx[ia[2]]; qv[2].y = sy[ia[2]]; qv[2].z = srw[ia[2]];
            area = ( qv[1].x - qv[0].x ) * ( qv[2].y - qv[0].y )
                 - ( qv[2].x - qv[0].x ) * ( qv[1].y - qv[0].y );
            /*
             * Backface, or too small to cover a scanline: qglRsPoly
             * refuses anything whose denominator is under 2 (qgl$l1sqr,
             * twice the area of one pixel) and area IS that denominator
             * -- the triple it searches out of three vertices is these
             * three. e1m6's monsters hand over 287 triangles a frame and
             * 241 of them die in there, each having paid for a texture
             * map, a gradient and a clip first.
             */
            if ( area > -2.0f ) continue;
            qv[0].u = (float) tri[j].u1 / MDL_UV_SCALE; qv[0].v = (float) tri[j].v1 / MDL_UV_SCALE;
            qv[1].u = (float) tri[j].u2 / MDL_UV_SCALE; qv[1].v = (float) tri[j].v2 / MDL_UV_SCALE;
            qv[2].u = (float) tri[j].u3 / MDL_UV_SCALE; qv[2].v = (float) tri[j].v3 / MDL_UV_SCALE;
            qglRsPoly( dst, (void far *) qv, 3, QGL_M_TEX, skin );
            drawn++;
            continue;
        }

        sbuf = 0;
        cn[0] = 3;
        for ( k = 0; k < 3; k++ ) {
            cbx[0][k] = vx[ia[k]];
            cby[0][k] = vy[ia[k]];
            cbw[0][k] = vw[ia[k]];
        }
        cbu[0][0] = (float) tri[j].u1 / MDL_UV_SCALE;
        cbu[0][1] = (float) tri[j].u2 / MDL_UV_SCALE;
        cbu[0][2] = (float) tri[j].u3 / MDL_UV_SCALE;
        cbv[0][0] = (float) tri[j].v1 / MDL_UV_SCALE;
        cbv[0][1] = (float) tri[j].v2 / MDL_UV_SCALE;
        cbv[0][2] = (float) tri[j].v3 / MDL_UV_SCALE;

        /* Sutherland-Hodgman against the five clip-space planes. */
        for ( cp = 0; cp < 5; cp++ ) {
            nin = 0;
            for ( k = 0; k < cn[sbuf]; k++ ) {
                switch ( cp ) {
                case 0:  cd[k] = cbw[sbuf][k] - z_near;      break;
                case 1:  cd[k] = cbw[sbuf][k] - cbx[sbuf][k]; break;
                case 2:  cd[k] = cbw[sbuf][k] + cbx[sbuf][k]; break;
                case 3:  cd[k] = cbw[sbuf][k] - cby[sbuf][k]; break;
                default: cd[k] = cbw[sbuf][k] + cby[sbuf][k]; break;
                }
                if ( cd[k] >= 0.0f ) nin++;
            }
            if ( nin == 0 ) { cn[sbuf] = 0; break; }
            if ( nin == cn[sbuf] ) continue;      /* wholly inside */

            dbuf = 1 - sbuf;
            nout = 0;
            for ( k = 0; k < cn[sbuf]; k++ ) {
                k2 = k + 1; if ( k2 == cn[sbuf] ) k2 = 0;
                if ( cd[k] >= 0.0f ) {
                    cbx[dbuf][nout] = cbx[sbuf][k];
                    cby[dbuf][nout] = cby[sbuf][k];
                    cbw[dbuf][nout] = cbw[sbuf][k];
                    cbu[dbuf][nout] = cbu[sbuf][k];
                    cbv[dbuf][nout] = cbv[sbuf][k];
                    nout++;
                }
                if ( (cd[k] >= 0.0f) != (cd[k2] >= 0.0f) ) {
                    f = cd[k] / ( cd[k] - cd[k2] );
                    cbx[dbuf][nout] = cbx[sbuf][k] + f * ( cbx[sbuf][k2] - cbx[sbuf][k] );
                    cby[dbuf][nout] = cby[sbuf][k] + f * ( cby[sbuf][k2] - cby[sbuf][k] );
                    cbw[dbuf][nout] = cbw[sbuf][k] + f * ( cbw[sbuf][k2] - cbw[sbuf][k] );
                    cbu[dbuf][nout] = cbu[sbuf][k] + f * ( cbu[sbuf][k2] - cbu[sbuf][k] );
                    cbv[dbuf][nout] = cbv[sbuf][k] + f * ( cbv[sbuf][k2] - cbv[sbuf][k] );
                    nout++;
                }
            }
            cn[dbuf] = nout;
            sbuf = dbuf;
        }
        nout = cn[sbuf];
        if ( nout < 3 ) continue;

        /* The divide, on corners that are all inside the frustum. RAW u
           and v: the model is drawn affine, and that filler steps them
           linearly in screen space. */
        for ( k = 0; k < nout; k++ ) {
            rw = 1.0f / cbw[sbuf][k];
            qv[k].x = xresh + cbx[sbuf][k] * rw * xresh;
            qv[k].y = yresh - cby[sbuf][k] * rw * yresh;
            qv[k].z = rw;
            qv[k].u = cbu[sbuf][k];
            qv[k].v = cbv[sbuf][k];
        }

        /* Backface after the clip: clipping preserves winding, so the
           first three corners answer for all of them. */
        area = ( qv[1].x - qv[0].x ) * ( qv[2].y - qv[0].y )
             - ( qv[2].x - qv[0].x ) * ( qv[1].y - qv[0].y );
        if ( area < 0.0f ) {
            qglRsPoly( dst, (void far *) qv, nout, QGL_M_TEX, skin );
            drawn++;
        }
    }
    return drawn;
}


/* A pickup as a box: half wide either way, top high, spun by yaw, six
   flat quads depth-tested like the model. Any corner behind the near
   plane drops the whole box -- at ten units wide that means the player
   is standing in it, which is the touch that takes it. */
short pascal far mdl_draw_box(
    Vec3  *org,
    float  half,
    float  top,
    float  cyaw,
    float  syaw,
    float *m,
    float  xresh,
    float  yresh,
    float  z_near,
    long   dst,
    short  side_col,
    short  top_col )
{
    static short near face[6][4] = {
        {0,1,2,3}, {7,6,5,4}, {0,4,5,1}, {1,5,6,2}, {2,6,7,3}, {3,7,4,0} };
    float bx[8], by[8], bw[8];
    float lx, ly, lz, rx, ry, rz, rw;
    short i, k;

    for ( i = 0; i < 8; i++ ) {
        lx = ( (i & 3) == 1 || (i & 3) == 2 ) ? half : -half;
        ly = ( (i & 3) >= 2 ) ? half : -half;
        lz = ( i >= 4 ) ? top : 0.0f;
        rx = org->x + ( lx * cyaw - ly * syaw );
        rz = org->y + ( lx * syaw + ly * cyaw );
        ry = org->z + lz;
        bw[i] = rx*m[3] + ry*m[7] + rz*m[11] + m[15];
        if ( bw[i] < z_near ) return 0;
        bx[i] = rx*m[0] + ry*m[4] + rz*m[ 8] + m[12];
        by[i] = rx*m[1] + ry*m[5] + rz*m[ 9] + m[13];
    }
    qglSfZMode( dst, QGL_Z_TEST );
    for ( i = 0; i < 6; i++ ) {
        for ( k = 0; k < 4; k++ ) {
            rw = 1.0f / bw[face[i][k]];
            qv[k].x = xresh + bx[face[i][k]] * rw * xresh;
            qv[k].y = yresh - by[face[i][k]] * rw * yresh;
            qv[k].z = rw;
            qv[k].u = 0.0f; qv[k].v = 0.0f;
        }
        qglRsPoly( dst, (void far *) qv, 4, QGL_M_FLAT, (long) ( i == 1 ? top_col : side_col ) );
    }
    return 6;
}


/* A pickup as its b_*.bsp: q_ent.bi's CrateModel, five textured quads
   from org's corner -- the bottom is on the floor and never shipped --
   each corner a bit per axis and its u,v in 32nds, as mkassets read
   them off the model's faces. A +N chain steps at 10 Hz like the
   world's. A face with a corner behind the near plane is dropped;
   the rest of the box still draws. */
typedef struct { short tex, frames; signed char v[12]; } CrateFace;
typedef struct { Vec3 size; CrateFace f[5]; } CrateModel;

short pascal far mdl_draw_crate(
    void       *g,
    Vec3       *org,
    CrateModel *c,
    float      *m,
    float       xresh,
    float       yresh,
    float       z_near,
    long        dst,
    short       mip,
    float       anim_time )
{
    float bx[8], by[8], bw[8];
    float rx, ry, rz, rw;
    long  src, step;
    short i, k, ci, drawn = 0;
    const CrateFace *cf;

    step = (long) ( anim_time * 10.0f );
    for ( i = 0; i < 8; i++ ) {
        rx = org->x + ( (i & 1) ? c->size.x : 0.0f );
        rz = org->y + ( (i & 2) ? c->size.y : 0.0f );
        ry = org->z + ( (i & 4) ? c->size.z : 0.0f );
        bw[i] = rx*m[3] + ry*m[7] + rz*m[11] + m[15];
        bx[i] = rx*m[0] + ry*m[4] + rz*m[ 8] + m[12];
        by[i] = rx*m[1] + ry*m[5] + rz*m[ 9] + m[13];
    }
    qglSfZMode( dst, QGL_Z_TEST );
    for ( i = 0; i < 5; i++ ) {
        cf = &c->f[i];
        for ( k = 0; k < 4; k++ ) if ( bw[ cf->v[k*3] ] < z_near ) break;
        if ( k < 4 ) continue;
        src = mod_tex_shaded( g, (short) ( cf->tex + ( cf->frames > 1 ? step % cf->frames : 0 ) ), mip );
        if ( src == 0 ) continue;
        for ( k = 0; k < 4; k++ ) {
            ci = cf->v[k*3];
            rw = 1.0f / bw[ci];
            qv[k].x = xresh + bx[ci] * rw * xresh;
            qv[k].y = yresh - by[ci] * rw * yresh;
            qv[k].z = rw;
            qv[k].u = (float) cf->v[k*3+1] / 32.0f;
            qv[k].v = (float) cf->v[k*3+2] / 32.0f;
        }
        qglRsPoly( dst, (void far *) qv, 4, QGL_M_TEX, src );
        drawn++;
    }
    return drawn;
}
