#!/usr/bin/env bash
# Build a guest-only DSI fixture without modifying the prepared ARM64 kernel.
set -euo pipefail
kernel=$(realpath -e "${1:?prepared ARM64 kernel directory}")
out=$(realpath -e "${2:?empty output directory}")
[[ $out != "$kernel" && $out != "$kernel/"* ]]
test -z "$(ls -A -- "$out")"
source=$kernel/drivers/gpu/drm/vkms
cp -- "$source"/*.{c,h} "$source/Makefile" "$out/"

# Expose a DSI-named connector so the installed board helper can find it.
test "$(grep -c 'DRM_MODE_CONNECTOR_VIRTUAL' "$out/vkms_connector.c")" = 1
sed -i 's/DRM_MODE_CONNECTOR_VIRTUAL/DRM_MODE_CONNECTOR_DSI/' "$out/vkms_connector.c"
test "$(grep -c '^static int __init vkms_init(void)$' "$out/vkms_drv.c")" = 1
sed -i '/^static int __init vkms_init(void)$/i#include <linux/of.h>' "$out/vkms_drv.c"
sed -i '/^static int __init vkms_init(void)$/{ n; a\
\tif (!of_machine_is_compatible("linux,dummy-virt"))\n\t\treturn -ENODEV;
}' "$out/vkms_drv.c"

unshare --mount --propagation private bash -s -- "$kernel" "$out" <<'NS'
set -euo pipefail
mount --bind "$1" "$1"
mount -o remount,bind,ro "$1"
make -j2 -C "$1" M="$2" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_DRM_VKMS=m modules
NS
readelf -h "$out/vkms.ko" | grep 'Machine:'
modinfo -F vermagic "$out/vkms.ko"
sha256sum "$out/vkms.ko"
