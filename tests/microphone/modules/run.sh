#!/usr/bin/env bash
# Load the exact staged compressed modules using Debian kmod on a hardware-free virt board.
set -euo pipefail
mode=shipped
image_hash=4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1
notes=c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564
root_hash=e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb
elf_manifest=643fcd01ad5b928ff99648b11189640f1cb551d9ac2dae5395623cd95aaae933
stage_manifest=ccadea506a41b8883fc7d689d8c7e764129f4b3b520bf6a283321166e13a47e6
if [[ ${1:-} == --build-base ]]; then
    shift
    mode=build-base
    image_hash=9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db
    notes=2e6b047aba528bfdea5549b9aae9af362a9af055bb630a650bcdd7c654ec9066
elif [[ ${1:-} == --dev12.12 || ${1:-} == --dev12.12-120 ]]; then
    mode=${1#--}
    shift
    root_hash=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
    elf_manifest=091e21b852b20a4c0f85ac4204cdf82fccb897ff8e302a92c81099d8c407f28d
    stage_manifest=f1b578a728d058be00c037fb3b20abb60506e5f96fb108dc6af75d1f31c24eee
    if [[ $mode == dev12.12 ]]; then
        image_hash=0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60
        notes=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063
    else
        image_hash=b103d0fcd65a08cadb592fbdc69c8c483a7727ef212c15e464208f5c30a1a625
        notes=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6
    fi
fi
[[ $# == 5 ]] || { echo 'Usage: run.sh [--build-base|--dev12.12|--dev12.12-120] KERNEL_IMAGE SEALED_ROOT.ext4 MODULE_BUILD ARM64_BUSYBOX NEW_LOG_DIR' >&2; exit 2; }
image=$(realpath -e "$1")
disk=$(realpath -e "$2")
build=$(realpath -e "$3")
busybox=$(realpath -e "$4")
out=$(realpath -m "$5")
here=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir "$out"
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-mic-load.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
release=7.3.4-asphalt-prc
printf '%s  %s\n' "$image_hash" "$image" \
    "$root_hash" "$disk" "$elf_manifest" "$build/SHA256SUMS" \
    "$stage_manifest" "$build/staged.sha256" > "$out/inputs.sha256"
sha256sum --strict -c "$out/inputs.sha256"
(cd "$build" && sha256sum --strict --quiet -c SHA256SUMS)
(cd "$build/staged" && sha256sum --strict --quiet -c ../staged.sha256)
mkdir -p "$work/init"/{bin,dev,proc,sys,guest,modules,qa}
install -m755 "$busybox" "$work/init/bin/busybox"
install -m755 "$here/init" "$work/init/init"
install -m644 "$here/guest.sh" "$work/init/qa/guest.sh"
printf '%s\t%s\t%s\n' "$mode" "$image_hash" "$notes" > "$work/init/qa/kernel.tsv"
cp -a "$build/staged/lib/modules/$release" "$work/init/modules"
{
    awk '{sub("^modules/", "kernel/", $2); print $2}' "$build/SHA256SUMS"
    printf '%s\n' kernel/sound/soc/codecs/snd-soc-cs35l45{,-i2c}.ko
} | while read -r target; do
    zstd -qd < "$work/init/modules/$release/$target.zst" > "$work/module.ko"
    llvm-objcopy --dump-section ".note.gnu.build-id=$work/note" "$work/module.ko" "$work/copy.ko"
    hash=$(sha256sum "$work/note")
    name=$(basename "$target" .ko)
    printf '%s\t%s\t%s\n' "${name//-/_}" "${hash%% *}" "$target.zst"
done > "$work/init/qa/modules.tsv"
[[ $(wc -l < "$work/init/qa/modules.tsv") == 14 ]]
cp "$work/init/qa/modules.tsv" "$out/"
(cd "$work/init" && find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd.gz")
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
timeout -k 5 90 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 2 -m 512 -nodefaults -no-user-config \
    -display none -monitor none -nic none -serial "file:$out/serial.log" -no-reboot \
    -kernel "$image" -initrd "$work/initrd.gz" -append 'console=ttyAMA0 rdinit=/init loglevel=3 panic=4 y700.module_test=1' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=root </dev/null
tr -d '\r' < "$out/serial.log" | grep -E '^(MODULE_|MIC_MODULES_)' > "$out/receipt.log"
cat "$out/receipt.log"
grep -Fxq 'MIC_MODULES_PASS rounds=2 targets=14' "$out/receipt.log"
grep -Fxq 'MIC_MODULES_EXIT=0' "$out/receipt.log"
grep -q 'reboot: Power down' "$out/serial.log"
