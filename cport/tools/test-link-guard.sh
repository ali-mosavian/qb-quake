#!/bin/bash
# Regression test: linking must not write into the C library directory,
# and an unusable library must be named rather than swallowed.
#
# What went wrong: DOS LINK takes its output paths from positional
# fields of a response file and creates the list file before validating
# anything, so a trailing '+' on the object list shifted every field up
# one, the LIBRARY field landed in the list-file slot, and LINK
# truncated MATHM.LIB to zero bytes on its way to reporting an
# unrelated "object file not found". The next link then failed with
# "L1102: unexpected end-of-file" naming no file at all, and the real
# damage -- a destroyed toolchain library -- was invisible.
#
#   cport/tools/test-link-guard.sh <build-dir-with-objs> "<obj-names>"
#
# LINK_SH overrides the linker under test, which is how this was
# mutation-checked against the DOS-LINK version it replaced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: test-link-guard.sh <build-dir> <obj-names>}"
OBJS="${2:?usage: test-link-guard.sh <build-dir> <obj-names>}"
LINK_SH="${LINK_SH:-$HERE/link.sh}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/work/other/d32x/toolchains}"
SRCLIB="${BCLIB:-$TOOLCHAINS/bcpp31/LIB}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/LIB"
cp "$SRCLIB"/C0M.OBJ "$SRCLIB"/CM.LIB "$SRCLIB"/MATHM.LIB "$SRCLIB"/FP87.LIB "$TMP/LIB/"

sums() { for f in "$TMP"/LIB/*; do printf '%s %s\n' "$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)" "$(basename "$f")"; done; }

fail=0

before="$(sums)"
BCLIB="$TMP/LIB" "$LINK_SH" "$OUT" "$OBJS" >/dev/null 2>&1
after="$(sums)"
if [[ "$before" != "$after" ]]; then
    echo "FAIL: the link modified the library directory" >&2
    diff <(echo "$before") <(echo "$after") >&2
    fail=1
else
    echo "ok: library directory unchanged across a link"
fi

# An unusable library must be named. The failure this replaces reported
# "unexpected end-of-file" and named nothing, which reads as a corrupt
# response file rather than a destroyed library.
: > "$TMP/LIB/MATHM.LIB"
msg="$( BCLIB="$TMP/LIB" "$LINK_SH" "$OUT" "$OBJS" 2>&1 )"
if [[ $? -eq 0 ]]; then
    echo "FAIL: linked against an empty MATHM.LIB" >&2; fail=1
elif ! grep -qi 'MATHM.LIB' <<<"$msg"; then
    echo "FAIL: empty library not named in the failure:" >&2; echo "$msg" >&2; fail=1
else
    echo "ok: an empty library is named, not swallowed"
fi

exit $fail
