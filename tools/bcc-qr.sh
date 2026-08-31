#!/bin/bash
# Compile one of qrender's OWN C modules (r_walk.c, sb_build.c, pl_trace.c,
# r_span.c -- not mgl's) with Borland C++ 3.1 under DOSBox-X.
#
#   tools/bcc-qr.sh src/r_span.c build/vbd/r_span.obj
#
# One DOSBox per file, same reasoning as tools/bcc.sh and tools/bc.sh.
# A SEPARATE script from tools/bcc.sh on purpose: that one carries mgl's
# own include root (mgl's inc/) and __BASLIB__ define for sources this
# project does not own and must not reinterpret. Otherwise the same
# flags qrender's own C has always used: -3 -mm -Ox -IW:\ -IB:\INCLUDE.
#
# -B, and TASM mounted on the path, unconditionally: r_span.c's rdtsc_now
# uses __emit__ plus an __asm { } block referencing ebx, which BCC's own
# built-in inline assembler does not accept ("Undefined symbol 'ebx'")
# -- only TASM's fuller support does. Harmless for the other three C
# files, which have no inline asm of their own; simpler to always pass
# it than to special-case the one file that needs it.
set -euo pipefail

SRC_REL="${1:?usage: bcc-qr.sh <src-c> <out-obj>}"
OUT="${2:?usage: bcc-qr.sh <src-c> <out-obj>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

base=$(basename "$SRC_REL" .c)
up=$(echo "$base" | tr 'a-z' 'A-Z')

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$ROOT/src/$base.c" "$W/"
cp "$ROOT"/src/*.h "$W/" 2>/dev/null || true

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $W"
  echo "mount b $TOOLCHAINS/bcpp31"
  echo "mount t $TOOLCHAINS/tasm50/TASM/BIN"
  echo "path b:\\bin;t:"
  echo "w:"
  echo "b:\\bin\\bcc.exe -c -B -3 -mm -Ox -IW:\\ -IB:\\INCLUDE $base.c > w:\\cc.txt"
  echo "exit"
} > "$W/build.conf"

## Headless: a -j8 build launches several of these at once, and without
## this every one of them pops a real window.
SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-120}" "$DOSBOX_BIN" -nolog -conf "$W/build.conf" >/dev/null 2>&1 || true

if [[ ! -f "$W/$up.OBJ" && ! -f "$W/$base.obj" ]]; then
    echo "== bcc-qr FAILED: $SRC_REL" >&2
    [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | tail -30 >&2
    exit 1
fi
if [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | grep -qE "\*\*\* [0-9]+ errors|^Fatal"; then
    echo "== bcc-qr errors: $SRC_REL" >&2
    tr -d '\r' < "$W/cc.txt" | grep -E "^Error |^Fatal|\*\*\*" | head -20 >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [[ -f "$W/$up.OBJ" ]]; then cp "$W/$up.OBJ" "$OUT"; else cp "$W/$base.obj" "$OUT"; fi
