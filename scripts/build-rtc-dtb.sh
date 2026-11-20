#!/bin/bash
# Compile the optional PMK8350 RTC board change from the prepared Asphalt tree.
set -euo pipefail
reserve_rtc1=0
if [[ ${1:-} == --probe-rtc1 ]]; then reserve_rtc1=1; shift; fi
if (( $# != 2 )); then
    echo 'Usage: build-rtc-dtb.sh [--probe-rtc1] PREPARED_KERNEL NEW_DIRECTORY' >&2
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
cat >>"$work/rtc.dts" <<'DTS'

&pmk8350_rtc {
	status = "okay";
};
DTS
cp -- "$work/original.dtb" "$work/expected.dtb"
fdtput -t s "$work/expected.dtb" "$rtc" status okay
if (( reserve_rtc1 )); then
    ! fdtget -p "$work/original.dtb" /aliases | grep -Eq '^rtc[0-9]+$' || exit 1
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
echo "RTC_DTB original_rebuilt=exact semantic_changes=$((reserve_rtc1 + 1)) rtc_status=okay rtc1_alias=$reserve_rtc1 alarm=0:62:1:rising"
