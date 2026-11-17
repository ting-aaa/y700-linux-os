#!/bin/bash
# Fail closed if preparation never completed or its checks failed.
set -Eeuo pipefail
PROJECT=${1:?project directory required}
ROOTFS=${2:?rootfs directory required}
test -f "$ROOTFS/etc/y700/image-id"
test -s "$PROJECT/rootfs/build-completed.txt"
test -s "$PROJECT/rootfs/integration-completed.txt"
test "$PROJECT/rootfs/integration-completed.txt" -nt "$PROJECT/rootfs/build-completed.txt"
test -f "$PROJECT/logs/dpkg-audit.log"
test ! -s "$PROJECT/logs/dpkg-audit.log"
test -s "$PROJECT/rootfs/packages.tsv"
grep -Fxq 'ARM64 userspace commands passed under QEMU user emulation; tablet hardware/kernel not tested.' \
  "$PROJECT/logs/arm64-userspace-smoke.log"
