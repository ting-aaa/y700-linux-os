#!/usr/bin/env bash
# Build the stock simulator against a prepared kernel without writing to it.
set -euo pipefail
kernel=$(realpath -e "${1:?prepared ARM64 kernel directory}")
out=$(realpath -e "${2:?empty output directory}")
[[ $out != "$kernel" && $out != "$kernel/"* ]]
test -z "$(ls -A -- "$out")"
source=$kernel/drivers/net/wireless/virtual
cp -- "$source"/mac80211_hwsim*.{c,h} "$source/Makefile" "$out/"
unshare --mount --propagation private bash -s -- "$kernel" "$out" <<'NS'
set -euo pipefail
mount --bind "$1" "$1"
mount -o remount,bind,ro "$1"
make -j2 -C "$1" M="$2" ARCH=arm64 LLVM=1 CONFIG_MAC80211_HWSIM=m modules
NS
readelf -h "$out/mac80211_hwsim.ko" | grep 'Machine:'
modinfo -F vermagic "$out/mac80211_hwsim.ko"
