#!/bin/bash
# Regression test: the spawn faces the way the map says.
#
# What went wrong: ent_load_spawn set start_angle to the map's own
# angle. The map's angle is CCW from +x, but the freelook math makes
# the eye direction (cos a, -sin a) in bsp x,y, so the renderer's yaw
# is 360 - angle. Unmirrored, every map started the player facing the
# wall BEHIND them -- and it looked like a plausible frame, because a
# wall is what most spawns have behind them.
#
# -walk from e1m1's spawn is the measurement: bsp y -352, facing +y
# (angle 90). Wrong way it walked 47 units backwards and stopped
# against the wall; right way it travels the hall, 651 units.
#
#   cport/tools/test-spawnyaw.sh build/cport-e1m1
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-spawnyaw.sh <build-dir>}"
MIN="${MIN:-300}"

[[ -f "$OUT/e1m1.qmp" ]] || { echo "SKIP: no e1m1.qmp in $OUT"; exit 0; }

TIMEOUT="${TIMEOUT:-200}" "${RUN_SH:-$HERE/run.sh}" "$OUT" \
    "e1m1.qmp -nostats -walk -ticks 200" >/dev/null 2>&1

log="$OUT/cstep.txt"
# cstep prints RENDERER coordinates: x, y is bsp z, z is bsp y.
spawn_y=$(tr -d '\r' < "$log" 2>/dev/null | sed -n 's/^spawn=[^,]*,[^,]*,\([-0-9]*\).*/\1/p' | head -1)
final_y=$(tr -d '\r' < "$log" 2>/dev/null | sed -n 's/.*pos=[^,]*,[^,]*,\([-0-9]*\).*/\1/p' | head -1)

[[ -n "$spawn_y" && -n "$final_y" ]] || { echo "FAIL: no spawn/pos in $log" >&2; exit 1; }

went=$(( final_y - spawn_y ))
if [[ $went -lt $MIN ]]; then
    echo "FAIL: -walk from the spawn went $went units along +y (bsp y $spawn_y -> $final_y);" >&2
    echo "      the map faces +y, so it should travel at least $MIN -- the yaw is not mirrored" >&2
    exit 1
fi
echo "ok: the spawn faces the map's way -- walked $went units (bsp y $spawn_y -> $final_y)"
