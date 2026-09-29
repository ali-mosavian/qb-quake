#!/bin/bash
# Regression test: e1m1's first double door opens when walked into.
#
# ents.bin's header grew nlight (78 bytes) and the BASIC EntsHead stayed
# 76, so every record after it was read two bytes early: the bench dumped
# door fields as 9.18e-41, no door moved, and the walk stopped at the
# door at px 272.03.
#
#   tools/test-doors.sh build/llrm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(cd "${1:?usage: test-doors.sh <build-dir>}" && pwd)"

A="$ROOT/data/assets"
trap 'cp "$A/assets.zip" "$A/texr.raw" "$A/texs.raw" "$A/pal.raw" "$OUT/"' EXIT
cp "$OUT"/MAPS/E1M1/* "$OUT/"
rm -f "$OUT/BENCH.TXT" "$OUT/bench.txt"
VBD_OUT="$OUT" TIMEOUT="${TIMEOUT:-240}" \
    QFLAGS="-nosound -walk -bench 400 -ticks 240 -at 330 576 40 -yaw 180" \
    "$ROOT/tools/dosbox.sh" run e1m1.bsp >/dev/null 2>&1 || true
px=$(cat "$OUT"/[Bb][Ee][Nn][Cc][Hh].[Tt][Xx][Tt] 2>/dev/null | tr -d '\r' | awk '$1 == "px" {print $2}' || true)
[[ -n "$px" ]] || { echo "FAIL: no bench written" >&2; exit 1; }

if awk -v p="$px" 'BEGIN { exit !(p < 190) }'; then
    echo "ok: walked through the door, px $px"
else
    echo "FAIL: px $px -- the door did not open" >&2
    exit 1
fi
