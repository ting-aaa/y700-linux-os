#!/bin/bash
# Compile the optional PMK8350 RTC board change from the prepared Asphalt tree.
set -euo pipefail
reserve_rtc1=0
with_lens=false
case ${1:-} in
    --probe-rtc1) reserve_rtc1=1; shift ;;
    --gt9768-rtc1) reserve_rtc1=1; with_lens=true; shift ;;
esac
if (( $# != 2 )); then
    echo 'Usage: build-rtc-dtb.sh [--probe-rtc1|--gt9768-rtc1] PREPARED_KERNEL NEW_DIRECTORY' >&2
    exit 2
fi
kernel=$(realpath -e "$1")
output=$(realpath -m "$2")
[[ ! -e $output && ! -L $output ]]
parent=$(dirname "$output")
work=$(mktemp -d "$parent/.rtc-build.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
board=$kernel/arch/arm64/boot/dts/qcom
dtc=$kernel/scripts/dtc/dtc
includes=$kernel/scripts/dtc/include-prefixes
source=$board/sm8475-lenovo-asphalt.dts
original=1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d
rtc=/soc@0/spmi@c400000/pmic@0/rtc@6100

compile() {
    clang -E -nostdinc -I "$board" -I "$includes" -undef -D__DTS__ -x assembler-with-cpp "$1" >"$work/board.pre"
    "$dtc" -q -I dts -O dtb -b 0 -i "$board" -i "$includes" "$work/board.pre" -o "$2"
}
compile "$source" "$work/original.dtb"
printf '%s  %s\n' "$original" "$work/original.dtb" | sha256sum --strict -c
[[ $(fdtget "$work/original.dtb" "$rtc" status) == disabled ]]

cp -- "$source" "$work/rtc.dts"
base=$work/original.dtb
if $with_lens; then
    project=$(cd "$(dirname "$0")/.." && pwd)
    # Replay the exact camera DTS hunk without patching any prepared kernel files.
    sed -n '/^--- a\/arch\/arm64\/boot\/dts\/qcom\/sm8475-lenovo-asphalt.dts$/,$p' \
        "$project/tests/camera-focus-ldo5.patch" >"$work/camera.patch"
    patch --batch --fuzz=0 "$work/rtc.dts" "$work/camera.patch"
    cat "$project/config/kernel/asphalt-gt9768.dtsi" >>"$work/rtc.dts"
    base=$work/lens.dtb
    compile "$work/rtc.dts" "$base"
    printf '%s  %s\n' a178f9de454d0e8aa5b474c91b4280da3aadc6aad0622c0120661447d836209f "$base" | sha256sum --strict -c
fi
cat >>"$work/rtc.dts" <<'DTS'

&pmk8350_rtc {
	status = "okay";
};
DTS
cp -- "$base" "$work/expected.dtb"
fdtput -t s "$work/expected.dtb" "$rtc" status okay
if (( reserve_rtc1 )); then
    ! fdtget -p "$base" /aliases | grep -Eq '^rtc[0-9]+$' || exit 1
    printf '%s\n' '/ { aliases { rtc1 = &pmk8350_rtc; }; };' >>"$work/rtc.dts"
    fdtput -t s "$work/expected.dtb" /aliases rtc1 "$rtc"
fi
mkdir "$work/delivery"
candidate=$work/delivery/board.dtb
compile "$work/rtc.dts" "$candidate"
for blob in "$work/expected.dtb" "$candidate"; do
    "$dtc" -q -s -I dtb -O dts "$blob" -o "$work/$(basename "$blob").dts"
done
cmp "$work/expected.dtb.dts" "$work/board.dtb.dts"
[[ $(fdtget -t x "$candidate" "$rtc" interrupts) == '0 62 1 1' ]]
(cd "$work/delivery" && sha256sum board.dtb >SHA256SUMS && sha256sum --strict -c SHA256SUMS)
mv -T --no-clobber "$work/delivery" "$output"
[[ ! -e $work/delivery ]]
if $with_lens; then echo 'GT9768_BASE_DTB rebuilt=exact'; fi
echo "RTC_DTB original_rebuilt=exact semantic_changes=$((reserve_rtc1 + 1)) rtc_status=okay rtc1_alias=$reserve_rtc1 alarm=0:62:1:rising"
