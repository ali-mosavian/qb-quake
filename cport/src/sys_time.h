#ifndef __SYS_TIME_H__
#define __SYS_TIME_H__

#include "tmr.h"

/*
 * sys_time.h -- the frame clock. C port of sys.bas's sys_time_init/
 * sys_frame_time/sys_tick_hz/sys_now/sys_rdtsc/sys_rdtsc_hz slice --
 * the rest of sys.bas (argv parsing, stuff.ini, DIR$/error-path shims)
 * is Config's own future home, not this file's.
 *
 * The original calibrated RDTSC via sndDebugStat(6) (__snd_tsc), which
 * needs the sound sub-libraries -- deliberately excluded from
 * cport/'s __CMP__=BC uGL build (sound is dropped project-wide,
 * sound.enabled ships false). The port plan's own note already
 * anticipated this: sys_rdtsc moves to direct RDTSC, the way
 * r_span.c's own rdtsc_now already reads it (inline __emit__ 0x0f,
 * 0x31 -- the RDTSC opcode bcc's own assembler doesn't know the
 * mnemonic for, same reasoning as FSIN needing -B/TASM elsewhere in
 * cport/). sys_rdtsc_raw here returns the low 32 bits of the 64-bit
 * counter, same truncation r_span.c's version makes and the same
 * reason: cyc_per_us divides it down before a caller ever takes a
 * difference, which is what turns a ~28-second wraparound window into
 * roughly half an hour.
 *
 * Own context rather than folded into Renderer/PhaseTimes: this is a
 * genuinely separate concern (measuring time) from what reads the
 * measurements (Renderer's counters, PhaseTimes' sums).
 */
typedef struct {
    TMR   frame_tmr;
    float tick_hz;      /* frame_tmr's MEASURED rate -- see sys_time_init
                            on why this is calibrated, not trusted from
                            the rate asked for */
    long  last_tick;
    short timing_on;    /* false until sys_time_init has run; sys_frame_time
                            returns a nominal 1/60 until then rather than
                            dividing by an uncalibrated tick_hz */
    float rdtsc_hz;      /* calibrated in the same window as tick_hz,
                             against the same tick-aligned reference */
    long  cyc_per_us;    /* rdtsc_hz/1e6, floored at 1 -- sys_rdtsc divides
                             the raw counter by this with integer
                             division, not floating point, so two close
                             readings subtract to an exact microsecond
                             delta with no rounding on either side */
} SysClock;

/* Starts the frame clock. Must run after tmrInit (in_init). */
void sys_time_init( SysClock *clk );

/* Seconds since the previous call, clamped to [0.001, 0.1] so a frame
   too short doesn't freeze physics and one too long doesn't let a
   sweep pass through a wall. *raw_dt receives the UNCLAMPED delta --
   the benchmark's own worst-frame number, which the clamps would
   otherwise flatten to whatever the clamp is, not what actually
   happened. */
float sys_frame_time( SysClock *clk, float *raw_dt );

/* The measured tick rate, for the benchmark to report. */
float sys_tick_hz( SysClock *clk );

/* Seconds on the same clock sys_frame_time reads, for timing a PART of
   a frame rather than the whole of it -- take it before and after,
   subtract. Not an absolute time and not meant to be one; only deltas
   are ever valid. */
float sys_now( SysClock *clk );

/*
 * name: sys_rdtsc
 * desc: Microseconds on the RDTSC clock, NOT raw cycles -- see this
 *       file's own header on why cyc_per_us divides it down.
 *
 *       Only ever meaningful as a difference between two calls, never
 *       as a value on its own. A caller taking that difference must
 *       treat a negative or wildly-oversized delta as a glitched
 *       sample and discard it (the dynamic core's own RDTSC
 *       virtualization has been observed resetting near zero on some
 *       internal event) -- exactly as sys_frame_time already does for
 *       frame_tmr wrapping.
 */
long sys_rdtsc( SysClock *clk );

/* The calibrated rate sys_rdtsc counts at, for converting a delta to
   seconds, or for reporting cycles alongside milliseconds without
   silently mixing units. */
float sys_rdtsc_hz( SysClock *clk );

#endif
