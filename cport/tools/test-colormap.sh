#!/usr/bin/env bash
# The surface builder's colormap is the OKLCH ramp table, byte for byte.
# The md5 is of cmoklch.py's oklch_w4, the table the renders were judged
# on; mkassets' port of it must not drift by one entry.
#
#   cport/tools/test-colormap.sh [map.qmp or assets dir]
set -euo pipefail
cd "$(dirname "$0")/../.."

WANT=e16ada724ae7b65cf5b079a338e2e794
SRC="${1:-data/maps/e1m1/assets.zip}"

got="$(python3 - "$SRC" <<'EOF'
import hashlib, sys, zipfile
p = sys.argv[1]
b = zipfile.ZipFile(p).read("colmap.bin")
print(hashlib.md5(b).hexdigest(), len(b))
EOF
)"
if [[ "$got" != "$WANT 16384" ]]; then
    echo "FAIL: colmap.bin in $SRC is $got, want $WANT 16384" >&2
    exit 1
fi
echo "ok: colmap.bin is the OKLCH ramp table"
