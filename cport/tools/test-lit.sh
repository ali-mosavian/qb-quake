#!/bin/bash
# Regression test: a map big enough to refuse the portal flood must
# still get a surface cache.
#
# e1m1 has 1,531 leaves and 6,624 portal refs, both past r_portal_mark's
# own static tables, so the flood returned -2 on its first line every
# frame for the life of the run -- 0 pops, 0 projections. The table was
# loaded anyway: 95,800 bytes of conventional memory for a pass that did
# nothing. sc_init then died on its first allocation, 44,128 bytes
# wanted against 15,616 free, and e1m1 drew unlit with -lm changing
# nothing at all.
#
# The BASIC build never had this. Its r_load_portals bailed because
# 6,624 x 7 x 2 is past a BASIC array's 64K, and the port's far
# pointers removed the accident that had been protecting it.
#
# Two halves, because one assertion cannot fail both ways:
#   e1m1  -- -lm must change the picture, which it can only do with a
#            live cache. The symptom, not the allocation.
#   dm3ish -- must still flood, or the fix is "portals off everywhere".
#
#   cport/tools/test-lit.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-lit.sh <build-dir>}"

field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }
run() {
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "$1" >/dev/null 2>&1
    [[ -s "$OUT/BENCH.BMP" ]] && ( md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1 ) || echo MISSING
}

BASE="-nostats -noai -bench 4000 -ticks 120"
unlit=$(run "e1m1.qmp $BASE")
lit=$(run "e1m1.qmp $BASE -lm")

fail=0
if [[ "$unlit" == MISSING || "$lit" == MISSING ]]; then
    echo "FAIL: no frame written -- the run did not render" >&2
    fail=1
elif [[ "$unlit" == "$lit" ]]; then
    echo "FAIL: -lm changes nothing on e1m1 -- the surface cache is dead again" >&2
    fail=1
else
    echo "ok: e1m1 draws lit ($unlit unlit, $lit with -lm)"
fi

run "dm3ish.qmp $BASE -lm" >/dev/null
pops=$(field pt_pops)
if [[ -z "$pops" ]]; then
    echo "FAIL: no pt_pops in BENCH.TXT -- the instrument is gone" >&2
    fail=1
elif (( pops <= 0 )); then
    echo "FAIL: dm3ish floods no portals -- the table is refused everywhere now" >&2
    fail=1
else
    echo "ok: dm3ish still floods, $pops pops a frame"
fi

exit $fail
