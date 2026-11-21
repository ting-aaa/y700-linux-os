#!/usr/bin/env bash
# An ordinary QEMU virt board must resolve module imports and then fail its OF guard.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: guest-check.sh BOARD_KERNEL_DIR .ko ARM64_BUSYBOX NEW_LOG' >&2; exit 2; }
k=$(realpath -e "$1"); ko=$(realpath -e "$2"); box=$(realpath -e "$3"); log=$(realpath -m "$4")
[[ ! -e $log ]]
case $(sha256sum "$k/kernel.efi" | cut -d' ' -f1) in
  b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625) notes=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ;;
  0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60) notes=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 ;;
  *) exit 1 ;;
esac
printf '%s  %s\n' 3ad4f89a4c1b58bfc676136fb15e63b29c9ddae4a2fe9a471f87075c47147dbb "$ko" \
  7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34 "$box" | sha256sum --strict -c -
w=$(mktemp -d)
trap 'rm -r --one-file-system -- "$w"' EXIT
mkdir -p "$w"/root/{bin,sys,proc,dev}
install -m755 "$box" "$w/root/bin/busybox"
cp "$ko" "$w/root/y700_bob_read.ko"
echo "$notes" > "$w/root/notes"
cat > "$w/root/init" <<'INIT'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
[ "$(sha256sum /sys/kernel/notes | cut -d' ' -f1)" = "$(cat /notes)" ]
grep -zFxq linux,dummy-virt /sys/firmware/devicetree/base/compatible
if insmod /y700_bob_read.ko 2>/reason; then exit 1; fi
grep -Fq 'No such device' /reason
[ ! -e /sys/module/y700_bob_read ]
echo "BOB_VM_REJECT notes=$(cat /notes) no_such_device=1 retained_module=0"
sleep 1
exec poweroff -f
INIT
chmod 755 "$w/root/init"
(cd "$w/root"; find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$w/initrd")
data=(); [[ -z ${QEMU_DATA_DIR:-} ]] || data=(-L "$QEMU_DATA_DIR")
timeout -k 3 65 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${data[@]}" -machine virt,gic-version=3 \
  -cpu max -smp 2 -m 400 -nodefaults -no-user-config -no-reboot -display none -monitor none -nic none \
  -serial stdio -kernel "$k/kernel.efi" -initrd "$w/initrd" -append 'rdinit=/init console=ttyAMA0 quiet panic=3' \
  </dev/null 2>&1 | tr -d '\r' | tee "$log"
grep -Fx "BOB_VM_REJECT notes=$notes no_such_device=1 retained_module=0" "$log"
