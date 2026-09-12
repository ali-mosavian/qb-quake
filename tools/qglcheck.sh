#!/bin/bash
# Run qrender.exe -qglcheck and report PASS/FAIL.
#
#   tools/qglcheck.sh [build-dir]
#
# The qgl ABI test, run against the LINKED PRODUCTION EXE rather than a
# synthetic one: same BASIC compiler, same calling convention, same
# objects. qgl.bi is generated from qgl.inc so the two cannot drift on
# paper; this is the half that catches a stale object or a library built
# from a different qgl.inc.
#
# THE MAP ARGUMENT IS REQUIRED and must come first. sys_parse_args takes
# argv(0) as the map name unconditionally and only scans options from
# index 1, so `qrender.exe -qglcheck` makes "-qglcheck" the map and the
# flag is never seen -- the run then exits 0 having done nothing, which
# reads exactly like a passing test that wrote no output.
#
# The check itself runs before the map is opened, so the file only has to
# be nameable, not loadable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build/vbd}"
CONF="$BUILD/qglcheck.conf"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

cat > "$CONF" <<EOF
[sdl]
autolock=false
[dosbox]
memsize=16
startbanner=false
quit warning=false
[cpu]
core=dynamic
cycles=75000
[dos]
ems=true
xms=true
[autoexec]
@echo off
mount c "$BUILD"
c:
qrender.exe dm3ish.bsp -qglcheck
exit
EOF

rm -f "$BUILD/QGLCHK.LOG" "$BUILD/qglchk.log"
SDL_VIDEODRIVER=dummy timeout 180 "$DOSBOX_BIN" -nolog -conf "$CONF" -exit >/dev/null 2>&1 || true

# The log is written with BASIC file I/O, not PRINT and a redirect:
# PRINT goes to the display, so `> out.txt` yields an empty file and a
# silent pass. AGENTS.md records the same trap for ExitError.
out=$(ls "$BUILD"/QGLCHK.LOG "$BUILD"/qglchk.log 2>/dev/null | head -1)
if [[ -z "$out" ]]; then
    echo "qglcheck: no log -- the flag never ran (is the map argument first?)"
    exit 1
fi
cat "$out"
grep -q "RESULT PASS" "$out"
