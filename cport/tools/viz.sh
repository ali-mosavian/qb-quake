#!/bin/bash
# Write a windowed conf for a cport build and print its path.
#
#   cport/tools/viz.sh build/cport-e1m1 "e1m1.qmp -at 88 1420 -190 -yaw 270"
#
# autolock=true, and that is the point of this file: the headless
# runner sets it false, and a viz window copied from it captures no
# mouse at all -- the view will not turn and nothing says why. The
# emulated machine is the pinned one, same as everywhere else.
set -euo pipefail

OUT="${1:?usage: viz.sh <build-dir> [\"args\"]}"
QARGS="${2:-dm3ish.qmp}"
OUT="$(cd "$OUT" && pwd)"

{ printf '[sdl]\nautolock=true\noutput=opengl\npriority=higher,normal\n'
  printf '[dosbox]\nmemsize=32\nstartbanner=false\nquit warning=false\n'
  printf '[cpu]\ncore=dynamic\ncycles=%s\n[dos]\nxms=true\nems=true\n[autoexec]\n' "${CYCLES:-75000}"
  echo "@echo off"
  echo "mount w $OUT"
  echo "w:"
  echo "QCPORT.EXE $QARGS"
} > "$OUT/viz.conf"

echo "$OUT/viz.conf"
