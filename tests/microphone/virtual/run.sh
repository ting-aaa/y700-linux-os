#!/usr/bin/env bash
# One private ARM64 guest per topology, each with a new tmpfs upper.
set -euo pipefail
if [[ $# != 5 ]]; then
    echo 'Usage: run.sh PREPARED_KERNEL DEV12.9.ext4 ARM64_BUSYBOX ARM64_UV NEW_LOG_DIR' >&2
    exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
kernel=$(realpath -e "$1")
disk=$(realpath -e "$2")
busybox=$(realpath -e "$3")
uv=$(realpath -e "$4")
out=$(realpath -m "$5")
umask 077
mkdir "$out"
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-mic-virtual.XXXXXXXX")
trap 'rm -r --one-file-system -- "$work"' EXIT
printf '%s  %s\n' e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb "$disk" \
    91d9d719acc33ea5b9d172195dd7be37cb5e74e75342e9ae3646f3852df7779b "$kernel/sound/drivers/pcmtest.c" \
    9afa9b69763b33133f20d137047084343c5e5465cbb1a0bbfa56b01b9d76b4db "$kernel/arch/arm64/boot/Image" > "$out/inputs.sha256"
sha256sum --strict -c "$out/inputs.sha256"
mkdir -p "$work/mod" "$work/init"/{bin,dev,guest,lower,proc,run,sys,test}
cp "$kernel/sound/drivers/pcmtest.c" "$work/mod/"
patch --fuzz=0 -d "$work/mod" -p1 < "$here/pcmtest.patch"
printf 'obj-m := snd-y700-fixture.o\nsnd-y700-fixture-y := pcmtest.o\n' > "$work/mod/Makefile"
make -s -C "$kernel" M="$work/mod" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- modules
cd "$work/init"
chmod 755 test
install -m644 "$work/mod/snd-y700-fixture.ko" test/
# Reuse the two banks of speaker controls; narrow the original driver-ID guard to ours.
sed 's/identity.driver, "Dummy"/identity.driver, "Y700Fixture"/' "$repo/tests/speaker-ucm/controls.c" > "$work/speaker-controls.c"
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -Wall -Wextra -Werror -O2 -static -I"$work" "$here/controls.c" -o test/controls
install -m755 "$busybox" bin/busybox
install -m755 "$uv" test/uv
install -m755 "$here/init" init
install -m644 "$here/guest.sh" "$here/session.py" test/
for profile in Lenovo-Y700.conf HiFi-Mic.conf Mic.conf; do
    install -m644 "$repo/packaging/microphone/$profile" test/
done
sha256sum test/{Lenovo-Y700,HiFi-Mic,Mic}.conf > "$out/candidate.sha256"
find . -print0 | cpio -o --null --quiet -H newc | gzip -1 > "$work/initrd.gz"
args=()
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then args+=(-L "$QEMU_FIRMWARE_DIR"); fi
for mode in ${MIC_CASES:-playback capture}; do
    [[ $mode == playback || $mode == capture ]]
    timeout -k 5 145 "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${args[@]}" -machine virt,gic-version=3 \
        -cpu max -smp 3 -m 768 -nodefaults -no-user-config -display none -nic none -serial stdio -monitor none -no-reboot \
        -kernel "$kernel/arch/arm64/boot/Image" -initrd "$work/initrd.gz" \
        -append "console=ttyAMA0 panic=4 loglevel=3 y700.mic_fixture=$mode" \
        -drive "if=none,id=root,format=raw,readonly=on,file=$disk" -device virtio-blk-device,drive=root \
        </dev/null 2>&1 | tr -d '\r' | tee "$out/$mode.log"
    grep -Fxq "MIC_CASE_PASS $mode" "$out/$mode.log"
    grep -Fxq 'MIC_FIXTURE_EXIT=0' "$out/$mode.log"
done
