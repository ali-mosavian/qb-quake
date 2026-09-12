/*
 * snd_mix.c -- Quake's S_PaintChannels for one 8-bit mono ring.
 *
 * Eight channels, each a run of samples in the EMS handle snd.bsc was
 * loaded into, mixed into the DMA ring dsp.asm plays, from where the
 * mixer last stopped to a quarter second past where the DMA is.
 * Thirty-two more are the map's ambients: S_StaticSound, looped from
 * sample 0 and re-spatialised from the player every frame.
 *
 * The paint buffer, the table and the channels live in the block
 * dsp.asm took from DOS, beyond its ring -- conventional memory this
 * program is short of, and the one place already sized for it.
 *
 * A sample is read through PAGE_SLOT, mapped fresh for every run and
 * held across nothing, the same way every other reader of that slot
 * behaves; the call sits between the tick and the render, where no one
 * else has a window open.
 *
 * It is not a byte on the way in. mksnd.py ships bsc4/32n -- 32 samples
 * a block, a scale byte and sixteen of 4-bit codes -- so snd_fetch
 * decodes a run into snd_dbuf through mksnd's own table and the paint
 * reads that. 963 blocks fit a 16K page and none straddles one, so a
 * block is still one window and a divide away.
 */

#include "snd_mix.h"
#include "qgl.h"

#define PAGE_SLOT   2
#define SND_RING    4096L
#define SND_CHANS   8               /* S_StartSound's */
#define SND_STATICS 32              /* the ambients', looping; a silent one costs its pointer arithmetic */
#define SND_ALL     (SND_CHANS + SND_STATICS)
#define SND_CHUNK   512
#define SND_BLK     32              /* samples a block, bsc4/32n */
#define SND_BLK_B   17              /* its bytes: the scale, then sixteen of codes */
#define SND_DTAB    512             /* 32 scales x 16 codes, mksnd.py's */
#define SND_NSCALE  32              /* and the scale byte selects one, so it is masked */
#define SND_TAB     1024            /* 128 (offset, length) records */
#define SND_AHEAD   2756L           /* a quarter second at 11025 */
#define EMS_PAGE    16384
#define SND_BLK_PG  (EMS_PAGE / SND_BLK_B)  /* 963; the page's last 13 bytes are padding */
#define SND_ATTN_STATIC 3L          /* ATTN_STATIC, per sound_nominal_clip_dist */
#define SND_CLIP_DIST   1000L

typedef struct { long pos, end, beg; short vol; } SndChan;  /* end 0: free; beg >= 0 loops */
typedef struct { short id, vol; float x, y, z; } SndAmb;

static short snd_hnd     = 0;
static short snd_count   = 0;
static short snd_lastpos = 0;
static short snd_under   = 0;
static short snd_namb    = 0;
static short snd_loops   = 0;
static long  snd_time    = 0;   /* samples the DMA has played */
static long  snd_painted = 0;   /* samples written */
static unsigned char far *snd_ring;
static int           far *snd_paint;        /* SND_CHUNK ints */
static SndRec        far *snd_tab;
static SndChan       far *snd_chan;
static SndAmb             snd_amb[SND_STATICS];
static signed char        snd_dtab[SND_DTAB];   /* scale row, then code */
static signed char        snd_dbuf[SND_CHUNK];  /* one run, decoded */

short snd_mix_ambient( short id, short vol, BspVec3 *org )
{
    if ( snd_namb >= SND_STATICS ) return -1;
    snd_amb[snd_namb].id  = id;
    snd_amb[snd_namb].vol = vol;
    snd_amb[snd_namb].x   = org->x;
    snd_amb[snd_namb].y   = org->y;
    snd_amb[snd_namb].z   = org->z;
    return snd_namb++;
}

short snd_mix_loops( void )
{
    return snd_loops;
}

short snd_mix_setup( short hnd, unsigned char far *ring, void far *scratch,
                      SndRec far *tab, short count, short scratch_bytes,
                      signed char far *dec )
{
    SndChan far *ch;
    short i;

    if ( count * 8 > SND_TAB ||
         SND_CHUNK * 2 + SND_TAB + SND_ALL * (short) sizeof(SndChan) > scratch_bytes )
        return -1;
    snd_hnd   = hnd;
    snd_count = count;
    snd_ring  = ring;
    snd_paint = (int far *) scratch;
    snd_tab   = (SndRec far *) ( (char far *) scratch + SND_CHUNK * 2 );
    snd_chan  = (SndChan far *) ( (char far *) snd_tab + SND_TAB );
    for ( i = 0; i < count; i++ ) snd_tab[i] = tab[i];
    for ( i = 0; i < SND_DTAB; i++ ) snd_dtab[i] = dec[i];
    for ( i = 0; i < SND_ALL; i++ ) snd_chan[i].end = 0;

    snd_loops = 0;
    for ( i = 0; i < snd_namb; i++ ) {
        if ( snd_amb[i].id < 0 || snd_amb[i].id >= count ) continue;
        ch = &snd_chan[SND_CHANS + i];
        ch->beg = ch->pos = snd_tab[ snd_amb[i].id ].ofs;
        ch->end = ch->beg + snd_tab[ snd_amb[i].id ].len;
        ch->vol = 0;
        snd_loops++;
    }
    snd_time = snd_painted = 0;
    snd_lastpos = snd_under = 0;
    return count;
}

short snd_mix_start( short id, short vol )
{
    short i, pick = 0;
    long  least = 0x7fffffffL, left;

    if ( id < 0 || id >= snd_count ) return -1;
    for ( i = 0; i < SND_CHANS; i++ ) {
        if ( snd_chan[i].end == 0 ) { pick = i; break; }
        left = snd_chan[i].end - snd_chan[i].pos;
        if ( left < least ) { least = left; pick = i; }
    }
    snd_chan[pick].pos = snd_tab[id].ofs;
    snd_chan[pick].end = snd_tab[id].ofs + snd_tab[id].len;
    snd_chan[pick].beg = -1;
    snd_chan[pick].vol = vol;
    return pick;
}

/*
 * name: snd_fetch
 * desc: n samples from pos, decoded into out. bsc4/32n: the block's
 *       scale byte picks one of 32 rows of mksnd.py's table and each
 *       4-bit code indexes it, so nothing here computes a gain and the
 *       runtime never meets the ladder. Answers how many it did --
 *       fewer than n at the end of a page, where the caller comes back
 *       for the rest -- and 0 when the page would not map.
 */
static short snd_fetch( long pos, short n, signed char *out )
{
    long  blk = pos >> 5;                       /* SND_BLK */
    short seg, k = 0, j, k0, run, nb;
    unsigned char far *p;
    signed char *row;

    seg = qglGemMap( snd_hnd, (short) ( blk / SND_BLK_PG ), PAGE_SLOT );
    if ( seg == 0 ) return 0;
    nb = (short) ( blk % SND_BLK_PG );
    p  = (unsigned char far *) ( ( (unsigned long) seg << 16 ) | (unsigned) ( nb * SND_BLK_B ) );
    k0 = (short) ( pos & (SND_BLK - 1) );
    nb = SND_BLK_PG - nb;                       /* blocks this page has left */
    if ( n > nb * SND_BLK - k0 ) n = (short) ( nb * SND_BLK - k0 );
    while ( k < n ) {
        row = &snd_dtab[ (short) ( p[0] & (SND_NSCALE - 1) ) << 4 ];
        run = SND_BLK - k0;
        if ( run > n - k ) run = (short) ( n - k );
        for ( j = 0; j < run; j++, k0++ )
            out[k + j] = row[ (k0 & 1) ? ( p[1 + (k0 >> 1)] >> 4 )
                                       : ( p[1 + (k0 >> 1)] & 15 ) ];
        k  = (short) ( k + run );
        k0 = 0;
        p += SND_BLK_B;
    }
    return n;
}

unsigned long snd_mix_sum( void )
{
    unsigned long sum = 0;
    long  pos, end;
    short i, k, n, got;

    for ( i = 0; i < snd_count; i++ ) {
        pos = snd_tab[i].ofs;
        end = pos + snd_tab[i].len;
        while ( pos < end ) {
            n = end - pos > SND_CHUNK ? SND_CHUNK : (short) ( end - pos );
            got = snd_fetch( pos, n, snd_dbuf );
            if ( got == 0 ) return 0;
            for ( k = 0; k < got; k++ )
                sum = sum * 31 + (unsigned char) ( snd_dbuf[k] + 128 );
            pos += got;
        }
    }
    return sum;
}

static void snd_mix_chan( SndChan far *ch, short n )
{
    long  left;
    short i = 0, run, k, vol = ch->vol, got;

    while ( i < n ) {
        if ( ch->pos >= ch->end ) {
            if ( ch->beg < 0 ) { ch->end = 0; return; }
            ch->pos = ch->beg;
        }
        left = ch->end - ch->pos;
        run = (short) ( n - i );
        if ( run > left ) run = (short) left;
        if ( vol == 0 ) { ch->pos += run; i = (short) ( i + run ); continue; }   /* out of earshot: keep time */
        got = snd_fetch( ch->pos, run, snd_dbuf );
        if ( got == 0 ) { ch->end = 0; return; }
        for ( k = 0; k < got; k++ )
            snd_paint[i + k] += ( snd_dbuf[k] * vol ) >> 3;
        i = (short) ( i + got );
        ch->pos += got;
    }
    if ( ch->pos >= ch->end && ch->beg < 0 ) ch->end = 0;
}

static long snd_isqrt( long v )
{
    long r = v, x = 1;

    if ( v <= 0 ) return 0;
    while ( r > x ) { r = (r + x) / 2; x = v / r; }
    return r;
}

/* SND_Spatialize for the statics: the ambient's volume less the
   distance's share of a third of a thousand units. */
static void snd_mix_place( BspVec3 *ear )
{
    SndChan far *ch;
    short i;
    long  dx, dy, dz, dist;

    for ( i = 0; i < snd_namb; i++ ) {
        ch = &snd_chan[SND_CHANS + i];
        if ( ch->end == 0 ) continue;
        dx = (long) ( snd_amb[i].x - ear->x );
        dy = (long) ( snd_amb[i].y - ear->y );
        dz = (long) ( snd_amb[i].z - ear->z );
        dist = snd_isqrt( dx * dx + dy * dy + dz * dz ) * SND_ATTN_STATIC;
        ch->vol = dist >= SND_CLIP_DIST ? 0
                : (short) ( (long) snd_amb[i].vol * (SND_CLIP_DIST - dist) / SND_CLIP_DIST );
    }
}

short snd_mix_frame( short pos, long adv, BspVec3 *ear )
{
    long  delta = (long) pos - snd_lastpos, endt;
    short n, ringpos, k, c;
    int   v;

    snd_mix_place( ear );
    if ( delta < 0 ) delta += SND_RING;
    while ( adv - delta > SND_RING / 2 ) { delta += SND_RING; adv -= SND_RING; }
    snd_lastpos = pos;
    snd_time += delta;
    if ( snd_painted < snd_time ) {
        if ( snd_painted ) snd_under++;
        snd_painted = snd_time;
    }

    /* and the paint, which runs whether or not anything is playing: an
       idle channel contributes zeros and the ring gets 128, silence.
       Skipping the write while every channel is idle would leave the
       last quarter second in the buffer, and the card plays it round
       and round -- the DMA never stops, so the mixer never does. */
    endt = snd_time + SND_AHEAD;
    while ( snd_painted < endt ) {
        n = (short) ( endt - snd_painted );
        if ( n > SND_CHUNK ) n = SND_CHUNK;
        ringpos = (short) ( snd_painted & (SND_RING - 1) );
        if ( n > (short) (SND_RING - ringpos) ) n = (short) ( SND_RING - ringpos );
        for ( k = 0; k < n; k++ ) snd_paint[k] = 0;
        for ( c = 0; c < SND_ALL; c++ )
            if ( snd_chan[c].end ) snd_mix_chan( &snd_chan[c], n );
        for ( k = 0; k < n; k++ ) {
            v = snd_paint[k] >> 5;
            if ( v > 127 ) v = 127; else if ( v < -128 ) v = -128;
            snd_ring[ringpos + k] = (unsigned char) ( v + 128 );
        }
        snd_painted += n;
    }
    return snd_under;
}
