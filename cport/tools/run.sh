#!/bin/bash
# Run QCPORT.EXE headless. cport.txt/cstep.txt land in the same dir.
#
#   cport/tools/run.sh build/cport ["dm3ish.qmp -ticks 300"]
#
# sys_parse_args needs a map name; the command line defaults to
# "dm3ish.qmp -ticks 300" if not given -- no -ticks means unbounded
# (main.bas's own default, stops only on ESC), which a headless,
# nobody-there-to-press-ESC run must never be left at.
set -euo pipefail

OUT="${1:?usage: run.sh <build-dir> [\"args\"]}"
QARGS="${2:-dm3ish.qmp -ticks 300}"
# The pinned machine, not cycles=max: a frame time is only comparable
# if both sides ran on the same emulated CPU, and max scales with host
# load. dosbox/template.conf says 75000 for the same reason.
CYCLES="${CYCLES:-75000}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

# BENCH.* too, or a run that dies before rendering leaves the previous
# run's frame and numbers in place and every test downstream reads them
# as this run's. Three of them reported ok that way once.
# NEXT.BAT/RUN1.BAT too: a changelevel writes NEXT.BAT and the autoexec
# below runs it, so one left behind by the previous run would start a
# map this run never asked for.
rm -f "$OUT/cport.txt" "$OUT/cstep.txt" "$OUT/error.log" \
      "$OUT/BENCH.BMP" "$OUT/BENCH.TXT" \
      "$OUT/NEXT.BAT" "$OUT/RUN1.BAT" "$OUT/CARRY.BIN" "$OUT/run.out"

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=%s\n[dos]\nxms=true\nems=true\n' "$CYCLES"
  # The card dsp.asm programs, pinned: the emulator's own defaults, but
  # a run is only comparable if both sides had the same machine.
  # nosound=true still advances the DMA, so the mixer is exercised.
  printf '[mixer]\nnosound=true\n[sblaster]\nsbtype=sb16\nsbbase=220\nirq=7\ndma=1\nhdma=5\n'
  printf '[autoexec]\n'
  echo "@echo off"
  echo "mount w $OUT"
  echo "w:"
  echo "QCPORT.EXE $QARGS"
  # QARGS2: a second run in the SAME session. The ISRs a run leaves
  # installed are invisible until something runs after it, which is
  # what a changelevel does.
  [[ -n "${QARGS2:-}" ]] && echo "QCPORT.EXE $QARGS2"
  # the changelevel: host_next_level wrote the next map's command line
  # to NEXT.BAT. It is CALLed from a copy because a batch file deleted
  # while it is running is "Batch file missing", and deleted first so a
  # map that does not exit again cannot loop.
  echo "if exist NEXT.BAT copy NEXT.BAT RUN1.BAT > nul"
  echo "if exist NEXT.BAT del NEXT.BAT"
  echo "if exist RUN1.BAT call RUN1.BAT"
  echo "exit"
} > "$OUT/run.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-60}" "$DOSBOX_BIN" -nolog -conf "$OUT/run.conf" >/dev/null 2>&1 || true

echo "== cstep.txt =="
cat "$OUT/cstep.txt" 2>/dev/null || echo "(none)"
echo "== cport.txt =="
cat "$OUT/cport.txt" 2>/dev/null || echo "(none)"
