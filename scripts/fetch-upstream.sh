#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/reference/y700-linux/asphalt-upstream"
commit=8dcb481fc2ce91794fd294630e06f15a52ec7513
test ! -e "$target" || { echo 'Upstream path already exists; inspect it instead of overwriting.' >&2; exit 1; }
git clone --no-checkout --filter=blob:none https://github.com/dianqk/nixos-android-devices.git "$target"
git -C "$target" checkout --detach "$commit"
test "$(git -C "$target" rev-parse HEAD)" = "$commit"
echo 'Pinned source ready. No tablet operation performed.'
