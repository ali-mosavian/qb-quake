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

DBG=$([[ "${DEBUGINFO:-1}" == "0" ]] || echo " -v")
SRC="${1:?usage: bcc.sh <src-c> <out-obj>}"
OUT="${2:?usage: bcc.sh <src-c> <out-obj>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CPORT="$ROOT/cport"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"

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
  echo "path b:\\bin;t:"
  echo "w:"
  # -B: bcc's own built-in inline assembler predates FSIN (same
  # reasoning as r_span.c's rdtsc_now needing it for RDTSC) -- only
  # TASM's fuller instruction set accepts it. Harmless for files with
  # no inline asm, so passed unconditionally rather than special-cased.
  #
  # -v is CodeView, and it has to survive from the OBJ into the tail of
  # the EXE or the debugger can only say LMEM+0x943: bcc -v here and
  # link.sh's "debug codeview" both, or neither is any use. DEBUGINFO=0
  # for a lean build.
  echo "b:\\bin\\bcc.exe -c${DBG} -B -3 -f87 -mm -Ox -IW:\\ -IB:\\INCLUDE $base.c > w:\\cc.txt"
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
