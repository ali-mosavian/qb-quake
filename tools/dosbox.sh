#!/bin/bash
# Run qrender under DOSBox-X on the host, no DOS machine needed. The
# build is the Makefile's.
#
#   tools/dosbox.sh run   [map.bsp]        headless run, screenshots via the 's' key
#   tools/dosbox.sh viz   [map.bsp]        emit a windowed config to watch it live
#
# Env overrides:
#   TOOLCHAINS   compiler collection (default ~/work/other/d32x/toolchains)
#   DOSBOX_BIN   dosbox-x binary     (default: first found on PATH)
#   TIMEOUT      seconds             (default 300 build / 900 run)
#   QFLAGS       extra qrender args  (e.g. -lm, -ticks 120)
#
# Artifacts land in build/<target>/ on the host side.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"

cmd="${1:-run}"; arg="${2:-}"
# extra qrender arguments for the run/viz recipes, e.g. QFLAGS=-lm
QFLAGS="${QFLAGS:-}"

DOSBOX_BIN="${DOSBOX_BIN:-}"
if [[ -z "$DOSBOX_BIN" ]]; then
    for c in "$HOME/work/other/dosbox-x-debug/src/dosbox-x" "$(command -v dosbox-x || true)"; do
        [[ -n "$c" && -x "$c" ]] && { DOSBOX_BIN="$c"; break; }
    done
fi
[[ -n "$DOSBOX_BIN" ]] || { echo "no dosbox-x found; set DOSBOX_BIN" >&2; exit 1; }

## SERIAL_LOG=1 reads back the call trace a `make SERIAL_LOG=1` build
## writes to port E9h. TWO things are needed and both are easy to miss:
## dosbox-x only installs the port when `bochs debug port e9` is set, and
## -nolog discards every LOG_MSG before it reaches the file, so the flag
## has to go as well. Either one missing gives an EMPTY log, which reads
## exactly like a build whose LOG lines never fired.
launch () {   # $1 = conf file, $2 = timeout
    local logflag=-nolog
    if [[ "${SERIAL_LOG:-}" = 1 ]]; then
        logflag=
        printf '\n[dosbox]\nbochs debug port e9 = true\n[log]\nlogfile=%s\n' \
            "$(dirname "$1")/E9LOG.TXT" >> "$1"
    fi
    SDL_VIDEODRIVER=dummy timeout "$2" "$DOSBOX_BIN" $logflag -conf "$1" -exit >/dev/null 2>&1 || true
}

case "$cmd" in
run)
    map="${arg:-dm3ish.bsp}"
    out="${VBD_OUT:-$ROOT/build/vbd}"
    [[ -f "$out/qrender.exe" ]] || { echo "no exe; run: make" >&2; exit 1; }
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
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$out|" \
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
    #
    # The template's trailing `exit` is dropped here and nowhere else. It
    # quits DOSBox the moment qrender returns, so a viz window shuts
    # itself the instant you press Esc, taking with it whatever qrender
    # drew on the way out -- and an error drawn as PIXELS is invisible to
    # text_screen, so there is nothing left to read. build and run WANT
    # that exit; watching does not.
    map="${arg:-dm3ish.bsp}"
    out="${VBD_OUT:-$ROOT/build/vbd}"
    [[ -f "$out/qrender.exe" ]] || { echo "no exe; run: make" >&2; exit 1; }
    cp "$ROOT/data/$map" "$out/"
    conf="$out/dosbox-viz.conf"
    ## Every -e must precede the file operand: BSD sed (macOS) does not
    ## permute options after it, so the trailing -e's were being opened as
    ## filenames and none of the viz-specific edits applied.
    sed -e "s|@CDRIVE@|$out|" -e "s|@VDRIVE@|$out|" \
        -e "s|@BAT@|qrender.exe $map $QFLAGS|" -e "s|@PRE@||" \
        -e "s|^cycles=75000$|cycles=${CYCLES:-75000}|" \
        -e "s|^core=dynamic$|core=${CORE:-dynamic}|" \
        -e 's/^output=surface$/output=opengl/' \
        -e '$ { /^exit$/d; }' \
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
