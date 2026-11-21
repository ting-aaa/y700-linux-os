#!/usr/bin/env bash
# Reproduce the dev12.13 PRC kernel from its prepared tree, then port the sealed UFS changes in RAM/COW.
set -euo pipefail
export LC_ALL=C
[[ $# == 4 && $EUID == 0 ]] || { echo 'Usage as root: build-candidate.sh PREPARED_KERNEL COMMUNITY_INPUTS DEV12.13_ESP NEW_OUTPUT' >&2; exit 2; }
src=$(realpath -e "$1"); input=$(realpath -e "$2"); esp=$(realpath -e "$3"); out=$(realpath -m "$4")
[[ ! -e $out && ! -L $out && $out != "$src" && $out != "$src/"* ]]
if [[ $(readlink /proc/self/ns/mnt) == "$(readlink /proc/1/ns/mnt)" || $(findmnt -nro PROPAGATION -T /) != private ]]; then
    exec unshare --mount --propagation private bash "$0" "$@"
fi
project=$(cd "$(dirname "$0")/../.." && pwd)
uv=${UV_BIN:-uv}
for cmd in "$uv" clang llvm-readelf llvm-objcopy fdtget mtype dt-validate yamllint; do command -v "$cmd" >/dev/null; done
(cd "$input"; sha256sum --strict -c "$project/tests/ufs-scaling/inputs.sha256")
echo "cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d  $esp" | sha256sum -c -
pins='4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1  arch/arm64/boot/Image
1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
a20e5eb808bce84a3f5beaea7f02a2182a5d21c6a8e937787b886963aea5aa56  .config
da21f7dd5826d906a7165d33ed1fb2d2027ebb9f1be54ad844823e92bd7c8066  vmlinux.symvers
bda8d5663b736a6d6b07331a213c20423e3f153130d5f092e2b17c7d4bb8cc34  arch/arm64/boot/dts/qcom/sm8475.dtsi
16e5fc4642a44e7bb506f535a6d6d2c2c10a17575bf88dc2d3eeba7c8f6cb4ee  drivers/ufs/core/ufshcd.c'
(cd "$src"; sha256sum --strict -c <<<"$pins")
scratch=$(mktemp -d /var/tmp/y700-ufs-build.XXXXXXXX)
delivery=$(mktemp -d "$(dirname "$out")/.y700-ufs-output.XXXXXXXX")
cleanup() {
    cd /
    if mountpoint -q "$scratch/tree"; then umount "$scratch/tree" || return; fi
    rm -r --one-file-system -- "$scratch"
    if [[ -d $delivery ]]; then rm -r --one-file-system -- "$delivery"; fi
}
trap cleanup EXIT
mkdir "$scratch"/{upper,work,tree}
mount -t overlay overlay -o "lowerdir=$src,upperdir=$scratch/upper,workdir=$scratch/work" "$scratch/tree"
cd "$scratch/tree"
dtb=arch/arm64/boot/dts/qcom/sm8475-lenovo-asphalt.dtb
mtype -i "$esp" ::/loader/entries/debian.conf | grep -Fx 'devicetree /EFI/debian/board.dtb'
mtype -i "$esp" ::/EFI/debian/board.dtb > "$scratch/release.dtb"
echo "53bc719146da49baff7b975c06942892278639909e48d0f998b894220c7d05b7  $scratch/release.dtb" | sha256sum -c -
if "$uv" run --offline --no-project --python /usr/bin/python3 python -B "$input/asphalt-ufs.py" "$scratch/release.dtb" >"$delivery/baseline-check.log" 2>&1; then
    echo 'Expected baseline to fail the new contract' >&2; exit 1
fi
grep -q '"clock-names"' "$delivery/baseline-check.log"
for prior in "$input"/003[2345]-*.patch; do
    patch --reverse --forward --dry-run --batch --fuzz=0 -p1 < "$prior"
done

# These are the existing PRC release source changes. Match the complete Image and DTB before porting UFS.
patch --batch --fuzz=0 -p1 < "$project/tests/camera-focus-ldo5.patch"
install -m644 "$project/config/kernel/asphalt-gt9768.c" drivers/media/i2c/
echo 'obj-$(CONFIG_VIDEO_ASPHALT_SENSORS) += asphalt-gt9768.o' >> drivers/media/i2c/Makefile
cat "$project/config/kernel/asphalt-gt9768.dtsi" >> "${dtb%.dtb}.dts"
cat >> "${dtb%.dtb}.dts" <<'RTC'
&pmk8350_rtc { status = "okay"; };
/ { aliases { rtc1 = &pmk8350_rtc; }; };
RTC
patch --batch --fuzz=0 -p1 < "$project/config/kernel/nt36523n-y700-60hz.patch"
export KBUILD_BUILD_USER=y700 KBUILD_BUILD_HOST=builder KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP='2026-11-18 00:00:00 UTC'
build=(make -j"${JOBS:-4}" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-)
target=qcom/sm8475-lenovo-asphalt.dtb
"${build[@]}" Image "$target"
echo '0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60  arch/arm64/boot/Image' | sha256sum -c -
cmp "$dtb" "$scratch/release.dtb"

patch --batch --fuzz=0 -p1 < "$input/0036-sm8475-ufs-ice-mx-opps.patch"
patch --batch --fuzz=0 -p1 < "$input/ufs-opp-init-order.patch"
objs=(drivers/ufs/core/ufshcd.o drivers/ufs/host/ufs-qcom.o drivers/clk/qcom/gcc-sm8450.o drivers/clk/qcom/gdsc.o drivers/soc/qcom/ice.o)
# Remove only these build outputs within our private overlay to require actual compilation.
rm -f -- "${objs[@]}"
"${build[@]}" "${objs[@]}"
for obj in "${objs[@]}"; do
    llvm-readelf -h "$obj" | grep -E 'Machine:.*AArch64' >/dev/null
done
sha256sum "${objs[@]}" > "$delivery/objects.sha256"
"${build[@]}" Image "$target"
cmp .config "$src/.config"; cmp include/config/kernel.release "$src/include/config/kernel.release"
cmp <(sort vmlinux.symvers) <(sort "$src/vmlinux.symvers")
"$uv" run --offline --no-project --python /usr/bin/python3 python -B "$input/asphalt-ufs.py" "$dtb"
bash "$project/tests/ufs-scaling/check-board.sh" "$scratch/release.dtb" "$dtb"
schemas='clock/qcom,gcc-sm8450.yaml:ufs/qcom,sc7180-ufshc.yaml:crypto/qcom,inline-crypto-engine.yaml'
"${build[@]}" dt_binding_check DT_SCHEMA_FILES="$schemas" > "$delivery/bindings.log" 2>&1 || { tail -24 "$delivery/bindings.log" >&2; exit 1; }
"${build[@]}" CHECK_DTBS=y DT_SCHEMA_FILES="$schemas" "$target"
dt-validate -p Documentation/devicetree/bindings/processed-schema.json -l "$schemas" "$dtb" > "$delivery/board-schema.log" 2>&1
[[ ! -s $delivery/board-schema.log ]] || { cat "$delivery/board-schema.log" >&2; exit 1; }
# Verify that the selected schema really inspects the candidate's GCC instance.
cp "$dtb" "$scratch/wrong-gcc.dtb"
gcc=/soc@0/clock-controller@100000
read -ra parents < <(fdtget -tx "$dtb" "$gcc" power-domains)
fdtput -tx "$scratch/wrong-gcc.dtb" "$gcc" power-domains "${parents[@]:0:2}"
dt-validate -p Documentation/devicetree/bindings/processed-schema.json -l "$schemas" "$scratch/wrong-gcc.dtb" > "$delivery/schema-negative.log" 2>&1
grep -F 'power-domains' "$delivery/schema-negative.log"
cp arch/arm64/boot/Image "$delivery/kernel.efi"
cp "$dtb" "$delivery/board.dtb"
llvm-objcopy --dump-section ".notes=$delivery/notes" --only-section=.notes vmlinux "$scratch/notes.elf"
(cd "$delivery"; sha256sum kernel.efi board.dtb notes > SHA256SUMS; sha256sum --strict -c SHA256SUMS)
(cd "$src"; sha256sum --strict -c <<<"$pins")
mv -T --no-clobber "$delivery" "$out"
[[ ! -e $delivery ]]
