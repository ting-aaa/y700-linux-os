#!/bin/bash
# Compare RTC class registration on the physical baseline kernel in two small VMs.
set -euo pipefail
awake=0
if [[ ${1:-} == --awake ]]; then awake=1; shift; fi
[[ $# == 3 ]] || { echo 'Usage: run.sh [--awake] PREPARED_KERNEL STATIC_ARM64_BUSYBOX NEW_LOG_DIRECTORY' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd -P)
k=$(realpath -e "$1")
busybox=$(realpath -e "$2")
logs=$(realpath -m "$3")
mkdir -m 700 "$logs"
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
image=$k/arch/arm64/boot/Image
printf '%s  %s\n' 9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db "$image" | sha256sum --strict -c
mkdir -p "$work"/{module,root/{bin,dev,proc,sys}}
cp "$k/drivers/rtc/rtc-pl031.c" "$work/module/"
echo 'obj-m += rtc-pl031.o' >"$work/module/Makefile"
make -s -C "$k" M="$work/module" ARCH=arm64 LLVM=1 modules
cp "$work/module/rtc-pl031.ko" "$work/root/"
cp "$busybox" "$work/root/bin/busybox"
ln -s busybox "$work/root/bin/sh"
if (( awake )); then
    cc=${AARCH64_CC:-aarch64-linux-gnu-gcc}
    "$cc" -static -O2 -Wall -Wextra -Werror -s "$here/awake-alarm.c" -o "$work/root/board-probe"
    "$cc" -static -O2 -Wall -Wextra -Werror -s -DRTC_QA_PL031 "$here/awake-alarm.c" -o "$work/root/guest-probe"
    cp "$here/check-awake.sh" "$work/root/awake-qa"
fi
cat >"$work/root/init" <<'INIT'
#!/bin/sh
set -eu
b=/bin/busybox
$b mount -t devtmpfs devtmpfs /dev
$b mount -t proc proc /proc
$b mount -t sysfs sysfs /sys
exec > /dev/console 2>&1
trap '$b poweroff -f' EXIT
test -z "$($b ls /sys/class/rtc)"
if test -f /awake-qa; then
    $b insmod /rtc-pl031.ko
    $b sh /awake-qa
    exit
fi
$b date -u -s '2024-01-02 03:04:05' >/dev/null
before=$($b date -u +%s)
$b insmod /rtc-pl031.ko
for i in 1 2 3 4 5; do test -n "$($b ls /sys/class/rtc)" && break; $b sleep 1; done
name=$($b ls /sys/class/rtc)
clock=/sys/class/rtc/$name
hardware=$($b cat "$clock/since_epoch")
after=$($b date -u +%s)
synced=$($b cat "$clock/hctosys")
test "$before" -ge 1704164645
test "$before" -lt 1704164945
test "$hardware" -ge 1262401445
test "$hardware" -lt 1262401745
if $b grep -qw rtcqa.alias=1 /proc/cmdline; then
    test "$name" = rtc1
    test "$synced" = 0
    test "$after" -ge "$before"
    test "$after" -lt "$((before+300))"
else
    test "$name" = rtc0
    test "$synced" = 1
    test "$after" -ge "$((hardware-2))"
    test "$after" -le "$((hardware+2))"
fi
echo "RTC_ALIAS_PASS name=$name hctosys=$synced before=$before after=$after hardware=$hardware"
INIT
chmod +x "$work/root/init"
(cd "$work/root" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n > "$work/initrd")
qemu=( "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" )
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
common=(-cpu max -smp 2 -m 512 -nodefaults -no-user-config -nic none -display none -monitor none)
"${qemu[@]}" -M "virt,gic-version=3,dumpdtb=$work/dump.dtb" "${common[@]}"
# Remove QEMU's 1 MiB dump padding before passing either DT back as a boot input.
dtc -q -I dtb -O dtb -o "$work/plain.dtb" "$work/dump.dtb"
cp "$work/plain.dtb" "$work/aliased.dtb"
fdtput -t s "$work/aliased.dtb" /aliases rtc1 /pl031@9010000
for variant in plain aliased; do
    if (( awake )) && [[ $variant == plain ]]; then continue; fi
    alias_id=0
    if [[ $variant == aliased ]]; then alias_id=1; fi
    timeout 90 "${qemu[@]}" -M virt,gic-version=3 "${common[@]}" -serial "file:$logs/$variant.log" -no-reboot \
        -dtb "$work/$variant.dtb" -kernel "$image" -initrd "$work/initrd" \
        -rtc base=2010-01-02T03:04:05,clock=vm \
        -append "console=ttyAMA0,115200 nokaslr rdinit=/init rtcqa.alias=$alias_id" \
        >"$logs/$variant.qemu.log" 2>&1
    if (( awake )); then grep '^RTC_AWAKE_QA_PASS ' "$logs/$variant.log"
    else grep '^RTC_ALIAS_PASS ' "$logs/$variant.log"; fi
done
