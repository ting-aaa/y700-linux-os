#!/usr/bin/env bash
# Compare the two actual WCD SoundWire modules on the dev12.12 release kernel.
set -euo pipefail
[[ $# == 6 ]] || { echo 'Usage: run.sh KERNEL_BUILD DEV12.12_KERNEL OLD_WCD_SDW.ko DEV12.12_MODULE_BUILD ARM64_BUSYBOX NEW_OUTPUT' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
k=$(realpath -e "$1"); image=$(realpath -e "$2"); old=$(realpath -e "$3")
build=$(realpath -e "$4"); box=$(realpath -e "$5"); out=$(realpath -m "$6")
mkdir -m700 "$out"
codec=snd-soc-wcd938x-sdw
printf '%s  %s\n' \
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$image" \
    628ddf5a05886bc14d47249cf4efde49b480d06c1b44809c944140dc46d44e18 "$old" \
    7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34 "$box" \
    48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83 "$k/Module.symvers" \
    584377e54526d29fac812db0a94dbd898a12251574998e38795c6e6489d1b3bb "$build/closure/$codec.txt" \
    dff5e5783c32884a0329ecd1e540f4570517be963a30f9284366f6b1b59c8c27 "$build/new-exports.tsv" \
    ca40cb5239c13c1cc669c118ab2dd4e87ce1e93fc1162c4d332ec569f275a64d "$build/staged.sha256" | sha256sum --strict -c -
(cd "$build/staged" && sha256sum --strict --quiet -c ../staged.sha256)
w=$(mktemp -d /var/tmp/y700-wcd-sdw.XXXXXXXX)
trap 'rm -r --one-file-system -- "$w"' EXIT
mkdir -p "$w/probe" "$w/root"/{bin,dev,proc,sys,modules}
cp "$here/channels.c" "$w/probe/"
cat > "$w/probe/Makefile" <<'KBUILD'
obj-m := channels.o
ccflags-y += -I$(srctree)/sound/soc/codecs -DCONFIG_SND_SOC_WCD938X_SDW_MODULE=1
KBUILD
awk -v provider="sound/soc/codecs/$codec" '$3==provider' "$build/new-exports.tsv" > "$w/probe/codec.symvers"
make -s -C "$k" ARCH=arm64 LLVM=1 M="$w/probe" KBUILD_EXTRA_SYMBOLS="$w/probe/codec.symvers" modules
install -m755 "$box" "$w/root/bin/busybox"
install -m755 "$here/guest.sh" "$w/root/init"
cp "$w/probe/channels.ko" "$w/root/modules/"
cp "$old" "$w/root/modules/original.ko"
while read -r action path; do
    [[ $action == insmod ]]
    name=$(basename "$path" .zst)
    if [[ $name == "$codec.ko" ]]; then
        name=candidate.ko
    else
        printf '/modules/%s\n' "$name" >> "$w/root/modules/dependencies"
    fi
    zstd -dc "$build/staged/$path" > "$w/root/modules/$name"
done < "$build/closure/$codec.txt"
(cd "$w/root" && find . -print0 | cpio --null --quiet -o -H newc | gzip -1) > "$w/initrd"
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
timeout -k 3 60 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 2 -m 384 -nodefaults -no-user-config \
    -display none -monitor none -nic none -serial "file:$out/serial.log" -no-reboot \
    -kernel "$image" -initrd "$w/initrd" -append 'console=ttyAMA0 rdinit=/init panic=3' </dev/null
tr -d '\r' < "$out/serial.log" | sed -n -e 's/^.*\(WCD_SDW channels=.*\)$/\1/p' -e '/^WCD_SDW_/p' > "$out/receipt.txt"
grep -Fxq 'WCD_SDW_PASS variants=2 cases_each=5 physical_bus=0' "$out/receipt.txt"
grep -Fxq 'WCD_SDW_EXIT=0' "$out/receipt.txt"
[[ $(grep -c '^WCD_SDW channels=' "$out/receipt.txt") == 10 ]]
cat "$out/receipt.txt"
