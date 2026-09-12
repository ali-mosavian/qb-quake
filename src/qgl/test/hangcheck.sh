#!/bin/sh
# hangcheck.sh -- run1.sh must give up on an emulator that will not stop.
#
# It used a bare `timeout 60`, which sends SIGTERM. Measured: with
# SURF_EMS mutated to 1, t03surf left dosbox-x running for eleven minutes
# with the timeout long since fired and a core at 100%, and the suite --
# and therefore tools/check.sh -- waiting on it forever. A gate that can
# hang is not a gate. With `-k 5` the same case gives up at 66s and the
# test FAILS, which is what it is for.
#
# The stand-in is a script that ignores SIGTERM, not a DOS program that
# loops: a guest in a plain `jmp $` dies to SIGTERM quite happily, so a
# spinning test EXE reproduces nothing and passes either way -- that
# version of this file was written first and mutation said so. What has
# to be tested is run1.sh's own budget against a child that refuses the
# polite signal, and run1.sh takes the emulator as its first argument,
# so it can be handed one.
set -u
cd "$(dirname "$0")" || exit 1

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT

cat > "$d/db" <<'EOF'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
EOF
chmod +x "$d/db"

s=$(date +%s)
# The outer bound is what makes a red result a REPORT rather than a
# second hang: without it this file inherits the disease it tests for,
# and the mutation run that proved that is the reason the line is here.
QGL_TEST_TIMEOUT=5 timeout -k 5 30 sh run1.sh "$d/db" "$d" > /dev/null 2>&1
rc=$?
e=$(( $(date +%s) - s ))

fail=0
say () {
    if [ "$2" -eq 0 ]; then printf '   ok   %s\n' "$1"
    else printf '   FAIL %s\n' "$1"; fail=1; fi
}

say "an emulator that will not stop fails the test" "$(( rc == 0 ))"
# The budget is 5s and -k adds 5, so a working run1.sh returns in about
# ten. 15 leaves room for a loaded host and still sits well under the
# outer bound -- which matters, because the outer bound firing must read
# as a failure and not as a pass with a large number in it.
[ "$e" -lt 15 ]; say "and run1.sh gives up in ${e}s, not eventually" "$?"

[ "$fail" -eq 0 ] || { echo "RESULT FAIL"; exit 1; }
echo "RESULT PASS"
