#!/bin/bash
# Regression test: walking relights nothing unless something emits light.
#
# A test light followed the player always, which Quake never had, and a
# moving light rebuilds every lit face in reach each tick: walking e1m1
# spent 85.6 ms of a 140 ms frame building surfaces, 3,274 of 3,898
# builds relit. -plight keeps it, and is the arm that shows the counter
# can read above zero.
#
#   tools/test-plight.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-plight.sh <build-dir>}" && pwd)"
A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"

dlit() {
    rm -f "$OUT/BENCH.TXT"
    VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-300}" \
        QFLAGS="-lm -nosound -nostats -noai -walk -bench 999 -ticks 120 $1" \
        "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
    tr -d '\r' < "$OUT/BENCH.TXT" 2>/dev/null | awk '$1 == "sc_dlit" {print $2}'
}

with=$(dlit -plight)
without=$(dlit "")
[[ -n "$with" && "$with" -gt 0 ]] || { echo "FAIL: -plight relit ${with:-nothing} -- the counter reads nothing" >&2; exit 1; }
[[ "$without" == 0 ]] || { echo "FAIL: walking relit $without surfaces with no light" >&2; exit 1; }
echo "ok: walking relights nothing ($with with -plight)"
