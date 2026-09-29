#!/bin/bash
# Regression test: a flickering light style keeps a surface per value.
#
# A face held one surface keyed on its styles' epochs, which never
# repeat, so every flicker of style 10 rebuilt every (0, 10) face in
# view: standing at the e1m1 spawn built 1,406 surfaces by tick 300 and
# 2,558 by 600, 15.5 ms a frame. Keyed on the values, a face chains up
# to SC_VARIANTS surfaces, and once each value has been seen nothing
# rebuilds. sc_test is the cache's selftest.
#
#   tools/test-scvariants.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-scvariants.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

field() { tr -d '\r' < "$OUT/BENCH.TXT" | awk -v k="$1" '$1 == k {print $2}'; }
built() {
    rm -f "$OUT/BENCH.TXT"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-400}" \
        QFLAGS="-lm -nosound -nostats -noai -bench 9999 -ticks $1" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    [[ -s "$OUT/BENCH.TXT" ]] || { echo "FAIL: no bench written" >&2; exit 1; }
    [[ "$(field sc_test)" == 1 ]] || { echo "FAIL: sc_test $(field sc_test)" >&2; exit 1; }
    field sc_built
}

early=$(built 300)
late=$(built 600)
if [[ "$late" != "$early" ]]; then
    echo "FAIL: $early surfaces built by tick 300, $late by 600 -- the flicker rebuilds" >&2
    exit 1
fi
echo "ok: $early surfaces built, none after the styles came round"
