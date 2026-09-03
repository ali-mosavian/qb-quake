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

#include "mod_tex.h"
#include "bsphdr.h"  /* DiskMipTex */
#include "assets.h"
#include "dos.h"     /* memAlloc/memFree */
#include "sys.h"     /* sys_error */

static void modtex_fatal( char *what )
{
    sys_error( what );
}
/*
 * name: mod_link_anims
 * desc: Groups +0name, +1name ... into chains. A frame's name is '+'
 *       then a digit then the shared suffix, and the digit gives the
 *       order. Records, for every frame, where its chain starts and
 *       how long it is -- all d_draw_faces needs to pick a frame,
 *       given the chain is stored contiguously (an mkassets.py
 *       guarantee, not re-checked here, matching the original).
 */
static void mod_link_anims( World *world, DiskMipTex far *t_mip_inf, long texture_count )
{
    long i, j, chain0, n;
    char far *suffix;

    for ( i = 0; i < texture_count; i++ ) {
        if ( t_mip_inf[i].name[0] != '+' ) continue;
        if ( world->miptex[i].anim_count > 1 ) continue;   /* already claimed */

        suffix = t_mip_inf[i].name + 2;   /* skip '+' and the digit */
        chain0 = i;
        n = 0;

        for ( j = i; j < texture_count; j++ ) {
            if ( t_mip_inf[j].name[0] == '+' && _fstrncmp( t_mip_inf[j].name + 2, suffix, 14 ) == 0 )
                n++;
        }

        if ( n > 1 ) {
            for ( j = chain0; j < chain0 + n; j++ ) {
                world->miptex[j].anim_base  = (short) chain0;
                world->miptex[j].anim_count = (short) n;
            }
        }
    }
}

PRGB mod_load_textures( World *world, FILE *f, MapCounts *counts )
{
    long far *tex_offs;
    DiskMipTex far *t_mip_inf;
    long i;
    short j;
    PRGB pal;

    world->texinfo = (TexInfo far *) asset_load( "assets.zip::texinf.bld",
                                                  counts->tex_infos * (long) sizeof(TexInfo) );

    /* The numtex offset table: one long per texture, right after the
       lump's own leading numtex long mod_open already read. */
    tex_offs = (long far *) memAlloc( counts->textures * (long) sizeof(long) );
    if ( !tex_offs ) modtex_fatal( "out of memory for the texture offset table" );
    if ( fseek( f, counts->mip_tex_offs + 4, SEEK_SET ) != 0 ) modtex_fatal( "mip_tex offsets seek failed" );
    for ( i = 0; i < counts->textures; i++ ) {
        long o;
        if ( fread( &o, sizeof(long), 1, f ) != 1 ) modtex_fatal( "mip_tex offsets short read" );
        tex_offs[i] = o;
    }

    t_mip_inf = (DiskMipTex far *) memAlloc( counts->textures * (long) sizeof(DiskMipTex) );
    world->miptex = (MipTex far *) memAlloc( counts->textures * (long) sizeof(MipTex) );
    if ( !t_mip_inf || !world->miptex ) modtex_fatal( "out of memory for texture headers" );

    for ( i = 0; i < counts->textures; i++ ) {
        DiskMipTex hdr;

        if ( fseek( f, counts->mip_tex_offs + tex_offs[i], SEEK_SET ) != 0 )
            modtex_fatal( "texture header seek failed" );
        if ( fread( &hdr, sizeof(DiskMipTex), 1, f ) != 1 )
            modtex_fatal( "texture header short read" );
        _fmemcpy( &t_mip_inf[i], &hdr, sizeof(DiskMipTex) );

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
    }

    memFree( (void far *) tex_offs );

    /*
     * The pixels: two atlases, four views each. A cell is a FLAT run
     * of cell*cell bytes, not a window on the 8192-wide image -- the
     * fillers map one page and walk the cell by the VIEW's own bps.
     * The placement is READ, not re-derived: mkassets.py owns the
     * layout. BMP_OPT_NO332 matters: without it uGL remaps the image
     * to its own 3-3-2 palette and the indices, already correct,
     * would be destroyed.
     */
    world->tex_raw    = uglNewBMPEx( UGL_EMS, UGL_8BIT, "assets.zip::texr.bmp", BMP_OPT_NO332 );
    world->tex_shaded = uglNewBMPEx( UGL_EMS, UGL_8BIT, "assets.zip::texs.bmp", BMP_OPT_NO332 );
    if ( !world->tex_raw || !world->tex_shaded ) modtex_fatal( "texture atlas would not load" );

    /* texofs.bld is sized to the map's own texture count (mkassets.py:
       ntex*MIPS longs), not to tex_ofs[]'s fixed 256-texture capacity --
       asset_load demands an exact byte count, so a fixed sizeof() here
       is always wrong except at the one texture count that happens to
       fill the array. asset_load_whole reads whatever the file holds. */
    {
        long n;
        unsigned char far *ofsbuf = asset_load_whole( "assets.zip::texofs.bld", &n );
        _fmemcpy( world->tex_ofs, ofsbuf, n );
        memFree( (void far *) ofsbuf );
    }

    for ( j = 0; j < 4; j++ ) {
        world->tex_cell[j]    = (short) ( 64 >> j );
        world->tex_aim_raw[j] = -1;
        world->tex_aim_shd[j] = -1;

        world->tex_v_raw[j]    = uglNewView( world->tex_raw, 0, world->tex_cell[j], world->tex_cell[j] );
        world->tex_v_shaded[j] = uglNewView( world->tex_shaded, 0, world->tex_cell[j], world->tex_cell[j] );
        if ( !world->tex_v_raw[j] || !world->tex_v_shaded[j] ) modtex_fatal( "no room for a texture view" );
    }

    mod_link_anims( world, t_mip_inf, counts->textures );
    memFree( (void far *) t_mip_inf );

    /* The palette is still loaded here because vid.c's v_init
       installs it and frees it -- nothing in this routine looks at
       its contents. */
    pal = uglPalLoad( "base.dat::color/palette.lmp", PAL_RGB );

    return pal;
}

PDC mod_tex_raw( World *world, short k, short mip )
{
    if ( world->tex_aim_raw[mip] != k ) {
        if ( !uglSetView( world->tex_v_raw[mip], world->tex_ofs[ (long) k*4 + mip ] ) ) return 0;
        world->tex_aim_raw[mip] = k;
    }
    return world->tex_v_raw[mip];
}

PDC mod_tex_shaded( World *world, short k, short mip )
{
    if ( world->tex_aim_shd[mip] != k ) {
        if ( !uglSetView( world->tex_v_shaded[mip], world->tex_ofs[ (long) k*4 + mip ] ) ) return 0;
        world->tex_aim_shd[mip] = k;
    }
    return world->tex_v_shaded[mip];
}

long world_tex_ofs_ptr( World *world )
{
    return (long) (void far *) world->tex_ofs;
}
