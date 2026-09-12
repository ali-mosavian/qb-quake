#!/bin/bash
# Regression test: portal culling must change the cost and not the picture.
#
# What went wrong: r_load_portals was written and never called, so
# world->pt_idx stayed null and r_portal_mark indexed off it -- reading
# the interrupt vector table as a per-leaf portal index. The ranges it
# found were thousands of entries wide: 4,752,450 box projections a
# frame against the 1,566 the map actually has, 2.38 seconds of a 2.39
# second frame, and 28 leaves culled on the strength of it. Nothing
# faulted. It looked like a slow renderer, not a null pointer.
#
# Two assertions. The picture must be identical with portals on and off
# -- a portal cull may only remove what is genuinely invisible. And the
# flood must project at most one leaf's worth of portal boxes for each
# leaf it pops, which is the invariant the null index broke: 2,008 per
# pop against a map whose busiest leaf has 32 portals.
#
# NOT a timing assertion. The defect was 114x, but at the spawn the
# flood has almost nothing to cull and pays its scan for no gain --
# 19.6ms against 18.5ms without -- so "portals are never slower" fails
# on an honest frame, and one run per arm is not a measurement anyway.
# Bounding the work is what distinguishes the bug.
#
# -lm is deliberately absent: the surface cache draws a different
# picture run to run with lightmaps on (see CLAUDE.md), so the image
# comparison would be testing that instead.
#
#   cport/tools/test-portals.sh build/cport-qgl
#
# RUN_SH overrides the runner, which is how both assertions were
# mutation-checked -- the work bound against the counters the broken
# build really produced (4,752,450 projections over 2,366 pops).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-portals.sh <build-dir>}"

arm() {   # arm <extra-flags> -> "<md5> <ft_mean>"
    TIMEOUT="${TIMEOUT:-400}" "${RUN_SH:-$HERE/run.sh}" "$OUT" "dm3ish.bsp -nostats -ticks 60 $1" >/dev/null 2>&1
    # An absent frame must not read as a matching one: without this both
    # arms return the empty string and "identical picture" passes for a
    # program that never rendered.
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "MISSING-$1"; return; }
    md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1
}

field() { tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk -v k="$1" '$1==k{print $2}'; }

off_md5="$(arm '-noportal')"
on_md5="$(arm '')"
pops="$(field pt_pops)"; projs="$(field pt_projs)"

fail=0
if [[ "$off_md5" == MISSING-* || "$on_md5" == MISSING-* ]]; then
    echo "FAIL: no frame written ($off_md5 / $on_md5) -- the run did not render" >&2
    fail=1
elif [[ "$off_md5" != "$on_md5" ]]; then
    echo "FAIL: portals change the picture ($off_md5 off, $on_md5 on)" >&2
    fail=1
else
    echo "ok: identical picture with portals on and off"
fi

# The busiest leaf's portal count, out of the map's own index, so the
# bound is the data's and not a number picked to make this pass.
maxrefs=$(unzip -p "$OUT/assets.zip" portalidx.bld | python3 -c 'import sys,struct; d=sys.stdin.buffer.read(); a=struct.unpack("<%dh"%(len(d)//2),d); print(max(a[i+1]-a[i] for i in range(len(a)-1)))')

if [[ -z "$pops" || -z "$projs" || "$pops" -le 0 ]]; then
    echo "FAIL: no flood counters in BENCH.TXT -- the instrument is gone" >&2
    fail=1
elif [[ $projs -gt $(( pops * maxrefs )) ]]; then
    echo "FAIL: $projs projections over $pops pops; the busiest leaf has $maxrefs portals" >&2
    fail=1
else
    echo "ok: $projs projections over $pops pops, bound $(( pops * maxrefs ))"
fi

exit $fail
