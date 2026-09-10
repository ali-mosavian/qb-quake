#!/bin/sh
# Run one built qgl test EXE in its own headless DOSBox. Pass = RESULT PASS.
#
# ems=true is the one real difference from mgl's version of this script:
# half of what qgl_sf does only exists when there is a page frame to map
# into, and a test that silently skipped the EMS path would be worse than
# no test at all.
db="$1"; d="$2"
# A test with a "keys" file gets them typed a second in, through the
# emulator's own keyboard path, so an INT 9 hook is driven by hardware.
keys=""
[ -f "$d/keys" ] && keys="autotype -w 1 -p 0.3 $(cat "$d/keys")"
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
$keys
t.exe
exit
EOF
rm -f "$d/OUT.TXT" "$d/pass"
# -k, because dosbox-x IGNORES the SIGTERM `timeout` sends: a test that
# does not exit sat here for eleven minutes with the timeout long since
# fired and the emulator still burning a core. SIGKILL cannot be ignored,
# so the suite fails the test instead of hanging the gate.
#
# QGL_TEST_TIMEOUT is for hangcheck.sh, which needs a test to time out on
# purpose and should not cost a minute to say so.
t=${QGL_TEST_TIMEOUT:-60}
status=0
SDL_VIDEODRIVER=dummy timeout -k 5 "$t" "$db" -nolog -conf "$d/run.conf" -exit >/dev/null 2>&1 || status=$?
out="$d/OUT.TXT"
if [ "$status" -eq 0 ] && [ -f "$out" ] && grep -q "RESULT PASS" "$out"; then
    touch "$d/pass"
else
    echo "== $(basename "$d") failed (runner status $status)"
    cat "$out" 2>/dev/null || echo "(no output -- did not run)"
    exit 1
fi
