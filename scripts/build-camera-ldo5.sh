#!/usr/bin/env bash
# Build the optional CN350 slot-0 sensor supply change against the installed kernel.
set -euo pipefail
export LC_ALL=C
args=("$@")
lens=false
if [[ ${1:-} == --lens ]]; then lens=true; shift; fi
[[ $# == 2 && $EUID == 0 ]] || { echo 'Usage as root: build-camera-ldo5.sh [--lens] PREPARED_KERNEL NEW_OUTPUT' >&2; exit 2; }
src=$(realpath -e "$1")
out=$(realpath -m "$2")
project=$(cd "$(dirname "$0")/.." && pwd)
[[ ! -e $out && ! -L $out && $out != "$src" && $out != "$src/"* ]]
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private bash "$0" "${args[@]}"
fi
dtb=arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
pins='4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1  arch/arm64/boot/Image
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
da21f7dd5826d906a7165d33ed1fb2d2027ebb9f1be54ad844823e92bd7c8066  vmlinux.symvers
90a7e501f0b57d934487d89d8944dcbfa625fa676b825acf3f34e2300c096cd5  drivers/media/i2c/asphalt-sensors.c
40f48c21a90bb04b40d045d5d89f28e81e935a8876f6a29734f3b205463e2139  arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dts'
(cd "$src"; sha256sum --strict --check <<<"$pins")
scratch=$(mktemp -d /var/tmp/y700-sensor-ldo5.XXXXXXXX)
delivery=
cleanup() {
    cd /
    if mountpoint -q "$scratch/tree"; then umount "$scratch/tree" || return 1; fi
    rm -rf -- "$scratch"
    if [[ -n $delivery && -d $delivery ]]; then rm -r -- "$delivery"; fi
}
trap cleanup EXIT
mkdir "$scratch"/{upper,work,tree}
mount -t overlay overlay -o "lowerdir=$src,upperdir=$scratch/upper,workdir=$scratch/work" "$scratch/tree"
cd "$scratch/tree"
patch --batch --fuzz=0 -p1 <"$project/tests/camera-focus-ldo5.patch"
if $lens; then
    [[ ! -e drivers/media/i2c/asphalt-gt9768.c ]]
    install -m644 "$project/config/kernel/asphalt-gt9768.c" drivers/media/i2c/
    echo 'obj-$(CONFIG_VIDEO_ASPHALT_SENSORS) += asphalt-gt9768.o' >> drivers/media/i2c/Makefile
    cat "$project/config/kernel/asphalt-gt9768.dtsi" >> "${dtb%.dtb}.dts"
fi
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='2026-11-18 00:00:00 UTC'
make -j"${JOBS:-4}" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- Image qcom/sm8475-lenovo-asphalt.dtb
cmp .config "$src/.config"
cmp include/config/kernel.release "$src/include/config/kernel.release"
cmp <(sort vmlinux.symvers) <(sort "$src/vmlinux.symvers")
! cmp -s arch/arm64/boot/Image "$src/arch/arm64/boot/Image" || exit 1

# dtc allocates a phandle when this previously unreferenced rail gains its first
# consumer. Compile the original source with one independent path-based amendment.
base=/soc@0/cci@ac15000/i2c-bus@0/camera@20
rail=/soc@0/cci@ac16000/i2c-bus@0/regulator@29/regulators/ldo5
board=$(dirname "$src/$dtb")
incs=$src/scripts/dtc/include-prefixes
independent_dtb() {
    clang -E -nostdinc -I "$board" -I "$incs" -undef -D__DTS__ -x assembler-with-cpp "$1" |
        "$src/scripts/dtc/dtc" -q -I dts -O dtb -b 0 -i "$board" -i "$incs" -o "$2" -
}
cp "$board/sm8475-lenovo-asphalt.dts" "$scratch/reference.dts"
independent_dtb "$scratch/reference.dts" "$scratch/reference.dtb"
cmp "$scratch/reference.dtb" "$src/$dtb"
printf '\n&{%s} { aux-supply = <&{%s}>; };\n' "$base" "$rail" >>"$scratch/reference.dts"
if $lens; then
    cat >>"$scratch/reference.dts" <<'DTS'
&cci0_i2c0 {
    expected_actuator: lens@c {
        compatible = "lenovo,tb320fc-gt9768";
        reg = <12>;
        vaf-supply = <&vreg_bob>;
    };
};
&{/soc@0/cci@ac15000/i2c-bus@0/camera@20} { lens-focus = <&expected_actuator>; };
DTS
fi
independent_dtb "$scratch/reference.dts" "$scratch/expected.dtb"
dtc -q -s -I dtb -O dts "$scratch/expected.dtb" >"$scratch/expected.dts"
dtc -q -s -I dtb -O dts "$dtb" | cmp - "$scratch/expected.dts"
[[ $(fdtget -tx "$dtb" "$base" aux-supply) == "$(fdtget -tx "$dtb" "$rail" phandle)" ]]
(cd "$src"; sha256sum --strict --check <<<"$pins")

delivery=$(mktemp -d "$(dirname "$out")/.camera-ldo5.XXXXXXXX")
cp arch/arm64/boot/Image "$delivery/kernel.efi"
cp "$dtb" "$delivery/board.dtb"
llvm-objcopy --dump-section ".notes=$delivery/notes" --only-section=.notes vmlinux "$scratch/notes.elf"
(cd "$delivery"; sha256sum kernel.efi board.dtb notes >SHA256SUMS; sha256sum --strict -c SHA256SUMS)
mv --no-clobber -T "$delivery" "$out"
[[ ! -e $delivery ]]
