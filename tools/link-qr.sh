#!/bin/bash
# Link qrender.exe from already-compiled .obj files (tools/bc.sh and
# tools/bcc-qr.sh). The one step in this pipeline that is NOT per-file:
# LINK needs every object at once, so it gets its own single isolated
# DOSBox session rather than one per module.
#
#   tools/link-qr.sh <build-dir> "<bas-mods, main first>" "<c-mods>"
#
# vbd only -- see tools/bc.sh's own note on why.
set -euo pipefail

OUT="${1:?usage: link-qr.sh <build-dir> <bas-mods> <c-mods>}"
BAS_MODS="${2:?usage: link-qr.sh <build-dir> <bas-mods> <c-mods>}"
C_MODS="${3:-}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
MGL="${MGL:-$HOME/work/badlogic/mgl}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

# Four objects per line, not one giant one: LINK's response file has its
# own line-length limit, distinct from the DOS 127-char command-line cap
# the response file itself exists to route around. A '+' at the end of a
# line continues the object list onto the next, same as it separates
# names on one line -- see tools/dosbox.sh's own copy of this note.
OBJS=""; n=0
for m in $BAS_MODS; do
    OBJS="$OBJS$m.obj+"; n=$((n+1))
    [[ $((n % 4)) -eq 0 ]] && OBJS="$OBJS"$'\r\n'
done
for m in $C_MODS; do
    up=$(echo "$m" | tr 'a-z' 'A-Z')
    OBJS="$OBJS$up.OBJ+"; n=$((n+1))
    [[ $((n % 4)) -eq 0 ]] && OBJS="$OBJS"$'\r\n'
done
OBJS="${OBJS}M:\\LIB\\ADDONS\\U3D.OBJ"

# MATHC.LIB/CL.LIB supply bcc's own codegen support (F_FTOL@, F_SCOPY@)
# for a float-to-long cast or a whole-struct assignment -- not app-level
# stdlib, and only pulled in when a C module is actually part of the
# build. Same reasoning as tools/dosbox.sh's own CLIBS.
CLIBS=""
[[ -n "$C_MODS" ]] && CLIBS="+B:\\LIB\\MATHC.LIB+B:\\LIB\\CL.LIB"

{
  printf '%s\r\n' \
    "/NOE /MAP /SEG:800 $OBJS" \
    'qrender.exe' \
    'qrender.map' \
    "V:\\LIB\\VBDCL10E.LIB+C:\\UGLV.LIB$CLIBS" \
    ';'
} > "$OUT/link.rsp"

{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=64\nstartbanner=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\nems=true\n[autoexec]\n'
  echo "@echo off"
  echo "mount c $OUT"
  echo "mount v $TOOLCHAINS/vbdos"
  echo "mount m $MGL"
  echo "mount b $TOOLCHAINS/bcpp31"
  echo "c:"
  echo "if exist qrender.exe del qrender.exe"
  echo "if exist link.out del link.out"
  echo "V:\\BIN\\LINK.EXE @link.rsp > link.out"
  echo "exit"
} > "$OUT/link.conf"

SDL_VIDEODRIVER=dummy timeout "${TIMEOUT:-120}" "$DOSBOX_BIN" -nolog -conf "$OUT/link.conf" >/dev/null 2>&1 || true

# LINK emits an EXE even with an unresolved external -- the call site is
# patched to an int 3 and the program dies the moment it reaches it, so
# "did an exe appear" is not the authoritative check. See tools/dosbox.sh's
# own copy of this note.
if [[ -f "$OUT/link.out" ]] && grep -qiE "unresolved external|error L[0-9]" "$OUT/link.out"; then
    echo "== LINK errors:" >&2
    grep -i "error\|unresolved" "$OUT/link.out" >&2
    exit 1
fi
if [[ ! -f "$OUT/qrender.exe" ]]; then
    echo "== LINK produced no exe" >&2
    [[ -f "$OUT/link.out" ]] && tail -30 "$OUT/link.out" >&2
    exit 1
fi
