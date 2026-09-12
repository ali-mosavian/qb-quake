/*
 * sys_time.c -- the frame clock. C port of sys.bas's timing slice.
 */

#include "sys_time.h"

/*
 * The BIOS tick counter at 0000:046C, incremented by INT 8h at the PIT's
 * own 18.2065 Hz (1193182/65536) -- what QuickBASIC's own TIMER reads
 * under the hood in real mode, and the one clock DOS guarantees without
 * calling into any library. Cast directly rather than including dos.h
 * for MK_FP: mgl ships its OWN inc/dos.h (qglMemAlloc/qglMemCopy, unrelated to
 * the standard library's), and bcc.sh's include order (-IM:\ before
 * -IB:\INCLUDE) means <dos.h> would resolve to that one, not Borland's.
 * A Borland far pointer is segment:offset packed exactly as this cast
 * assumes -- the same layout every (long)(void far*) conversion already
 * used throughout cport/ relies on.
 */
#define BIOS_TICK_HZ 18.2065f

static unsigned long bios_ticks( void )
{
    return *(unsigned long far *) ( ((unsigned long) 0x0040 << 16) | 0x006CUL );
}

/*
 * The low 32 bits of RDTSC (0F 31h) -- bcc's own inline assembler
 * predates the mnemonic, hence the raw __emit__ bytes, same reasoning
 * as d_poly.c's FSIN needing -B/TASM. Matches r_span.c's own
 * rdtsc_now() exactly: RDTSC leaves the 64-bit count in EDX:EAX, and
 * this keeps only EAX (the low half), reassembled into Borland's
 * DX:AX long-return convention -- the high half is discarded on
 * purpose, since a caller only ever wants a delta between two close
 * readings, not an absolute count.
 */
static unsigned long near rdtsc_raw( void )
{
    __asm push ebx
    __emit__( 0x0f, 0x31 );
    __asm {
        mov  ebx, eax
        shr  ebx, 16
        mov  dx, bx
        pop  ebx
    }
}

/*
 * Calibrate rather than trust the requested rate. Asking uGL for 1 kHz
 * and dividing by 1000 gave a dt about seven times too small once: the
 * physics was frame-rate independent but ran in slow motion, every
 * speed in the game being units per seven seconds. What the timer
 * actually delivers depends on uGL and the emulator underneath it, so
 * measure it against the BIOS tick, which is accurate only to ~55ms but
 * ample over half a second.
 *
 * Aligned to a tick edge before starting, and the window ends on one
 * too (the loop below exits the moment one lands), so elapsed is an
 * exact multiple of the tick period instead of that plus an unknown
 * fraction. Without this the same binary measured 142.9 Hz on one run
 * and 148.1 on the next, and the game ran 4% faster on one of them.
 */
void sys_time_init( SysClock *clk )
{
    unsigned long t0, c0, c1;
    unsigned long r0, r1;
    float elapsed;

    /* qgl owns one timer, started by qglTmrInit and read by
       qglTmrTicks -- there is no per-caller TMR to place, which is
       also one fewer intrusive list node for a stray write to
       corrupt. The rate asked for is still not the rate believed:
       the calibration below measures what arrived. */
    t0 = bios_ticks();
    while ( bios_ticks() == t0 ) { /* align to a tick edge */ }

    t0 = bios_ticks();
    c0 = (unsigned long) qglTmrTicks();
    r0 = rdtsc_raw();

    while ( (float) (bios_ticks() - t0) / BIOS_TICK_HZ < 0.5f ) { /* wait */ }

    elapsed = (float) (bios_ticks() - t0) / BIOS_TICK_HZ;
    c1 = (unsigned long) qglTmrTicks();
    r1 = rdtsc_raw();

    /*
     * Calibrated in the SAME window as tick_hz, against the SAME
     * tick-aligned reference, for the same reason: DOSBox ties RDTSC
     * to cycles actually executed under the pinned cycles= setting,
     * not wall-clock time, far more reproducible run to run than a
     * real timer -- but "cycles per second" still depends on the
     * emulator underneath, so this is measured too, not assumed.
     */
    if ( elapsed > 0.0f && r1 > r0 ) clk->rdtsc_hz = (float) (r1 - r0) / elapsed;
    else                             clk->rdtsc_hz = 1.0f;

    clk->cyc_per_us = (long) (clk->rdtsc_hz / 1000000.0f);
    if ( clk->cyc_per_us < 1 ) clk->cyc_per_us = 1;

    if ( elapsed > 0.0f && c1 > c0 ) clk->tick_hz = (float) (c1 - c0) / elapsed;
    else                             clk->tick_hz = 1000.0f;

    clk->last_tick  = qglTmrTicks();
    clk->timing_on  = -1;
}

/*
 * Clamped at both ends. Zero would freeze physics on a frame that
 * completed inside one tick; a large value would let one slow frame --
 * the first after loading, say -- move the player far enough to pass
 * through a wall, since the sweep is only as long as dt makes it.
 */
float sys_frame_time( SysClock *clk, float *raw_dt )
{
    long  tick;
    float dt;

    if ( !clk->timing_on ) return 1.0f / 60.0f;

    tick = qglTmrTicks();
    dt   = (float) (tick - clk->last_tick) / clk->tick_hz;
    clk->last_tick = tick;

    if ( dt < 0.0f ) dt = 1.0f / 60.0f;   /* counter wrapped */

    /* The UNCLAMPED delta, for the benchmark -- the clamps below keep
       the simulation stable but flatten every frame slower than 10fps
       to read as exactly 10fps, which would make the reported worst
       frame the clamp rather than the renderer. Record the truth
       before flattening it. */
    if ( raw_dt ) *raw_dt = dt;

    if ( dt < 0.001f ) dt = 0.001f;
    if ( dt > 0.1f )   dt = 0.1f;

    return dt;
}

float sys_tick_hz( SysClock *clk )
{
    return clk->tick_hz;
}

float sys_now( SysClock *clk )
{
    return (float) qglTmrTicks() / clk->tick_hz;
}

long sys_rdtsc( SysClock *clk )
{
    return (long) ( rdtsc_raw() / (unsigned long) clk->cyc_per_us );
}

float sys_rdtsc_hz( SysClock *clk )
{
    return clk->rdtsc_hz;
}
