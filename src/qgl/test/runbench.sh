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
cycles=75000
[dos]
ems=true
xms=true
[autoexec]
@echo off
mount w "$d"
w:
b.exe > out.txt
exit
EOF
rm -f "$d/OUT.TXT" "$d/out.txt"
SDL_VIDEODRIVER=dummy timeout 900 "$db" -nolog -conf "$d/run.conf" -exit >/dev/null 2>&1
out=$(ls "$d"/OUT.TXT "$d"/out.txt 2>/dev/null | head -1)
cat "$out" 2>/dev/null || echo "(no output -- did not run)"
