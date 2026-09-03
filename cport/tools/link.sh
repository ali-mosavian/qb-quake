#!/bin/bash
# Link the standalone-cport objects into QCPORT.EXE, medium model,
# against uGL built with __CMP__=BC (not __CMP__=VBD -- that one pulls
# B$SETM and drags VBDCL10E.LIB back in). One DOSBox session: unlike
# compiling, linking needs every object at once.
#
#   cport/tools/link.sh build/cport "qmain vid d_poly"
set -euo pipefail

OUT="${1:?usage: link.sh <build-dir> <obj-names>}"
OBJS="${2:?usage: link.sh <build-dir> <obj-names>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
UGL="${CPORT_UGL:-$ROOT/build/native-mgl-bc/UGLV.LIB}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }
[[ -f "$UGL" ]] || { echo "no C-convention uGL at $UGL -- build it: make -f tools/native/Makefile BUILD=\$PWD/build/native-mgl-bc JWASMFLAGS=\"-c -Cp -Zg -D__CMP__=BC -I\$MGL/src/inc -omf\"" >&2; exit 1; }

cp "$UGL" "$OUT/UGLC.LIB"

objlist=""
for o in $OBJS; do
    up=$(echo "$o" | tr 'a-z' 'A-Z')
    objlist="$objlist+$up.OBJ"
done
objlist="${objlist#+}"

## DOS command lines cap at 127 chars -- TLINK's own line is well past
## that once there's more than a couple of objects (measured: 165 chars
## for 4). A response file sidesteps the limit entirely; TLINK reads
## one field per line in the same order the command line would have
## them (objs / exe,map / libs), '+' continuation works the same way.
{
  echo "T:\\LIB\\C0M.OBJ+$objlist"
  echo "QCPORT.EXE"
  echo "QCPORT.MAP"
  # FP87.LIB: MATHM.LIB's own objects reference FIDRQQ/FIWRQQ/FIERQQ
  # (the 8087 exception handlers) without defining them -- this project
  # always assumes real FPU hardware (see r_ptproj.asm and friends), so
  # FP87 not EMU.
  # CC.LIB: bcc's own struct-assignment helper F_SCOPY@ (any `a = b;`
  # where a/b are structs, e.g. Vec3) is model-independent compiler
  # support, not part of tc201's medium-model runtime pair -- it lives
  # in bcpp31's own CC.LIB, confirmed present by string search.
  # MATHC.LIB: F_FTOL@ (the float/double-to-int cast helper, e.g.
  # `(short) some_float_expr`) isn't in tc201's MATHM.LIB (which has
  # only the differently-named FTOL@) -- it's in bcpp31's own MATHC.LIB.
  # Listed after MATHM.LIB, so it only ever contributes the handful of
  # modules MATHM.LIB doesn't already satisfy -- a library only pulls
  # in an object for a symbol still unresolved when it's scanned, so
  # this can't collide with anything MATHM.LIB already provided.
  echo "UGLC.LIB+T:\\LIB\\MATHM.LIB+T:\\LIB\\CM.LIB+T:\\LIB\\FP87.LIB+B:\\LIB\\CC.LIB+B:\\LIB\\MATHC.LIB"
} > "$OUT/LINK.RSP"

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\nems=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount w $OUT"
  echo "mount b $TOOLCHAINS/bcpp31"
  echo "mount t $TOOLCHAINS/tc201"
  echo "path b:\\bin"
  echo "w:"
  echo "b:\\bin\\tlink.exe /c @LINK.RSP > w:\\lk.txt"
  echo "exit"
} > "$OUT/link.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-120}" "$DOSBOX_BIN" -nolog -conf "$OUT/link.conf" >/dev/null 2>&1 || true

if [[ ! -f "$OUT/QCPORT.EXE" ]]; then
    echo "== link FAILED" >&2
    [[ -f "$OUT/lk.txt" ]] && tr -d '\r' < "$OUT/lk.txt" | tail -30 >&2
    exit 1
fi
if [[ -f "$OUT/lk.txt" ]] && tr -d '\r' < "$OUT/lk.txt" | grep -qiE "error|warning.*unresolved"; then
    echo "== link warnings/errors:" >&2
    tr -d '\r' < "$OUT/lk.txt" | grep -iE "error|unresolved" | head -20 >&2
fi
