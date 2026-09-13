#!/bin/bash
# Regression test: skipping a subtree with no visible leaf must change
# the cost and not the picture.
#
# The walk now returns at a node whose whole subtree is out of the PVS --
# Quake's node->visframe -- which on e1m1 takes it from 2,493 nodes a
# frame to 540. Two things it must not lose:
#
#   A brush entity is drawn with the PVS IGNORED, because its own leaves
#   are not in it: a lift sits inside its solid shaft. It is emitted at
#   the node ent_find_node placed it under, and that node is routinely
#   one the PVS pass leaves unmarked -- prune it and the entity is gone.
#   vis_walk carries the root-to-node path of every placed entity for
#   exactly this. Dropping that marking costs 152 of e1m1's 589 marked
#   faces a frame at the spawn, which is what pt_marked reads here.
#
#   And nothing else at all: the two arms must render the same frame.
#
# pt_marked is the sharper of the two and the reason it exists. It is a
# mean over the PROFILED frames only -- summed from frame 0 and divided
# by that count it read 575 against 486 on two arms that rendered a
# different number of frames over the same ticks, i.e. on every A/B
# where one arm is faster, and that false gap cost a session.
#
#   cport/tools/test-subvis.sh build/cport-e1m1 [map]
#
# e1m1 and not dm3ish: dm3ish's only drawable submodel rests out of
# sight down its own shaft, so the entity half cannot fail there.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-subvis.sh <build-dir> [map]}"
MAP="${2:-e1m1.qmp}"

arm() {   # arm <flags> -> "<md5> <pt_marked> <pt_nodes>"
    TIMEOUT="${TIMEOUT:-300}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
        "$MAP -nostats -noai -bench 4000 -ticks 120 $1" >/dev/null 2>&1
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "MISSING 0 0"; return; }
    echo "$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1)" \
         "$(field pt_marked)" "$(field pt_nodes)" "$(field pt_polys)"
}
field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }

read -r off_md5 off_mk off_nd off_pl <<< "$(arm '-nosubvis')"
read -r on_md5  on_mk  on_nd  on_pl  <<< "$(arm '')"

fail=0
if [[ "$off_md5" == MISSING || "$on_md5" == MISSING ]]; then
    echo "FAIL: no frame written -- the run did not render" >&2
    fail=1
elif [[ "$off_md5" != "$on_md5" ]]; then
    echo "FAIL: the subtree skip changes the picture ($off_md5 off, $on_md5 on)" >&2
    fail=1
else
    echo "ok: identical picture with the subtree skip on and off"
fi

if [[ -z "$off_mk" || -z "$on_mk" || -z "$off_pl" || -z "$on_pl" ]]; then
    echo "FAIL: no pt_marked/pt_polys in BENCH.TXT -- the instrument is gone" >&2
    fail=1
elif [[ "$off_mk" != "$on_mk" || "$off_pl" != "$on_pl" ]]; then
    echo "FAIL: $off_mk marked / $off_pl drawn a frame without the skip, $on_mk / $on_pl with it" >&2
    fail=1
else
    echo "ok: $on_mk faces marked and $on_pl drawn a frame either way"
fi

# Or the two above are vacuous: a skip that skips nothing passes both.
if [[ -z "$off_nd" || -z "$on_nd" ]] || (( on_nd * 2 > off_nd )); then
    echo "FAIL: $off_nd nodes a frame without the skip, $on_nd with it -- it is not skipping" >&2
    fail=1
else
    echo "ok: $off_nd nodes a frame down to $on_nd"
fi

exit $fail
