/*
 * screen.c -- see screen.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mem.h>       /* _fmemcpy */

#include "screen.h"
#include "uglpatch.h"  /* RGB/uglPalGet/uglPSet/uglShadeRect/uglPalBestFit */
#include "assets.h"    /* asset_load_whole */
#include "dos.h"       /* memFree */
#include "mod.h"       /* mod_cm_map */

/* One bit of glyph[ch][bit/16], MSB first within each word -- ported
   verbatim from draw_load_font's own bit-extraction loop rather than
   re-derived, since guessing at the byte/word order would silently
   swap which pixels are set. */
static short font_bit( Font far *font, unsigned char ch, short x, short y )
{
    short bit = (short)( y * 8 + x );
    short word_idx = (short)( bit >> 4 );
    short bitpos = (short)( 15 - ( bit & 15 ) );
    return (short) ( ( font->glyph[ch][word_idx] >> bitpos ) & 1 );
}

void font_load( Font far *font, char *flname )
{
    long n;
    unsigned char far *buf = asset_load_whole( flname, &n );
    /* 4-byte "font" id, then 256 glyphs of 4 words (8 bytes) each. */
    _fmemcpy( font->glyph, buf + 4, 256 * 8 );
    memFree( (void far *) buf );
}

void draw_string( Hud far *hud, PDC dc, short x, short y, char *text, long col )
{
    short i, gx, gy, posx = x;

    for ( i = 0; text[i]; i++ ) {
        unsigned char ch = (unsigned char) text[i];
        for ( gy = 0; gy < 8; gy++ )
            for ( gx = 0; gx < 8; gx++ )
                if ( font_bit( &hud->font, ch, gx, gy ) )
                    uglPSet( dc, (short)(posx+gx), (short)(y+gy), col );
        posx = (short) ( posx + 4 );
    }
}

void draw_string_r( Hud far *hud, PDC dc, short x, short y, char *text, long col )
{
    draw_string( hud, dc, (short) ( x - 4 * (short) strlen( text ) ), y, text, col );
}

void hud_num( Hud far *hud, PDC dc, short x, short y, short sc, char *txt, long col )
{
    short i, gx, gy, px, bx, by, pass;

    for ( pass = 0; pass < 2; pass++ ) {
        px = x;
        for ( i = 0; txt[i]; i++ ) {
            unsigned char ch = (unsigned char) txt[i];
            for ( gy = 0; gy < 8; gy++ ) {
                for ( gx = 0; gx < 8; gx++ ) {
                    if ( font_bit( &hud->font, ch, gx, gy ) ) {
                        bx = (short) ( px + gx*sc );
                        by = (short) ( y + gy*sc );
                        if ( pass == 0 )
                            uglRectF( dc, (short)(bx+1), (short)(by+1), (short)(bx+sc), (short)(by+sc), hud->hc_slablo );
                        else
                            uglRectF( dc, bx, by, (short)(bx+sc-1), (short)(by+sc-1), col );
                    }
                }
            }
            px = (short) ( px + 4*sc + 1 );
        }
    }
}

void scr_hud_colors( Hud far *hud )
{
    RGB pal[256];

    uglPalGet( 0, 256, (RGB far *) pal );

    hud->hc_bg     = uglPalBestFit( (RGB far *) pal,  12,  10,   8 );
    hud->hc_slab   = uglPalBestFit( (RGB far *) pal,  52,  40,  28 );
    hud->hc_slabhi = uglPalBestFit( (RGB far *) pal, 104,  84,  60 );
    hud->hc_slablo = uglPalBestFit( (RGB far *) pal,  18,  14,  10 );
    hud->hc_hist   = uglPalBestFit( (RGB far *) pal, 150, 104,  56 );
    hud->hc_peak   = uglPalBestFit( (RGB far *) pal, 252, 216, 128 );
    hud->hc_meter  = uglPalBestFit( (RGB far *) pal, 200, 128,  56 );
    hud->hc_good   = uglPalBestFit( (RGB far *) pal, 244, 196,  92 );
    hud->hc_warn   = uglPalBestFit( (RGB far *) pal, 224, 164,  48 );
    hud->hc_bad    = uglPalBestFit( (RGB far *) pal, 216,  52,  36 );
    /* stands in for the original's fixed LP_TEXT index -- see hud.h's
       own note on why this is best-fit rather than assumed. */
    hud->hc_text   = uglPalBestFit( (RGB far *) pal, 240, 232, 216 );

    hud->hud_flash  = 0;
    hud->hud_pevict = 0;
    hud->hud_pflush = 0;
}

void hud_shade( World *world, Hud far *hud, PDC dc, short x0, short y0, short x1, short y1, short rw )
{
    if ( world->cmap_dc == 0 ) {
        uglRectF( dc, x0, y0, x1, y1, hud->hc_slab );
        return;
    }
    uglShadeRect( dc, x0, y0, x1, y1, (long) (void far *) mod_cm_map( world ), rw );
}

void hud_panel( World *world, Hud far *hud, PDC dc, short x, short y, short w, short h, char *title )
{
    hud_shade( world, hud, dc, x, y, (short)(x+w), (short)(y+h), 46 );
    uglHLine( dc, x, y, (short)(x+w), hud->hc_slabhi );
    uglVLine( dc, x, y, (short)(y+h), hud->hc_slabhi );
    uglHLine( dc, x, (short)(y+h), (short)(x+w), hud->hc_slablo );
    uglVLine( dc, (short)(x+w), y, (short)(y+h), hud->hc_slablo );

    uglPSet( dc, (short)(x+2),   (short)(y+2),   hud->hc_slabhi );
    uglPSet( dc, (short)(x+3),   (short)(y+3),   hud->hc_slablo );
    uglPSet( dc, (short)(x+w-3), (short)(y+2),   hud->hc_slabhi );
    uglPSet( dc, (short)(x+w-2), (short)(y+3),   hud->hc_slablo );
    uglPSet( dc, (short)(x+2),   (short)(y+h-3), hud->hc_slabhi );
    uglPSet( dc, (short)(x+3),   (short)(y+h-2), hud->hc_slablo );
    uglPSet( dc, (short)(x+w-3), (short)(y+h-3), hud->hc_slabhi );
    uglPSet( dc, (short)(x+w-2), (short)(y+h-2), hud->hc_slablo );

    /* the title sits in the top rule, so blank the run it occupies */
    uglHLine( dc, (short)(x+5), y, (short)( x+8+(short)strlen(title)*4 ), hud->hc_slab );
    draw_string( hud, dc, (short)(x+7), (short)(y-3), title, hud->hc_text );
}

void hud_row( Hud far *hud, PDC dc, short x, short w, short y, char *label, char *value )
{
    draw_string( hud, dc, (short)(x+5), y, label, hud->hc_text );
    draw_string_r( hud, dc, (short)(x+w-5), y, value, hud->hc_text );
}

void hud_bar( Hud far *hud, PDC dc, short x, short y, short w, short h, float percent )
{
    short f;
    if ( percent < 0.0f ) percent = 0.0f;
    if ( percent > 100.0f ) percent = 100.0f;
    f = (short) ( ( w * percent ) / 100.0f );

    uglRectF( dc, x, y, (short)(x+w), (short)(y+h), hud->hc_bg );
    uglRect( dc, x, y, (short)(x+w), (short)(y+h), hud->hc_slablo );
    if ( f > 1 ) uglRectF( dc, (short)(x+1), (short)(y+1), (short)(x+f-1), (short)(y+h-1), hud->hc_meter );
}

void hud_graph( Hud far *hud, PDC dc, short x, short y, short h, short *buf, short mx )
{
    short i, k, v, c, top;

    if ( mx < 1 ) mx = 1;

    uglRectF( dc, x, y, (short)(x+GRAPH_N), (short)(y+h), hud->hc_bg );

    for ( i = 0; i < GRAPH_N; i += 3 ) {
        uglPSet( dc, (short)(x+i), (short)(y+1), hud->hc_slablo );
        uglPSet( dc, (short)(x+i), (short)(y+h/2), hud->hc_slablo );
    }

    for ( i = 0; i < GRAPH_N; i++ ) {
        k = (short) ( ( hud->g_head + i ) % GRAPH_N );
        v = buf[k];
        if ( v > 0 ) {
            top = (short) ( ( (long) v * h ) / mx );
            if ( top > h ) top = h;
            c = (short) ( v >= mx ? hud->hc_peak : hud->hc_hist );
            uglVLine( dc, (short)(x+i), (short)(y+h-top), (short)(y+h), c );
        }
    }
    uglRect( dc, x, y, (short)(x+GRAPH_N), (short)(y+h), hud->hc_slablo );
}

void scr_draw_hud( World *world, Renderer *rdr, Camera *cam, Player *player,
                    SurfCache far *sc, Hud far *hud, PDC h_dst_dc, short w, short h )
{
    CacheStats scs;
    short lx, rx, cw, yy, fcol, wide;
    char buf[80], ftr[128];
    float dxv, dyv, ayv, yawd;

    cw = 146;
    lx = 3;
    rx = (short) ( w - cw - 3 );

    /* Two columns need 2*cw and the gaps between them -- narrower than
       that (the real stuff.ini render width, 160, is exactly this
       case) drops the right column rather than draw it over the
       left: the right column is the map's static counts, the left is
       what changes per frame. */
    wide = (short) ( rx > lx + cw );

    if ( hud->stats ) {
        hud_panel( world, hud, h_dst_dc, lx, 6, cw, 76, "RENDER" );

        if ( hud->fps >= 30 )      fcol = hud->hc_good;
        else if ( hud->fps >= 15 ) fcol = hud->hc_warn;
        else                       fcol = hud->hc_bad;

        sprintf( buf, "%d", hud->fps );
        hud_num( hud, h_dst_dc, (short)(lx+6), 13, 2, buf, fcol );
        draw_string( hud, h_dst_dc, (short)(lx+34), 18, "fps", hud->hc_text );

        sprintf( buf, "%d", rdr->polys );
        hud_row( hud, h_dst_dc, lx, cw, 30, "Polygons", buf );
        sprintf( buf, "%d", rdr->tris );
        hud_row( hud, h_dst_dc, lx, cw, 38, "Triangles", buf );
        sprintf( buf, "%d/%d", rdr->drw_leafs, rdr->cul_leafs );
        hud_row( hud, h_dst_dc, lx, cw, 46, "Leaves drawn/culled", buf );
        sprintf( buf, "%d", rdr->pt_culled );
        hud_row( hud, h_dst_dc, lx, cw, 54, "Leaves portal-cut", buf );
        draw_string( hud, h_dst_dc, (short)(lx+5), 60, "fps 60", hud->hc_text );
        hud_graph( hud, h_dst_dc, (short)(lx+cw-GRAPH_N-5), 59, 17, hud->g_fps, 60 );

        /* left, below: the surface cache -- builds-in-one-frame is
           what a hitch is made of, so it leads, and the worst frame
           is kept because an average over a run hides the spike. */
        sc_stats( sc, &scs );

        hud_panel( world, hud, h_dst_dc, lx, 90, cw, 78, "SURFACE CACHE" );

        /* Warning flash: evictions and flushes are the events being
           hunted, so the panel calls attention to itself when one
           lands rather than waiting to be read. */
        if ( scs.evict > hud->hud_pevict || scs.flushes > hud->hud_pflush ) hud->hud_flash = 12;
        hud->hud_pevict = scs.evict;
        hud->hud_pflush = scs.flushes;
        if ( hud->hud_flash > 0 ) {
            if ( ( hud->hud_flash & 2 ) != 0 )
                uglRect( h_dst_dc, lx, 90, (short)(lx+cw), (short)(90+78), hud->hc_bad );
            hud->hud_flash--;
        }

        sprintf( buf, "%d/%d", scs.hits, scs.builds );
        hud_row( hud, h_dst_dc, lx, cw, 96, "Hit / built", buf );
        sprintf( buf, "%d", scs.bpeak );
        hud_row( hud, h_dst_dc, lx, cw, 104, "Worst frame", buf );
        sprintf( buf, "%ld", scs.live );
        hud_row( hud, h_dst_dc, lx, cw, 112, "Resident", buf );
        sprintf( buf, "%ld", scs.evict );
        hud_row( hud, h_dst_dc, lx, cw, 120, "Evicted", buf );
        sprintf( buf, "%ld", scs.flushes );
        hud_row( hud, h_dst_dc, lx, cw, 128, "Flushes", buf );

        /* the store as a proportion of what it can hold, which a bare
           kilobyte count never conveys */
        draw_string( hud, h_dst_dc, (short)(lx+5), 136, "Store", hud->hc_text );
        hud_bar( hud, h_dst_dc, (short)(lx+cw-GRAPH_N-5), 136, GRAPH_N, 6,
                 (float) ( scs.peak * 100.0 / 4194304.0 ) );
        sprintf( buf, "builds %d", scs.bpeak );
        draw_string( hud, h_dst_dc, (short)(lx+5), 146, buf, hud->hc_text );
        hud_graph( hud, h_dst_dc, (short)(lx+cw-GRAPH_N-5), 145, 17, hud->g_bld, scs.bpeak );

        /* right: the map, which never changes while it is loaded */
        if ( wide ) {
            hud_panel( world, hud, h_dst_dc, rx, 6, cw, 56, "WORLD" );
            sprintf( buf, "%dx%d", w, h );
            hud_row( hud, h_dst_dc, rx, cw, 12, "Resolution", buf );
            sprintf( buf, "%d", world->vert_count );
            hud_row( hud, h_dst_dc, rx, cw, 20, "Vertices", buf );
            sprintf( buf, "%d", world->edge_count );
            hud_row( hud, h_dst_dc, rx, cw, 28, "Edges", buf );
            sprintf( buf, "%d", world->face_count );
            hud_row( hud, h_dst_dc, rx, cw, 36, "Faces", buf );
            sprintf( buf, "%d", world->node_count );
            hud_row( hud, h_dst_dc, rx, cw, 44, "Nodes", buf );
            sprintf( buf, "%d", world->leaf_count );
            hud_row( hud, h_dst_dc, rx, cw, 52, "Leaves", buf );
        }

        /* one footer line for every toggle, in the order of the keys */
        strcpy( ftr, "F1 mip " );
        strcat( ftr, rdr->use_mips ? "ON " : "off" );
        strcat( ftr, rdr->rend_mode == 0 ? "   F2 perspective" : "   F2 wireframe  " );
        strcat( ftr, "   B cull " );
        strcat( ftr, rdr->backface ? "ON " : "off" );
        strcat( ftr, "   L lm " );
        strcat( ftr, rdr->lightmap ? "ON " : "off" );
        strcat( ftr, "   P portal " );
        strcat( ftr, rdr->portal ? "ON " : "off" );
        strcat( ftr, "   O ptl " );
        strcat( ftr, hud->portal_wire ? "ON " : "off" );
        strcat( ftr, "   F12 hide" );

        yy = (short) ( h - 9 );
        uglRectF( h_dst_dc, 0, (short)(yy-2), w, h, hud->hc_bg );
        uglHLine( h_dst_dc, 0, (short)(yy-2), w, hud->hc_slabhi );
        draw_string( hud, h_dst_dc, 4, yy, ftr, hud->hc_text );
    } else {
        yy = (short) ( h - 9 );
        draw_string( hud, h_dst_dc, 4, yy, "F12 stats", hud->hc_text );
    }

    /* Where the camera is, always -- with or without the stats panel,
       drawn last so the panel cannot cover it. pl.pos, not cam.pos:
       -at takes the hull origin, and the eye is PL_EYE above it. The
       yaw is mirrored the way -yaw wants (the eye direction is
       (cos a, -sin a) in bsp x,y) and normalised to 0..360, since
       -yaw is fed to mousePos as (x_res-1)*yaw/360 and a negative
       angle is a negative screen x. */
    dxv = cam->look_at.x - cam->pos.x;
    dyv = cam->look_at.z - cam->pos.z;
    ayv = -dyv;

    if ( dxv > 0.0f ) {
        yawd = (float) ( atan( ayv / dxv ) * 57.29578 );
    } else if ( dxv < 0.0f ) {
        if ( ayv >= 0.0f ) yawd = (float) ( atan( ayv / dxv ) * 57.29578 + 180.0 );
        else               yawd = (float) ( atan( ayv / dxv ) * 57.29578 - 180.0 );
    } else if ( ayv >= 0.0f ) {
        yawd = 90.0f;
    } else {
        yawd = -90.0f;
    }
    if ( yawd < 0.0f ) yawd += 360.0f;

    sprintf( buf, "at: [%d,%d,%d]  yaw: [%d]",
             (int) player->pos.x, (int) player->pos.y, (int) player->pos.z, (int) yawd );

    uglRectF( h_dst_dc, 0, 0, w, 9, hud->hc_bg );
    draw_string( hud, h_dst_dc, 4, 1, buf, hud->hc_text );

    /* Frame rate, top right, in the same always-drawn bar -- worth
       having whether or not the stats panel is up. */
    sprintf( buf, "fps: [%d]", hud->fps );
    draw_string_r( hud, h_dst_dc, (short)(w-4), 1, buf, hud->hc_text );
}

void scr_count_frame( Hud far *hud, Renderer *rdr, SurfCache far *sc, float frame_dt )
{
    hud->frame_count++;
    hud->fps_accum += frame_dt;

    if ( hud->fps_accum >= 1.0f ) {
        hud->fps = hud->frame_count;
        if ( hud->frame_count > hud->fps_peak ) hud->fps_peak = hud->frame_count;
        hud->frame_count = 0;
        hud->fps_accum -= 1.0f;   /* carry the remainder rather than drop it */
    }

    rdr->tris  = 0;
    rdr->polys = 0;

    hud->g_bld[hud->g_head] = sc_frame_end( sc );
    hud->g_fps[hud->g_head] = hud->fps;
    hud->g_head = (short) ( ( hud->g_head + 1 ) % GRAPH_N );
}

/* x86 is little-endian and so is BMP, so a direct fwrite of a native
   short/long's bytes needs no manual byte-order handling -- the
   original's mkl$/mki$ byte-packing existed only because BASIC's PUT
   has no other way to control binary layout, not because the target
   format differs from the host's own. */
static void put_u16( unsigned v, FILE *f ) { fwrite( &v, 2, 1, f ); }
static void put_u32( unsigned long v, FILE *f ) { fwrite( &v, 4, 1, f ); }

void scr_screenshot( char *flname, PDC dc, short w, short h )
{
    FILE *f;
    short x, y, pad;
    long  rowlen, imgsz, off_bits;
    RGB   palbuf[256];
    unsigned char row[2048];   /* w+pad never exceeds this at any mode
                                   this renderer supports (max 1600 wide) */

    pad     = (short) ( (4 - (w % 4)) % 4 );
    rowlen  = (long) w + pad;
    imgsz   = rowlen * (long) h;
    off_bits = 14 + 40 + 1024;

    if ( rowlen > (long) sizeof(row) ) return;   /* wider than any real mode */

    uglPalGet( 0, 256, (RGB far *) palbuf );

    f = fopen( flname, "wb" );
    if ( !f ) return;

    /* BITMAPFILEHEADER */
    fputc( 'B', f ); fputc( 'M', f );
    put_u32( (unsigned long) ( off_bits + imgsz ), f );
    put_u16( 0, f );
    put_u16( 0, f );
    put_u32( (unsigned long) off_bits, f );

    /* BITMAPINFOHEADER */
    put_u32( 40, f );
    put_u32( (unsigned long) w, f );
    put_u32( (unsigned long) h, f );
    put_u16( 1, f );
    put_u16( 8, f );
    put_u32( 0, f );
    put_u32( (unsigned long) imgsz, f );
    put_u32( 2835, f );
    put_u32( 2835, f );
    put_u32( 256, f );
    put_u32( 0, f );

    /* Palette, written BGRA. */
    for ( x = 0; x < 256; x++ ) {
        fputc( palbuf[x].blue,  f );
        fputc( palbuf[x].green, f );
        fputc( palbuf[x].red,   f );
        fputc( 0, f );
    }

    /* Pixels, bottom row first. Pad bytes stay zero. */
    for ( y = (short)( h - 1 ); y >= 0; y-- ) {
        for ( x = 0; x < w; x++ ) row[x] = (unsigned char) ( uglPGet( dc, x, y ) & 255 );
        for ( ; x < rowlen; x++ ) row[x] = 0;
        fwrite( row, 1, (size_t) rowlen, f );
    }

    fclose( f );
}
