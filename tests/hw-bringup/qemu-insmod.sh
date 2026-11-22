#!/usr/bin/env bash
# Actually insmod and rmmod ALL 15 newly built modules (+ deps) on the running ARM64 QEMU kernel!
set -euo pipefail
export LC_ALL=C
[[ $# == 1 ]] || { echo 'Usage: qemu-insmod.sh HW_BUILD_DIR' >&2; exit 2; }
hw_build=$(realpath -e "$1")
q=${Y700_QEMU_PREFIX:-/usr}
if [[ -d "$q/lib/x86_64-linux-gnu" ]]; then
    export LD_LIBRARY_PATH="$q/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QEMU_MODULE_DIR="$q/lib/x86_64-linux-gnu/qemu"
fi
busybox_bin=${Y700_BUSYBOX:-/bin/busybox}
base_mods=${Y700_BASE_MODULES:-/lib/modules/7.3.4-asphalt-prc}

work=$(mktemp -d /var/tmp/y700-hw-insmod.XXXXXXXX)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/init"/{bin,dev,proc,sys,mods}
cp "$busybox_bin" "$work/init/bin/busybox"

# Copy base deps by filename search + our 15 newly built .ko modules
for name in \
    ff-memless.ko led-class-flash.ko soundwire-bus.ko \
    mc.ko videodev.ko v4l2-async.ko v4l2-fwnode.ko \
    snd-soc-core.ko snd-pcm.ko snd-compress.ko snd-timer.ko snd.ko \
    snd-soc-qcom-common.ko snd-soc-qcom-sdw.ko snd-soc-sc8280xp.ko \
    q6apm.ko q6apm-dai.ko q6apm-lpass-dais.ko q6prm.ko q6prm-clocks.ko \
    audioreach.ko snd-q6dsp-common.ko apr.ko qcom_glink.ko qcom_glink_smem.ko pdr_interface.ko qmi_helpers.ko
do
    found=$(find "$base_mods" -name "$name" -o -name "$name.zst" 2>/dev/null | head -n 1 || true)
    if [[ -n $found ]]; then
        if [[ $found == *.zst ]]; then
            zstd -qd "$found" -o "$work/init/mods/$name"
        else
            cp "$found" "$work/init/mods/$name"
        fi
    fi
done

while IFS= read -r -d '' ko; do
    cp "$ko" "$work/init/mods/$(basename "$ko")"
done < <(find "$hw_build/modules" -name '*.ko' -type f -print0)

cat > "$work/init/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "INSMOD_TEST_START"
load() {
    if [ -f "/mods/$1.ko" ]; then
        insmod "/mods/$1.ko" || { echo "INSMOD_FAIL=$1"; poweroff -f; exit 1; }
        echo "INSMOD_OK=$1"
    fi
}
# 1. Haptics
load ff-memless
load aw86927
# 2. Flash LED bridge
load mc
load videodev
load v4l2-async
load v4l2-fwnode
load led-class-flash
load v4l2-flash-led-class
load leds-qcom-flash
# 3. Microphone SoundWire + WCD938x + LPASS Macros + Board Machine Driver
load snd
load snd-timer
load snd-pcm
load snd-compress
load snd-soc-core
load soundwire-bus
load regmap-sdw
load soundwire-qcom
load snd-soc-wcd-common
load snd-soc-wcd-mbhc
load snd-soc-wcd-classh
load snd-soc-wcd938x-sdw
load snd-soc-wcd938x
load snd-soc-lpass-macro-common
load snd-soc-lpass-va-macro
load snd-soc-lpass-rx-macro
load snd-soc-lpass-tx-macro
load snd-soc-qcom-common
load snd-soc-qcom-sdw
load snd-soc-sc8280xp
echo "TAINT_AFTER_LOAD=$(cat /proc/sys/kernel/tainted)"
# Unload our new modules cleanly
for m in snd_soc_sc8280xp snd_soc_lpass_tx_macro snd_soc_lpass_rx_macro snd_soc_lpass_va_macro snd_soc_lpass_macro_common \
         snd_soc_wcd938x snd_soc_wcd938x_sdw snd_soc_wcd_classh snd_soc_wcd_mbhc snd_soc_wcd_common \
         soundwire_qcom regmap_sdw leds_qcom_flash v4l2_flash_led_class aw86927; do
    rmmod "$m" || { echo "RMMOD_FAIL=$m"; poweroff -f; exit 1; }
done
echo "TAINT_AFTER_UNLOAD=$(cat /proc/sys/kernel/tainted)"
echo "INSMOD_ALL_PASS=1"
poweroff -f
INIT
chmod 755 "$work/init/init"
(cd "$work/init" && find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$work/initrd.gz")

timeout -k 5 60 "$q/bin/qemu-system-aarch64" -L "$q/share/qemu" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 512 -nodefaults -no-user-config \
    -display none -monitor none -nic none -serial "file:$work/serial.log" -no-reboot \
    -kernel "$hw_build/kernel.efi" -initrd "$work/initrd.gz" \
    -append 'console=ttyAMA0 rdinit=/init loglevel=4 panic=4' </dev/null

tr -d '\r' < "$work/serial.log" | grep -E '^(INSMOD_|RMMOD_|TAINT_)' || { cat "$work/serial.log"; exit 1; }
grep -Fq 'TAINT_AFTER_LOAD=0' "$work/serial.log"
grep -Fq 'TAINT_AFTER_UNLOAD=0' "$work/serial.log"
grep -Fq 'INSMOD_ALL_PASS=1' "$work/serial.log"
