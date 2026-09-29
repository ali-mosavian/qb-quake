#!/bin/bash
# Regression test: caching an entity's leaves must not change what draws.
#
# r_mdl_visible descended the tree from the root at nine points a box,
# 62 levels on e1m1, for every item and monster every frame: 7.7 ms of
# an 80 ms frame at the spawn, drawing nothing. r_walk.c now caches the
# nine LEAVES, which depend on the box alone, and reads the PVS fresh.
# The camera walks, because a cache of the visible/not answer is only
# wrong once the eye changes leaf. -nolcache is the reference.
#
#   tools/test-lcache.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-lcache.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

arm() {
    rm -f "$OUT/BENCH.BMP"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-300}" \
        QFLAGS="-nosound -nostats -at 88 1420 -190 -yaw 270 -walk -bench 999 -ticks 200 $1" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.BMP" ]] || { echo "FAIL: no frame written" >&2; exit 1; }
    echo "$(md5 -q "$OUT/BENCH.BMP" 2>/dev/null || md5sum "$OUT/BENCH.BMP" | cut -d' ' -f1)" \
         "$(tr -d '\r' < "$OUT/BENCH.TXT" | awk '$1 == "mdl_drawn" {print $2}')"
}

read -r off drawn_off <<< "$(arm -nolcache)"
read -r on drawn_on <<< "$(arm "")"
[[ "$drawn_off" -gt 0 ]] || { echo "FAIL: no model in view -- the arm tests nothing" >&2; exit 1; }
if [[ "$off" != "$on" || "$drawn_off" != "$drawn_on" ]]; then
    echo "FAIL: leaf cache on $on ($drawn_on drawn), off $off ($drawn_off drawn)" >&2
    exit 1
fi
echo "ok: same picture with the leaf cache, $drawn_on models drawn"
