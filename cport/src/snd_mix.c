/*
 * snd_mix.c -- Quake's S_PaintChannels for one 8-bit mono ring.
 *
 * Eighteen channels, each a run of samples in the EMS handle snd.bsc
 * was loaded into, mixed into the DMA ring dsp.asm plays, from where the
 * mixer last stopped to a quarter second past where the DMA is. Two are
 * S_UpdateAmbientSounds' water and sky, faded to the listener's leaf;
 * eight are S_StartSound's, re-placed from where each began every frame;
 * eight are the map's statics, one a sound however many points play it.
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

#include <math.h>

#include "snd_mix.h"
#include "qgl.h"

#define PAGE_SLOT   2
#define SND_RING    4096L
#define SND_LEAF    2               /* water and sky; id's slime and lava have no sound */
#define SND_CHANS   8               /* MAX_DYNAMIC_CHANNELS */
#define SND_VOICES  8               /* distinct static sounds: e1's maps use seven at most */
#define SND_DYN0    SND_LEAF
#define SND_VOICE0  (SND_LEAF + SND_CHANS)
#define SND_ALL     (SND_LEAF + SND_CHANS + SND_VOICES)
#define SND_CHUNK   512
#define SND_BLK     32              /* samples a block, bsc4/32n */
#define SND_BLK_B   17              /* its bytes: the scale, then sixteen of codes */
#define SND_DTAB    512             /* 32 scales x 16 codes, mksnd.py's */
#define SND_NSCALE  32              /* and the scale byte selects one, so it is masked */
#define SND_TAB     176             /* records */
#define SND_AHEAD   2756L           /* a quarter second at 11025 */
#define SND_RATE    11025L
#define EMS_PAGE    16384
#define SND_BLK_PG  (EMS_PAGE / SND_BLK_B)  /* 963; the page's last 13 bytes are padding */
#define SND_CLIP    1000.0f         /* sound_nominal_clip_dist */
#define SND_ATTN_STATIC 3.0f
#define SND_REACH   333.4f          /* past this a static is silent */
#define SND_FADE    100L            /* ambient_fade, volume a second */

typedef struct {
    long  pos, end, beg;            /* end 0: free; beg >= 0 loops */
    short vol, master;
    short id, ent, chan, attn;
    float x, y, z;
} SndChan;

/* a static's place, whole units, and the voice that plays it */
typedef struct { unsigned char voice, vol; short x, y, z; } SndPoint;

static short snd_hnd     = 0;
static short snd_count   = 0;
static short snd_lastpos = 0;
static short snd_under   = 0;
static short snd_loops   = 0;
static short snd_wraps   = 0;
static long  snd_time    = 0;   /* samples the DMA has played */
static long  snd_painted = 0;   /* samples written */
static long  snd_fade_acc = 0;
static unsigned char far *snd_ring;
static int           far *snd_paint;        /* SND_CHUNK ints */
static SndRec        far *snd_tab;
static SndChan       far *snd_chan;
static SndPoint      far *snd_pts   = 0;
static short              snd_npts  = 0;
static short              snd_ptmax = 0;
static short              snd_nvoice = 0;
static short              snd_voice_id[SND_VOICES];
static signed char        snd_dtab[SND_DTAB];   /* scale row, then code */
static signed char        snd_dbuf[SND_CHUNK];  /* one run, decoded */

short snd_mix_statics( short n )
{
    snd_pts = n > 0 ? (SndPoint far *) qglMemAlloc( (long) n * sizeof(SndPoint) ) : 0;
    snd_ptmax = snd_pts ? n : 0;
    snd_npts = snd_nvoice = 0;
    return snd_ptmax;
}

short snd_mix_ambient( short id, short vol, BspVec3 *org )
{
    SndPoint far *p;
    short v;

    if ( snd_npts >= snd_ptmax ) return -1;
    for ( v = 0; v < snd_nvoice && snd_voice_id[v] != id; v++ ) ;
    if ( v == snd_nvoice ) {
        if ( v == SND_VOICES ) return -1;
        snd_voice_id[ snd_nvoice++ ] = id;
    }
    p = &snd_pts[snd_npts];
    p->voice = (unsigned char) v;
    p->vol   = (unsigned char) vol;
    p->x = (short) org->x;
    p->y = (short) org->y;
    p->z = (short) org->z;
    return snd_npts++;
}

short snd_mix_loops( void )  { return snd_loops; }
short snd_mix_voices( void ) { return snd_nvoice; }
short snd_mix_wraps( void )  { return snd_wraps; }

short snd_mix_leaf_vol( short i )
{
    return snd_chan ? snd_chan[i].vol : 0;
}

short snd_mix_live( short *ids )
{
    short i, n = 0;

    if ( !snd_chan ) return 0;
    for ( i = SND_DYN0; i < SND_VOICE0; i++ )
        if ( snd_chan[i].end ) ids[n++] = snd_chan[i].id;
    return n;
}

/* a loop from sample 0, silent until it is placed */
static short snd_loop_start( SndChan far *ch, short id )
{
    if ( id < 0 || id >= snd_count || snd_tab[id].loop < 0 ) return 0;
    ch->pos = snd_tab[id].ofs;
    ch->end = ch->pos + snd_tab[id].len;
    ch->beg = ch->pos + snd_tab[id].loop;
    ch->vol = ch->master = 0;
    ch->id = id;
    ch->ent = ch->chan = 0;
    return 1;
}

short snd_mix_setup( short hnd, unsigned char far *ring, void far *scratch,
                      SndRec far *tab, short count, short scratch_bytes,
                      signed char far *dec, short water, short sky )
{
    short i;

    if ( count > SND_TAB ||
         SND_CHUNK * 2 + SND_TAB * (short) sizeof(SndRec) + SND_ALL * (short) sizeof(SndChan) > scratch_bytes )
        return -1;
    snd_hnd   = hnd;
    snd_count = count;
    snd_ring  = ring;
    snd_paint = (int far *) scratch;
    snd_tab   = (SndRec far *) ( (char far *) scratch + SND_CHUNK * 2 );
    snd_chan  = (SndChan far *) ( (char far *) snd_tab + SND_TAB * sizeof(SndRec) );
    for ( i = 0; i < count; i++ ) snd_tab[i] = tab[i];
    for ( i = 0; i < SND_DTAB; i++ ) snd_dtab[i] = dec[i];
    for ( i = 0; i < SND_ALL; i++ ) snd_chan[i].end = 0;

    snd_loop_start( &snd_chan[0], water );
    snd_loop_start( &snd_chan[1], sky );
    for ( i = 0; i < snd_nvoice; i++ )
        snd_loop_start( &snd_chan[SND_VOICE0 + i], snd_voice_id[i] );
    snd_loops = 0;
    for ( i = 0; i < snd_npts; i++ )
        if ( snd_chan[SND_VOICE0 + snd_pts[i].voice].end ) snd_loops++;

    snd_time = snd_painted = 0;
    snd_lastpos = snd_under = 0;
    return count;
}

/* SND_Spatialize, mono: the player's own sounds at full volume */
static void snd_mix_spatialize( SndChan far *ch, BspVec3 *ear )
{
    float dx, dy, dz, scale;

    if ( ch->ent == SND_ENT_PLAYER || ch->attn == 0 ) { ch->vol = ch->master; return; }
    dx = ch->x - ear->x;
    dy = ch->y - ear->y;
    dz = ch->z - ear->z;
    scale = 1.0f - (float) sqrt( dx*dx + dy*dy + dz*dz ) * ch->attn / SND_CLIP;
    ch->vol = scale <= 0.0f ? 0 : (short) ( ch->master * scale );
}

short snd_mix_start( short id, short vol, short ent, short chan, short attn,
                      BspVec3 *org, BspVec3 *ear )
{
    SndChan far *ch;
    short i, pick = -1;
    long  least = 0x7fffffffL, left;

    if ( id < 0 || id >= snd_count ) return -1;
    for ( i = SND_DYN0; i < SND_VOICE0; i++ ) {
        ch = &snd_chan[i];
        if ( chan != 0 && ch->end && ch->ent == ent && ch->chan == chan ) { pick = i; break; }
        if ( ch->end && ch->ent == SND_ENT_PLAYER && ent != SND_ENT_PLAYER ) continue;
        left = ch->end ? ch->end - ch->pos : -1L;
        if ( left < least ) { least = left; pick = i; }
    }
    if ( pick < 0 ) return -1;

    ch = &snd_chan[pick];
    ch->pos    = snd_tab[id].ofs;
    ch->end    = ch->pos + snd_tab[id].len;
    ch->beg    = snd_tab[id].loop < 0 ? -1L : ch->pos + snd_tab[id].loop;
    ch->master = vol;
    ch->id     = id;
    ch->ent    = ent;
    ch->chan   = chan;
    ch->attn   = attn;
    ch->x = org->x; ch->y = org->y; ch->z = org->z;
    snd_mix_spatialize( ch, ear );
    /* the channel was taken either way: a stop out of earshot still
       ends its entity's loop */
    if ( ch->vol == 0 ) { ch->end = 0; return -1; }
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
            if ( ch->ent ) snd_wraps++;
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

/* S_UpdateAmbientSounds: ambient_level 0.3 of the leaf's level, nothing
   under 8, moving toward it ambient_fade a second. adv is the frame's
   time in samples; the remainder carries, or short frames never fade. */
static void snd_mix_leaf( unsigned char amb, long adv )
{
    SndChan far *ch;
    short i, want, step;

    snd_fade_acc += adv * SND_FADE;
    step = (short) ( snd_fade_acc / SND_RATE );
    snd_fade_acc %= SND_RATE;
    for ( i = 0; i < SND_LEAF; i++ ) {
        ch = &snd_chan[i];
        want = (short) ( ( ( i ? amb : amb >> 4 ) & 15 ) * 17 * 3 / 10 );
        if ( want < 8 ) want = 0;
        if ( ch->vol < want ) {
            ch->vol = (short) ( ch->vol + step );
            if ( ch->vol > want ) ch->vol = want;
        } else if ( ch->vol > want ) {
            ch->vol = (short) ( ch->vol - step );
            if ( ch->vol < want ) ch->vol = want;
        }
    }
}

/* SND_Spatialize for the statics, then S_UpdateSounds' combine: a voice
   plays at its points' summed volume, 255 at most. */
static void snd_mix_place( BspVec3 *ear )
{
    short acc[SND_VOICES];
    SndPoint far *p;
    float dx, dy, dz, d2;
    short i;

    for ( i = 0; i < snd_nvoice; i++ ) acc[i] = 0;
    for ( i = 0; i < snd_npts; i++ ) {
        p = &snd_pts[i];
        dx = p->x - ear->x;
        if ( dx > SND_REACH || dx < -SND_REACH ) continue;
        dy = p->y - ear->y;
        if ( dy > SND_REACH || dy < -SND_REACH ) continue;
        dz = p->z - ear->z;
        d2 = dx*dx + dy*dy + dz*dz;
        if ( d2 >= SND_REACH * SND_REACH ) continue;
        acc[p->voice] += (short) ( p->vol * ( 1.0f - (float) sqrt( d2 ) * SND_ATTN_STATIC / SND_CLIP ) );
    }
    for ( i = 0; i < snd_nvoice; i++ )
        snd_chan[SND_VOICE0 + i].vol = acc[i] > 255 ? 255 : acc[i];
}

short snd_mix_frame( short pos, long adv, BspVec3 *ear, unsigned char amb )
{
    long  delta = (long) pos - snd_lastpos, endt;
    short n, ringpos, k, c;
    int   v;

    snd_mix_leaf( amb, adv );
    for ( c = SND_DYN0; c < SND_VOICE0; c++ )
        if ( snd_chan[c].end ) snd_mix_spatialize( &snd_chan[c], ear );
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
