#!/bin/bash
# Rebuild uGL assembler modules and swap them into uglv.lib, without dmake.
#
#   tools/mglbuild.sh uglplxtg uglpltpg ugllut   rebuild these modules
#   tools/mglbuild.sh --all                      rebuild every .asm module (151)
#   tools/mglbuild.sh --list                     print the module -> directory map
#
# Why not dmake: mgl's makefiles are dmake's dialect -- .IF, :=, {list}.obj,
# $(mktmp ...) -- and no dmake exists on this machine or in the toolchains.
# The recipes it would run are two commands, so this drives them directly.
#
# Why in place rather than from scratch: three sub-libraries (music, xsnd,
# xsnd/snddrv) are C, built with Borland bcc. Updating the shipped library
# module by module leaves those alone and needs only MASM.
#
# The shipped uglv.lib is stale against src/ -- uglTriTG, uglTriTPG, uglSetLUT
# and uglBlit are all in the sources and the module lists but not in the
# library. Rebuilding a module is how you get it back.
#
# Builds run on the dynamic core at cycles=max. That is only safe because
# there is no debug socket here -- the socket needs core=normal and a fixed
# cycle count or the guest starves it.
#
# Env: MGL, TOOLCHAINS, DOSBOX_BIN as in dosbox.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGL="${MGL:-$HOME/work/badlogic/mgl}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
LIB="$MGL/lib/release/vbd/uglv.lib"
MASM="$TOOLCHAINS/masm611/work"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }
[[ -f "$LIB" ]] || { echo "not found: $LIB  (set MGL)" >&2; exit 1; }

# module -> source directory, read out of the .mk ASMLIST declarations
map_modules () {
    /usr/bin/python3 - "$MGL" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]) / "src"
for mk in sorted(src.rglob("*.mk")):
    if mk.name in ("common.mk", "startup.mk", "makefile.mk"):
        continue
    m = re.search(r'ASMLIST\s*[:+]?=\s*((?:[^\n\\]*\\\s*\n)*[^\n]*)', mk.read_text())
    if not m:
        continue
    for mod in m.group(1).replace("\\", "").split():
        print(mod, mk.parent.relative_to(src).as_posix())
PY
}

case "${1:-}" in
  --list) map_modules; exit 0 ;;
  --all)  mods=$(map_modules | cut -d' ' -f1) ;;
  "")     echo "usage: $0 [--all|--list|module ...]" >&2; exit 1 ;;
  *)      mods="$*" ;;
esac

MAP=$(map_modules)
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$LIB" "$W/UGLV.LIB"
[[ -f "$LIB.orig" ]] || cp "$LIB" "$LIB.orig"     # keep the shipped one, once

{ echo "@echo off"
  echo "mount w $W"
  echo "mount m $MGL"
  echo "mount a $MASM"
  echo "mount t $MGL/tools/liblink"
  echo "path a:;t:"
  echo "w:"
} > "$W/head.txt"

n=0
for m in $mods; do
    dir=$(echo "$MAP" | awk -v k="$m" '$1==k {print $2; exit}')
    [[ -n "$dir" ]] || { echo "unknown module: $m" >&2; exit 1; }
    dos_dir=$(echo "$dir" | tr '/' '\\')
    up=$(echo "$m" | tr 'a-z' 'A-Z')
    # /omf is not a MASM 6.11 option and an invalid option aborts parsing of
    # everything after it -- including /D, which then silently does not apply.
    echo "ml /c /Cp /D__CMP__=VBD /IM:\\SRC\\INC /FoW:\\$up.OBJ M:\\SRC\\$dos_dir\\$m.asm >> ml.txt"
    # LIB's -+ replace does not match uGL's lowercase module names; delete then
    # add. The trailing ; suppresses the prompts it would otherwise block on.
    echo "lib16 /NOI UGLV.LIB -$m; >> lib.txt"
    echo "lib16 /NOI UGLV.LIB +$up.OBJ; >> lib.txt"
    n=$((n+1))
done > "$W/body.txt"

# The commands go into a batch file on W: rather than straight into
# [autoexec]: --all emits 3 lines per module (453 for 151 modules) and
# dosbox-x silently truncates an oversized autoexec, so the run ended after
# the mounts with nothing built and no error anywhere.
cp "$W/body.txt" "$W/build.bat"
{ cat "$W/head.txt"; echo "call build.bat"; echo "exit"; } > "$W/auto.txt"
{ printf '[sdl]\nautolock=false\n[dosbox]\nmemsize=32\nstartbanner=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=max\n[dos]\nxms=true\n[autoexec]\n'
  cat "$W/auto.txt"
} > "$W/build.conf"

echo "assembling $n module(s)..."
timeout "${TIMEOUT:-900}" "$DOSBOX_BIN" -nolog -conf "$W/build.conf" >/dev/null 2>&1 || true

if grep -qiE "error A[0-9]|fatal" "$W/ml.txt" 2>/dev/null; then
    echo "== ASSEMBLY FAILED"; grep -iE -B2 "error A[0-9]|fatal" "$W/ml.txt" | head -30; exit 1
fi
built=$(ls "$W"/*.OBJ 2>/dev/null | wc -l | tr -d ' ')
[[ "$built" == "$n" ]] || { echo "== only $built of $n objects built"; exit 1; }

# lib16's output was previously never inspected, so a librarian failure left a
# silently stale library behind and the assembly check above still passed.
# Deleting a module the library does not have yet is expected -- for modules
# the shipped library predates, and for brand new ones being added. LIB says
# U2155 for that (U4151 in some versions); neither is a real failure, so
# filter them out and let anything else count.
if grep -iE "error U[0-9]|fatal|cannot " "$W/lib.txt" 2>/dev/null | grep -qvE "U2155|U4151"; then
    echo "== LIBRARIAN FAILED"
    grep -iE -B2 "error U[0-9]|fatal|cannot " "$W/lib.txt" | grep -vE "U2155|U4151" | head -30
    exit 1
fi

cp "$W/UGLV.LIB" "$LIB"
echo "== $n module(s) rebuilt and installed into $LIB"
echo "   original preserved at $LIB.orig"
