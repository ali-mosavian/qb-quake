#!/usr/bin/env bash
# depcheck.sh -- an edit to a header must invalidate what includes it.
#
# The renderer's assembly includes src/qgl/qgl.inc, which carries the
# surface kinds, the struct layouts and FARADD. Change any of them with
# the objects already built and make has nothing to notice: the .asm
# files are untouched, so the stale objects stay, LINK is happy, and the
# EXE runs the OLD constants against the new BASIC declarations. Nothing
# in the build says so. The BASIC and C rules already list their headers;
# the assembly rule did not.
#
# The check builds no code. It fabricates a fully-built tree, asserts
# make calls it up to date -- without that half the test could pass for
# the wrong reason -- and then touches each header in turn and asserts
# make no longer does.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/o"
mkdir -p "$OUT"

# NATIVE_UGL is an input to the build, not part of it: point it at a file
# of our own so a missing or stale library cannot decide this result.
: > "$TMP/UGLV.LIB"

mods=$(make BUILD="$OUT" NATIVE_UGL="$TMP/UGLV.LIB" -p -n 2>/dev/null |
       sed -n 's/^ASM_MODS := //p;s/^BAS_MODS := //p;s/^C_MODS := //p' | tr ' ' '\n')
[[ -n "$mods" ]] || { echo "depcheck: cannot read the module lists"; exit 1; }

for m in $mods; do : > "$OUT/$m.obj"; done
: > "$OUT/stuff.ini"; : > "$OUT/base.dat"; : > "$OUT/UGLV.LIB"
: > "$OUT/.assets-stamp"; : > "$OUT/qrender.exe"

uptodate () { make -q BUILD="$OUT" NATIVE_UGL="$TMP/UGLV.LIB" build 2>/dev/null; }

fail=0
say () { printf '   %-4s %s\n' "$1" "$2"; }

if uptodate; then
    say ok "a built tree is up to date"
else
    say FAIL "a built tree is up to date"
    fail=$((fail + 1))
fi

for h in src/qgl/*.inc src/qgl/b8/*.inc; do
    [[ -e "$h" ]] || continue
    # GNU make 3.81 compares mtimes at one-second resolution, so a header
    # touched in the same second as the objects reads as no newer than
    # them and the check passes vacuously.
    sleep 1
    touch "$h"
    if uptodate; then
        say FAIL "$h invalidates the build"
        fail=$((fail + 1))
    else
        say ok "$h invalidates the build"
    fi
    # Put the tree back, or the first header tested would mask the rest.
    for m in $mods; do : > "$OUT/$m.obj"; done
    : > "$OUT/qrender.exe"
done

if (( fail )); then echo "RESULT FAIL ($fail)"; exit 1; fi
echo "RESULT PASS"
