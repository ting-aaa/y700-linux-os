# Test the packaged Xorg DSI geometry on ARM64

Use a Linux host with cpio, gzip, QEMU system ARM64, a static ARM64 BusyBox, and a built Y700 7.3.4 kernel tree. The input root is an ext4 image with stock Trixie `xserver-xorg-core 2:21.1.16-1.3+deb13u4` and `xrandr`. Run the commands from the repository. Set `kernel` to the configured kernel build tree.

Build a virtual connector module against that exact kernel. Its module parameters control connector type, KMS size and EDID. The fixture checks the machine's device-tree compatible at module initialization and is compiled separately from the board image.

```sh
fixture=$(mktemp -d)
cp "$kernel/drivers/gpu/drm/vkms/"*.c "$kernel/drivers/gpu/drm/vkms/"*.h \
    "$kernel/drivers/gpu/drm/vkms/Makefile" "$fixture/"
(cd "$fixture" && sha256sum --check - <<'EOF'
eb59b02ca1b6cc1a083b058682cc2a9c68775f37124caa94ae6a1e65df657314  vkms_connector.c
4ce37aecdea98794cdc5c855b59b6aa7764168b85d4e5f0ea9065db63e6d1007  vkms_drv.c
EOF
)
patch --batch --fuzz=0 -d "$fixture" -p1 < tests/xorg-dsi/vkms-connector.patch
make -C "$kernel" M="$fixture" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- \
    CONFIG_DRM_VKMS=m modules
bash tests/xorg-dsi/run-vm.sh "$kernel/arch/arm64/boot/Image" "$root_ext4" \
    "$arm64_busybox" "$fixture/vkms.ko" "$package_directory" "$new_receipt"
```

The VM mounts the input root read-only and runs dpkg in a temporary RAM overlay. It first launches the stock X server. It then installs both candidate packages and starts Xorg on its default module search path. For each case it checks the connector's EDID byte count, runs three RandR queries and checks the reported millimeters. The test passes when all five cases match and the guest powers off. The serial receipt reports the installed versions and each RandR result.

The VM uses 896 MiB and has no network adapter. Set `QEMU_SYSTEM_AARCH64` and `QEMU_DATA_DIR` to use a host QEMU installation outside PATH.
