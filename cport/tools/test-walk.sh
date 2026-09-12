#!/bin/bash
# Regression test: -walk from the dm3ish spawn must actually travel.
#
# What went wrong: Keys was sized 87 (in.bi's named-field count) where
# qglKbdInit clears 128 words, so in_init ran 82 bytes past the struct
# and over the Camera the compiler had placed next on the stack. The
# spawn was read out of the map correctly -- the load marks said so --
# and then zeroed before pl_init could use it, so the player started at
# the origin inside solid geometry. Every key read as dead, which is
# what it looks like from the keyboard, and -walk (which writes the key
# state directly and never touches the ISR) failed identically, which
# is what named the camera rather than the input.
#
#   cport/tools/test-walk.sh build/cport-qgl
#
# RUN_SH overrides the runner, which is how the two assertions below
# were mutation-checked against the log the broken build produced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-walk.sh <build-dir>}"

TIMEOUT="${TIMEOUT:-150}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "dm3ish.bsp -nostats -walk -ticks 200" >/dev/null 2>&1

# tr -d '\r': cstep.txt is written by the DOS program, so every line
# ends CRLF and the last field carries the CR into $(( )).
log="$OUT/cstep.txt"
spawn=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^spawn=' | sed 's/^spawn=\([^ ]*\).*/\1/')
final=$(tr -d '\r' < "$log" 2>/dev/null | grep -m1 '^frames=' | sed 's/.*pos=//')

[[ -n "$spawn" && -n "$final" ]] || { echo "FAIL: no spawn/pos in $log" >&2; exit 1; }

IFS=, read sx sy sz <<< "$spawn"
IFS=, read fx fy fz <<< "$final"

fail=0
if [[ "$fx" == "0" && "$fz" == "0" ]]; then
    echo "FAIL: camera at the origin (spawn was $spawn) -- the Camera was clobbered" >&2
    fail=1
fi

dist=$(( (fx-sx)*(fx-sx) + (fz-sz)*(fz-sz) ))
if [[ $dist -lt 2500 ]]; then
    echo "FAIL: -walk moved ${dist} sq.units from $spawn to $final; 200 ticks should travel" >&2
    fail=1
fi

[[ $fail -eq 0 ]] && echo "ok: -walk travelled $spawn -> $final"
exit $fail
