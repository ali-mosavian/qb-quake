#!/bin/bash
# Link the standalone-cport objects into QCPORT.EXE, medium model. The
# graphics layer is qgl, assembled natively into the same object list --
# there is no UGLV.LIB here and no BASIC runtime.
#
# jwlink, natively, not DOS LINK under DOSBox. Three reasons, in order
# of how much they cost to learn:
#
# 1. DOS LINK takes its output paths from POSITIONAL fields of a
#    response file, and CREATES the list file before it validates
#    anything. One stray '+' at the end of the object list shifts every
#    later field up by one, so the LIBRARY field lands in the list-file
#    slot and LINK truncates a library to zero bytes on its way to
#    reporting an unrelated error. That is not hypothetical: it
#    destroyed tc201's MATHM.LIB here, and the next run's only symptom
#    was "L1102: unexpected end-of-file" naming nothing.
#    cport/tools/test-link-guard.sh is the regression test.
# 2. TLINK 5.1 refuses jwasm's 32-bit OMF fixups (qgl addresses
#    gs:[ebp*2+imm32] in the span fillers) and DOS LINK needs
#    /NOE /MAP /SEG:800 plus four-objects-per-line CRLF response files
#    to get as far as trying. jwlink reads all of it without ceremony.
# 3. It is a native binary: no emulator boot per link.
#
# Every object name is single-quoted because wlink's directive parser
# has keywords -- an unquoted `config.obj` is the `config` directive.
#
#   cport/tools/link.sh build/cport "qmain vid d_poly"
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: link.sh <build-dir> <obj-names>}"
OBJS="${2:?usage: link.sh <build-dir> <obj-names>}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
JWLINK="${JWLINK:-$TOOLCHAINS/native/bin/jwlink}"

# One product, one memory model. bcc.sh compiles with bcpp31's own
# bcc -mm, so the startup and runtime are bcpp31's own medium-model
# pair; mixing in tc201's (which is what the DOS-LINK version did, for
# want of a C0M/CM pair in this bcpp31 copy) pulls NEAR-code math
# modules -- sqrt, sin, cos, atan2 -- into a FAR-code program, which
# links clean and crashes on the first call.
BCLIB="${BCLIB:-$TOOLCHAINS/bcpp31/LIB}"
for f in C0M.OBJ CM.LIB MATHM.LIB FP87.LIB; do
    [[ -s "$BCLIB/$f" ]] || { echo "link.sh: $BCLIB/$f missing or empty" >&2; exit 1; }
done

{
  echo "format dos"
  echo "option quiet, map=$OUT/QCPORT.MAP"
  [[ "${DEBUGINFO:-1}" == "0" ]] || echo "debug codeview"
  echo "name $OUT/QCPORT.EXE"
  echo "file '$BCLIB/C0M.OBJ'"
  for o in $OBJS; do echo "file '$OUT/$o.obj'"; done
  # FP87 not EMU: this project assumes real FPU hardware throughout
  # (see r_ptproj.asm and friends).
  echo "library '$BCLIB/CM.LIB'"
  echo "library '$BCLIB/MATHM.LIB'"
  echo "library '$BCLIB/FP87.LIB'"
} > "$OUT/QCPORT.LNK"

rm -f "$OUT/QCPORT.EXE"
"$JWLINK" @"$OUT/QCPORT.LNK" > "$OUT/lk.txt" 2>&1 || true

if [[ ! -f "$OUT/QCPORT.EXE" ]]; then
    echo "== link FAILED" >&2
    tail -30 "$OUT/lk.txt" >&2
    exit 1
fi
if grep -qiE 'undefined reference|Error!' "$OUT/lk.txt"; then
    echo "== link errors:" >&2
    grep -iE 'undefined reference|Error!' "$OUT/lk.txt" | head -20 >&2
    exit 1
fi

# The one thing that links clean and cannot start: near data plus the
# stack past 64K. See dgroup-check.sh.
STKLEN=$(sed -n 's/^unsigned _stklen = \([0-9]*\)U*;.*/\1/p' "$HERE/../src/qmain.c")
[[ -n "$STKLEN" ]] || { echo "link.sh: no _stklen in src/qmain.c" >&2; exit 1; }
"$HERE/dgroup-check.sh" "$OUT/QCPORT.MAP" "$STKLEN" || exit 1
