#!/bin/bash
# Compile one QuickBASIC/VBDOS source with BC.EXE under DOSBox-X.
#
#   tools/bc.sh src/main.bas build/vbd/main.obj
#
# One DOSBox per file, deliberately -- same reasoning as tools/bcc.sh: each
# invocation is independent, so a Makefile pattern rule can run these under
# -j without serialising the whole program's compile through one shared
# build session (which is what tools/dosbox.sh's build.bat still does).
#
# vbd only, on purpose: it is the one target every run and benchmark in
# this tree actually uses. tools/dosbox.sh keeps pds/qb45 for whoever
# needs them; this script does not carry that weight.
#
# BASIC compiles independently per module -- cross-module calls are
# resolved by DECLARE against a symbol name, not by seeing the other
# module's source, so each invocation only needs its own .bas plus every
# .bi this project owns (all of them, copied in: BC's own $include cannot
# tell which subset a given module actually needs without parsing it, and
# copying all of them costs nothing they are small). uGL's own headers
# (ugl.bi, u3d.bi, etc.) are NOT in src/ -- set INCLUDE=M:\INC is what
# template.conf's shared flow uses for those, mirrored here.
set -euo pipefail

SRC_REL="${1:?usage: bc.sh <src-bas> <out-obj>}"
OUT="${2:?usage: bc.sh <src-bas> <out-obj>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
MGL="${MGL:-$HOME/work/badlogic/mgl}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

base=$(basename "$SRC_REL" .bas)

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$ROOT/src/$base.bas" "$W/"
cp "$ROOT"/src/*.bi "$W/" 2>/dev/null || true

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\n'
  # core=dynamic/cycles=max: a compile's correctness does not depend on
  # the emulated clock the way a benchmark's timing does -- see
  # dosbox/template.conf's own note on why cycles is pinned THERE.
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $W"
  echo "mount v $TOOLCHAINS/vbdos"
  echo "mount m $MGL"
  echo "set INCLUDE=M:\\INC"
  echo "w:"
  echo "v:\\bin\\bc.exe /O /FPi /R /G3 /E $base.bas, $base.obj; > w:\\bc.txt"
  echo "exit"
} > "$W/build.conf"

## Headless: a -j8 build launches up to 8 of these at once, and without
## this every one of them pops a real window.
SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-120}" "$DOSBOX_BIN" -nolog -conf "$W/build.conf" >/dev/null 2>&1 || true

if [[ ! -f "$W/$base.obj" ]]; then
    echo "== bc FAILED: $SRC_REL" >&2
    [[ -f "$W/bc.txt" ]] && tr -d '\r' < "$W/bc.txt" | tail -30 >&2
    exit 1
fi
# BC can leave a stale/partial .obj from a previous crash in rare cases;
# the log's own error tally is the authoritative check, same principle
# tools/bcc.sh applies for bcc's summary line.
if [[ -f "$W/bc.txt" ]] && tr -d '\r' < "$W/bc.txt" | grep -qE "[0-9]+ Severe  Error"; then
    if ! tr -d '\r' < "$W/bc.txt" | grep -qE "^ *0 Severe  Error"; then
        echo "== bc errors: $SRC_REL" >&2
        tr -d '\r' < "$W/bc.txt" | tail -30 >&2
        exit 1
    fi
fi

mkdir -p "$(dirname "$OUT")"
cp "$W/$base.obj" "$OUT"
