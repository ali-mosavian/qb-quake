option explicit
''
'' snd.bas -- the sound layer: Quake's snd_dma.c, without the stereo.
''
'' qglDspInit starts a Sound Blaster playing a 4096-byte ring; snd.bsc,
'' mksnd.py's concatenation of the game's wavs as bsc4/32n, goes into one
'' EMS handle a page at a time and snddec.raw is the 512-byte table it is
'' decoded through; snd_mix.c mixes eight channels into the ring ahead
'' of the DMA once a frame. A sound starts at one volume, Quake's
'' distance falloff from the player where it was started, and plays out.
'' No card, or -nosound, and every call here returns at once.
''
'$include: 'qgl.bi'
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_mdl.bi'
'$include: 'q_game.bi'

declare function qglDspInit ( byval rate as integer ) as integer
declare function qglDspPos ( ) as integer
declare function qglDspBuf ( ) as long
declare function qglDspScratch ( ) as long
declare function qglDspScratchBytes ( ) as integer
declare sub qglDspShutdown ( )
declare function qglGemAlloc ( byval nbytes as long ) as integer
declare function qglGemMap ( byval h as integer, byval pg as integer, _
                             byval slot as integer ) as integer
declare sub qglGemFree ( byval h as integer )
declare function qglFileOpenBas ( flname as string ) as integer
declare function qglFileSize ( byval h as integer ) as long
declare function qglFileRead ( _
    byval h as integer, _
    byval dst as long, _
    byval nbytes as long _
) as long
declare sub qglFileClose ( byval h as integer )
declare function snd_mix_setup ( _
    byval hnd as integer, _
    byval ring as long, _
    byval scratch as long, _
    byval sndtab as long, _
    byval count as integer, _
    byval scratch_bytes as integer, _
    byval dec as long _
) as integer
declare function snd_mix_start ( _
    byval id as integer, _
    byval vol as integer _
) as integer
declare function snd_mix_frame ( _
    byval dma_pos as integer, _
    byval adv as long, _
    byval ear as long _
) as integer
declare function snd_mix_ambient ( _
    byval id as integer, _
    byval vol as integer, _
    byval org as long _
) as integer
declare function snd_mix_loops ( ) as integer

const SND_RATE%      = 11025
const SND_TAB_BYTES% = SND_COUNT% * 8   '' sndtab.raw after its count
const SND_DTAB_BYTES% = 512             '' snddec.raw: 32 scales x 16 codes
const SND_CLIP_DIST# = 1000.0           '' sound_nominal_clip_dist, ATTN_NORM
const SND_PAGE&      = 16384


sub snd_init ( g as Game )
    dim f as integer, n as integer, u as integer, pgseg as integer, pg as integer
    dim sndtab as string * SND_TAB_BYTES%
    dim snddec as string * SND_DTAB_BYTES%
    dim remain as long, want as long

    g.snd.on = 0
    if ( g.snd.off ) then exit sub
    if ( qglDspInit( SND_RATE% ) = 0 ) then sys_mem_mark "snd_no_dsp" : exit sub

    f = freefile
    open "sndtab.raw" for binary as #f
    if ( lof( f ) = 0 ) then close #f : sys_error "0x0050, sndtab.raw is missing -- run make assets"
    get #f, 1, n
    if ( n <> SND_COUNT% ) then sys_error "0x0050, sndtab.raw has " + ltrim$( str$( n ) ) + " sounds, q_pl.bi says " + ltrim$( str$( SND_COUNT% ) )
    get #f, , sndtab
    close #f

    f = freefile
    open "snddec.raw" for binary as #f
    if ( lof( f ) <> SND_DTAB_BYTES% ) then close #f : sys_error "0x0054, snddec.raw is missing or not 512 bytes -- run make assets"
    get #f, 1, snddec
    close #f

    u = qglFileOpenBas( "snd.bsc" )
    if ( u = 0 ) then sys_error "0x0051, snd.bsc is missing -- run make assets"
    remain = qglFileSize( u )
    g.snd.hnd = qglGemAlloc( remain )
    if ( g.snd.hnd = 0 ) then
        sys_mem_mark "snd_no_ems"
        qglFileClose u
        qglDspShutdown
        exit sub
    end if
    pg = 0
    do while ( remain > 0 )
        pgseg = qglGemMap( g.snd.hnd, pg, PAGE_SLOT )
        if ( pgseg = 0 ) then sys_error "0x0052, snd.bsc page would not map"
        want = remain
        if ( want > SND_PAGE& ) then want = SND_PAGE&
        if ( qglFileRead( u, clng( pgseg ) * 65536&, want ) <> want ) then sys_error "0x0052, snd.bsc short"
        remain = remain - want
        pg = pg + 1
    loop
    qglFileClose u

    n = snd_mix_setup( g.snd.hnd, qglDspBuf(), qglDspScratch(), _
                       clng( varseg( sndtab ) ) * 65536& + ( clng( varptr( sndtab ) ) and 65535& ), SND_COUNT%, _
                       qglDspScratchBytes(), _
                       clng( varseg( snddec ) ) * 65536& + ( clng( varptr( snddec ) ) and 65535& ) )
    if ( n < 0 ) then sys_error "0x0053, dsp.asm's DSP_SCRATCH is short of snd_mix.c's table and channels"
    g.snd.on = -1
    g.snd.loops = snd_mix_loops()
    sys_mem_mark "snd"
end sub


'' ambientsound: recorded at map load, started with the card, looped
'' for good; the mixer places it from the player each frame
sub snd_ambient ( _
    g as Game, _
    byval id as integer, _
    byval vol as integer, _
    org as Vec3 _
)
    dim c as integer

    if ( g.snd.off ) then exit sub
    c = snd_mix_ambient( id, vol, clng( varseg( org ) ) * 65536& + ( clng( varptr( org ) ) and 65535& ) )
end sub


'' S_StartSound and SND_Spatialize, mono: 255 less the distance's share
'' of a thousand units, once, where the sound began
sub snd_play ( _
    g as Game, _
    byval id as integer, _
    org as Vec3 _
)
    dim dx as single, dy as single, dz as single, vol as integer

    if ( g.snd.on = 0 ) then exit sub
    dx = org.x - g.pl.pos.x
    dy = org.y - g.pl.pos.y
    dz = org.z - g.pl.pos.z
    vol = int( 255.0 * ( 1.0 - sqr( dx * dx + dy * dy + dz * dz ) / SND_CLIP_DIST# ) )
    if ( vol <= 0 ) then exit sub
    if ( snd_mix_start( id, vol ) >= 0 ) then g.snd.started = g.snd.started + 1
end sub


'' once a frame, between the tick and the render: nothing holds an EMS
'' window then, and the mixer takes PAGE_SLOT
sub snd_frame ( g as Game )
    if ( g.snd.on = 0 ) then exit sub
    g.snd.under = snd_mix_frame( qglDspPos(), clng( g.scr.frame_time * SND_RATE% ), _
                                 clng( varseg( g.pl.pos ) ) * 65536& + ( clng( varptr( g.pl.pos ) ) and 65535& ) )
end sub


sub snd_shutdown ( g as Game )
    if ( g.snd.on = 0 ) then exit sub
    g.snd.on = 0
    qglDspShutdown
    qglGemFree g.snd.hnd
end sub
