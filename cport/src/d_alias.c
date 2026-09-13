/*
 * d_alias.c -- what is drawn that is not world geometry. For now the
 * pickups, as flat boxes; the alias models (d_mdl.bas) are not ported.
 *
 * Everything here is DEPTH TESTED. A box is an object of its own with
 * no place in the BSP order -- the walk cannot sort it against the
 * world the way it sorts the world against itself -- so 1/z decides,
 * which is what the depth buffer is for.
 */

#include <math.h>
#include <mem.h>   /* _fmemset -- the leaf caches, once */

#include "qrcfg.h"
#include "d_alias.h"
#include "mdl.h"
#include "mdl_ai.h"
#include "weapons.h"
#include "item.h"
#include "qgl.h"
#include "mod_tex.h"

/* The EMS slots a model reads through: PAGE_SLOT is what nodes,
   leaves and the lightmap already share, mapped fresh and never held;
   CM_SLOT is the colormap's, idle while a model draws, and the next
   surface build re-maps it for itself. */
#define PAGE_SLOT    2
#define CM_SLOT      3
#define MDL_CLIPV    9          /* five planes add at most one corner each */
#define MDL_UV_SCALE 32767.0f

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

/*
 * The ping-pong clip rings and the projected polygon.
 *
 * ONE ARRAY OF A RECORD, and two pointers swapped -- not five arrays
 * subscripted [ring][k]. A two-dimensional subscript costs bcc a
 * multiply and an add at every one of the ~100 accesses a plane makes,
 * which is what made a clip 115us against the 30-odd float operations
 * it actually performs.
 */
typedef struct { float x, y, w, u, v; } ClipV;
static ClipV near cba[MDL_CLIPV], cbb[MDL_CLIPV];
static float near cd[MDL_CLIPV];
static QVert near qv[MDL_CLIPV];

/* Times the clip-space winding disagreed with the projected one on a
   triangle that reached both. It is the identity the pre-clip backface
   test rests on, checked on live data every frame for one compare, and
   any number but zero says the test is throwing away front faces
   somewhere it is not being watched. Read by -bench through
   mdl_bf_bad(). */
static long near bf_bad;

long mdl_bf_bad( void ) { return bf_bad; }

static short mdl_draw_tris(
    short     ntri,
    short     nvert,
    short     frame,
    BspVec3  *org,              /* the monster's, BSP space, Z up */
    float     cyaw,             /* cos and sin of the yaw */
    float     syaw,
    float     cpitch,           /* and of the pitch, positive nose down */
    float     spitch,
    BspVec3  *scale,            /* vertex byte -> model unit */
    BspVec3  *origin,
    short     vtx_hnd,
    QSurf     skin,
    float    *m,                /* Mat4, 16 floats */
    float     xresh,
    float     yresh,
    float     z_near,
    QSurf     dst,
    short     zmode )           /* QGL_Z_TEST for a soldier, OFF for the view weapon */
{
    MdlTri far *tri;
    MdlTri far *t;
    unsigned char far *vb;
    short v, j, k, k2, cp, nin, nout, ns, nd, drawn = 0;
    short bf_pre;
    ClipV *cs, *cw, *ct;
    short ia[3];
    float rx, ry, rz, wx, wy, wz, rw, f, area, px, pz;
    float det;

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

    /* One walking far pointer, and each corner's index read once: the
       record is 18 bytes, so tri[j].a costs a multiply and a fresh
       es:bx every field. e1m6 walks 580 of these a frame and refuses
       most of them on the first test. */
    for ( t = tri, j = 0; j < ntri; j++, t++ ) {
        short a = t->a, b = t->b, c = t->c;

        ia[0] = a; ia[1] = b; ia[2] = c;
        if ( !( okv[a] || okv[b] || okv[c] ) ) continue;

        if ( inv[a] && inv[b] && inv[c] ) {
            qv[0].x = sx[a]; qv[0].y = sy[a]; qv[0].z = srw[a];
            qv[1].x = sx[b]; qv[1].y = sy[b]; qv[1].z = srw[b];
            qv[2].x = sx[c]; qv[2].y = sy[c]; qv[2].z = srw[c];
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
            qv[0].u = (float) t->u1 / MDL_UV_SCALE; qv[0].v = (float) t->v1 / MDL_UV_SCALE;
            qv[1].u = (float) t->u2 / MDL_UV_SCALE; qv[1].v = (float) t->v2 / MDL_UV_SCALE;
            qv[2].u = (float) t->u3 / MDL_UV_SCALE; qv[2].v = (float) t->v3 / MDL_UV_SCALE;
            qglRsPoly( dst, (void far *) qv, 3, QGL_M_TEX, skin );
            drawn++;
            continue;
        }

        /*
         * BACKFACE BEFORE THE CLIP, not after. Clipping a triangle costs
         * 115 us -- measured, 31.5 clipped triangles a frame on e1m6 for
         * 3.64ms -- and half of any closed model's are facing away.
         *
         * The projected cross product is the 3x3 determinant of the clip
         * -space corners over w0*w1*w2, and the screen y flip negates
         * it, so with every w past the near plane sign(area) = -sign(det)
         * and no divide is needed. A corner BEHIND the near plane has a
         * w of the wrong sign and breaks that, so those go on to the
         * clipper and are tested after it as they always were.
         */
        bf_pre = 0;
        if ( okv[a] && okv[b] && okv[c] ) {
            det = vx[a] * ( vy[b] * vw[c] - vy[c] * vw[b] )
                - vy[a] * ( vx[b] * vw[c] - vx[c] * vw[b] )
                + vw[a] * ( vx[b] * vy[c] - vx[c] * vy[b] );
            if ( det <= 0.0f ) continue;
            bf_pre = 1;
        }

        cs = cba; cw = cbb; ns = 3;
        for ( k = 0; k < 3; k++ ) {
            cs[k].x = vx[ia[k]];
            cs[k].y = vy[ia[k]];
            cs[k].w = vw[ia[k]];
        }
        cs[0].u = (float) t->u1 / MDL_UV_SCALE;
        cs[1].u = (float) t->u2 / MDL_UV_SCALE;
        cs[2].u = (float) t->u3 / MDL_UV_SCALE;
        cs[0].v = (float) t->v1 / MDL_UV_SCALE;
        cs[1].v = (float) t->v2 / MDL_UV_SCALE;
        cs[2].v = (float) t->v3 / MDL_UV_SCALE;

        /* Sutherland-Hodgman against the five clip-space planes. The
           plane is chosen ONCE and then the whole ring measured, rather
           than a five-way switch inside the vertex loop. */
        for ( cp = 0; cp < 5; cp++ ) {
            switch ( cp ) {
            case 0:  for ( k = 0; k < ns; k++ ) cd[k] = cs[k].w - z_near;  break;
            case 1:  for ( k = 0; k < ns; k++ ) cd[k] = cs[k].w - cs[k].x; break;
            case 2:  for ( k = 0; k < ns; k++ ) cd[k] = cs[k].w + cs[k].x; break;
            case 3:  for ( k = 0; k < ns; k++ ) cd[k] = cs[k].w - cs[k].y; break;
            default: for ( k = 0; k < ns; k++ ) cd[k] = cs[k].w + cs[k].y; break;
            }
            nin = 0;
            for ( k = 0; k < ns; k++ ) if ( cd[k] >= 0.0f ) nin++;
            if ( nin == 0 ) { ns = 0; break; }
            if ( nin == ns ) continue;            /* wholly inside */

            nd = 0;
            for ( k = 0; k < ns; k++ ) {
                k2 = k + 1; if ( k2 == ns ) k2 = 0;
                if ( cd[k] >= 0.0f ) cw[nd++] = cs[k];
                if ( (cd[k] >= 0.0f) != (cd[k2] >= 0.0f) ) {
                    f = cd[k] / ( cd[k] - cd[k2] );
                    cw[nd].x = cs[k].x + f * ( cs[k2].x - cs[k].x );
                    cw[nd].y = cs[k].y + f * ( cs[k2].y - cs[k].y );
                    cw[nd].w = cs[k].w + f * ( cs[k2].w - cs[k].w );
                    cw[nd].u = cs[k].u + f * ( cs[k2].u - cs[k].u );
                    cw[nd].v = cs[k].v + f * ( cs[k2].v - cs[k].v );
                    nd++;
                }
            }
            ct = cs; cs = cw; cw = ct;
            ns = nd;
        }
        nout = ns;
        if ( nout < 3 ) continue;

        /* The divide, on corners that are all inside the frustum. RAW u
           and v: the model is drawn affine, and that filler steps them
           linearly in screen space. */
        for ( k = 0; k < nout; k++ ) {
            rw = 1.0f / cs[k].w;
            qv[k].x = xresh + cs[k].x * rw * xresh;
            qv[k].y = yresh - cs[k].y * rw * yresh;
            qv[k].z = rw;
            qv[k].u = cs[k].u;
            qv[k].v = cs[k].v;
        }

        /* Backface after the clip: clipping preserves winding, so the
           first three corners answer for all of them. */
        area = ( qv[1].x - qv[0].x ) * ( qv[2].y - qv[0].y )
             - ( qv[2].x - qv[0].x ) * ( qv[1].y - qv[0].y );
        if ( bf_pre && area >= 0.0f ) bf_bad++;
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

/*
 * r_mdl_vis_c, without the BASIC array descriptors: the box against
 * the frustum, then its eight corners and its centre against the PVS,
 * each a descent of the tree. The near corner alone decides the
 * frustum test, as r_cull_box does -- there are no children to hand a
 * clip mask to.
 */
static short d_mdl_visible( World *world, Renderer *rdr, DiskPlane far *frustum,
                             BspVec3 *org, float radius, float zlo, float zhi,
                             LeafCache far *lc )
{
    float lo[3], hi[3], px, py, pz, dp;
    short i, nodenr, vis = 0;

#if QR_PROF
    rdr->dv_calls++;
#endif
    lo[0] = org->x - radius; hi[0] = org->x + radius;
    lo[1] = org->y - radius; hi[1] = org->y + radius;
    lo[2] = org->z + zlo;    hi[2] = org->z + zhi;

    /* the frustum is renderer space, y up: the box's z goes in y */
    for ( i = 0; i < 6; i++ ) {
        px = frustum[i].norm.x > 0.0f ? lo[0] : hi[0];
        py = frustum[i].norm.y > 0.0f ? lo[2] : hi[2];
        pz = frustum[i].norm.z > 0.0f ? lo[1] : hi[1];
        dp = frustum[i].norm.x * px + frustum[i].norm.y * py + frustum[i].norm.z * pz;
        if ( dp + frustum[i].dist > 0.0f ) {
#if QR_PROF
            rdr->dv_fout++;
#endif
            return 0;
        }
    }

    /* Same box as last time: the leaves are the same, whatever the PVS
       now says about them. The whole of the saving is here. */
    if ( lc && lc->ok && lc->at.x == org->x && lc->at.y == org->y && lc->at.z == org->z
         && lc->r == radius && lc->zlo == zlo && lc->zhi == zhi ) {
        for ( i = 0; i < 9; i++ ) {
            nodenr = lc->lf[i];
            if ( nodenr > 0 && rdr->pvs_now[nodenr] ) {
#if QR_PROF
                rdr->dv_vis++;
#endif
                return -1;
            }
        }
        return 0;
    }

    for ( i = 0; i < 9; i++ ) {
        if ( i == 8 ) {
            px = org->x; py = org->y; pz = org->z + ( zlo + zhi ) * 0.5f;
        } else {
            px = ( i & 1 ) ? hi[0] : lo[0];
            py = ( i & 2 ) ? hi[1] : lo[1];
            pz = ( i & 4 ) ? hi[2] : lo[2];
        }
        /* r_point_leaf: the tree in BSP space, z up, no swap */
#if QR_PROF
        rdr->dv_desc++;
#endif
        nodenr = 0;
        while ( !( nodenr & 0x8000 ) ) {
            Plane far *pl = &world->planes[ world->nodes[nodenr].plane_id ];
            dp = px * pl->norm.x + py * pl->norm.y + pz * pl->norm.z - pl->dist;
            nodenr = dp >= 0.0f ? world->nodes[nodenr].child0 : world->nodes[nodenr].child1;
        }
        nodenr = (short) ~nodenr;
        if ( lc ) lc->lf[i] = nodenr;
        if ( nodenr > 0 && rdr->pvs_now[nodenr] ) {
            vis = -1;
            /* with nowhere to record them, the remaining eight are
               wasted work -- answer now, as this always did */
            if ( !lc ) {
#if QR_PROF
                rdr->dv_vis++;
#endif
                return -1;
            }
        }
    }
    if ( lc ) {
        lc->at = *org; lc->r = radius; lc->zlo = zlo; lc->zhi = zhi; lc->ok = 1;
    }
#if QR_PROF
    if ( vis ) rdr->dv_vis++;
#endif
    return vis;
}

/* One slot per entity, made on the first frame that wants it: item_count
   and mon_count are the map's, not known when r_alloc_scratch runs. A
   refusal leaves the pointer null and every call recomputes, which is
   what this did before. */
static LeafCache far *lc_slot( Renderer *rdr, LeafCache far **arr, short n, short i )
{
    if ( n <= 0 || rdr->no_lcache ) return (LeafCache far *) 0;
    if ( !*arr ) {
        *arr = (LeafCache far *) qglMemAlloc( (long) n * sizeof(LeafCache) );
        if ( !*arr ) return (LeafCache far *) 0;
        _fmemset( *arr, 0, (unsigned) ( n * sizeof(LeafCache) ) );
    }
    return &(*arr)[i];
}

/*
 * A pickup as a box: half wide either way, top high, spun by yaw, six
 * flat quads. Any corner behind the near plane drops the whole box --
 * at ten units wide that means the player is standing in it, which is
 * the touch that takes it.
 */
static short mdl_draw_box( BspVec3 *org, float half, float top,
                            float cyaw, float syaw, float *m,
                            float xresh, float yresh, float z_near,
                            QSurf dst, short side_col, short top_col )
{
    static short face[6][4] = {
        {0,1,2,3}, {7,6,5,4}, {0,4,5,1}, {1,5,6,2}, {2,6,7,3}, {3,7,4,0} };
    float bx[8], by[8], bw[8];
    float lx, ly, lz, rx, ry, rz, rw;
    short i, k;

    for ( i = 0; i < 8; i++ ) {
        lx = ( (i & 3) == 1 || (i & 3) == 2 ) ? half : -half;
        ly = ( (i & 3) >= 2 ) ? half : -half;
        lz = ( i >= 4 ) ? top : 0.0f;
        /* BSP is z up and the matrix is the renderer's, y up */
        rx = org->x + ( lx * cyaw - ly * syaw );
        rz = org->y + ( lx * syaw + ly * cyaw );
        ry = org->z + lz;
        bw[i] = rx*m[3] + ry*m[7] + rz*m[11] + m[15];
        if ( bw[i] < z_near ) return 0;
        bx[i] = rx*m[0] + ry*m[4] + rz*m[ 8] + m[12];
        by[i] = rx*m[1] + ry*m[5] + rz*m[ 9] + m[13];
    }
    for ( i = 0; i < 6; i++ ) {
        for ( k = 0; k < 4; k++ ) {
            rw = 1.0f / bw[ face[i][k] ];
            qv[k].x = xresh + bx[ face[i][k] ] * rw * xresh;
            qv[k].y = yresh - by[ face[i][k] ] * rw * yresh;
            qv[k].z = rw;
            qv[k].u = 0.0f; qv[k].v = 0.0f;
        }
        qglRsPoly( dst, (void far *) qv, 4, QGL_M_FLAT,
                    (long) ( i == 1 ? top_col : side_col ) );
    }
    return 6;
}

/*
 * A pickup as its b_*.bsp: five textured quads from org's corner -- the
 * bottom is on the floor and never shipped. A +N chain steps at 10 Hz
 * like the world's. A face with a corner behind the near plane is
 * dropped; the rest of the box still draws.
 */
static short mdl_draw_crate( World *world, BspVec3 *org, CrateModel far *c,
                              float *m, float xresh, float yresh, float z_near,
                              QSurf dst, short mip, float anim_time )
{
    float bx[8], by[8], bw[8];
    float rx, ry, rz, rw;
    QSurf src;
    long  step;
    short i, k, ci, drawn = 0;
    CrateFace far *cf;

    step = (long) ( anim_time * 10.0f );
    for ( i = 0; i < 8; i++ ) {
        rx = org->x + ( (i & 1) ? c->size.x : 0.0f );
        rz = org->y + ( (i & 2) ? c->size.y : 0.0f );
        ry = org->z + ( (i & 4) ? c->size.z : 0.0f );
        bw[i] = rx*m[3] + ry*m[7] + rz*m[11] + m[15];
        bx[i] = rx*m[0] + ry*m[4] + rz*m[ 8] + m[12];
        by[i] = rx*m[1] + ry*m[5] + rz*m[ 9] + m[13];
    }
    for ( i = 0; i < 5; i++ ) {
        cf = &c->f[i];
        for ( k = 0; k < 4; k++ ) if ( bw[ cf->v[k*3] ] < z_near ) break;
        if ( k < 4 ) continue;
        src = mod_tex_shaded( world,
                (short) ( cf->tex + ( cf->frames > 1 ? (short) ( step % cf->frames ) : 0 ) ), mip );
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

short d_draw_items( World *world, Renderer *rdr, Player *player,
                     DiskPlane far *frustum, Mat4 *mtx_fin,
                     float xresh, float yresh, float z_near, QSurf dst )
{
    float *m = (float *) mtx_fin;
    float cyaw, syaw;
    short i, side, top, drawn = 0;
    BspVec3 bob;

    if ( !world->item_count || rdr->no_items ) return 0;

    /* spun and bobbed on the same clock as the liquids */
    cyaw = (float) cos( rdr->anim_time * 2.0 );
    syaw = (float) sin( rdr->anim_time * 2.0 );
    qglSfZMode( dst, QGL_Z_TEST );

    for ( i = 0; i < world->item_count; i++ ) {
        ItemEnt far *it = &world->item[i];

        if ( it->gone ) continue;
        bob = it->pos;
        if ( !d_mdl_visible( world, rdr, frustum, &bob,
                              ENT_BOX_HALF * 1.5f, 0.0f, ENT_BOX_TOP + 8.0f,
                              lc_slot( rdr, &rdr->item_lc, world->item_count, i ) ) ) continue;

        if ( it->crate >= 0 && it->crate < world->crate_count ) {
            /* the map's own b_*.bsp, still, and centred on the origin
               as the touch already is -- Quake's spans origin to
               origin + size. The mip by distance, d_faces.c's own
               thresholds. */
            CrateModel far *cm = &world->crate[ it->crate ];
            BspVec3 corg = it->pos;
            float dx, dy, dz2, cdist;
            short cmip = 0;

            corg.x -= cm->size.x * 0.5f;
            corg.y -= cm->size.y * 0.5f;
            dx = corg.x - player->pos.x;
            dy = corg.y - player->pos.y;
            dz2 = corg.z - player->pos.z;
            cdist = (float) sqrt( dx*dx + dy*dy + dz2*dz2 );
            if ( rdr->use_mips ) {
                if      ( cdist >= 1400.0f ) cmip = 3;
                else if ( cdist >= 560.0f )  cmip = 2;
                else if ( cdist >= 280.0f )  cmip = 1;
            }
            drawn = (short) ( drawn + mdl_draw_crate( world, &corg, cm, m,
                                 xresh, yresh, z_near, dst, cmip, rdr->anim_time ) );
            continue;
        }

        if ( it->kind == ENT_ITEM_EXPLOBOX ) {
            /* the box stands still, b_explob's size */
            drawn = (short) ( drawn + mdl_draw_box( &bob, ENT_BOX_HALF, ENT_BOX_TOP,
                                 1.0f, 0.0f, m, xresh, yresh, z_near, dst,
                                 ENT_COL_YELLOW, ENT_COL_BROWN ) );
            continue;
        }

        switch ( it->kind ) {
        case ENT_ITEM_QUAD:   side = ENT_COL_BLUE;  top = ENT_COL_WHITE;  break;
        case ENT_ITEM_SUIT:   side = ENT_COL_GREEN; top = ENT_COL_WHITE;  break;
        case ENT_ITEM_PENT:   side = ENT_COL_RED;   top = ENT_COL_YELLOW; break;
        case ENT_ITEM_HEALTH: side = ENT_COL_RED;   top = ENT_COL_WHITE;  break;
        default:              side = ENT_COL_BROWN; top = ENT_COL_YELLOW; break;
        }
        bob.z += 4.0f + 4.0f * (float) sin( rdr->anim_time * 3.0 );
        drawn = (short) ( drawn + mdl_draw_box( &bob, ENT_ITEM_HALF, ENT_ITEM_TOP,
                             cyaw, syaw, m, xresh, yresh, z_near, dst, side, top ) );
    }
    return drawn;
}


short d_draw_models( World *world, Renderer *rdr, DiskPlane far *frustum,
                      Mat4 *mtx_fin, float xresh, float yresh, float z_near,
                      QSurf dst )
{
    float *m = (float *) mtx_fin;
    short i, drawn = 0;

    if ( rdr->no_mdl ) return 0;

    for ( i = 0; i < world->mon_count; i++ ) {
        MdlEnt far *e = &world->mon[i];
        MdlState *ms = mdl_of( world, e->kind );
        /* near: `world->mon` is far, and a far-to-near cast drops the
           segment silently -- the box would be read out of DS. */
        BspVec3 org;
        float a;
        short frame;

        if ( !ms ) continue;
        org = e->pos;
        if ( !d_mdl_visible( world, rdr, frustum, &org,
                              ms->radius, ms->zlo, ms->zhi,
                              lc_slot( rdr, &rdr->mdl_lc, world->mon_count, i ) ) ) continue;

        /* The sets are contiguous in the vertex page, in the header's
           order: stand, run, death, pain, attack. A leaper has no leap
           frames on the page and flies through the run cycle. */
        switch ( e->state ) {
        case MDL_ST_STAND: frame = e->anim_frame; break;
        case MDL_ST_RUN:
        case MDL_ST_LEAP:  frame = (short) ( ms->nstand + e->anim_frame ); break;
        case MDL_ST_DEAD:  frame = (short) ( ms->nstand + ms->nrun + e->anim_frame ); break;
        case MDL_ST_PAIN:  frame = (short) ( ms->nstand + ms->nrun + ms->ndeath + e->anim_frame ); break;
        default:           frame = (short) ( ms->nstand + ms->nrun + ms->ndeath +
                                              ms->npain + e->anim_frame ); break;
        }
        if ( frame >= ms->nframe ) frame = (short) ( ms->nframe - 1 );

        a = e->yaw * 3.14159265f / 180.0f;
        drawn = (short) ( drawn + mdl_draw_tris(
            ms->ntri, ms->nvert, frame, &org,
            (float) cos( a ), (float) sin( a ), 1.0f, 0.0f,
            &ms->scale, &ms->origin, ms->vtx_hnd, ms->skin,
            m, xresh, yresh, z_near, dst, QGL_Z_TEST ) );
    }
    return drawn;
}

/*
 * The view weapon: the model in hand at the eye, turned by the view's
 * own yaw and pitch and drawn last with depth OFF, which is what Quake
 * does -- it is not in the world and must not be hidden by it.
 *
 * cam->look_at is a POINT by the time this runs (v_update_camera makes
 * it one on the way out), so the direction is the difference: the
 * yaw's cos and sin are its x and z over their length, the pitch's are
 * that length and -y, positive looking down.
 */
short d_draw_view( World *world, Renderer *rdr, Camera *cam, Player *player,
                    Fight *fight, Mat4 *mtx_fin, float xresh, float yresh,
                    float z_near, QSurf dst )
{
    MdlState *ms;
    BspVec3 eye;
    float dx, dy, dz, len;
    short frame;

    if ( rdr->no_mdl || rdr->no_view ) return 0;
    if ( fight->state == GS_EXIT ) return 0;     /* no gun in the intermission's view */
    ms = &world->vmdl[ pl_view_of( fight->weapon ) ];
    if ( !ms->loaded ) return 0;

    eye = player->pos;
    eye.z += PL_EYE;

    dx = cam->look_at.x - cam->pos.x;
    dy = cam->look_at.y - cam->pos.y;
    dz = cam->look_at.z - cam->pos.z;
    len = (float) sqrt( dx * dx + dz * dz );
    if ( len < 0.001f ) len = 0.001f;

    /* frame 0 is the gun held; the fire set runs at 10 Hz from the
       shot and holds its last frame until the weapon is ready again.
       The nailgun cycles its eight while fire is held, as
       player_nail1/2 do. */
    frame = 0;
    if ( rdr->anim_time < fight->next_fire ) {
        frame = (short) ( 1 + (short) ( ( rdr->anim_time - fight->fire_at ) * 10.0f ) );
        if ( fight->weapon == PL_IT_NAILGUN || fight->weapon == PL_IT_SNG )
            frame = (short) ( 1 + ( (long) ( rdr->anim_time * 10.0f ) % 8 ) );
    }
    if ( frame >= ms->nframe ) frame = (short) ( ms->nframe - 1 );

    return mdl_draw_tris( ms->ntri, ms->nvert, frame, &eye,
                          dx / len, dz / len, len, -dy,
                          &ms->scale, &ms->origin, ms->vtx_hnd, ms->skin,
                          (float *) mtx_fin, xresh, yresh, z_near, dst, QGL_Z_OFF );
}

/*
 * The projectiles in flight, a box each: a lava ball red and yellow and
 * twice the size, a grenade brown, a nail dark with a bright end. No
 * spike.mdl -- the vertex pages are spoken for.
 */
short d_draw_spikes( Fight *fight, Mat4 *mtx_fin, float xresh, float yresh,
                      float z_near, QSurf dst )
{
    float *m = (float *) mtx_fin;
    short i, drawn = 0;

    for ( i = 0; i < PL_NAILS_MAX; i++ ) {
        Spike *s = &fight->nail[i];
        BspVec3 at;

        if ( !s->alive ) continue;
        at = s->pos;
        at.z -= 1.0f;
        if ( s->toss )
            drawn = (short) ( drawn + mdl_draw_box( &at, 4.0f, 8.0f, 1.0f, 0.0f, m,
                        xresh, yresh, z_near, dst, ENT_COL_RED, ENT_COL_YELLOW ) );
        else if ( s->grenade )
            drawn = (short) ( drawn + mdl_draw_box( &at, 2.0f, 4.0f, 1.0f, 0.0f, m,
                        xresh, yresh, z_near, dst, ENT_COL_BROWN, ENT_COL_BROWN ) );
        else
            drawn = (short) ( drawn + mdl_draw_box( &at, 1.0f, 2.0f, 1.0f, 0.0f, m,
                        xresh, yresh, z_near, dst, ENT_COL_BROWN, ENT_COL_WHITE ) );
    }
    return drawn;
}
