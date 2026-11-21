#!/usr/bin/env bash
# Build the checked driver and exercise it and the stock cache reader on the release ARM64 kernel.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $# == 6 && $EUID == 0 ]] || { echo 'Usage: run.sh KERNEL_BUILD DEV12.12_EFI QUALIFIED_MIC_MODULES CN350_MODULES ARM64_BUSYBOX NEW_OUTPUT' >&2; exit 2; }
    exec unshare --mount --propagation private bash "$0" --inside "$@"
fi
shift
export LC_ALL=C
umask 022
here=$(cd "$(dirname "$0")" && pwd)
k=$(realpath -e "$1"); image=$(realpath -e "$2"); mic=$(realpath -e "$3"); oem=$(realpath -e "$4")
box=$(realpath -e "$5"); out=$(realpath -m "$6"); mkdir -m700 "$out"
printf '%s  %s\n' \
    0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$image" \
    c6d1fe48ee9f9c00e6b311277bf58bab711b84a08add74f4e69563eab0920ee1 "$k/sound/soc/codecs/wcd938x.c" \
    e11e4aec14484f00d2733d57addec6b45164b7c0e00f31d50675f8bf6dd53594 "$k/sound/soc/codecs/wcd938x.h" \
    0c3b35a67fe57f7e1536919bee79fcd58ad5129b74b568179cc878a917aaf548 "$k/sound/soc/codecs/wcd938x-sdw.c" \
    830dd1a2aed821ae4cc38b6c37c56630ba69cf7c59b486692a7b9769607a61d6 "$mic/candidate.config" \
    dff5e5783c32884a0329ecd1e540f4570517be963a30f9284366f6b1b59c8c27 "$mic/new-exports.tsv" \
    ccadea506a41b8883fc7d689d8c7e764129f4b3b520bf6a283321166e13a47e6 "$mic/staged.sha256" \
    65b9a48509d6244443cdd9e05e7ae42a09fb2acc86172290ff651cd7b73e51c3 "$mic/closure/snd-soc-wcd938x.txt" \
    48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83 "$k/Module.symvers" \
    7e4651a68cdf17413984a567efb545c5c9fd191c0c99cab6a722d37e42792e0a "$oem/wcd938x_dlkm.ko" \
    cf7a2e834dc3d3cc985a615f15d10887d2888bb4c5172a67cc6b1e9fab2e9d1d "$oem/machine_dlkm.ko" \
    7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34 "$box" | sha256sum --strict -c -
(cd "$mic/staged" && sha256sum --strict --quiet -c ../staged.sha256)
w=$(mktemp -d /var/tmp/y700-mic-id-vm.XXXXXXXX)
cleanup() { cd /; if mountpoint -q "$w/tree"; then umount "$w/tree"; fi; rm -r --one-file-system -- "$w"; }
trap cleanup EXIT
mkdir "$w"/{tree,upper,work,fixture}
mount -t overlay overlay -o "lowerdir=$k,upperdir=$w/upper,workdir=$w/work" "$w/tree"
cd "$w/tree"
cp "$mic/candidate.config" .config
patch -p1 --fuzz=0 < "$here/../../../config/kernel/asphalt-wcd938x-checked-id.patch"
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP='2026-11-21 00:00:00 UTC'
make=(make -s -j2 ARCH=arm64 LLVM=1)
"${make[@]}" olddefconfig
cmp .config "$mic/candidate.config"
# Single-target in-tree modpost also needs exports from the unchanged codec dependencies.
awk '$3!="vmlinux"' "$k/Module.symvers" > "$w/exports"
cat "$mic/new-exports.tsv" >> "$w/exports"
cat >"$w/modpost" <<'POST'
#!/bin/sh
exec scripts/mod/modpost -i "$(dirname "$0")/exports" "$@"
POST
chmod 755 "$w/modpost"
"${make[@]}" "MODPOST=$w/modpost" sound/soc/codecs/snd-soc-wcd938x.ko
cp sound/soc/codecs/snd-soc-wcd938x.ko "$out/"
src=sound/soc/codecs/wcd938x.c
{
    grep -E '^#define CHIPID_WCD938[05][[:space:]]' "$src"
    grep -E '^#define WCD938X_(DIGITAL_EFUSE_REG_0|ID_MASK)[[:space:]]' sound/soc/codecs/wcd938x.h
    sed -n '/^static int wcd938x_read_variant(/,/^}/p' "$src"
} > "$w/fixture/variant.inc"
cp "$here/regmap-test.c" "$w/fixture/"
echo 'obj-m := regmap-test.o' > "$w/fixture/Makefile"
"${make[@]}" -C "$k" M="$w/fixture" modules
root=$w/root
stock=$root/stock
mkdir -p "$root"/{bin,dev,proc,sys,modules} "$stock"/{system/bin,proc/asound/card0/codecs/wcd938x}
install -m755 "$box" "$root/bin/busybox"
ln "$root/bin/busybox" "$stock/system/bin/toybox-qa"
for cmd in sh cat sha256sum; do ln -s toybox-qa "$stock/system/bin/$cmd"; done
cat >"$stock/system/bin/getprop" <<'PROP'
#!/system/bin/sh
case "$1" in
  ro.product.device) echo TB320FC;;
  ro.build.version.incremental) cat /incremental;;
  *) exit 1;;
esac
PROP
chmod 755 "$stock/system/bin/getprop"
echo TB320FC_CN_OPEN_USER_Q00031.0_V_ZUI_17.0.350_ST_250418 > "$stock/incremental"
for m in wcd938x_dlkm machine_dlkm; do
    mkdir -p "$stock/sys/module/$m/notes"
    llvm-objcopy --dump-section ".note.gnu.build-id=$stock/sys/module/$m/notes/.note.gnu.build-id" "$oem/$m.ko" "$w/discard"
done
install -m755 "$here/../stock-variant.sh" "$stock/reader"
install -m755 "$here/guest.sh" "$root/init"
cp "$w/fixture/regmap-test.ko" "$root/modules/"
while read -r action path; do
    [[ $action == insmod ]]
    name=$(basename "$path" .zst)
    if [[ $name == snd-soc-wcd938x.ko ]]; then
        cp "$out/$name" "$root/modules/"
    else
        zstd -dc "$mic/staged/$path" >"$root/modules/$name"
    fi
    echo "/modules/$name" >> "$root/modules/order"
done < "$mic/closure/snd-soc-wcd938x.txt"
(cd "$root" && find . -print0 | cpio --quiet --null -o -H newc | gzip -1) > "$w/initrd"
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
timeout -k 3 80 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -m 384 -smp 2 -nodefaults -no-user-config \
    -display none -nic none -monitor none -serial "file:$out/boot.log" -no-reboot \
    -kernel "$image" -initrd "$w/initrd" -append 'console=ttyAMA0,115200 rdinit=/init panic=2'
tr -d '\r' < "$out/boot.log" | grep -E '(WCD_ID_|WCD_STOCK|WCD_QA_PASS|reboot: Power down)' > "$out/receipt.txt"
grep -Fq 'WCD_ID_MATRIX_PASS cases=7 reads=14 writes=0' "$out/receipt.txt"
grep -Fxq 'WCD_QA_PASS native_module=live stock_reader_cases=7' "$out/receipt.txt"
grep -Fq 'reboot: Power down' "$out/receipt.txt"
(cd "$out" && sha256sum snd-soc-wcd938x.ko >SHA256SUMS)
