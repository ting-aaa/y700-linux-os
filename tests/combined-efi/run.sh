#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 7 ]]; then
    echo 'Usage: run.sh ROOT_EXT4 ROOT_SHA256 ESP_FAT ESP_SHA256 VIRT_UBOOT VIRT_DTB NEW_LOG_DIR' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(realpath -e "$1")
esp=$(realpath -e "$3")
bios=$(realpath -e "$5")
dtb=$(realpath -e "$6")
out=$(realpath -m "$7")
[[ $2 =~ ^[0-9a-f]{64}$ && $4 =~ ^[0-9a-f]{64}$ ]]
regdb=${VERIFY_REGDB:-1}
[[ $regdb == 0 || $regdb == 1 ]]
cold=${COLD_BOOT:-0}
[[ $cold == 0 || $cold == 1 ]]
screen_lock=${SCREEN_LOCK:-off}
case "$screen_lock" in off|baseline|candidate|installed) ;; *) echo 'Invalid SCREEN_LOCK mode' >&2; exit 2 ;; esac
[[ $screen_lock == off || $screen_lock == installed || $cold == 0 ]]
if [[ $screen_lock == candidate || $screen_lock == installed ]]; then
    guest_uv=$(realpath -e "${UV_ARM64:?Provide the ARM64 uv binary for the GTK witness}")
fi
if [[ $screen_lock == candidate ]]; then
    lock_archives=$(realpath -e "${SCREEN_LOCK_ARCHIVES:?Provide the locked session-lock archive directory}")
    "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python "$here/../../scripts/repair-inputs.py" \
        verify "$lock_archives" "$here/../../config/touch-lock.lock.json"
fi
regdom=
if (( regdb )); then regdom=' cfg80211.ieee80211_regdom=CN'; fi
[[ $(stat -Lc %s "$root") == 6442450944 && $(stat -Lc %s "$esp") == 1073741824 ]]
umask 077
mkdir -- "$out"
work=$(mktemp -d /var/tmp/y700-combined-efi.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/var/tmp/y700-combined-efi\.[a-zA-Z0-9]{8}$ ]]
echo "COMBINED_EVIDENCE=$out"
echo "COMBINED_WORK=$work"
export_pid= fuse_pid=
cleanup() {
    if mountpoint -q "$work/view"; then fusermount3 -u "$work/view"; fi
    if [[ -n $fuse_pid ]]; then kill "$fuse_pid" 2>/dev/null || :; wait "$fuse_pid" 2>/dev/null || :; fi
    if [[ -n $export_pid ]]; then kill "$export_pid" 2>/dev/null || :; wait "$export_pid" 2>/dev/null || :; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
manifest=$out/input.sha256
printf '%s  %s\n' "$2" "$root" "$4" "$esp" \
    ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f "$bios" \
    a89bc8f2ee12f118656c6963fb9d45b862e6d5a1aeedf2630ddbe08f03079d31 "$dtb" > "$manifest"
sha256sum --strict -c "$manifest" | tee "$out/before.log"
cd "$work"
mkdir view
cp --sparse=always -- "$esp" test-esp.fat
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$here/touch.c" -o combined-touch
cat > observer.service <<'UNIT'
[Unit]
Description=Observe combined Y700 first login in QEMU
RequiresMountsFor=/boot
After=systemd-udev-trigger.service
Before=y700-firstboot.service
ConditionKernelCommandLine=y700.combined_efi=1
FailureAction=poweroff

[Service]
Type=oneshot
ExecStart=/bin/bash /boot/combined-observe.sh setup
TimeoutStartSec=170
UNIT
mcopy -i test-esp.fat ::/loader/entries/debian.conf entry
grep -Eq '^options .* drm_kms_helper\.fbdev_emulation=0( |$)' entry
unit=$(base64 -w0 observer.service)
sed -i "/^options /s|$| console=ttyAMA0 y700.combined_efi=1 y700.combined_regdb=$regdb$regdom systemd.wants=combined-observer.service systemd.set_credential_binary=systemd.extra-unit.combined-observer.service:$unit|" entry
mcopy -o -i test-esp.fat entry ::/loader/entries/debian.conf
mcopy -o -i test-esp.fat "$dtb" ::/EFI/debian/board.dtb
mcopy -i test-esp.fat "$here/observe.sh" ::/combined-observe.sh
mcopy -i test-esp.fat combined-touch ::/combined-touch
if [[ $screen_lock != off ]]; then
    printf '%s\n' "$screen_lock" > lock-mode
    mcopy -i test-esp.fat lock-mode "$here/../screen-lock/observe-lock.sh" ::/
    if [[ $screen_lock == candidate ]]; then
        mmd -i test-esp.fat ::/lock-archives
        mcopy -i test-esp.fat "$lock_archives"/*.deb ::/lock-archives/
    fi
    if [[ $screen_lock == candidate || $screen_lock == installed ]]; then
        mcopy -i test-esp.fat "$here/../screen-lock/witness.py" ::/lock-witness.py
        mcopy -i test-esp.fat "$guest_uv" ::/lock-test-uv
    fi
fi
for payload in /EFI/debian/initrd /EFI/debian/kernel.efi /EFI/BOOT/BOOTAA64.EFI; do
    original=$(mtype -i "$esp" "::$payload" | sha256sum)
    [[ $(mtype -i test-esp.fat "::$payload" | sha256sum) == "$original" ]]
    printf '%s  %s\n' "${original%% *}" "$payload"
done | tee "$out/efi-payload.sha256"
if (( regdb )); then
    iw=$(realpath -e "${IW_ARM64:?Debian ARM64 iw 6.9-1+b1 binary}")
    printf '%s  %s\n' d80e475972e85fae1264fcfcc60aa46ad84779162a1359effe8929586b46ed6b "$iw" | sha256sum --strict -c -
    mcopy -i test-esp.fat "$iw" ::/combined-iw
    mkdir initrd-pair
    mcopy -i test-esp.fat ::/EFI/debian/initrd initrd.gz
    (
        cd initrd-pair
        gzip -dc ../initrd.gz | cpio --quiet --no-absolute-filenames -id \
            'lib/firmware/regulatory.db' './lib/firmware/regulatory.db' \
            'lib/firmware/regulatory.db.p7s' './lib/firmware/regulatory.db.p7s'
        sha256sum --strict -c <<'CHECKSUMS'
2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b  lib/firmware/regulatory.db
c941c08f51c93e46722293b85631604c3740d86c3de0c75f79aef50d2e919179  lib/firmware/regulatory.db.p7s
CHECKSUMS
    ) | tee "$out/initrd-regdb.log"
fi

# Export the GPT header, private ESP, sealed root and GPT trailer as one read-
# only disk. QEMU uses its disposable overlay for all guest writes.
truncate -s 7171M layout.gpt
printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=1572864, type=linux, name=linux\n' |
    sfdisk --sector-size 4096 layout.gpt > "$out/layout.log"
dd if=layout.gpt of=head.bin bs=1M count=1 conv=sparse status=none
dd if=layout.gpt of=tail.bin bs=1M skip=7169 conv=sparse status=none
"${NBDKIT:-nbdkit}" -f -r -U "$work/gpt.sock" "${NBDKIT_SPLIT:-split}" \
    "$work/head.bin" "$work/test-esp.fat" "$root" "$work/tail.bin" > "$out/nbdkit.log" 2>&1 &
export_pid=$!
for _ in {1..120}; do [[ ! -S gpt.sock ]] || break; sleep .05; done
test -S gpt.sock
"${NBDFUSE:-nbdfuse}" -r "$work/view/disk.gpt" --unix "$work/gpt.sock" > "$out/nbdfuse.log" 2>&1 &
fuse_pid=$!
for _ in {1..120}; do [[ ! -f view/disk.gpt ]] || break; sleep .05; done
[[ $(stat -Lc %s view/disk.gpt) == "$(stat -Lc %s layout.gpt)" ]]

qemu_data=()
if [[ -n ${QEMU_DATA:-} ]]; then qemu_data=(-L "$QEMU_DATA"); fi
disk=-
budget=1500
if (( cold )); then
    disk=$work/session.qcow2
    budget=2480
    "${QEMU_IMG:-qemu-img}" create -q -f qcow2 -F raw -b "$work/view/disk.gpt" "$disk"
fi
timeout -k 25 "$budget" "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 \
    python -B "$here/qemu.py" "$work" "$out" "$disk" \
    "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_data[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 3 -m 2048 -nodefaults -no-user-config -display none -nic none \
    -device ramfb -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
    -device virtio-serial-device -bios "$bios" -no-reboot -monitor none | tee "$out/touch.log"
grep -Fxq 'COMBINED_QEMU_EXIT_0 phase=first' "$out/touch.log"
if [[ $screen_lock == baseline ]]; then
    grep -Fxq 'SCREEN_LOCK_BASELINE xflock4_exit=1 active=yes locked_hint=no greeter=no' "$out/first/report.log"
elif [[ $screen_lock == candidate || $screen_lock == installed ]]; then
    for report in "$out"/*/report.log; do
        for marker in SCREEN_LOCK_ACTIVE SCREEN_LOCK_BAD_PASSWORD_REJECTED SCREEN_LOCK_CANCEL_STILL_LOCKED SCREEN_LOCK_SAME_SESSION_DRAFT_RESTORED; do
            grep -Fxq "$marker" "$report"
        done
        if [[ $screen_lock == installed ]]; then grep -Fxq 'COMBINED_SAVER_AUTOSTART rotation=running auto_rotate=false' "$report"; fi
    done
fi
if (( cold )); then
    grep -Fxq 'COMBINED_QEMU_EXIT_0 phase=cold' "$out/touch.log"
    grep -Fxq 'COMBINED_COLD_RELOGIN_PASS two_processes=1 boot_ids_distinct=1 overlay_reused=1' "$out/touch.log"
fi
if (( regdb )); then
    for report in "$out"/*/report.log; do
        grep -Fxq 'COMBINED_REGDB cfg80211=1 load_errors=0 runtime_pair=upstream global_country=CN radios=0' "$report"
    done
fi
sha256sum --strict -c "$manifest" | tee "$out/after.log"
echo COMBINED_INPUTS_UNCHANGED
