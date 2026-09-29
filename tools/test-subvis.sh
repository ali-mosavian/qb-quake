#!/bin/bash
# Regression test: the walk's subtree skip draws what the full walk draws.
#
# The walk culled every node the frustum kept, 2,467 at the e1m1 spawn,
# to reach 208 visible leaves. A bit a node now says whether a PVS leaf
# or a drawn brush entity lies below it: 502 nodes, 56.1 ms to 53.6. An
# entity is drawn with the PVS ignored at a node the PVS alone leaves
# unmarked, so skipping its path loses entity faces behind walls: polys
# drop and the picture does not. Both are compared against -nosubvis.
#
#   tools/test-subvis.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-subvis.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

field() { tr -d '\r' < "$OUT/BENCH.TXT" | awk -v k="$1" '$1 == k {print $2}'; }
arm() {
    rm -f "$OUT/BENCH.BMP" "$OUT/BENCH.TXT"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-300}" \
        QFLAGS="-nosound -nostats -noai -bench 999 -ticks 60 $1" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }
    echo "$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1) $(field polys) $(field walk_nodes)"
}

read -r full_md5 full_polys full_nodes <<< "$(arm -nosubvis)"
read -r skip_md5 skip_polys skip_nodes <<< "$(arm "")"
if [[ "$skip_md5" != "$full_md5" || "$skip_polys" != "$full_polys" ]]; then
    echo "FAIL: skip draws $skip_polys polys ($skip_md5), full walk $full_polys ($full_md5)" >&2
    exit 1
fi
[[ "$skip_nodes" -lt "$full_nodes" ]] || { echo "FAIL: $skip_nodes nodes walked against $full_nodes -- nothing skipped" >&2; exit 1; }
echo "ok: $skip_polys polys either way, $skip_nodes nodes walked for $full_nodes"
