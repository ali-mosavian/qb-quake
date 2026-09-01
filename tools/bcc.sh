#!/bin/bash
# Compile one µGL C source with Borland C++ 3.1 under DOSBox-X.
#
#   tools/bcc.sh src/music/modcmn.c build/native-mgl/MUSIC/modcmn.obj
#
# One DOSBox per file, deliberately: each invocation is independent, so a
# Makefile pattern rule can run these under -j. A single shared session would
# serialise the whole sub-library.
#
# music/, xsnd/ and xsnd/snddrv/ are C, not assembler, so jwasm can't touch
# them. bcc 3.1 is the compiler they were written for -- and four of the files
# (modcmn, sndconv, sndmixer, sbdrv) contain inline asm, which needs -B, which
# makes bcc shell out to TASM. Hence tasm50 on the path too.
#
# Compiled as C, not C++ (no -P): these exports are `far pascal`, and C++
# would mangle them (@MODINIT$QV) so the BASIC side could not find MODINIT.
#
# mgl's own inc/ must precede Borland's: these sources do #include "dos.h"
# meaning mgl's inc/dos.h, and C:\INCLUDE\DOS.H would otherwise shadow it,
# leaving DOSFILE/BFILE undefined in arch.h.
#
# Flags mirror src/common.mk's own rule:
#   bcc -c -B -3 -mm -Ox /D__BASLIB__=TRUE -I<mgl>/inc
set -euo pipefail

SRC_REL="${1:?usage: bcc.sh <src-rel-path> <out-obj>}"
OUT="${2:?usage: bcc.sh <src-rel-path> <out-obj>}"
MGL="${MGL:-$HOME/work/badlogic/mgl}"
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
# compile from inside the source directory, as src/common.mk's rule does:
# these sources use quoted includes relative to their own dir ("inc/modcmn.h"),
# which bcc resolves against the current directory, not the source file's.
dos_dir="\\$(dirname "$SRC_REL" | tr '/' '\\')"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $W"
  echo "mount m $MGL"
  echo "mount c $TOOLCHAINS/bcpp31"
  echo "mount t $TOOLCHAINS/tasm50/TASM/BIN"
  echo "path c:\\bin;t:"
  echo "m:"
  echo "cd $dos_dir"
  echo "bcc -c -B -3 -mm -Ox -D__BASLIB__=TRUE -nW:\\ -IM:\\INC -IC:\\INCLUDE $base.c > W:\\cc.txt"
  echo "exit"
} > "$W/build.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-240}" "$DOSBOX_BIN" -nolog -conf "$W/build.conf" >/dev/null 2>&1 || true

if [[ ! -f "$W/$up.OBJ" && ! -f "$W/$base.obj" ]]; then
    echo "== bcc FAILED: $SRC_REL" >&2
    [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | tail -20 >&2
    exit 1
fi
# bcc may emit an object even after errors, so check the log too. Match only
# bcc's own summary ("*** 2 errors in Compile ***") and Fatal lines -- a bare
# "^Error" also matches TASM's "Error messages:    None" tally and would fail
# every file that assembles cleanly.
if [[ -f "$W/cc.txt" ]] && tr -d '\r' < "$W/cc.txt" | grep -qE "\*\*\* [0-9]+ errors|^Fatal"; then
    echo "== bcc errors: $SRC_REL" >&2
    tr -d '\r' < "$W/cc.txt" | grep -E "^Error |^Fatal|\*\*\*" | head -20 >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
if [[ -f "$W/$up.OBJ" ]]; then cp "$W/$up.OBJ" "$OUT"; else cp "$W/$base.obj" "$OUT"; fi
