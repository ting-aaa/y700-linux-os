#!/usr/bin/env bash
# Build the unified TB320FC full-hardware kernel, DTB, and loadable modules
# (GMU fix + 60/120 Hz + GT9768 AF + PMK8350 RTC + Dual AW86927 Haptics + WCD938x Mic + PM8350C Flash)
# inside a private read-only OverlayFS mount of the pristine prepared Linux 7.3.4 tree.
set -euo pipefail
export LC_ALL=C

wcd_variant=9385
while [[ $# -gt 0 ]]; do
    case $1 in
        --wcd-9380) wcd_variant=9380; shift ;;
        --wcd-9385) wcd_variant=9385; shift ;;
        --inside) break ;;
        *) break ;;
    esac
done

if [[ ${1:-} != --inside ]]; then
    [[ $# == 2 && $EUID == 0 ]] || {
        echo 'Usage as root: build-hw-bringup-kernel.sh [--wcd-9380|--wcd-9385] PREPARED_KERNEL NEW_OUTPUT' >&2
        exit 2
    }
    exec unshare --mount --propagation private bash "$0" "--wcd-$wcd_variant" --inside "$@"
fi
shift

src=$(realpath -e "$1")
out=$(realpath -m "$2")
repo=$(cd "$(dirname "$0")/.." && pwd)
jobs=${JOBS:-6}
[[ $jobs =~ ^[1-9][0-9]*$ && ! -e $out && ! -L $out && $out != "$src" && $out != "$src/"* ]]
base=$(dirname "$out")
[[ -d $base ]]

source "$repo/scripts/build-storage-guard.sh" receiver "$base"

# Verify pristine prepared baseline inputs
(cd "$src" && sha256sum --strict --quiet -c <<'INPUTS'
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  arch/arm64/boot/Image
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
3a545bcb6baf2505384b5cfd2e32464e5b8de04686af51d77a00917bb7d5343d  drivers/gpu/drm/msm/adreno/a6xx_hfi.c
90a7e501f0b57d934487d89d8944dcbfa625fa676b825acf3f34e2300c096cd5  drivers/media/i2c/asphalt-sensors.c
568833b7c4f84ce9409a5c2a73bac6ae193ebfc8f5321b6d795600e09cbef31e  drivers/gpu/drm/panel/panel-novatek-nt36523.c
f1176c6165b2850bc1aad28cd96d4d953f683ef1dd1e38fe61d002daa7e95e92  drivers/input/misc/aw86927.c
4626edf0d6fc948d3ae91160b0497ce3f394d47bcbefc34f607e87559f015fef  sound/soc/qcom/sc8280xp.c
37ad9373051ca515d2b33e3e38c3506f10dac003a71b8c82fcb7f81f2048a58b  sound/soc/codecs/lpass-tx-macro.c
c6d1fe48ee9f9c00e6b311277bf58bab711b84a08add74f4e69563eab0920ee1  sound/soc/codecs/wcd938x.c
0c3b35a67fe57f7e1536919bee79fcd58ad5129b74b568179cc878a917aaf548  sound/soc/codecs/wcd938x-sdw.c
INPUTS
)

umask 022
scratch=$(mktemp -d /var/tmp/y700-hw-bringup.XXXXXXXX)
result=$(mktemp -d "$base/.y700-hw-bringup.XXXXXXXX")
cleanup() {
    cd /
    if [[ -f $result/build.log ]]; then tail -20 "$result/build.log" >&2; fi
    if mountpoint -q "$scratch/tree" && ! umount "$scratch/tree"; then
        sleep 1
        umount "$scratch/tree" || { echo "Retained scratch at $scratch" >&2; return 1; }
    fi
    rm -r --one-file-system -- "$scratch"
    if [[ -d $result ]]; then rm -r --one-file-system -- "$result"; fi
}
trap cleanup EXIT

mkdir "$scratch"/{tree,upper,work}
mount --bind "$src" "$src"
mount -o remount,bind,ro "$src"
mount -t overlay overlay -o "lowerdir=$src,upperdir=$scratch/upper,workdir=$scratch/work" "$scratch/tree"

cd "$scratch/tree"

# 1. Apply all kernel source patches
patches=(
    config/kernel/asphalt-hfi-match-queued-vote.patch
    tests/camera-focus-ldo5.patch
    config/kernel/nt36523n-y700-60hz.patch
    config/kernel/asphalt-aw86927-tb320fc.patch
    config/kernel/asphalt-lpass-tx-stereo.patch
    config/kernel/asphalt-tx3-dma-map.patch
    config/kernel/asphalt-wcd938x-checked-id.patch
    config/kernel/asphalt-wcd938x-tx-clk-rate.patch
    config/kernel/asphalt-wcd938x-stream-channels.patch
)
(cd "$repo" && sha256sum "${patches[@]}") > "$result/patches.sha256"
for p in "${patches[@]}"; do
    patch --batch --no-backup-if-mismatch --fuzz=0 -p1 < "$repo/$p"
done

# 2. Add GT9768 rear AF actuator driver
[[ ! -e drivers/media/i2c/asphalt-gt9768.c ]]
install -m644 "$repo/config/kernel/asphalt-gt9768.c" drivers/media/i2c/
echo 'obj-$(CONFIG_VIDEO_ASPHALT_SENSORS) += asphalt-gt9768.o' >> drivers/media/i2c/Makefile

# 3. Compose unified TB320FC board DTS (preserving all existing peripherals + RTC + AF + Haptics + Mic + Flash)
dts=arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dts
cat "$repo/config/kernel/asphalt-gt9768.dtsi" >> "$dts"
cat >> "$dts" <<'DTS_RTC'

&pmk8350_rtc {
	status = "okay";
};

/ {
	aliases {
		rtc1 = &pmk8350_rtc;
	};
};
DTS_RTC
cat "$repo/config/kernel/asphalt-haptics.dtsi" >> "$dts"
cat "$repo/config/kernel/asphalt-flash-led.dtsi" >> "$dts"
cat "$repo/config/kernel/asphalt-mic.dtsi" >> "$dts"
if [[ $wcd_variant == 9380 ]]; then
    sed -i 's/qcom,wcd9385-codec/qcom,wcd9380-codec/' "$dts"
fi

# 4. Enable loadable modules (keeping built-in vmlinux ABI / vermagic compatible with 770 existing modules)
unset KBUILD_OUTPUT KCONFIG_CONFIG KBUILD_EXTMOD KBUILD_EXTRA_SYMBOLS KBUILD_MODPOST_WARN KBUILD_MODPOST_NOFINAL MODPROBE_OPTIONS
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-22 00:00:00 UTC'
kbuild=(make -j"$jobs" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)

scripts/config \
    -m SOUNDWIRE_QCOM \
    -m SND_SOC_WCD938X_SDW \
    -m SND_SOC_LPASS_VA_MACRO \
    -m SND_SOC_LPASS_RX_MACRO \
    -m SND_SOC_LPASS_TX_MACRO \
    -m V4L2_FLASH_LED_CLASS
"${kbuild[@]}" olddefconfig > "$result/build.log" 2>&1
cp .config "$result/candidate.config"
diff -U0 --label baseline.config --label candidate.config "$src/.config" .config > "$result/config.delta" || [[ $? == 1 ]]

# 5. Build Image + DTB
"${kbuild[@]}" Image qcom/sm8475-lenovo-asphalt.dtb >> "$result/build.log" 2>&1

cmp "$src/include/config/kernel.release" include/config/kernel.release
release=$(cat include/config/kernel.release)
[[ $release == 7.3.4-asphalt-prc ]]

# Verify built-in exported ABI stayed identical to baseline vmlinux!
awk '$3 == "vmlinux"' "$src/Module.symvers" | LC_ALL=C sort > "$scratch/base-vmlinux.symvers"
LC_ALL=C sort vmlinux.symvers > "$scratch/cand-vmlinux.symvers"
cmp "$scratch/base-vmlinux.symvers" "$scratch/cand-vmlinux.symvers"

# 6. Build all new & updated loadable modules with full retained symvers so modpost resolves every symbol
targets=(
    drivers/input/misc/aw86927.ko
    drivers/base/regmap/regmap-sdw.ko
    drivers/soundwire/soundwire-qcom.ko
    sound/soc/codecs/snd-soc-wcd-common.ko
    sound/soc/codecs/snd-soc-wcd-mbhc.ko
    sound/soc/codecs/snd-soc-wcd-classh.ko
    sound/soc/codecs/snd-soc-wcd938x.ko
    sound/soc/codecs/snd-soc-wcd938x-sdw.ko
    sound/soc/codecs/snd-soc-lpass-macro-common.ko
    sound/soc/codecs/snd-soc-lpass-va-macro.ko
    sound/soc/codecs/snd-soc-lpass-rx-macro.ko
    sound/soc/codecs/snd-soc-lpass-tx-macro.ko
    sound/soc/qcom/snd-soc-sc8280xp.ko
    drivers/media/v4l2-core/v4l2-flash-led-class.ko
    drivers/leds/flash/leds-qcom-flash.ko
)

printf '%s\n' "${targets[@]%.ko}" > "$scratch/rebuilt"
awk 'NR==FNR { rebuilt[$1]=1; next } $3!="vmlinux" && !($3 in rebuilt)' "$scratch/rebuilt" "$src/Module.symvers" > "$scratch/retained.symvers"
cat > "$scratch/modpost" <<'POST'
#!/bin/sh
exec scripts/mod/modpost -i "$(dirname "$0")/retained.symvers" "$@"
POST
chmod 755 "$scratch/modpost"
"${kbuild[@]}" "MODPOST=$scratch/modpost" "${targets[@]}" >> "$result/build.log" 2>&1

# 7. Verify Image mode table (60/120 Hz), DTB structure, and module metadata
dtb=arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
python3 "$repo/tests/panel-refresh/check-kernel.py" "$src/vmlinux" vmlinux arch/arm64/boot/Image > "$result/panel-check.log"
python3 "$repo/tests/board-device-tree.py" --dtb "$dtb" > "$result/dtb-check.log"

# Verify key new DT nodes are present & enabled
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a8c000 status) == okay ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a8c000/vibrator@5a compatible) == awinic,aw86927 ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a8c000/vibrator@5a label) == y700-haptic-left ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a8c000/vibrator@5a awinic,f0-hz) == 170 ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a98000 status) == okay ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a98000/vibrator@5a compatible) == awinic,aw86927 ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a98000/vibrator@5a label) == y700-haptic-right ]]
[[ $(fdtget "$dtb" /soc@0/geniqup@ac0000/i2c@a98000/vibrator@5a awinic,f0-hz) == 170 ]]
[[ $(fdtget "$dtb" /soc@0/spmi@c400000/pmic@2/led-controller@ee00 status) == okay ]]
[[ $(fdtget "$dtb" /soc@0/spmi@c400000/pmic@0/rtc@6100 status) == okay ]]
[[ $(fdtget "$dtb" /audio-codec compatible) == "qcom,wcd${wcd_variant}-codec" ]]
[[ $(fdtget "$dtb" /audio-codec pinctrl-names) == default ]]
[[ $(fdtget "$dtb" /soc@0/cci@ac15000/i2c-bus@0/lens@c compatible) == lenovo,tb320fc-gt9768 ]]

# Check vermagic and AArch64 ELF across all 15 modules
expected_vermagic="7.3.4-asphalt-prc SMP preempt mod_unload aarch64"
mkdir -p "$result/modules"
for target in "${targets[@]}"; do
    vm=$(modinfo -F vermagic "$target")
    [[ $vm == "$expected_vermagic" ]] || { echo "Bad vermagic on $target: $vm" >&2; exit 1; }
    llvm-readelf -h "$target" | grep -q 'Machine:.*AArch64'
    install -Dm644 "$target" "$result/modules/$target"
done

cp arch/arm64/boot/Image "$result/kernel.efi"
cp "$dtb" "$result/board.dtb"
llvm-objcopy --dump-section ".notes=$result/notes" --only-section=.notes vmlinux "$scratch/notes.elf"

# Also save a diskless DTB copy (UFS + SD disabled) for zero-storage-risk RAM probes
cp "$dtb" "$result/board-diskless.dtb"
fdtput -t s "$result/board-diskless.dtb" /soc@0/ufshc@1d84000 status disabled
fdtput -t s "$result/board-diskless.dtb" /soc@0/mmc@8804000 status disabled

(
    cd "$result"
    sha256sum kernel.efi board.dtb board-diskless.dtb notes $(find modules -name '*.ko' -type f | sort) > SHA256SUMS
    sha256sum --strict -c SHA256SUMS > /dev/null
)

printf 'HW_BRINGUP_BUILD_PASS release=%s wcd_variant=%s modules=%d vmlinux_abi_preserved=1\n' \
    "$release" "$wcd_variant" "${#targets[@]}" | tee "$result/verification.txt"

rm -f "$result/build.log"
mv -nT -- "$result" "$out"
[[ ! -e $result ]]
cat "$out/SHA256SUMS"
