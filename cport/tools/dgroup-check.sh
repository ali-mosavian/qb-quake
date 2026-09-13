#!/bin/bash
# DGROUP + _stklen must leave the near heap room inside one 64K segment.
#
#   cport/tools/dgroup-check.sh <QCPORT.MAP> <stklen> [min-heap]
#
# Borland's medium-model startup puts near data, the stack and the near
# heap in DGROUP. Over 64K it calls abort() BEFORE main: "Abnormal
# program termination" on stderr, which DOS does not redirect, so a
# redirected run leaves an empty file, no cstep.txt and a nonzero exit
# and reads exactly like a broken build. This build sat 22 bytes inside
# the limit; two shorts added to a struct crossed it and cost a session.
set -uo pipefail

MAP="${1:?usage: dgroup-check.sh <map> <stklen> [min-heap]}"
STK="${2:?usage: dgroup-check.sh <map> <stklen> [min-heap]}"
MIN="${3:-4096}"

DG=$(awk '$1=="DGROUP"{print $3; exit}' "$MAP")
[[ -n "$DG" ]] || { echo "dgroup-check: no DGROUP line in $MAP" >&2; exit 1; }
DG=$((16#$DG))

if (( DG + STK + MIN > 65536 )); then
    echo "dgroup-check: DGROUP $DG + stack $STK leaves $((65536 - DG - STK)) for the near heap, want $MIN." >&2
    echo "  Over 65536 the startup aborts before main with no output. Cut _stklen or near data." >&2
    exit 1
fi
echo "dgroup-check: DGROUP $DG + stack $STK, $((65536 - DG - STK)) bytes of near heap"
