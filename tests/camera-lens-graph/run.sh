#!/bin/bash
# Diskless ARM64 VIMC lens topology and metadata checks.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: run.sh PREPARED_KERNEL ARM64_BUSYBOX NEW_LOG_DIRECTORY' >&2; exit 2; }
kernel=$(realpath -e "$1")
busybox=$(realpath -e "$2")
logs=$(realpath -m "$3")
mkdir -m700 "$logs"
here=$(cd "$(dirname "$0")" && pwd -P)
w=$(mktemp -d)
trap 'rm -r --one-file-system -- "$w"' EXIT
image=$kernel/arch/arm64/boot/Image
echo "9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  $image" | sha256sum --strict -c -
m=$w/module
r=$w/root
mkdir -p "$m" "$r"/{bin,dev,proc,sys}
cp "$kernel"/drivers/media/test-drivers/vimc/*.{c,h} "$m/"
cp "$kernel"/drivers/media/common/v4l2-tpg/*.c "$m/"
cp "$kernel/drivers/media/common/videobuf2/videobuf2-vmalloc.c" "$m/"
cat > "$m/Makefile" <<'MAKE'
obj-m := videobuf2-vmalloc.o v4l2-tpg.o vimc.o
v4l2-tpg-y := v4l2-tpg-core.o v4l2-tpg-colors.o
vimc-y := vimc-core.o vimc-common.o vimc-streamer.o vimc-capture.o vimc-debayer.o vimc-scaler.o vimc-sensor.o vimc-lens.o
MAKE
build=(make -s -j4 -C "$kernel" M="$m" ARCH=arm64 LLVM=1 modules)
"${build[@]}"
cp "$m"/*.ko "$r/"
# Second VIMC keeps both lens entities, but omits only the ancillary link from Sensor A.
test "$(grep -Fc 'VIMC_ANCILLARY_LINK(0, 9),' "$m/vimc-core.c")" = 1
sed -i '/VIMC_ANCILLARY_LINK(0, 9),/d' "$m/vimc-core.c"
"${build[@]}"
cp "$m/vimc.ko" "$r/no-link.ko"
# A third graph registers the same sensors and data links, without either lens.
sed -i 's/\.num_ents\([[:space:]]*\)= ARRAY_SIZE(ent_config)/.num_ents\1= LENS_A/; s/\.num_ancillary_links = ARRAY_SIZE(ancillary_links)/.num_ancillary_links = 0/' "$m/vimc-core.c"
grep -Eq '\.num_ents[[:space:]]*= LENS_A,' "$m/vimc-core.c"
grep -Fq '.num_ancillary_links = 0,' "$m/vimc-core.c"
"${build[@]}"
cp "$m/vimc.ko" "$r/no-lens.ko"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -Wall -Wextra -Werror -static -O2 "$here/check.c" -o "$r/check"
cp "$busybox" "$r/bin/busybox"
ln -s busybox "$r/bin/sh"
cp "$here/guest.sh" "$r/init"
chmod 755 "$r/init"
(cd "$r" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n > "$w/initrd")
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
timeout 90 "${qemu[@]}" -M virt,gic-version=3 -cpu max -smp 2 -m 512 -nodefaults -no-user-config \
    -nic none -display none -monitor none -serial "file:$logs/guest.log" -no-reboot \
    -kernel "$image" -initrd "$w/initrd" -append 'console=ttyAMA0,115200 rdinit=/init nokaslr' >"$logs/qemu.log" 2>&1
grep '^LENS_GRAPH_QA_PASS ' "$logs/guest.log"
cp "$r/check" "$logs/lens-graph.arm64"
(cd "$logs" && sha256sum lens-graph.arm64 > SHA256SUMS)
