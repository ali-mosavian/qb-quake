#!/bin/bash
# Compile one standalone-cport C module with Borland C++ 3.1, medium
# model, under DOSBox-X.
#
#   cport/tools/bcc.sh cport/src/vid.c build/cport/vid.obj
#
# One DOSBox per file -- same reasoning as the main project's
# tools/bc.sh and tools/bcc-qr.sh: `make -jN` genuinely parallelises
# only if each compile is its own DOSBox session, not one shared batch.
#
# -mm (medium model) is not a preference: mgl addresses its own
# dispatch tables through SS in 927 places, which is only correct
# while SS is DGROUP -- see cport/README or tools/cport.sh's own note.
# All of qrender's BASIC-hosted C already compiles this way too.
set -euo pipefail

SRC="${1:?usage: bcc.sh <src-c> <out-obj>}"
OUT="${2:?usage: bcc.sh <src-c> <out-obj>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CPORT="$ROOT/cport"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
MGL="${MGL:-$HOME/work/badlogic/mgl}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

base=$(basename "$SRC" .c)
up=$(echo "$base" | tr 'a-z' 'A-Z')

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$CPORT/src/$base.c" "$W/"
cp "$CPORT"/src/*.h "$W/" 2>/dev/null || true

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $W"
  echo "mount b $TOOLCHAINS/bcpp31"
  echo "mount t $TOOLCHAINS/tasm50/TASM/BIN"
  echo "mount m $MGL/inc"
  echo "path b:\\bin;t:"
  echo "w:"
  # -B: bcc's own built-in inline assembler predates FSIN (same
  # reasoning as r_span.c's rdtsc_now needing it for RDTSC) -- only
  # TASM's fuller instruction set accepts it. Harmless for files with
  # no inline asm, so passed unconditionally rather than special-cased.
  #
  # -IM:\ : mgl's own real headers (UAR, u3dVector3f/u3dMtrx, MOUSEINF,
  # TKBD, TMR, RGB and most of ugl.h itself) -- used directly rather
  # than hand-transcribed. uglpatch.h supplies only the handful of
  # entries the shipped headers haven't caught up to yet
  # (uglPolyTP/uglBuildSurf/uglNewView/uglSetView/uglZMode/uglClearZ).
  #
  # -f87: without it, TASM emits FNSTCW/FLDCW (control-word save/
  # restore, needed for a truncating float-to-int cast -- see ent.c's
  # ftol_short) through its 8087-emulation macros, which don't cover
  # those two opcodes and fail with "Can't emulate 8087 instruction".
  # -f87 tells bcc to assume real FPU hardware and emit the plain
  # opcodes instead, consistent with this project already assuming a
  # real 8087 everywhere else (r_ptproj.asm and friends).
  echo "b:\\bin\\bcc.exe -c -B -3 -f87 -mm -Ox -IW:\\ -IM:\\ -IB:\\INCLUDE $base.c > w:\\cc.txt"
  echo "exit"
} > "$W/build.conf"

## Headless: a -j8 build launches several of these at once, and without
## this every one of them pops a real window.
SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-120}" "$DOSBOX_BIN" -nolog -conf "$W/build.conf" >/dev/null 2>&1 || true

if [[ ! -f "$W/$up.OBJ" && ! -f "$W/$base.obj" ]]; then
    echo "== bcc FAILED: $SRC" >&2
    [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | tail -30 >&2
    exit 1
fi
if [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | grep -qE "\*\*\* [0-9]+ errors|^Fatal"; then
    echo "== bcc errors: $SRC" >&2
    tr -d '\r' < "$W/cc.txt" | grep -E "^Error |^Fatal|\*\*\*" | head -20 >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [[ -f "$W/$up.OBJ" ]]; then cp "$W/$up.OBJ" "$OUT"; else cp "$W/$base.obj" "$OUT"; fi
