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

#include "d_alias.h"
#include "item.h"
#include "qgl.h"
#include "mod_tex.h"

/* One quad at a time; nothing here recurses or holds two. */
static QVert qv[4];

/*
 * r_mdl_vis_c, without the BASIC array descriptors: the box against
 * the frustum, then its eight corners and its centre against the PVS,
 * each a descent of the tree. The near corner alone decides the
 * frustum test, as r_cull_box does -- there are no children to hand a
 * clip mask to.
 */
static short d_mdl_visible( World *world, Renderer *rdr, DiskPlane far *frustum,
                             BspVec3 *org, float radius, float zlo, float zhi )
{
    float lo[3], hi[3], px, py, pz, dp;
    short i, nodenr;

    lo[0] = org->x - radius; hi[0] = org->x + radius;
    lo[1] = org->y - radius; hi[1] = org->y + radius;
    lo[2] = org->z + zlo;    hi[2] = org->z + zhi;

    /* the frustum is renderer space, y up: the box's z goes in y */
    for ( i = 0; i < 6; i++ ) {
        px = frustum[i].norm.x > 0.0f ? lo[0] : hi[0];
        py = frustum[i].norm.y > 0.0f ? lo[2] : hi[2];
        pz = frustum[i].norm.z > 0.0f ? lo[1] : hi[1];
        dp = frustum[i].norm.x * px + frustum[i].norm.y * py + frustum[i].norm.z * pz;
        if ( dp + frustum[i].dist > 0.0f ) return 0;
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
        nodenr = 0;
        while ( !( nodenr & 0x8000 ) ) {
            Plane far *pl = &world->planes[ world->nodes[nodenr].plane_id ];
            dp = px * pl->norm.x + py * pl->norm.y + pz * pl->norm.z - pl->dist;
            nodenr = dp >= 0.0f ? world->nodes[nodenr].child0 : world->nodes[nodenr].child1;
        }
        nodenr = (short) ~nodenr;
        if ( nodenr > 0 && rdr->pvs_now[nodenr] ) return -1;
    }
    return 0;
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
                              ENT_BOX_HALF * 1.5f, 0.0f, ENT_BOX_TOP + 8.0f ) ) continue;

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
