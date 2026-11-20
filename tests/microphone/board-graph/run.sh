#!/bin/bash
# Compile and examine the two possible graphs on a Linux PC. Keep no boot images.
set -euo pipefail
if (( $# != 4 )); then
    echo 'Usage: run.sh KERNEL_TREE CN350_MERGED.dtb CN350_RUNNING.dtb CN350_SKU_CAPE_DIRECTORY' >&2
    exit 2
fi
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd -P)
kernel=$(realpath -e "$1")
board=$kernel/arch/arm64/boot/dts/qcom
includes=$kernel/scripts/dtc/include-prefixes
dtc=$kernel/scripts/dtc/dtc
mixer=$4/mixer_paths_waipio_mtp.xml
manager=$4/resourcemanager_waipio_mtp.xml
work=$(mktemp -d)
trap 'rm -r --one-file-system -- "$work"' EXIT
py=("${UV_BIN:-uv}" run --offline --no-project --python "${UV_PYTHON:-/usr/bin/python3}" python)
printf '%s  %s\n' \
    7359763f57ceea931c6881581fa13c35198f0cb905116e00fdd20ec00cd181d5 "$2" \
    bda4b80b9cb73e1b001cf22666890ad0139f0246e08a86d432a190d8e06ba4c6 "$3" \
    76b637235cddeda4e6b6551b0e251772bd8563e823bf897e1d076b66f40ce0c9 "$mixer" \
    18b8646e5447673d2823025c1633eab09580c452543a2256bff5811520853b5e "$manager" | sha256sum --strict -c -
cpp=(clang -E -nostdinc -I "$board" -I "$includes" -I "$here" -undef -D__DTS__ -x assembler-with-cpp)
compile() {
    local target=$1 source=$2
    shift 2
    "${cpp[@]}" "$@" "$source" > "$work/board.pre"
    "$dtc" -q -I dts -O dtb -b 0 -i "$board" -i "$includes" -o "$target" "$work/board.pre"
}
compile "$work/original.dtb" "$board/sm8475-lenovo-asphalt.dts"
echo "1fcd5dedc5cec0b03e6f666421aaec317d0db2203bf3371a408078ba427deb7d  $work/original.dtb" | sha256sum --strict -c -
"${py[@]}" "$here/../check-wiring.py" "$2" "$3" "$work/original.dtb" "$mixer"
printf '%s\n' '#include "sm8475-lenovo-asphalt.dts"' '#include "asphalt-mic.dtsi"' > "$work/trial.dts"
for variant in 9380 9385; do
    compile "$work/$variant.dtb" "$work/trial.dts" -DY700_VERIFY_MIC_GRAPH -DY700_TEST_"$variant"
    "${py[@]}" "$here/../../board-device-tree.py" --dtb "$work/$variant.dtb"
done
if "${cpp[@]}" -DY700_VERIFY_MIC_GRAPH "$work/trial.dts" > /dev/null 2>"$work/no-variant"; then exit 1; fi
grep -Fq 'Select one WCD hypothesis' "$work/no-variant"
if "${cpp[@]}" -DY700_VERIFY_MIC_GRAPH -DY700_TEST_9380 -DY700_TEST_9385 "$work/trial.dts" > /dev/null 2>"$work/both"; then exit 1; fi
grep -Fq 'Select one WCD hypothesis' "$work/both"
"${py[@]}" "$here/verify.py" "$work/original.dtb" "$work/9380.dtb" "$work/9385.dtb" "$2" "$3" "$manager"
