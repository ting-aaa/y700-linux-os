#!/bin/bash
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=${1:?mmdebstrap target required}
if [[ -d "$PROJECT/rootfs/package-cache" ]]; then
  install -d "$TARGET/var/cache/apt/archives"
  find "$PROJECT/rootfs/package-cache" -maxdepth 1 -type f -name '*.deb' \
    -exec cp --target-directory="$TARGET/var/cache/apt/archives" -- {} +
fi
