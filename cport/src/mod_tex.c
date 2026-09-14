/*
 * mod_tex.c -- reading texture headers and handing the preprocessed
 * bitmaps to uGL, in the game palette. C port of mod_tex.bas. The
 * resampling and colour matching mod_tex.bas used to do at load
 * happen offline now, in tools/mkassets.py -- this only reads the
 * headers (for the per-texture scale factor and animation/liquid
 * classification) and re-aims views onto the pre-built atlases.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "qgl.h"

#include "mod_tex.h"
#include "bsphdr.h"  /* DiskMipTex */
#include "assets.h"
#include "sys.h"     /* sys_error */
#include "qglsurf.h"  /* qgl_surf_from_file, TEX_ATLAS_W/LM_ATLAS_W */
#include "d_sky.h"

static void modtex_fatal( char *what )
{
    sys_error( what );
}
/*
 * name: mod_link_anims
 * desc: Groups +0name, +1name ... into chains. The digit gives the
 *       frame order and the text after it names the chain.
 *
 *       Chains are NOT contiguous in the miptex lump and never were:
 *       e1m1 has +0planet at 55 with +1..+3planet at 70..72, and
 *       +0slip at 56 with +1..+6slip at 73..78. The first version of
 *       this counted the frames, then stamped that many CONSECUTIVE
 *       entries starting at the first one -- so "planet" claimed 55,
 *       56, 57, 58, and drawing planet frame 1 fetched +0slip. On
 *       screen: a wall cycling through three unrelated textures. It
 *       survived because dm3ish has no +N textures at all, and the
 *       comment here asserted a contiguity "guarantee" from
 *       mkassets.py that mkassets.py does not make.
 *
 *       So the frame order is written down instead of assumed:
 *       world->anim_tab holds each chain's texture indices back to
 *       back, anim_base indexes INTO THAT, and anim_count is its
 *       length. d_draw_faces reads anim_tab[base + frame % count].
 *
 *       +a..+j are Quake's alternate animation, switched by an entity
 *       state this renderer has no notion of. They are skipped rather
 *       than folded into the main chain, which is what made
 *       +abasebtn a fourth "frame" of basebtn.
 */
static void mod_link_anims( World *world, DiskMipTex far *t_mip_inf, long texture_count )
{
    long i, j, k;
    short frame[10], nf, d, best, bi;
    char far *suffix;
    short used = 0;

    /* Counted first, then allocated to fit. e1m1 has 16 frames across
       its chains against 81 textures, so sizing this to texture_count
       would waste 130 bytes -- and on e1m1 the conventional heap is
       tight enough that sc_init is already failing, which makes even
       that worth not spending. No animated textures at all means no
       table. */
    {
        long want = 0;
        for ( i = 0; i < texture_count; i++ )
            if ( t_mip_inf[i].name[0] == '+' &&
                 t_mip_inf[i].name[1] >= '0' && t_mip_inf[i].name[1] <= '9' )
                want++;
        if ( want < 2 ) return;
        world->anim_tab = (short far *) qglMemAlloc( want * (long) sizeof(short) );
        if ( !world->anim_tab ) modtex_fatal( "out of memory for the animation table" );
    }

    for ( i = 0; i < texture_count; i++ ) {
        if ( t_mip_inf[i].name[0] != '+' ) continue;
        if ( world->miptex[i].anim_count > 1 ) continue;   /* already claimed */
        if ( t_mip_inf[i].name[1] < '0' || t_mip_inf[i].name[1] > '9' ) continue;

        suffix = t_mip_inf[i].name + 2;
        nf = 0;

        for ( j = i; j < texture_count && nf < 10; j++ ) {
            if ( t_mip_inf[j].name[0] != '+' ) continue;
            if ( t_mip_inf[j].name[1] < '0' || t_mip_inf[j].name[1] > '9' ) continue;
            if ( _fstrncmp( t_mip_inf[j].name + 2, suffix, 14 ) != 0 ) continue;
            frame[nf++] = (short) j;
        }

        if ( nf < 2 ) continue;

        /* By the digit, not by lump order: nothing says +1 is stored
           after +0, and on e1m1 several chains are interleaved. */
        for ( k = 0; k < nf - 1; k++ ) {
            bi = (short) k;
            best = (short)( t_mip_inf[ frame[k] ].name[1] );
            for ( j = k + 1; j < nf; j++ ) {
                d = (short)( t_mip_inf[ frame[j] ].name[1] );
                if ( d < best ) { best = d; bi = (short) j; }
            }
            if ( bi != k ) { d = frame[k]; frame[k] = frame[bi]; frame[bi] = d; }
        }

        for ( k = 0; k < nf; k++ ) {
            world->anim_tab[ used + k ] = frame[k];
            world->miptex[ frame[k] ].anim_base  = used;
            world->miptex[ frame[k] ].anim_count = nf;
        }
        used = (short)( used + nf );
    }
}

PalRgb far * mod_load_textures( World *world, MapCounts *counts )
{
    DiskMipTex far *t_mip_inf;
    long i;
    short j;
    PalRgb far *pal;

    world->texinfo = (TexInfo far *) asset_load( "texinf.bld",
                                                  counts->tex_infos * (long) sizeof(TexInfo) );

    /* The miptex headers, which used to be seeked out of the raw .bsp
       one at a time -- the only thing this program still opened it for.
       mkassets ships them back to back instead, one per texture the map
       owns; a texture the map lists with no lump is 40 zero bytes,
       which is a blank name, which is neither a liquid nor a chain. */
    t_mip_inf = (DiskMipTex far *) asset_load( "miptex.bin",
                                                counts->textures * (long) sizeof(DiskMipTex) );
    world->miptex = (MipTex far *) qglMemAlloc( counts->textures * (long) sizeof(MipTex) );
    if ( !world->miptex ) modtex_fatal( "out of memory for texture headers" );

    for ( i = 0; i < counts->textures; i++ ) {
        DiskMipTex hdr;

        _fmemcpy( &hdr, &t_mip_inf[i], sizeof(DiskMipTex) );

        /* The renderer scales texture axes by the reciprocal of the
           ORIGINAL texture size, so these dimensions are still needed
           even though the pixels come from the atlas bitmaps. */
        world->miptex[i].wdth = 1.0f / (float) hdr.wdth;
        world->miptex[i].hght = 1.0f / (float) hdr.hght;

        /* Quake encodes what a texture does in its name: a leading
           '*' is a liquid, which flows; a leading '+N' is one frame
           of an animation, the rest of whose frames share the name
           after the digit. */
        world->miptex[i].liquid     = 0;
        world->miptex[i].anim_base  = (short) i;
        world->miptex[i].anim_count = 1;
        if ( hdr.name[0] == '*' ) world->miptex[i].liquid = -1;
        world->miptex[i].sky = ( ( hdr.name[0] | 32 ) == 's' && ( hdr.name[1] | 32 ) == 'k' &&
                                 ( hdr.name[2] | 32 ) == 'y' );
    }

    /*
     * The pixels: two atlases, four views each. A cell is a FLAT run
     * of cell*cell bytes, not a window on the 8192-wide image -- the
     * fillers map one page and walk the cell by the VIEW's own bps.
     * The placement is READ, not re-derived: mkassets.py owns the
     * layout. These are RAW byte streams, not BMPs: mgl needed
     * BMP_OPT_NO332 to stop it remapping already-correct indices into
     * its own 3-3-2 palette, and qgl has no decoder to defend against.
     */
    world->tex_raw    = qgl_surf_from_member( "texr.raw", TEX_ATLAS_W, QGL_SURF_EMS, 0 );
    world->tex_shaded = qgl_surf_from_member( "texs.raw", TEX_ATLAS_W, QGL_SURF_EMS, 0 );
    if ( !world->tex_raw || !world->tex_shaded ) modtex_fatal( "texture atlas would not load" );

    /* texofs.bld is sized to the map's own texture count (mkassets.py:
       ntex*MIPS longs), not to tex_ofs[]'s fixed 256-texture capacity --
       asset_load demands an exact byte count, so a fixed sizeof() here
       is always wrong except at the one texture count that happens to
       fill the array. asset_load_whole reads whatever the file holds. */
    {
        long n;
        unsigned char far *ofsbuf = asset_load_whole( "texofs.bld", &n );
        _fmemcpy( world->tex_ofs, ofsbuf, n );
        qglMemFree( (long) ofsbuf );
    }

    /* A view's address table is its HEIGHT's, and qglSfViewShape can
       change the width but not that -- so it is one view per height,
       made when a texture of that height is first drawn, exactly as the
       surface cache's five are. A map uses a handful. */
    for ( j = 0; j < TEX_HEIGHTS; j++ ) {
        world->tex_v_raw[j]    = 0;
        world->tex_v_shaded[j] = 0;
        world->tex_aim_raw[j]  = -1;
        world->tex_aim_shd[j]  = -1;
    }

    mod_link_anims( world, t_mip_inf, counts->textures );
    d_sky_init( world );
    qglMemFree( (long) t_mip_inf );

    /* pal.raw, not base.dat: base.dat is a Quake PACK and qgl links a
       zip driver only, so there is nothing to open it with. mkassets
       writes the 768 bytes loose beside the exe and the qgl renderer
       reads them the same way -- r, g, b per entry, 8 bits each.

       Still loaded here because vid.c's v_init installs it and frees
       it; nothing in this routine looks at its contents. */
    pal = (PalRgb far *) asset_load( "pal.raw", 768L );

    return pal;
}

/* Aim one view of the right height at cell (k, mip) and give it that
   cell's width. `aim` is per height slot, so consecutive faces sharing a
   texture still cost the compare and nothing else. */
static QSurf tex_view( World *world, short k, short mip, QSurf atlas,
                       QSurf far *views, short far *aim )
{
    /* mkassets.py packs log2 of the cell width into bits 23..26 of the
       entry and log2 of the height into 27..30, which is what lets a
       texture keep its own size and aspect instead of being squeezed
       into a square. The low 23 bits are the offset. */
    long  ent = world->tex_ofs[ (long) k*4 + mip ];
    short cw  = (short) ( 1 << ( ( ent >> 23 ) & 15 ) );
    short ch  = (short) ( 1 << ( ( ent >> 27 ) & 15 ) );
    short hi  = (short) ( ( ent >> 27 ) & 15 );
    short key = (short) ( k*4 + mip );

    if ( hi >= TEX_HEIGHTS ) return 0;
    if ( !views[hi] ) {
        /* qglSfViewNew, not qglNewView: a cell can be narrower than
           eight (mip 2 of a 16x128 texture is 4x32) and qglNewView
           rounds bps up to a multiple of 8, which for a view is rows
           that are not where the parent's bytes are. This one takes the
           stride. */
        views[hi] = qglSfViewNew( atlas, cw, ch, cw );
        if ( !views[hi] ) return 0;
        aim[hi] = -1;
    }
    if ( aim[hi] != key ) {
        if ( !qglSfViewShape( views[hi], cw, ent & 0x007FFFFFL ) ) return 0;
        aim[hi] = key;
    }
    return views[hi];
}

QSurf mod_tex_raw( World *world, short k, short mip )
{
    return tex_view( world, k, mip, world->tex_raw,
                     world->tex_v_raw, world->tex_aim_raw );
}

QSurf mod_tex_shaded( World *world, short k, short mip )
{
    return tex_view( world, k, mip, world->tex_shaded,
                     world->tex_v_shaded, world->tex_aim_shd );
}

long world_tex_ofs_ptr( World *world )
{
    return (long) (void far *) world->tex_ofs;
}
