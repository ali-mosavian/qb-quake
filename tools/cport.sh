#!/bin/bash
# Build the standalone C port probe: bcc only, no BASIC runtime.
#
# MEDIUM model (-mm), and it is not a preference: mgl addresses its own
# dispatch tables through SS (`call ss:ul$dctTB[bp].wrBegin` in ul$rectf,
# and 927 other `ss:` references), which is only correct while SS is
# DGROUP. Under BASIC it always is. Large model puts _STACK in its own
# segment -- measured SS=0x1317 against DS=0x1175 -- so every one of
# those reads lands in the wrong place; uglRectF dispatched through
# garbage and span in ROM at F000:CA64. Medium keeps the stack inside
# DGROUP, so SS==DS and mgl's assumption holds.
#
# bcpp31 ships no C0M/CM pair, so the medium runtime comes from tc201
# (Turbo C 2.01) alongside it. Medium is also what this project's
# BASIC-hosted C modules already compile with.
#
# mgl is called `far pascal`: inc/2dfx.h's UGLAPI is `far pascal`, and
# lang.inc under __CMP__=BC changes only STRING/ARRAY to raw far
# pointers -- it does NOT switch the langtype to C.
#
# The library is uGL built with __CMP__=BC (see the make line below),
# NOT the __CMP__=VBD uglv.lib the BASIC renderer links -- that one
# pulls B$SETM and would drag VBDCL10E.LIB back in.
#
#   make -f tools/native/Makefile BUILD=$PWD/build/native-mgl-bc \
#        JWASMFLAGS="-c -Cp -Zg -D__CMP__=BC -I$MGL/src/inc -omf"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${CPORT_OUT:-$ROOT/build/cport}"
UGL="${CPORT_UGL:-$ROOT/build/native-mgl-bc/UGLV.LIB}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
DOSBOX_BIN="${DOSBOX_BIN:-$HOME/work/other/dosbox-x-debug/src/dosbox-x}"

[[ -f "$UGL" ]] || { echo "no C-convention uGL at $UGL" >&2; exit 1; }
mkdir -p "$OUT"
cp "$ROOT"/src/cport/*.c "$ROOT"/src/cport/*.h "$OUT/"
cp "$UGL" "$OUT/UGLC.LIB"

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\nems=true\n[autoexec]\n'
  printf '%s\n' '@echo off'
  printf '%s\n' "mount w $OUT"
  printf '%s\n' "mount b $TOOLCHAINS/bcpp31"
  printf '%s\n' "mount t $TOOLCHAINS/tc201"
  printf '%s\n' 'path b:\bin'
  printf '%s\n' 'w:'
  printf '%s\n' 'b:\bin\bcc.exe -c -3 -mm -Ox -IW:\ -IB:\INCLUDE qmain.c > w:\cc.txt'
  printf '%s\n' 'b:\bin\tlink.exe /c T:\LIB\C0M.OBJ+QMAIN.OBJ,qcport.exe,qcport.map,UGLC.LIB+T:\LIB\MATHM.LIB+T:\LIB\CM.LIB > w:\lk.txt'
  printf '%s\n' 'exit'
} > "$OUT/build.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-180}" "$DOSBOX_BIN" -nolog -conf "$OUT/build.conf" >/dev/null 2>&1 || true
echo "== compile =="; tr -d '\r' < "$OUT/CC.TXT" 2>/dev/null | tail -12 || echo "(no cc.txt)"
echo "== link =="   ; tr -d '\r' < "$OUT/LK.TXT" 2>/dev/null | tail -12 || echo "(no lk.txt)"
[[ -f "$OUT/QCPORT.EXE" ]] && ls -l "$OUT/QCPORT.EXE" || echo "NO EXE"
