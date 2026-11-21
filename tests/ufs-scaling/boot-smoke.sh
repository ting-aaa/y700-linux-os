#!/usr/bin/env bash
# Boot the exact Image and match its running build notes on QEMU virt without block devices.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: boot-smoke.sh CANDIDATE ARM64_BUSYBOX NEW_LOG' >&2; exit 2; }
candidate=$(realpath -e "$1"); busybox=$(realpath -e "$2"); log=$(realpath -m "$3")
[[ ! -e $log && ! -L $log ]]
(cd "$candidate"; sha256sum --strict -c SHA256SUMS)
w=$(mktemp -d)
trap 'rm -r -- "$w"' EXIT
mkdir -p "$w/root"/{bin,sys,proc,dev}
install -m755 "$busybox" "$w/root/bin/busybox"
sha256sum < "$candidate/notes" | cut -d' ' -f1 > "$w/root/notes.sha"
cat > "$w/root/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t sysfs sysfs /sys
mount -t proc proc /proc
grep -zFxq linux,dummy-virt /sys/firmware/devicetree/base/compatible
test "$(sha256sum /sys/kernel/notes | cut -d' ' -f1)" = "$(cat /notes.sha)"
test ! -e /sys/bus/platform/devices/1d84000.ufshc
echo "UFS_IMAGE_SMOKE release=$(uname -r) notes=$(cat /notes.sha) qemu_virt=1 physical_ufs=0"
exec /bin/busybox poweroff -f
INIT
chmod 755 "$w/root/init"
(cd "$w/root"; find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$w/initrd")
args=(); [[ -z ${QEMU_DATA_DIR:-} ]] || args=(-L "$QEMU_DATA_DIR")
timeout -k 4 110 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 768 -nodefaults -no-user-config -no-reboot \
    -display none -monitor none -nic none -serial stdio -kernel "$candidate/kernel.efi" -initrd "$w/initrd" \
    -append 'rdinit=/init console=ttyAMA0 quiet panic=4' </dev/null 2>&1 | tr -d '\r' | tee "$log"
expected=$(cat "$w/root/notes.sha")
grep -Fx "UFS_IMAGE_SMOKE release=7.3.4-asphalt-prc notes=$expected qemu_virt=1 physical_ufs=0" "$log"
