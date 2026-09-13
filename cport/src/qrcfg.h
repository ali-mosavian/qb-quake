/*
 * qrcfg.h -- build-time switches for the instrumentation.
 *
 * Both default ON, so an unconfigured build is the one every gate and
 * every reference image was taken against. -DQR_PROF=0 / -DQR_LOG=0 on
 * the compiler line turn them off; cport/Makefile passes CDEFS through.
 *
 * A define changes what an object MEANS while leaving its source
 * untouched, and make cannot see that. Build each arm in its own BUILD
 * directory -- the project's never-share rule, for a second reason.
 *
 * PhaseTimes itself and DrawParams' counter fields stay declared under
 * either setting: what is measured here is the instructions the frame
 * runs, and 56 bytes of main's stack frame is not that.
 */
#ifndef QRCFG_H
#define QRCFG_H

/* The frame profile: PhaseTimes' brackets, d_faces' per-face rdtsc
   pairs and sc_find key sums, the walk's bench-only counters, and
   bench.txt's whole pt_* block. cport/tools/test-prof.sh needs it. */
#ifndef QR_PROF
#define QR_PROF 1
#endif

/* mark() -- the cstep.txt load trace, and the sprintf that feeds it.
   Costs no frame time (every call is load- or exit-time) and buys 368
   bytes of DGROUP. Note the run SUMMARY goes out the same way, so a
   QR_LOG=0 build writes no cstep.txt and the gates that grep it --
   test-walk.sh, test-items.sh and their kin -- need the default. */
#ifndef QR_LOG
#define QR_LOG  1
#endif

#endif
