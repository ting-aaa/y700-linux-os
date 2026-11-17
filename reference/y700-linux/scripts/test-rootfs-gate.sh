#!/bin/bash
set -Eeuo pipefail
SCRIPT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/verify-rootfs-integration.sh
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/project/rootfs" "$FIXTURE/project/logs" "$FIXTURE/rootfs/etc/y700"
touch "$FIXTURE/rootfs/etc/y700/image-id"
printf 'built\n' > "$FIXTURE/project/rootfs/build-completed.txt"
touch -t 202001010000 "$FIXTURE/project/rootfs/build-completed.txt"
printf 'package\t1\tarm64\n' > "$FIXTURE/project/rootfs/packages.tsv"
: > "$FIXTURE/project/logs/dpkg-audit.log"
printf '%s\n' 'ARM64 userspace commands passed under QEMU user emulation; tablet hardware/kernel not tested.' \
  > "$FIXTURE/project/logs/arm64-userspace-smoke.log"
expect_failure() {
  if bash "$SCRIPT" "$FIXTURE/project" "$FIXTURE/rootfs"; then
    echo "FAIL: unexpectedly accepted $1" >&2; exit 1
  fi
  echo "PASS: rejected $1"
}
expect_failure 'missing integration receipt'
printf 'integrated\n' > "$FIXTURE/project/rootfs/integration-completed.txt"
touch -t 201901010000 "$FIXTURE/project/rootfs/integration-completed.txt"
expect_failure 'receipt from an older build'
touch "$FIXTURE/project/rootfs/integration-completed.txt"
printf 'unconfigured package\n' > "$FIXTURE/project/logs/dpkg-audit.log"
expect_failure 'package audit errors'
: > "$FIXTURE/project/logs/dpkg-audit.log"
: > "$FIXTURE/project/logs/arm64-userspace-smoke.log"
expect_failure 'incomplete smoke run'
printf '%s\n' 'ARM64 userspace commands passed under QEMU user emulation; tablet hardware/kernel not tested.' \
  > "$FIXTURE/project/logs/arm64-userspace-smoke.log"
bash "$SCRIPT" "$FIXTURE/project" "$FIXTURE/rootfs"
echo 'PASS: complete integration receipt and logs accepted'
