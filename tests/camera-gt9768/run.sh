#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: run.sh PREPARED_KERNEL CANDIDATE ARM64_BUSYBOX NEW_RESULTS' >&2; exit 2; }
kernel=$(realpath -e "$1")
candidate=$(realpath -e "$2")
busybox=$(realpath -e "$3")
results=$(realpath -m "$4")
mkdir -m700 "$results"
(cd "$candidate"; sha256sum --strict -c SHA256SUMS)
here=$(cd "$(dirname "$0")" && pwd)
w=$(mktemp -d)
trap 'rm -r --one-file-system -- "$w"' EXIT
r=$w/root
mkdir -p "$r"/{bin,dev,proc,sys} "$w/module"
cp "$here/adapter.c" "$w/module/"
echo 'obj-m := adapter.o' >"$w/module/Makefile"
make -s -C "$kernel" M="$w/module" LLVM=1 ARCH=arm64 modules
cp "$w/module/adapter.ko" "$r/"
for pair in "$here/control.c:$r/control" "$here/../camera-lens-graph/check.c:$r/graph"; do
	aarch64-linux-gnu-gcc -O2 -Wall -Wextra -Werror -static "${pair%:*}" -o "${pair##*:}"
done
cp "$busybox" "$r/bin/busybox"
ln -s busybox "$r/bin/sh"
cp "$here/init.sh" "$r/init"
chmod 755 "$r/init"
(cd "$r"; find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n > "$w/initrd")
q=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then q+=(-L "$QEMU_DATA"); fi
opts=(-cpu max -smp 2 -m 512 -nodefaults -no-user-config -nic none -display none -monitor none)
"${q[@]}" "${opts[@]}" -M "virt,gic-version=3,dumpdtb=$w/base.dtb"
dtc -q -I dtb -O dts "$w/base.dtb" > "$w/guest.dts"
cat "$here/vm.dtsi" >> "$w/guest.dts"
dtc -q -I dts -O dtb "$w/guest.dts" -o "$w/guest.dtb"
timeout 150 "${q[@]}" "${opts[@]}" -M virt,gic-version=3 -dtb "$w/guest.dtb" -serial "file:$results/guest.log" -no-reboot \
    -kernel "$candidate/kernel.efi" -initrd "$w/initrd" -append 'console=ttyAMA0,115200 rdinit=/init nokaslr loglevel=4' >"$results/qemu.log" 2>&1
grep -E '^(LENS_(GRAPH|PASS)|GT9768_QA_PASS)' "$results/guest.log"
grep -q '^GT9768_QA_PASS ' "$results/guest.log"
! grep -Eq 'BUG:|Call trace:|Kernel panic|WARNING: CPU:' "$results/guest.log"
