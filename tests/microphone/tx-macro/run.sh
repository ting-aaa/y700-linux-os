#!/bin/bash
# Run identical ALSA control and DAI calls with the baseline and patched driver.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Usage: run.sh PREPARED_KERNEL MODULES_ROOT ARM64_BUSYBOX NEW_LOGS' >&2; exit 2; }
k=$(realpath -e "$1")
module_root=$(realpath -e "$2")
busybox=$(realpath -e "$3")
logs=$(realpath -m "$4")
here=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$k/include/config/kernel.release")
image=$k/arch/arm64/boot/Image
printf '%s  %s\n' \
    37ad9373051ca515d2b33e3e38c3506f10dac003a71b8c82fcb7f81f2048a58b "$k/sound/soc/codecs/lpass-tx-macro.c" \
    4626edf0d6fc948d3ae91160b0497ce3f394d47bcbefc34f607e87559f015fef "$k/sound/soc/qcom/sc8280xp.c" \
    f19efb1abd2a5edec2278fa9de4b6b2f82f0339fb2513404004ec06be85f05fe "$k/sound/soc/qcom/qdsp6/audioreach.c" \
    40a0edb5cc7ba4e2288d320bb8e551cd8e181b218e9a0331d7ebb403afc91c23 "$k/sound/soc/qcom/qdsp6/q6apm-lpass-dais.c" \
    9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db "$image" | sha256sum --strict -c -
mkdir -m700 "$logs"
work=$(mktemp -d)
trap 'rm -r --one-file-system -- "$work"' EXIT
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_DATA:-} ]]; then qemu+=(-L "$QEMU_DATA"); fi
args=(-cpu max -m 512 -smp 2 -nodefaults -no-user-config -nic none -display none -monitor none)
"${qemu[@]}" "${args[@]}" -machine "virt,gic-version=3,dumpdtb=$work/base.dtb"
dtc -@ -I dts -O dtb -o "$work/macro.dtbo" "$here/virtual.dts"
fdtoverlay -i "$work/base.dtb" -o "$work/test.dtb" "$work/macro.dtbo"
mkdir -p "$work/modules" "$work/root"/{bin,sys,proc,dev,modules}
cp "$k/sound/soc/codecs/"{lpass-macro-common.h,lpass-macro-common.c,lpass-tx-macro.c} "$work/modules/"
cp "$here/"{test-card,q6-packet}.c "$k/sound/soc/qcom/sc8280xp.c" "$work/modules/"
cat > "$work/modules/Makefile" <<'KBUILD'
ccflags-y += -I$(srctree)/sound/soc/qcom -I$(srctree)/sound/soc/qcom/qdsp6
snd-soc-lpass-macro-common-y := lpass-macro-common.o
snd-soc-lpass-tx-macro-y := lpass-tx-macro.o
snd-soc-sc8280xp-y := sc8280xp.o
obj-m += snd-soc-lpass-macro-common.o snd-soc-lpass-tx-macro.o snd-soc-sc8280xp.o test-card.o q6-packet.o
KBUILD
cp "$busybox" "$work/root/bin/busybox"
modprobe -d "$module_root" -S "$version" --show-depends snd-soc-core > "$work/dependencies"
while read -r verb path; do
    [[ $verb == insmod ]]
    name=$(basename "$path" .zst)
    case $path in
        *.ko.zst) zstd -dq "$path" -o "$work/root/modules/$name" ;;
        *.ko) cp "$path" "$work/root/modules/$name" ;;
        *) exit 1 ;;
    esac
    echo "/modules/$name" >> "$work/root/modules/order"
done < "$work/dependencies"
cat > "$work/root/init" <<'INIT'
#!/bin/busybox sh
set -eu
b=/bin/busybox
trap '$b poweroff -f' EXIT
$b mount -t proc proc /proc
$b mount -t sysfs sysfs /sys
$b mount -t devtmpfs devtmpfs /dev
while read -r module; do $b insmod "$module"; done < /modules/order
for m in snd-soc-lpass-macro-common snd-soc-lpass-tx-macro test-card q6-packet; do $b insmod "/modules/$m.ko"; done
$b cat /proc/asound/cards
$b grep -q Y700-TX-test /proc/asound/cards
echo TX_STEREO_CARD_REGISTERED
INIT
chmod 755 "$work/root/init"
for variant in original fixed; do
    if [[ $variant == fixed ]]; then
        patch -s --fuzz=0 -p4 -d "$work/modules" < "$here/../../../config/kernel/asphalt-lpass-tx-stereo.patch"
        patch -s --fuzz=0 -p4 -d "$work/modules" < "$here/../../../config/kernel/asphalt-tx3-dma-map.patch"
    fi
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python "$here/q6-source.py" \
        "$k" "$work/modules/sc8280xp.c" "$work/modules/q6-source.inc"
    make -s -j4 -C "$k" M="$work/modules" ARCH=arm64 LLVM=1 modules
    cp "$work/modules/"*.ko "$work/root/modules/"
    (cd "$work/modules"; sha256sum snd-soc-lpass-tx-macro.ko snd-soc-sc8280xp.ko) > "$logs/$variant-module.sha256"
    (cd "$work/root"; find . -print0 | cpio --quiet --null -o -H newc | gzip -1 > "$work/initrd")
    timeout -k 5 90 "${qemu[@]}" "${args[@]}" -machine virt,gic-version=3 -no-reboot \
        -dtb "$work/test.dtb" -kernel "$image" -initrd "$work/initrd" -serial "file:$logs/$variant.log" \
        -append 'console=ttyAMA0,115200 rdinit=/init panic=5 nokaslr' </dev/null
    tr -d '\r' < "$logs/$variant.log" > "$work/serial"
    grep -Fxq TX_STEREO_CARD_REGISTERED "$work/serial"
    grep -F 'TX_STEREO initial=' "$work/serial"
    grep -F 'TX3_PACKET ' "$work/serial"
    if [[ $variant == original ]]; then
        grep -Fq 'TX_STEREO initial=24/3 duplicate=1 unmuted=04 after_mute=00 last_disable=0 final=04/2' "$work/serial"
        grep -Fq 'TX3_PACKET rate=48000 bits=16 channels=2 lpaif=1 index=4 mask=03' "$work/serial"
    else
        grep -Fq 'TX_STEREO initial=24/2 duplicate=0 unmuted=24 after_mute=00 last_disable=1 final=00/0' "$work/serial"
        grep -Fq 'TX_REOPEN single=20/1 unmuted=20 final=00/0' "$work/serial"
        grep -Fq 'TX3_PACKET rate=48000 bits=16 channels=2 lpaif=1 index=4 mask=24' "$work/serial"
        cp "$work/modules/"{snd-soc-lpass-tx-macro,snd-soc-sc8280xp}.ko "$logs/"
    fi
done
echo TX_STEREO_REGRESSION_PASS
