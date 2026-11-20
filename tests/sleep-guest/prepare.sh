#!/usr/bin/env bash
# Build only the virtual machine's PL031 RTC driver beside the QA payload.
set -euo pipefail
seed=$1
work=$2
kernel=$(realpath -e "${KERNEL_BUILD:?Set KERNEL_BUILD to the prepared 7.3.4-asphalt-prc kernel tree}")
[[ $(cat "$kernel/include/config/kernel.release") == 7.3.4-asphalt-prc ]]
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
mkdir "$work/rtc-module"
cp "$kernel/drivers/rtc/rtc-pl031.c" "$work/rtc-module/"
echo 'obj-m := rtc-pl031.o' > "$work/rtc-module/Makefile"
cross=${CROSS_COMPILE:-aarch64-linux-gnu-}
make -s -C "$kernel" ARCH=arm64 LLVM=1 M="$work/rtc-module" modules
"${cross}strip" --strip-debug "$work/rtc-module/rtc-pl031.ko" -o "$seed/rtc-pl031.ko"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -std=c11 -Wall -Wextra -Werror -static \
    "$here/../suspend/awake-clocks.c" -lrt -o "$seed/awake-clocks"
"${cross}strip" "$seed/awake-clocks"
cp "$here/check-sleep.sh" "$seed/"
