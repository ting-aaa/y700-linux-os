#!/usr/bin/env bash
# Only the read-only root and an initramfs are connected to an isolated ARM VM.
set -euo pipefail
if (( $# < 6 || $# > 7 )); then
    echo 'Usage: run-qemu.sh ROOT.qcow2 Y700_KERNEL_BUILD BUSYBOX_ARM64 UV_ARM64 BLUEZ_5.82_SRC BTVIRT_ARM64 [--classic]' >&2
    exit 2
fi
root=$(realpath -e "$1")
kernel=$(realpath -e "$2")
busybox=$(realpath -e "$3")
uv=$(realpath -e "$4")
bluez=$(realpath -e "$5")
btvirt=$(realpath -e "$6")
marker=Y700_VIRTUAL_HOG_PASS
extra_cmdline=
if (( $# == 7 )); then
    [[ $7 == --classic ]] || exit 2
    extra_cmdline=y700.virtual_classic=1
    marker=Y700_VIRTUAL_CLASSIC_INPUT_PASS
fi
fixture=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/y700-virtual-hid.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/module" "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test}
printf '%s  %s\n' 4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1 "$kernel/arch/arm64/boot/Image" | sha256sum -c -
printf '%s  %s\n' \
    929e7d251411b8b2ce48b8c2980e54d466591920d99a4c18c201897a8a273736 "$kernel/drivers/bluetooth/hci_vhci.c" \
    48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83 "$kernel/Module.symvers" \
    a190508dd5bafd048ead4404535610c8c827181917cb569530f8de36ad329fd6 "$bluez/test/example-gatt-server" \
    48cda541a25514609bcdd0ea6f9787cc2729f232c37bb8915c714ad8f9ac7b28 "$bluez/test/example-advertisement" \
    b801ccb950de2e511f351f7e346a2cdc519fef1e41634f056850dd7d36dbf742 "$btvirt" | sha256sum -c -
if [[ -n ${XORG_DUMMY_DEB:-} ]]; then
    printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$XORG_DUMMY_DEB" | sha256sum -c -
    cp "$XORG_DUMMY_DEB" "$work/init/test/dummy.deb"
    cp "$fixture/"{desktop.py,desktop-xorg.sh} "$work/init/test/"
fi
cp "$kernel/drivers/bluetooth/hci_vhci.c" "$work/module/"
echo 'obj-m += hci_vhci.o' > "$work/module/Makefile"
make -s -C "$kernel" M="$work/module" ARCH=arm64 LLVM="${LLVM:--21}" modules
cp "$work/module/hci_vhci.ko" "$work/init/test/"
cp "$bluez/test/example-gatt-server" "$work/init/test/gatt.py"
cp "$bluez/test/example-advertisement" "$work/init/test/adv.py"
cp "$fixture/"{central.py,peer.py,classic.py,guest.sh} "$work/init/test/"
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$uv" "$work/init/test/uv"
install -m755 "$btvirt" "$work/init/test/btvirt"
cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t ext4 -o ro,noload /dev/vda /lower
mount -t tmpfs tmpfs /runtime
mkdir /runtime/upper /runtime/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/runtime/upper,workdir=/runtime/work /guest
for d in dev proc sys; do mount --bind "/$d" "/guest/$d"; done
mount -t tmpfs tmpfs /guest/run
mkdir -p /guest/opt/y700-virtual-hid
mount --bind /test /guest/opt/y700-virtual-hid
rc=0
chroot /guest /bin/bash /opt/y700-virtual-hid/guest.sh || rc=$?
echo "Y700_VIRTUAL_HID_EXIT=$rc"
poweroff -f
INIT
chmod 755 "$work/init/init"
(cd "$work/init"; find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd")
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 4 190 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
    -machine virt,gic-version=3 -cpu max -m 680 -smp 2 -nodefaults -no-user-config \
    -display none -monitor none -serial stdio -nic none -no-reboot \
    -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initrd" \
    -append "console=ttyAMA0 loglevel=4 y700.virtual_hid=1 $extra_cmdline panic=4" \
    -drive "if=none,id=root,format=qcow2,readonly=on,file=$root" -device virtio-blk-device,drive=root \
    </dev/null 2>&1 | tr -d '\r' | tee "$work/run.log"
grep -Fxq "$marker" "$work/run.log"
grep -Fxq Y700_VIRTUAL_HID_EXIT=0 "$work/run.log"
if [[ -n ${XORG_DUMMY_DEB:-} ]]; then
    expected=3
    [[ $marker != Y700_VIRTUAL_CLASSIC_INPUT_PASS ]] || expected=2
    [[ $(grep -Fxc Y700_GTK_HID_INPUT_PASS "$work/run.log") == "$expected" ]]
fi
