#!/bin/bash
# Regression test: caching an entity's leaves must not change which
# entities are drawn.
#
# d_mdl_visible asks whether any of nine points around an entity's box
# lands in a leaf the PVS keeps, and each point was a descent from the
# root -- 62 levels on e1m1, nine of them per entity, 36 entities: 13,007
# node visits a frame, against 540 for the entire world walk. What is
# cached is the nine LEAVES, which depend on the box alone; the PVS is
# re-read every frame. e1m1 at the spawn went 39.43 ms a frame to 31.53.
#
# The camera WALKS, and that is the whole design of the arm. A cache that
# kept the visible/not answer instead of the leaves is the natural wrong
# version, and nothing catches it while the eye stands still -- pvs_now
# only changes when the camera changes leaf. Standing at the spawn it
# draws the same frame, the same polygons and the same entity count as
# the correct code over 900 ticks, with the AI on.
#
#   cport/tools/test-lcache.sh build/cport-e1m1 [map]
#
# Mutation-checked with that version: md5 differs, 238 polygons for 240,
# and 2 entities visible a frame for 4. Freezing the key instead -- never
# re-descending for a MOVED entity -- is NOT caught, here or at any arm
# tried: a monster's nine leaves stay on the same side of the PVS over
# the few hundred units it walks in these runs, so the defect has no
# symptom to assert on. Said plainly rather than left looking covered.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-lcache.sh <build-dir> [map]}"
MAP="${2:-e1m1.qmp}"
AT="-at 88 1420 -190 -yaw 270 -walk -bench 4000 -ticks 200"

field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }

arm() {   # arm <flags> -> "<md5> <pt_polys> <pt_dv_vis> <pt_dv_desc>"
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "$MAP -nostats $AT $1" >/dev/null 2>&1
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "MISSING 0 0 0"; return; }
    echo "$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1)" \
         "$(field pt_polys)" "$(field pt_dv_vis)" "$(field pt_dv_desc)"
}

read -r off_md5 off_pl off_vis off_desc <<< "$(arm '-nolcache')"
read -r on_md5  on_pl  on_vis  on_desc  <<< "$(arm '')"

fail=0
if [[ "$off_md5" == MISSING || "$on_md5" == MISSING ]]; then
    echo "FAIL: no frame written -- the run did not render" >&2
    fail=1
elif [[ "$off_md5" != "$on_md5" ]]; then
    echo "FAIL: the leaf cache changes the picture ($off_md5 off, $on_md5 on)" >&2
    fail=1
else
    echo "ok: identical picture with the leaf cache on and off"
fi

if [[ -z "$off_pl" || -z "$on_pl" || -z "$off_vis" || -z "$on_vis" ]]; then
    echo "FAIL: no pt_polys/pt_dv_vis in BENCH.TXT -- the instrument is gone" >&2
    fail=1
elif [[ "$off_pl" != "$on_pl" || "$off_vis" != "$on_vis" ]]; then
    echo "FAIL: $off_pl polys and $off_vis entities a frame without the cache, $on_pl and $on_vis with it" >&2
    fail=1
else
    echo "ok: $on_pl polygons and $on_vis entities a frame either way"
fi

# Or every assertion above is vacuous: a cache that never hits passes them.
if [[ -z "$off_desc" || -z "$on_desc" ]] || (( on_desc * 4 > off_desc )); then
    echo "FAIL: $off_desc descents a frame without the cache, $on_desc with it -- it is not caching" >&2
    fail=1
else
    echo "ok: $off_desc tree descents a frame down to $on_desc"
fi

exit $fail
