#!/bin/bash
# Build only local files. Never accesses a host or tablet block device.
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${Y700_BUILD_ROOT:-/home/builder/y700-linux-build}
ROOTFS="$WORK/debian-rootfs"
MIRROR=${Y700_DEBIAN_MIRROR:-https://mirrors.ustc.edu.cn/debian}
SECURITY_MIRROR=${Y700_SECURITY_MIRROR:-https://security.debian.org/debian-security}
LOGDIR="$PROJECT/logs"
mkdir -p "$WORK" "$LOGDIR" "$PROJECT/rootfs"
if [[ $EUID != 0 ]]; then echo 'Run under WSL as root.' >&2; exit 1; fi
if [[ -e "$ROOTFS" ]]; then
  echo "Rootfs already exists: $ROOTFS. Refusing to overwrite; use a new Y700_BUILD_ROOT." >&2
  exit 1
fi
rm -f -- "$PROJECT/rootfs/build-completed.txt" "$PROJECT/rootfs/integration-completed.txt"
command -v mmdebstrap >/dev/null
test -r /usr/share/keyrings/debian-archive-keyring.gpg
PACKAGES=$(grep -vE '^[[:space:]]*(#|$)' "$PROJECT/config/rootfs-packages.txt" | paste -sd,)
date -u +%FT%TZ > "$PROJECT/rootfs/build-started.txt"
mmdebstrap --architectures=arm64 --mode=root --variant=minbase --format=directory \
  --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
  --setup-hook="bash '$PROJECT/scripts/seed-package-cache.sh' \"\$1\"" \
  --aptopt='Acquire::Retries "4"' \
  --aptopt='Acquire::ForceIPv4 "true"' \
  --aptopt='Acquire::https::Timeout "30"' \
  --aptopt='APT::Install-Recommends "false"' \
  --aptopt='APT::Install-Suggests "false"' \
  --include="$PACKAGES" trixie "$ROOTFS" \
  "deb $MIRROR trixie main non-free-firmware" \
  "deb $MIRROR trixie-updates main non-free-firmware" \
  "deb $SECURITY_MIRROR trixie-security main non-free-firmware" \
  2>&1 | tee "$LOGDIR/rootfs-build.log"
bash "$PROJECT/scripts/configure-rootfs.sh" "$ROOTFS"
chroot "$ROOTFS" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' \
  > "$PROJECT/rootfs/packages.tsv"
cp "$ROOTFS/etc/os-release" "$PROJECT/rootfs/os-release"
date -u +%FT%TZ > "$PROJECT/rootfs/build-completed.txt"
echo "Built rootfs: $ROOTFS"
