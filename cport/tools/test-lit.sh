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

# And the budget. e1m1 read 117,168 and 120,416 on two runs of one
# binary the day the four per-face cuts landed -- CacheSlot to one
# short a face, face_mdl into Face.side's spare bits, pflag to one
# bit, SC_NBLK 1024 to 384, 59 KB between them. It is NOT a
# deterministic figure, so the floor sits well under the lower
# reading: it catches CacheSlot (33 KB) and face_mdl (11 KB) being
# undone, and any new array of that size, but not SC_NBLK alone
# (6.4 KB), which is inside the noise. Move it deliberately, with a
# reason, never because it went red.
largest=$(tr -d '\r' < "$OUT/CSTEP.TXT" 2>/dev/null |
          sed -n 's/.*sc_init ok largest=\([0-9]*\).*/\1/p' | tail -1)
if [[ -z "$largest" ]]; then
    echo "FAIL: no 'sc_init ok largest=' in cstep.txt -- the cache died, or the mark did" >&2
    fail=1
elif (( largest < 110000 )); then
    echo "FAIL: $largest bytes free after sc_init, was 117-120 K -- something took the cuts back" >&2
    fail=1
else
    echo "ok: $largest bytes still free after the cache is built"
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
