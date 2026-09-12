#!/bin/bash
# Regression test: the frame profile adds up, and each phase measures
# the work its name claims.
#
# Why this is a gate and not just a number to read: a pass added to the
# frame without a bracket around it does not report a large time, it
# reports NO time, and the phases then describe a frame that is not the
# one running. Three passes were already in that state when this was
# written -- the alias models (7.6 ms of e1m1's 53), the mixer and the
# present -- while pt_tick/cull/draw/hud looked perfectly reasonable and
# summed to two thirds of the frame with nothing saying so.
#
#   1. pt_frame_mean, measured at the frame's own boundaries, must agree
#      with ft_mean, which comes from the other clock (sys_frame_time's
#      PIT ticks against the profiler's rdtsc). Two independent measures
#      of the same frame.
#   2. pt_other_mean -- the frame less every phase -- must stay under 2%
#      of it. The frame count and ft_mean repeat exactly run to run, but
#      the phase microseconds do not quite: two runs of one binary on
#      e1m1 put the residual at 0.123 and 0.278 ms of a 53 ms frame, the
#      interrupts landing an instruction apart. So the bound is measured
#      spread doubled, and it catches any unbracketed pass costing more
#      than about half a millisecond a frame -- and a negative residual,
#      which is a bracket counted twice, just as well.
#   3. The alias phase must actually be the models: with -nomdl -noitems
#      -noview it has to fall away, while the frame keeps its other
#      phases. A bracket around the wrong lines passes 1 and 2 happily.
#
#   cport/tools/test-prof.sh build/cport-e1m1 [dm3ish]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-prof.sh <build-dir> [map]}"
MAP="${2:-dm3ish}"
RUN="${RUN_SH:-$HERE/run.sh}"

[[ -f "$OUT/$MAP.qmp" ]] || { echo "SKIP: no $MAP.qmp in $OUT"; exit 0; }

ARGS="-lm -nostats -bench 4000 -ticks 400"
fail=0

# BENCH.TXT is deleted by run.sh before each run, so a value read here is
# this run's or is missing -- never the previous run's.
field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | grep -m1 "^$1 " | sed "s/^$1 //"; }

TIMEOUT="${TIMEOUT:-900}" "$RUN" "$OUT" "$MAP.qmp $ARGS" >/dev/null 2>&1
frame=$(field pt_frame_mean); ft=$(field ft_mean)
other=$(field pt_other_mean); alias_on=$(field pt_alias_mean)
n=$(field pt_frames)

if [[ -z "$frame" || -z "$ft" || -z "$other" ]]; then
    echo "FAIL: the run wrote no profile (pt_frame_mean='$frame' ft_mean='$ft' pt_other_mean='$other')" >&2
    exit 1
fi

TIMEOUT="${TIMEOUT:-900}" "$RUN" "$OUT" "$MAP.qmp $ARGS -nomdl -noitems -noview" >/dev/null 2>&1
alias_off=$(field pt_alias_mean)

python3 - "$frame" "$ft" "$other" "$alias_on" "${alias_off:-}" "${n:-0}" <<'PY'
import sys
frame, ft, other, a_on, a_off, n = (float(x) if x else 0.0 for x in sys.argv[1:7])
bad = []
if frame <= 0:
    bad.append(f'pt_frame_mean is {frame} -- the profiler measured nothing')
elif abs(frame - ft) > 0.05 * frame:
    bad.append(f'pt_frame_mean {frame} against ft_mean {ft} -- the two clocks disagree by '
               f'{abs(frame - ft) / frame * 100:.1f}%')
if frame > 0 and abs(other) > 0.02 * frame:
    bad.append(f'pt_other_mean {other} is {abs(other) / frame * 100:.1f}% of the {frame} ms frame '
               f'-- a pass is unbracketed, or one is counted twice')
if a_on <= 0:
    bad.append(f'pt_alias_mean is {a_on} with the models drawing')
elif a_off > 0.25 * a_on:
    bad.append(f'pt_alias_mean is {a_off} with -nomdl -noitems -noview against {a_on} with them '
               f'-- the bracket is not around the models')
for b in bad:
    print('FAIL:', b, file=sys.stderr)
if not bad:
    print(f'ok: {int(n)} frames of {frame} ms account for all but {other} ms, '
          f'ft_mean reads {ft}, and the models are {a_on} of it ({a_off} without them)')
sys.exit(1 if bad else 0)
PY