#!/bin/sh
# Run one qgl benchmark EXE. CORE=normal, and that is not a preference:
# both arms patch immediates into their own inner loops, and AGENTS.md
# records that the recompiler throws its translations away when mgl does
# that. Timing on the dynamic core would measure the recompiler.
#
# cycles is the pinned 75000 from dosbox/template.conf, so the emulated
# machine is the one every other number in this repo was taken on.
db="$1"; d="$2"
cat > "$d/run.conf" <<EOF
[sdl]
autolock=false
[dosbox]
memsize=16
startbanner=false
quit warning=false
[cpu]
core=normal
# The pinned machine, matching dosbox/template.conf. Observed: under
# cputype=386 this harness produced a zero-byte OUT.TXT and no
# diagnostic. Running here does not prove real-hardware compatibility.
#
# Pinning this changes the machine, so it starts a new epoch: results
# taken before it are not comparable with results taken after. Rerun
# BOTH arms of any comparison.
cputype=pentium_iii
cycles=75000
[dos]
ems=true
xms=true
[autoexec]
@echo off
mount w "$d"
w:
b.exe
exit
EOF
rm -f "$d/OUT.TXT" "$d/pass"
status=0
SDL_VIDEODRIVER=dummy timeout -k 5 900 "$db" -nolog -conf "$d/run.conf" -exit >/dev/null 2>&1 || status=$?
out="$d/OUT.TXT"
if [ "$status" -ne 0 ] || [ ! -f "$out" ] || ! grep -q "RESULT PASS" "$out"; then
    echo "== $(basename "$d") failed (runner status $status)"
    cat "$out" 2>/dev/null || echo "(no output -- did not run)"
    exit 1
fi
touch "$d/pass"
cat "$out"
