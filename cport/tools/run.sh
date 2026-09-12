#!/bin/bash
# Run QCPORT.EXE headless. cport.txt/cstep.txt land in the same dir.
#
#   cport/tools/run.sh build/cport ["dm3ish.bsp -ticks 300"]
#
# sys_parse_args needs a map name; the command line defaults to
# "dm3ish.bsp -ticks 300" if not given -- no -ticks means unbounded
# (main.bas's own default, stops only on ESC), which a headless,
# nobody-there-to-press-ESC run must never be left at.
set -euo pipefail

OUT="${1:?usage: run.sh <build-dir> [\"args\"]}"
QARGS="${2:-dm3ish.bsp -ticks 300}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

rm -f "$OUT/cport.txt" "$OUT/cstep.txt" "$OUT/error.log"

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\nems=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $OUT"
  echo "w:"
  echo "QCPORT.EXE $QARGS"
  echo "exit"
} > "$OUT/run.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-60}" "$DOSBOX_BIN" -nolog -conf "$OUT/run.conf" >/dev/null 2>&1 || true

echo "== cstep.txt =="
cat "$OUT/cstep.txt" 2>/dev/null || echo "(none)"
echo "== cport.txt =="
cat "$OUT/cport.txt" 2>/dev/null || echo "(none)"
