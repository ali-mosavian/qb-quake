#!/bin/bash
# Build or run bsp_pvs under DOSBox-X on the host, no DOS machine needed.
#
#   tools/dosbox.sh build [qb45|pds|vbd]   compile + link  (default vbd)
#   tools/dosbox.sh run   [map.bsp]        headless run, screenshots via the 's' key
#   tools/dosbox.sh viz   [map.bsp]        emit a windowed config to watch it live
#
# Env overrides:
#   MGL          uGL tree            (default ~/work/badlogic/mgl)
#   TOOLCHAINS   compiler collection (default ~/work/other/d32x/toolchains)
#   DOSBOX_BIN   dosbox-x binary     (default: first found on PATH)
#   TIMEOUT      seconds             (default 300 build / 900 run)
#   QFLAGS       extra qrender args  (e.g. -lm, -ticks 120)
#
# Artifacts land in build/<target>/ on the host side.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGL="${MGL:-$HOME/work/badlogic/mgl}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"

cmd="${1:-build}"; arg="${2:-}"
# extra qrender arguments for the run/viz recipes, e.g. QFLAGS=-lm
QFLAGS="${QFLAGS:-}"

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
      vbd)  cdir=vbdos;  bc='V:\BIN\BC.EXE /O /FPi /R /G3 /E';         lnk='V:\BIN\LINK.EXE';  rt='V:\LIB\VBDCL10E.LIB';   ugl='C:\UGLV.LIB' ;;
      pds)  cdir=pds71;  bc='V:\BINB\BC.EXE /O /FPi /R /G2 /FS /LR /ES'; lnk='V:\BINB\LINK.EXE'; rt='V:\LIB\BCL71EFR.LIB'; ugl='M:\LIB\RELEASE\PDS\UGLP.LIB' ;;
      qb45) cdir=qb45;   bc='V:\BC.EXE /O /FPi /R';                    lnk='V:\LINK.EXE';      rt='V:\LIB\BCOM45.LIB';    ugl='M:\LIB\RELEASE\QB\UGL.LIB' ;;
      *) echo "unknown target: $tc (want vbd, pds or qb45)" >&2; exit 1 ;;
    esac
    out="$ROOT/build/$tc"
    ## VBD_OUT relocates the vbd tree only -- it is what check.sh isolates
    ## so two sessions do not share BENCH.BMP and bench.txt.
    [ "$tc" = vbd ] && out="${VBD_OUT:-$out}"
    mkdir -p "$out"
    cp "$ROOT"/src/*.bas "$ROOT"/src/*.bi "$ROOT"/data/stuff.ini "$ROOT"/data/base.dat "$out/"
    ##
    ## uGL comes from the NATIVE build (tools/native/Makefile), not from a
    ## prebuilt lib in the mgl tree: uglBuildSurf and the view API only exist
    ## in the one we assemble ourselves, and mixing a stale shipped lib with
    ## current headers is the trap mgl-lib-stale-vs-headers describes.
    ##
    ## NATIVE_UGL can point elsewhere. Two sessions building mgl into the
    ## same build/native-mgl overwrite each other's objects mid-archive,
    ## which shows up as symbols missing from a library whose sources
    ## plainly define them -- and as tests that pass and fail from
    ## identical source minutes apart.
    NATIVE_UGL="${NATIVE_UGL:-$ROOT/build/native-mgl/UGLV.LIB}"
    [[ -f "$NATIVE_UGL" ]] || {
        echo "no $NATIVE_UGL -- run: make -f tools/native/Makefile" >&2; exit 1; }
    cp "$NATIVE_UGL" "$out/UGLV.LIB"
    # Preprocessed assets (tools/mkassets.py): the .bmp textures texLoadAll
    # hands to uglNewBMPEx, and the .bld lumps model.bas BLOADs straight into
    # its arrays. Copy the whole directory -- naming the extensions here is
    # how the .bld files silently failed to stage the first time.
    cp "$ROOT"/data/assets/. "$out/" -R 2>/dev/null || \
        cp -R "$ROOT"/data/assets/* "$out/" 2>/dev/null || true
    # every .bas except the superseded rewrite is a module of the program
    # main must come first: it carries the module-level main code
    MODS="main $(cd "$ROOT/src" && ls *.bas | sed 's/\.bas$//' | grep -vx main | tr '\n' ' ')"
    OBJS=""; for m in $MODS; do OBJS="$OBJS$m.obj+"; done
    OBJS="${OBJS}M:\\LIB\\ADDONS\\U3D.OBJ"

    # one BC line per module, then one LINK line naming every object.
    # u3d is a uGL addon and is not inside the uglX.lib -- link it explicitly.
    {
        printf '%s\r\n' '@echo off' 'if exist result.txt del result.txt' \
                          'if exist bc.out del bc.out' \
                          'if exist *.obj del *.obj' 'if exist qrender.exe del qrender.exe'
        for m in $MODS; do printf '%s\r\n' "$bc $m.bas, $m.obj; >> bc.out"; done
    } > "$out/build.bat"
    printf '%s\r\n' \
      'if not exist main.obj goto bcfail' \
      "$lnk @link.rsp > link.out" \
      'if not exist qrender.exe goto linkfail' \
      'echo PASS > result.txt' \
      'goto end' \
      ':bcfail' \
      'echo BCFAIL > result.txt' \
      'goto end' \
      ':linkfail' \
      'echo LINKFAIL > result.txt' \
      ':end' >> "$out/build.bat"

    # LINK's command line would blow past the DOS 127-char limit once there
    # are several modules -- and a truncated line loses the trailing ';' that
    # suppresses its prompts, so it just sits there waiting. Response file.
    #
    # /MAP writes the PUBLICS into qrender.map. Without it the map carries
    # segments only, and a debugger can say "LMEM+0x943" but not which
    # routine that is.
    printf '%s\r\n' \
      "/NOE /MAP /SEG:800 $OBJS" \
      'qrender.exe' \
      'qrender.map' \
      "$rt+$ugl" \
      ';' > "$out/link.rsp"

    conf="$out/dosbox.conf"
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$TOOLCHAINS/$cdir|" -e "s|@MDRIVE@|$MGL|" \
        -e "s|@BAT@|build.bat|" -e "s|@PRE@||" "$ROOT/dosbox/template.conf" > "$conf"

    launch "$conf" "${TIMEOUT:-300}"

    # LINK emits an EXE even when a symbol is unresolved -- the call site is
    # patched to an int 3 and the program dies the moment it reaches it. The
    # batch file's "did an exe appear" test therefore reported PASS for a
    # build that could not run, so the authoritative check happens here.
    if grep -qiE "unresolved external|error L[0-9]" "$out/link.out" 2>/dev/null; then
        echo "LINKERR" > "$out/result.txt"
    fi

    echo "== $tc: $(cat "$out/result.txt" 2>/dev/null || echo NO-RESULT)"
    [[ -s "$out/bc.out"   ]] && sed -n '4,40p' "$out/bc.out"
    [[ -s "$out/link.out" ]] && grep -i error "$out/link.out" || true
    [[ -f "$out/qrender.exe" ]] && ls -l "$out/qrender.exe"
    ;;
run)
    map="${arg:-dm3ish.bsp}"
    out="${VBD_OUT:-$ROOT/build/vbd}"
    [[ -f "$out/qrender.exe" ]] || { echo "no exe; run: tools/dosbox.sh build" >&2; exit 1; }
    cp "$ROOT/data/$map" "$out/"
    ## Screenshot names only -- scrn*.bmp from the 's' key, bench.bmp from
    ## the benchmark. A blanket *.bmp takes the staged texture assets with
    ## it (build copies them into this very directory), which is the trap
    ## docs/bugs.md records.
    ## bench.txt and the error logs go too. A run that dies before writing
    ## its report leaves the PREVIOUS run's file sitting there, and reading
    ## it back reports the last map's numbers for this one -- which has
    ## already caused a stale figure to be quoted for a build that never
    ## produced it.
    rm -f "$out"/scrn*.bmp "$out"/SCRN*.BMP "$out"/bench.bmp "$out"/BENCH.BMP \
          "$out"/ran.txt "$out"/RAN.TXT "$out"/bench.txt "$out"/BENCH.TXT \
          "$out"/errmem.txt "$out"/ERRMEM.TXT "$out"/error.log "$out"/ERROR.LOG \
          "$out"/run.out "$out"/RUN.OUT

    printf '%s\r\n' \
      '@echo off' \
      'if exist ran.txt del ran.txt' \
      "qrender.exe $map $QFLAGS > run.out" \
      'echo DONE > ran.txt' > "$out/run.bat"

    conf="$out/dosbox-run.conf"
    # 's' screenshots the backbuffer; fire a series so at least one lands
    # after the (slow) texture conversion finishes.
    ## CYCLES and CORE are pinned, and default the SAME here as in viz:
    ## dynamic core, 40000 cycles (about a Pentium 75). A before/after is
    ## meaningless if the emulated CPU differs between the runs, and
    ## cycles=max makes it differ with host load.
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$out|" -e "s|@MDRIVE@|$out|" \
        -e "s|@BAT@|run.bat|" -e "s|@PRE@|autotype -w 150 -p 20.0 s s s s s s s s s s s s|" \
        -e "s|^cycles=75000$|cycles=${CYCLES:-75000}|" \
        -e "s|^core=dynamic$|core=${CORE:-dynamic}|" \
        "$ROOT/dosbox/template.conf" > "$conf"

    launch "$conf" "${TIMEOUT:-900}"
    echo "== exited: $(cat "$out/ran.txt" 2>/dev/null || echo 'did not return to DOS')"
    cat "$out/run.out" 2>/dev/null
    ls -l "$out"/scrn*.bmp "$out"/SCRN*.BMP "$out"/bench.bmp "$out"/BENCH.BMP \
        2>/dev/null || echo "(no screenshot captured)"
    ;;
viz)
    # windowed run for watching it live. core=dynamic always: it is several
    # times faster and it is what makes hands-on monitoring practical.
    # starves the debug socket; use dosbox.sh debug for a controllable one.
    map="${arg:-dm3ish.bsp}"
    out="${VBD_OUT:-$ROOT/build/vbd}"
    [[ -f "$out/qrender.exe" ]] || { echo "no exe; run: tools/dosbox.sh build" >&2; exit 1; }
    cp "$ROOT/data/$map" "$out/"
    conf="$out/dosbox-viz.conf"
    ## Every -e must precede the file operand: BSD sed (macOS) does not
    ## permute options after it, so the trailing -e's were being opened as
    ## filenames and none of the viz-specific edits applied.
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$out|" -e "s|@MDRIVE@|$out|" \
        -e "s|@BAT@|qrender.exe $map $QFLAGS|" -e "s|@PRE@||" \
        -e "s|^cycles=75000$|cycles=${CYCLES:-75000}|" \
        -e "s|^core=dynamic$|core=${CORE:-dynamic}|" \
        -e 's/^output=surface$/output=opengl/' \
        -e '/^\[sdl\]/a\
fullscreen=false\
autolock=true' \
        -e '/^\[dosbox\]/i\
[render]\
scaler=normal3x\
aspect=true\
\
[debugger]\
debuggerrun=normal\
' "$ROOT/dosbox/template.conf" > "$conf"
    echo "$conf"
    ;;
*) sed -n '2,16p' "$0"; exit 1 ;;
esac
