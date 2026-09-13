#!/bin/bash
# Regression test: the build must refuse an EXE that cannot start.
#
# What went wrong: Borland's medium-model startup puts near data, the
# stack and the near heap in one 64K DGROUP, and over 64K it calls
# abort() BEFORE main -- "Abnormal program termination", on stderr,
# which DOS does not redirect. The build was 22 bytes inside the limit
# with _stklen 32768; two shorts added to a struct crossed it, and the
# run then produced an empty redirect, no cstep.txt and a nonzero exit
# with no message anywhere. Nothing reported the cause, and it read as
# a broken build for a session.
#
#   cport/tools/test-dgroup.sh build/cport-e1m1
#
# Two arms: the build that is here must have near-heap room, and the
# guard must reject a map that does not. CHECK_SH overrides the guard,
# which is how this was mutation-checked.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-dgroup.sh <build-dir>}"
CHECK="${CHECK_SH:-$HERE/dgroup-check.sh}"
MAP="$OUT/QCPORT.MAP"

fail=0
[[ -s "$MAP" ]] || { echo "FAIL: no $MAP" >&2; exit 1; }

STKLEN=$(sed -n 's/^unsigned _stklen = \([0-9]*\)U*;.*/\1/p' "$HERE/../src/qmain.c")
if [[ -z "$STKLEN" ]]; then
    echo "FAIL: no _stklen in src/qmain.c -- the guard has nothing to check" >&2
    fail=1
elif ! "$CHECK" "$MAP" "$STKLEN" >/dev/null 2>&1; then
    echo "FAIL: this build has no near-heap room: $("$CHECK" "$MAP" "$STKLEN" 2>&1 | head -2)" >&2
    fail=1
else
    echo "ok: $("$CHECK" "$MAP" "$STKLEN")"
fi

# The map the broken build had: DGROUP 0xa534 with the same stack. Fed
# through the guard it must fail, or the guard cannot have caught it.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'Group                           Address              Size\n=====\nDGROUP                          288b:0000            0000a534\n' > "$TMP/over.map"
if "$CHECK" "$TMP/over.map" "$STKLEN" >/dev/null 2>&1; then
    echo "FAIL: the guard passed DGROUP 42292 + stack $STKLEN, which cannot start" >&2
    fail=1
else
    echo "ok: the guard rejects the DGROUP the dead build had"
fi

exit $fail
