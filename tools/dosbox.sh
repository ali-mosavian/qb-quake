#!/bin/bash
# Build or run bsp_pvs under DOSBox-X on the host, no DOS machine needed.
#
#   tools/dosbox.sh build [qb45|pds|vbd]   compile + link  (default vbd)
#   tools/dosbox.sh run   [map.bsp]        run the built exe (default dm3ish.bsp)
#
# Env overrides:
#   MGL          uGL tree            (default ~/work/badlogic/mgl)
#   TOOLCHAINS   compiler collection (default ~/work/other/d32x/toolchains)
#   DOSBOX_BIN   dosbox-x binary     (default: first found on PATH)
#   TIMEOUT      seconds             (default 300 build / 900 run)
#
# Artifacts land in build/<target>/ on the host side.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGL="${MGL:-$HOME/work/badlogic/mgl}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"

cmd="${1:-build}"; arg="${2:-}"

for d in "$MGL/inc" "$MGL/lib"; do
    [[ -d "$d" ]] || { echo "not found: $d  (set MGL)" >&2; exit 1; }
done

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

launch () {   # $1 = conf file, $2 = timeout
    SDL_VIDEODRIVER=dummy timeout "$2" "$DOSBOX_BIN" -nolog -conf "$1" -exit >/dev/null 2>&1 || true
}

case "$cmd" in
build)
    tc="${arg:-vbd}"
    case "$tc" in
      vbd)  cdir=vbdos;  bc='V:\BIN\BC.EXE /O /FPi /R /G3 /E';         lnk='V:\BIN\LINK.EXE';  rt='V:\LIB\VBDCL10E.LIB';   ugl='M:\LIB\RELEASE\VBD\UGLV.LIB' ;;
      pds)  cdir=pds71;  bc='V:\BINB\BC.EXE /O /FPi /R /G2 /FS /LR /ES'; lnk='V:\BINB\LINK.EXE'; rt='V:\LIB\BCL71EFR.LIB'; ugl='M:\LIB\RELEASE\PDS\UGLP.LIB' ;;
      qb45) cdir=qb45;   bc='V:\BC.EXE /O /FPi /R';                    lnk='V:\LINK.EXE';      rt='V:\LIB\BCOM45.LIB';    ugl='M:\LIB\RELEASE\QB\UGL.LIB' ;;
      *) echo "unknown target: $tc (want vbd, pds or qb45)" >&2; exit 1 ;;
    esac
    out="$ROOT/build/$tc"
    mkdir -p "$out"
    cp "$ROOT"/bsp_pvs.bas "$ROOT"/bsp_pvs.bi "$ROOT"/stuff.ini "$ROOT"/base.dat "$out/"

    # u3d is a uGL addon and is not inside the uglX.lib -- link it explicitly.
    printf '%s\r\n' \
      '@echo off' \
      'if exist result.txt del result.txt' \
      'if exist bsp_pvs.obj del bsp_pvs.obj' \
      'if exist bsp_pvs.exe del bsp_pvs.exe' \
      "$bc bsp_pvs.bas, bsp_pvs.obj; > bc.out" \
      'if not exist bsp_pvs.obj goto bcfail' \
      "$lnk /NOE /SEG:800 bsp_pvs.obj+M:\\LIB\\ADDONS\\U3D.OBJ, bsp_pvs.exe, bsp_pvs.map, $rt+$ugl; > link.out" \
      'if not exist bsp_pvs.exe goto linkfail' \
      'echo PASS > result.txt' \
      'goto end' \
      ':bcfail' \
      'echo BCFAIL > result.txt' \
      'goto end' \
      ':linkfail' \
      'echo LINKFAIL > result.txt' \
      ':end' > "$out/build.bat"

    conf="$out/dosbox.conf"
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$TOOLCHAINS/$cdir|" -e "s|@MDRIVE@|$MGL|" \
        -e "s|@BAT@|build.bat|" -e "s|@PRE@||" "$ROOT/dosbox/template.conf" > "$conf"

    launch "$conf" "${TIMEOUT:-300}"
    echo "== $tc: $(cat "$out/result.txt" 2>/dev/null || echo NO-RESULT)"
    [[ -s "$out/bc.out"   ]] && sed -n '4,40p' "$out/bc.out"
    [[ -s "$out/link.out" ]] && grep -i error "$out/link.out" || true
    [[ -f "$out/bsp_pvs.exe" ]] && ls -l "$out/bsp_pvs.exe"
    ;;
run)
    map="${arg:-dm3ish.bsp}"
    out="$ROOT/build/vbd"
    [[ -f "$out/bsp_pvs.exe" ]] || { echo "no exe; run: tools/dosbox.sh build" >&2; exit 1; }
    cp "$ROOT/$map" "$out/"
    rm -f "$out"/*.bmp "$out"/*.BMP "$out"/ran.txt "$out"/RAN.TXT

    printf '%s\r\n' \
      '@echo off' \
      'if exist ran.txt del ran.txt' \
      "bsp_pvs.exe $map > run.out" \
      'echo DONE > ran.txt' > "$out/run.bat"

    conf="$out/dosbox-run.conf"
    # 's' screenshots the backbuffer; fire a series so at least one lands
    # after the (slow) texture conversion finishes.
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$out|" -e "s|@MDRIVE@|$out|" \
        -e "s|@BAT@|run.bat|" -e "s|@PRE@|autotype -w 60 -p 45.0 s s s s s s s s s s s s|" \
        "$ROOT/dosbox/template.conf" > "$conf"

    launch "$conf" "${TIMEOUT:-900}"
    echo "== exited: $(cat "$out/ran.txt" 2>/dev/null || echo 'did not return to DOS')"
    cat "$out/run.out" 2>/dev/null
    ls -l "$out"/*.bmp "$out"/*.BMP 2>/dev/null || echo "(no screenshot captured)"
    ;;
*) sed -n '2,16p' "$0"; exit 1 ;;
esac
