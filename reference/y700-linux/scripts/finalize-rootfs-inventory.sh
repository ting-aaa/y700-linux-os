#!/bin/bash
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${Y700_BUILD_ROOT:-/home/builder/y700-linux-build}
ROOTFS="$WORK/debian-rootfs"
bash "$PROJECT/scripts/verify-rootfs-integration.sh" "$PROJECT" "$ROOTFS"
chroot "$ROOTFS" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' \
  > "$PROJECT/rootfs/packages.tsv"
test "$(chroot "$ROOTFS" dpkg --audit | wc -c)" = 0
# Exclude only builder-generated random state; user data never enters this tree.
if [[ -f "$ROOTFS/var/lib/systemd/random-seed" ]]; then
  rm -- "$ROOTFS/var/lib/systemd/random-seed"
fi
