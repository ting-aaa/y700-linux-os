#!/usr/bin/env bash
# Build only the V4L2 flash bridge and its Qualcomm client from the pinned PRC build.
set -euo pipefail
export LC_ALL=C
src=$(realpath -e "${1:?compiled PRC Linux tree}")
out=$(realpath -m "${2:?new output directory}")
jobs=${JOBS:-2}
test "$(id -u)" -eq 0
[[ $jobs =~ ^[1-9][0-9]*$ && $out != "$src" && $out != "$src/"* && ! -e $out && ! -L $out ]]
if [[ ${Y700_FLASH_BUILD_NAMESPACE:-} != 1 ]]; then
    exec unshare --mount --propagation private env Y700_FLASH_BUILD_NAMESPACE=1 bash "$0" "$src" "$out"
fi

unset KCONFIG_CONFIG KBUILD_OUTPUT KBUILD_EXTMOD KBUILD_EXTRA_SYMBOLS KBUILD_MODPOST_WARN KBUILD_MODPOST_NOFINAL
dtb=arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
led_class=drivers/leds/led-class-flash.ko
qcom=drivers/leds/flash/leds-qcom-flash.ko
bridge=drivers/media/v4l2-core/v4l2-flash-led-class.ko

# Pin the retained config, board and symbol inputs used for module-only modpost.
pins=$(cat <<'EOF'
9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db  arch/arm64/boot/Image
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
48a527e19315763690836c776660acf20e94ebd5a0087bd8a023d714b0cf9c83  Module.symvers
bdcb10cbce42c563d2b4f8563779d3be62c8de7dca135470efc21a664d8a0957  vmlinux.o
1c9d4e92269f45944ac546bdcd13b4437576290c6ff370bda421973906f76ea5  drivers/media/v4l2-core/v4l2-flash-led-class.c
770ba6ed706184e3017ebee3c06784569ad7f13a0f20326c6fa7fc56607ef4e0  drivers/leds/flash/leds-qcom-flash.c
EOF
)
check_inputs() { (cd "$src"; sha256sum -c <<<"$pins"); }

mount --bind "$src" "$src"
mount -o remount,bind,ro "$src"
check_inputs
mkdir -m 700 "$out"
scratch=$(mktemp -d /tmp/y700-flash-bridge.XXXXXXXX)
cleanup() {
    cd /
    if mountpoint -q "$scratch/tree"; then umount "$scratch/tree"; fi
    [[ $scratch == /tmp/y700-flash-bridge.* && -d $scratch && ! -L $scratch ]] && rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir "$scratch/upper" "$scratch/work" "$scratch/tree"
mount -t overlay overlay -o "lowerdir=$src,upperdir=$scratch/upper,workdir=$scratch/work" "$scratch/tree"
cd "$scratch/tree"

printf 'Building camera flash modules; see %s/build.log\n' "$out"
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-19 00:00:00 UTC'
kbuild=(make -j"$jobs" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)
scripts/config --module V4L2_FLASH_LED_CLASS
"${kbuild[@]}" olddefconfig >"$out/build.log" 2>&1
grep -qx 'CONFIG_V4L2_FLASH_LED_CLASS=m' .config
# A host with ARM64 libc headers can also update the link probe used by samples/Kconfig.
unchanged_config() {
    sed '/^# CONFIG_V4L2_FLASH_LED_CLASS is not set$/d; /^CONFIG_V4L2_FLASH_LED_CLASS=m$/d; /^CONFIG_CC_CAN_LINK=y$/d' "$1"
}
cmp <(unchanged_config "$src/.config") <(unchanged_config .config)

# Passing the existing LED class target supplies its exports to in-tree single-module modpost.
"${kbuild[@]}" "$led_class" "$qcom" "$bridge" >>"$out/build.log" 2>&1
cmp <(unchanged_config "$src/.config") <(unchanged_config .config)
grep -qx 'CONFIG_V4L2_FLASH_LED_CLASS=m' .config
diff -U0 --label baseline.config --label bridge.config "$src/.config" .config >"$out/config.delta" || [[ $? == 1 ]]
cmp "$src/$dtb" "$dtb"
cmp "$src/arch/arm64/boot/Image" arch/arm64/boot/Image
check_inputs >"$out/baseline-check.log"

vermagic=$(modinfo -F vermagic "$src/$qcom")
symbols() { llvm-nm --format=posix --undefined-only "$1" | awk '{print $1}' | sort -u; }
known_exports() { awk '{print $2}' "$src/Module.symvers" Module.symvers | sort -u; }
for module in "$qcom" "$bridge"; do
    readelf -h "$module" | grep -E '^ *Machine: *AArch64$'
    [[ $(modinfo -F vermagic "$module") == "$vermagic" ]]
    [[ $(modinfo -F intree "$module") == Y ]]
    missing=$(comm -23 <(symbols "$module") <(known_exports))
    [[ -z $missing ]] || { printf 'Missing exports for %s\n%s\n' "$module" "$missing" >&2; exit 1; }
done
[[ $(modinfo -F depends "$bridge") == led-class-flash ]]
[[ $(modinfo -F depends "$qcom" | tr ',' '\n' | sort) == $'led-class-flash\nv4l2-flash-led-class' ]]
for symbol in v4l2_flash_init v4l2_flash_release; do
    grep -Fx "$symbol" < <(symbols "$qcom")
    awk -v symbol="$symbol" -v provider="${bridge%.ko}" \
        '$2 == symbol && $3 == provider { found = 1 } END { exit !found }' Module.symvers
done

install -m 644 "$qcom" "$bridge" "$out/"
awk -v provider="${bridge%.ko}" '$3 == provider' Module.symvers >"$out/bridge-exports.txt"
{
    printf 'CONFIG_V4L2_FLASH_LED_CLASS=m\nArchitecture: AArch64\nVermagic: %s\n' "$vermagic"
    for module in "$qcom" "$bridge"; do
        printf '%s depends on %s\n' "${module##*/}" "$(modinfo -F depends "$module")"
    done
    printf 'All strong undefined symbols resolved against the pinned baseline or rebuilt module exports.\n'
} >"$out/verification.txt"
(cd "$out"; sha256sum leds-qcom-flash.ko v4l2-flash-led-class.ko > SHA256SUMS)
cat "$out/verification.txt" "$out/SHA256SUMS"
