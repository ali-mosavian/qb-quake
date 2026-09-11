/*
 * snd_mix.c -- Quake's S_PaintChannels for one 8-bit mono ring.
 *
 * Eight channels, each a run of samples in the EMS handle mksnd.py's
 * snd.raw was loaded into, mixed into the DMA ring dsp.asm plays, from
 * where the mixer last stopped to a quarter second past where the DMA
 * is. Eight more are the map's ambients: S_StaticSound, looped from
 * sample 0 and re-spatialised from the player every frame. Every
 * buffer lives in the block dsp.asm took from DOS -- the ring, then
 * this module's scratch -- so nothing here sits in DGROUP but a few
 * scalars and the ambient table: that is BASIC's string space and it
 * is what e1m1 runs out of.
 *
 * A sample is read through PAGE_SLOT, mapped fresh for every run and
 * held across nothing, the same way every other reader of that slot
 * behaves; the call sits between the tick and the render, where no one
 * has a window open.
 */
extern short pascal far qglGemMap( short h, short pg, short slot );

#define PAGE_SLOT   2
#define SND_RING    4096L
#define SND_CHANS   8               /* S_StartSound's */
#define SND_STATICS 32              /* the ambients', looping; a silent one costs its pointer arithmetic */
#define SND_ALL     (SND_CHANS + SND_STATICS)
#define SND_CHUNK   512
#define SND_TAB     1024            /* 128 (offset, length) records */
#define SND_AHEAD   2756L           /* a quarter second at 11025 */
#define EMS_PAGE    16384L
#define SND_ATTN_STATIC 3L          /* ATTN_STATIC, per sound_nominal_clip_dist */
#define SND_CLIP_DIST   1000L

typedef struct { long pos, end, beg; short vol; } SndChan;  /* end 0: free; beg >= 0 loops */
typedef struct { long ofs, len; } SndRec;
typedef struct { short id, vol; float x, y, z; } SndAmb;
typedef union { long l; struct { unsigned short lo, hi; } w; } Split;

static short           near snd_hnd      = 0;
static short           near snd_count    = 0;
static short           near snd_lastpos  = 0;
static short           near snd_under    = 0;
static short           near snd_namb     = 0;
static short           near snd_loops    = 0;
static long            near snd_time     = 0;   /* samples the DMA has played */
static long            near snd_painted  = 0;   /* samples written */
static unsigned char far *snd_ring;
static int           far *snd_paint;        /* SND_CHUNK ints */
static SndRec        far *snd_tab;
static SndChan       far *snd_chan;
static SndAmb        near snd_amb[SND_STATICS];

/* An ambient_* point, recorded at map load, before the card is up:
   vol is 255 times QuakeC's, org a Vec3 in BSP space. */
short pascal far snd_mix_ambient( short id, short vol, long org )
{
    float far *o = (float far *) org;

    if ( snd_namb >= SND_STATICS )
        return -1;
    snd_amb[snd_namb].id  = id;
    snd_amb[snd_namb].vol = vol;
    snd_amb[snd_namb].x   = o[0];
    snd_amb[snd_namb].y   = o[1];
    snd_amb[snd_namb].z   = o[2];
    return snd_namb++;
}

short pascal far snd_mix_loops( void )
{
    return snd_loops;
}

/* hnd: the samples' EMS handle; ring: the DMA ring; scratch: scratch_bytes
   for the paint buffer, the table and the channels, -1 when that is short
   -- the channels ran 304 bytes past dsp.asm's 1792 once the statics
   came, and e1m2 hung in the heap compactor; tab: count records of
   (offset, length) to copy in. Starts every recorded ambient on its own
   static channel. */
short pascal far snd_mix_setup( short hnd, long ring, long scratch, long tab, short count, short scratch_bytes )
{
    SndRec far *src = (SndRec far *) tab;
    SndChan far *ch;
    short i;

    if ( count * 8 > SND_TAB || SND_CHUNK * 2 + SND_TAB + SND_ALL * (short) sizeof(SndChan) > scratch_bytes )
        return -1;
    snd_hnd     = hnd;
    snd_count   = count;
    snd_ring    = (unsigned char far *) ring;
    snd_paint   = (int far *) scratch;
    snd_tab     = (SndRec far *) ((char far *) scratch + SND_CHUNK * 2);
    snd_chan    = (SndChan far *) ((char far *) snd_tab + SND_TAB);
    for ( i = 0; i < count; i++ )
        snd_tab[i] = src[i];
    for ( i = 0; i < SND_ALL; i++ )
        snd_chan[i].end = 0;
    snd_loops = 0;
    for ( i = 0; i < snd_namb; i++ ) {
        if ( snd_amb[i].id < 0 || snd_amb[i].id >= count )
            continue;
        ch = &snd_chan[SND_CHANS + i];
        ch->beg = ch->pos = snd_tab[snd_amb[i].id].ofs;
        ch->end = ch->beg + snd_tab[snd_amb[i].id].len;
        ch->vol = 0;
        snd_loops++;
    }
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
    snd_chan[pick].beg = -1;
    snd_chan[pick].vol = vol;
    return pick;
}

static void near snd_mix_chan( SndChan far *ch, short n )
{
    long  left;
    short i = 0, run, off, k, vol = ch->vol, seg;
    unsigned char far *p;
    Split at;

    while ( i < n ) {
        if ( ch->pos >= ch->end ) {
            if ( ch->beg < 0 ) { ch->end = 0; return; }
            ch->pos = ch->beg;
        }
        left = ch->end - ch->pos;
        run = n - i;
        if ( run > left ) run = (short) left;
        if ( vol == 0 ) { ch->pos += run; i += run; continue; }   /* out of earshot: keep time */
        at.l = ch->pos;             /* page and offset from the two words: no long divide */
        seg = qglGemMap( snd_hnd, (short) ((at.w.hi << 2) | (at.w.lo >> 14)), PAGE_SLOT );
        if ( seg == 0 ) { ch->end = 0; return; }
        off = (short) (at.w.lo & (EMS_PAGE - 1));
        if ( run > (short) (EMS_PAGE - off) ) run = (short) (EMS_PAGE - off);
        p = (unsigned char far *) (((unsigned long) seg << 16) | (unsigned short) off);
        for ( k = 0; k < run; k++ )
            snd_paint[i + k] += ( ((int) p[k] - 128) * vol ) >> 3;
        i += run;
        ch->pos += run;
    }
    if ( ch->pos >= ch->end && ch->beg < 0 ) ch->end = 0;
}

static long near snd_isqrt( long v )
{
    long r = v, x = 1;

    if ( v <= 0 ) return 0;
    while ( r > x ) { r = (r + x) / 2; x = v / r; }
    return r;
}

/* SND_Spatialize for the statics: the ambient's volume less the
   distance's share of a third of a thousand units. */
static void near snd_mix_place( float far *ear )
{
    SndChan far *ch;
    short i;
    long  dx, dy, dz, dist;

    for ( i = 0; i < snd_namb; i++ ) {
        ch = &snd_chan[SND_CHANS + i];
        if ( ch->end == 0 ) continue;
        dx = (long) (snd_amb[i].x - ear[0]);
        dy = (long) (snd_amb[i].y - ear[1]);
        dz = (long) (snd_amb[i].z - ear[2]);
        dist = snd_isqrt( dx * dx + dy * dy + dz * dz ) * SND_ATTN_STATIC;
        ch->vol = dist >= SND_CLIP_DIST ? 0
                : (short) ((long) snd_amb[i].vol * (SND_CLIP_DIST - dist) / SND_CLIP_DIST);
    }
}

/* pos: qglDspPos now; adv: the samples the frame's wall time is worth,
   which tells one wrap of the ring from two; ear: the player's Vec3.
   Returns the underruns so far -- frames that found the DMA past what
   had been painted. */
short pascal far snd_mix_frame( short pos, long adv, long ear )
{
    long  delta = (long) pos - snd_lastpos, endt;
    short n, ringpos, k, c;
    int   v;

    snd_mix_place( (float far *) ear );
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
        for ( c = 0; c < SND_ALL; c++ )
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
