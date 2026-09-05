#!/bin/sh
# Run one built qgl test EXE in its own headless DOSBox. Pass = RESULT PASS.
#
# ems=true is the one real difference from mgl's version of this script:
# half of what qgl_sf does only exists when there is a page frame to map
# into, and a test that silently skipped the EMS path would be worse than
# no test at all.
db="$1"; d="$2"
cat > "$d/run.conf" <<EOF
[sdl]
autolock=false
[dosbox]
memsize=16
startbanner=false
quit warning=false
[cpu]
core=dynamic
cycles=15000
[dos]
ems=true
xms=true
[autoexec]
@echo off
mount w "$d"
w:
t.exe > out.txt
exit
EOF
rm -f "$d/OUT.TXT" "$d/out.txt" "$d/pass"
SDL_VIDEODRIVER=dummy timeout 60 "$db" -nolog -conf "$d/run.conf" -exit >/dev/null 2>&1
out=$(ls "$d"/OUT.TXT "$d"/out.txt 2>/dev/null | head -1)
if [ -n "$out" ] && grep -q "RESULT PASS" "$out"; then
    touch "$d/pass"
else
    echo "== $(basename "$d")"
    cat "$out" 2>/dev/null || echo "(no output -- did not run)"
    exit 1
fi
