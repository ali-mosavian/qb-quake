/*
 * snd_mix.c -- Quake's S_PaintChannels for one 8-bit mono ring.
 *
 * Eight channels, each a run of samples in the EMS handle mksnd.py's
 * snd.raw was loaded into, mixed into the DMA ring dsp.asm plays, from
 * where the mixer last stopped to a quarter second past where the DMA
 * is. Every buffer lives in the block dsp.asm took from DOS -- the ring,
 * then this module's scratch -- so nothing here sits in DGROUP but a
 * few scalars: that is BASIC's string space and it is what e1m1 runs
 * out of.
 *
 * A sample is read through PAGE_SLOT, mapped fresh for every run and
 * held across nothing, the same way every other reader of that slot
 * behaves; the call sits between the tick and the render, where no one
 * has a window open.
 */
extern short pascal far qglGemMap( short h, short pg, short slot );

#define PAGE_SLOT   2
#define SND_RING    4096L
#define SND_CHANS   8
#define SND_CHUNK   512
#define SND_AHEAD   2756L           /* a quarter second at 11025 */
#define EMS_PAGE    16384L

typedef struct { long pos, end; short vol; } SndChan;   /* end 0: free */
typedef struct { long ofs, len; } SndRec;
typedef union { long l; struct { unsigned short lo, hi; } w; } Split;

static short           near snd_hnd;
static short           near snd_count;
static short           near snd_lastpos;
static short           near snd_under;
static long            near snd_time;       /* samples the DMA has played */
static long            near snd_painted;    /* samples written */
static unsigned char far *snd_ring;
static int           far *snd_paint;        /* SND_CHUNK ints */
static SndRec        far *snd_tab;
static SndChan       far *snd_chan;

/* hnd: the samples' EMS handle; ring: the DMA ring; scratch: 1664 bytes
   for the paint buffer, the table and the channels; tab: count records
   of (offset, length) to copy in. */
short pascal far snd_mix_setup( short hnd, long ring, long scratch, long tab, short count )
{
    SndRec far *src = (SndRec far *) tab;
    short i;

    snd_hnd     = hnd;
    snd_count   = count;
    snd_ring    = (unsigned char far *) ring;
    snd_paint   = (int far *) scratch;
    snd_tab     = (SndRec far *) ((char far *) scratch + SND_CHUNK * 2);
    snd_chan    = (SndChan far *) ((char far *) snd_tab + 512);
    for ( i = 0; i < count; i++ )
        snd_tab[i] = src[i];
    for ( i = 0; i < SND_CHANS; i++ )
        snd_chan[i].end = 0;
    snd_time = snd_painted = 0;
    snd_lastpos = snd_under = 0;
    return count;
}

/* S_StartSound's channel pick: a free one, else the one with the least
   left to play. vol 1..255. */
short pascal far snd_mix_start( short id, short vol )
{
    short i, pick = 0;
    long  least = 0x7fffffffL, left;

    if ( id < 0 || id >= snd_count )
        return -1;
    for ( i = 0; i < SND_CHANS; i++ ) {
        if ( snd_chan[i].end == 0 ) { pick = i; break; }
        left = snd_chan[i].end - snd_chan[i].pos;
        if ( left < least ) { least = left; pick = i; }
    }
    snd_chan[pick].pos = snd_tab[id].ofs;
    snd_chan[pick].end = snd_tab[id].ofs + snd_tab[id].len;
    snd_chan[pick].vol = vol;
    return pick;
}

static void near snd_mix_chan( SndChan far *ch, short n )
{
    long  left = ch->end - ch->pos;
    short i = 0, run, off, k, vol = ch->vol, seg;
    unsigned char far *p;
    Split at;

    if ( left < n ) n = (short) left;
    while ( i < n ) {
        at.l = ch->pos;             /* page and offset from the two words: no long divide */
        seg = qglGemMap( snd_hnd, (short) ((at.w.hi << 2) | (at.w.lo >> 14)), PAGE_SLOT );
        if ( seg == 0 ) { ch->end = 0; return; }
        off = (short) (at.w.lo & (EMS_PAGE - 1));
        run = n - i;
        if ( run > (short) (EMS_PAGE - off) ) run = (short) (EMS_PAGE - off);
        p = (unsigned char far *) (((unsigned long) seg << 16) | (unsigned short) off);
        for ( k = 0; k < run; k++ )
            snd_paint[i + k] += ( ((int) p[k] - 128) * vol ) >> 3;
        i += run;
        ch->pos += run;
    }
    if ( ch->pos >= ch->end ) ch->end = 0;
}

/* pos: qglDspPos now; adv: the samples the frame's wall time is worth,
   which tells one wrap of the ring from two. Returns the underruns so
   far -- frames that found the DMA past what had been painted. */
short pascal far snd_mix_frame( short pos, long adv )
{
    long  delta = (long) pos - snd_lastpos, endt;
    short n, ringpos, k, c;
    int   v;

    if ( delta < 0 ) delta += SND_RING;
    while ( adv - delta > SND_RING / 2 ) { delta += SND_RING; adv -= SND_RING; }
    snd_lastpos = pos;
    snd_time += delta;
    if ( snd_painted < snd_time ) {
        if ( snd_painted ) snd_under++;
        snd_painted = snd_time;
    }
    endt = snd_time + SND_AHEAD;
    while ( snd_painted < endt ) {
        n = (short) (endt - snd_painted);
        if ( n > SND_CHUNK ) n = SND_CHUNK;
        ringpos = (short) (snd_painted & (SND_RING - 1));
        if ( n > (short) (SND_RING - ringpos) ) n = (short) (SND_RING - ringpos);
        for ( k = 0; k < n; k++ ) snd_paint[k] = 0;
        for ( c = 0; c < SND_CHANS; c++ )
            if ( snd_chan[c].end ) snd_mix_chan( &snd_chan[c], n );
        for ( k = 0; k < n; k++ ) {
            v = snd_paint[k] >> 5;
            if ( v > 127 ) v = 127; else if ( v < -128 ) v = -128;
            snd_ring[ringpos + k] = (unsigned char) (v + 128);
        }
        snd_painted += n;
    }
    return snd_under;
}
