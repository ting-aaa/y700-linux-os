#!/usr/bin/env bash
# Boot a private file-backed trial twice, then inspect the stopped file systems.
set -euo pipefail
umask 077
if [[ $# != 6 || $(id -u) != 0 ]]; then
    echo 'Usage: run.sh PREPARED_OUTER_DIR FILE_TRIAL_ENTRY SEALED_DEV125_ESP VIRT_UBOOT VIRT_DTB NEW_LOG_DIR (Linux root)' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
combined=$(realpath -e "$here/../combined-efi")
outer_dir=$(realpath -e "$1")
entry=$(realpath -e "$2")
esp=$(realpath -e "$3")
bios=$(realpath -e "$4")
dtb=$(realpath -e "$5")
out=$(realpath -m "$6")
mkdir -m700 -- "$out"
work=$(mktemp -d /var/tmp/y700-file-boot.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/var/tmp/y700-file-boot\.[a-zA-Z0-9]{8}$ ]]
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
echo "FILE_TRIAL_EVIDENCE=$out"
echo "FILE_TRIAL_WORK=$work"
verify_sources() {
    (cd "$outer_dir" && sha256sum --strict -c outer.sha256 && sha256sum --strict -c source.sha256)
    (cd "$entry" && sha256sum --strict -c SHA256SUMS)
    printf '%s  %s\n' \
        495e63f8fa663db2ffcec1b2f3dc4146002604572835bffb725d57926fb520e6 "$esp" \
        ccfe8c4136a02adccdc68b2e7567fa4a06cc8874213064f62f20463803706c4f "$bios" \
        a89bc8f2ee12f118656c6963fb9d45b862e6d5a1aeedf2630ddbe08f03079d31 "$dtb" | sha256sum --strict -c -
}
verify_sources | tee "$out/before.log"
cd "$work"
mkdir view
truncate -s 1G outer-esp.fat
mkfs.fat -F32 -s 1 -S4096 -i 10ACCE55 outer-esp.fat
mcopy -s -i outer-esp.fat "$entry/EFI" "$entry/loader" ::/
mmd -i outer-esp.fat ::/EFI/BOOT
mcopy -i "$esp" ::/EFI/BOOT/BOOTAA64.EFI bootaa64.efi
mcopy -i outer-esp.fat bootaa64.efi ::/EFI/BOOT/BOOTAA64.EFI
mtype -i outer-esp.fat ::/EFI/BOOT/BOOTAA64.EFI | cmp - bootaa64.efi
for file in kernel.efi initrd; do
    mtype -i outer-esp.fat "::/EFI/y700-file/$file" | cmp - "$entry/EFI/y700-file/$file"
done
sha256sum "$entry/EFI/y700-file/"{kernel.efi,initrd,board.dtb} "$entry/loader/entries/y700-file.conf" | tee "$out/efi-payload.sha256"
mcopy -o -i outer-esp.fat "$dtb" ::/EFI/y700-file/board.dtb
printf 'default y700-file.conf\ntimeout 0\n' > loader.conf
mcopy -o -i outer-esp.fat loader.conf ::/loader/loader.conf

# Keep the real enrollment/desktop checks; substitute the nested topology and
# read instrumentation only from the private read-only mount of the outer ESP.
awk '
    /^    \[\[ \$\(findmnt -nro SOURCE,FSTYPE \/\) / {
        print "    /bin/bash /run/y700-file-qa/check-topology.sh"
        changed++
        next
    }
    /^        test -f "\$audio_marker"$/ {
        print "        if test -f \"$audio_marker\"; then echo FILE_TRIAL_AUDIO_MARKER persisted=1; else echo FILE_TRIAL_AUDIO_MARKER persisted=0; fi"
        cold_marker++
        next
    }
    /^greeter\(\) / {
        print "greeter() { systemctl is-active --quiet lightdm; }"
        greeter_service++
        next
    }
    /^wait_for 200 greeter greeter$/ {
        print "if ! wait_for 280 greeter-service greeter >/dev/null; then"
        print "    timeout -k 1 8 /bin/bash /run/y700-file-qa/onboard-diagnostics.sh || :"
        print "    echo COMBINED_FAIL timeout=greeter-service"
        print "    false"
        print "fi"
        greeter_wait++
        next
    }
    /^desktop\(\) / {
        print "source /run/y700-file-qa/check-login-stage.sh"
        login_stage++
    }
    /^wait_for 300 desktop desktop$/ {
        print "if ! wait_for 300 desktop desktop >/dev/null; then login_timeout xfce-ready; fi"
        desktop_stage++
        next
    }
    /^\[\[ -n \$sid && \$uid != 0 \]\]$/ {
        print "[[ -n $sid && $uid != 0 && $sid == \"$pam_session\" ]]"
        session_match++
        next
    }
    /^echo .*COMBINED_PAM_XFCE / {
        print "printf \047FILE_TRIAL_XFCE_READY same_pam_session=1 elapsed=%ss\\n\047 \"$((SECONDS - pam_time))\""
    }
    /^        sleep \.35$/ { print "        sleep 1.5"; next }
    /^wait_for 220 onboard onboard_ready$/ { optional++; exit }
    { gsub("/boot/combined-", "/run/y700-file-qa/combined-")
      gsub("root=/dev/vda2 esp=/dev/vda1", "root=$(findmnt -nro SOURCE /) esp=$(findmnt -nro SOURCE /boot)")
      print }
    END { if (changed != 1 || cold_marker != 1 || greeter_service != 1 || greeter_wait != 1 || login_stage != 1 || desktop_stage != 1 || session_match != 1 || optional != 1) exit 1 }
' "$combined/observe.sh" > combined-observe.sh
cat >> combined-observe.sh <<'OPTIONAL_DESKTOP'
# Optional user-bus reads can stall, even on an already verified desktop. Give
# their private log a short collection window and never wait for this job.
optional_dir=$(mktemp -d /run/y700-file-optionals.XXXXXXXX)
(
    exec >"$optional_dir/report" 2>&1
    trap - ERR
    if onboard_ready; then
        if [[ $(asuser timeout -k 1 3 gsettings get org.onboard.auto-show enabled) == true &&
              $(asuser timeout -k 1 3 gsettings get org.onboard.auto-show keyboard-device-detection-enabled) == true ]]; then
            echo 'COMBINED_ONBOARD ordinary=1 autostart=1 auto_show=1 detect_keyboard=1'
        else
            echo 'FILE_TRIAL_OPTIONAL_CHECK onboard=unconfirmed-settings'
        fi
    else
        onboard_process=absent
        if pgrep -u "$uid" -x onboard >/dev/null; then onboard_process=present; fi
        echo "FILE_TRIAL_OPTIONAL_CHECK onboard=dbus-owner-unconfirmed process=$onboard_process"
    fi
    scale=$(asuser timeout -k 1 3 xfconf-query -c xsettings -p /Gdk/WindowScalingFactor 2>/dev/null || :)
    printf 'COMBINED_XFCE_SCALE factor=%s virtual_display=1024x768\n' "${scale:-unconfirmed}"
    if test -f "$audio_marker" &&
       [[ $(asuser timeout -k 1 3 xfconf-query -c xfce4-panel -p /plugins/plugin-19) == pulseaudio ]] &&
       ids=$(asuser timeout -k 1 3 xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids | awk '/^[0-9]+$/{printf "%s ",$0}') &&
       [[ $ids == '1 2 3 4 5 6 19 7 8 9 10 ' ]] &&
       wrapper=$(pgrep -o -u "$uid" -f '^/usr/lib/[^ ]+/xfce4/panel/wrapper-2\.0 .*/libpulseaudio-plugin\.so 19( |$)') &&
       grep -Fq '/libpulseaudio-plugin.so' "/proc/$wrapper/maps"; then
        echo 'COMBINED_AUDIO_PANEL ordinary=1 marker=1 top_panel=1 mapped_wrapper=1'
    else
        echo 'FILE_TRIAL_OPTIONAL_CHECK audio-panel=unconfirmed'
    fi
    touch "$optional_dir/done"
) &
sleep 6
if test -f "$optional_dir/report"; then cat "$optional_dir/report"; fi
if ! test -f "$optional_dir/done"; then
    echo 'FILE_TRIAL_OPTIONAL_CHECK collection=budget-exhausted unfinished=unconfirmed'
fi
echo COMBINED_PASS
systemctl --no-block poweroff
OPTIONAL_DESKTOP
bash -n combined-observe.sh
"${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$combined/touch.c" -o combined-touch
mcopy -i outer-esp.fat combined-observe.sh combined-touch "$here/check-topology.sh" "$here/check-login-stage.sh" "$here/onboard-diagnostics.sh" ::/
cat > probe.service <<'UNIT'
[Unit]
Description=Probe Y700 file-backed EFI desktop trial
RequiresMountsFor=/boot
Requires=dev-vda1.device
After=systemd-udev-trigger.service dev-vda1.device
Before=y700-firstboot.service
FailureAction=poweroff
ConditionKernelCommandLine=y700.file_probe=1

[Service]
Type=oneshot
TimeoutStartSec=170
StandardOutput=journal+console
StandardError=journal+console
ExecStartPre=/usr/bin/install -d -m0700 /run/y700-file-qa
ExecStartPre=/usr/bin/mount -o ro,nodev,nosuid,noexec /dev/vda1 /run/y700-file-qa
ExecStart=/bin/bash /run/y700-file-qa/combined-observe.sh setup
UNIT
grep -Fxq 'linux /EFI/y700-file/kernel.efi' "$entry/loader/entries/y700-file.conf"
grep -Fxq 'initrd /EFI/y700-file/initrd' "$entry/loader/entries/y700-file.conf"
sed -n 's/^options //p' "$entry/loader/entries/y700-file.conf" > exported-options
[[ $(wc -l < exported-options) == 1 ]]
grep -Eq '(^| )rdinit=/y700-file-trial-init( |$)' exported-options
grep -Eq '(^| )y700\.media=file( |$)' exported-options
grep -Eq '(^| )drm_kms_helper\.fbdev_emulation=0( |$)' exported-options
mcopy -i outer-esp.fat exported-options ::/exported-options
unit=$(base64 -w0 probe.service)
sed "/^options /s|$| console=ttyAMA0 loglevel=7 y700.file_probe=1 y700.combined_efi=1 systemd.wants=y700-file-probe.service systemd.set_credential_binary=systemd.extra-unit.y700-file-probe.service:$unit|" \
    "$entry/loader/entries/y700-file.conf" > probed.conf
mcopy -o -i outer-esp.fat probed.conf ::/loader/entries/y700-file.conf

truncate -s 10243M layout.gpt
printf 'label: gpt\nunit: sectors\n\nstart=256, size=262144, type=uefi, name=linux-boot\nstart=262400, size=2359296, type=linux, name=linux\n' |
    sfdisk --sector-size 4096 layout.gpt > "$out/layout.log"
dd if=layout.gpt of=head.bin bs=1M count=1 conv=sparse status=none
dd if=layout.gpt of=tail.bin bs=1M skip=10241 conv=sparse status=none
"${NBDKIT:-nbdkit}" -f -r -U "$work/base.sock" "${NBDKIT_SPLIT:-split}" \
    "$work/head.bin" "$work/outer-esp.fat" "$outer_dir/outer.ext4" "$work/tail.bin" > "$out/nbdkit.log" 2>&1 &
export_pid=$!
for _ in {1..120}; do [[ ! -S base.sock ]] || break; sleep .05; done
test -S base.sock
"${NBDFUSE:-nbdfuse}" -r "$work/view/disk.gpt" --unix "$work/base.sock" > "$out/nbdfuse.log" 2>&1 &
fuse_pid=$!
for _ in {1..120}; do [[ ! -f view/disk.gpt ]] || break; sleep .05; done
[[ $(stat -Lc %s view/disk.gpt) == "$(stat -Lc %s layout.gpt)" ]]
"${QEMU_IMG:-qemu-img}" create -q -f qcow2 -F raw -b "$work/view/disk.gpt" "$work/session.qcow2"
qemu_data=()
if [[ -n ${QEMU_DATA:-} ]]; then qemu_data=(-L "$QEMU_DATA"); fi
timeout -k 25 2480 "${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 \
    python -B "$here/qemu-file.py" "$work" "$out" "$work/session.qcow2" \
    "${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" "${qemu_data[@]}" \
    -machine virt,gic-version=3 -cpu max -smp 3 -m 2048 -nodefaults -no-user-config -display none -nic none \
    -device ramfb -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
    -device virtio-serial-device \
    -chardev socket,id=login-phase,path=login-phase.sock,server=on,wait=off \
    -device virtserialport,chardev=login-phase,name=org.y700.login-phase \
    -bios "$bios" -no-reboot -monitor none | tee "$out/touch.log"
grep -Fxq 'COMBINED_COLD_RELOGIN_PASS two_processes=1 boot_ids_distinct=1 overlay_reused=1' "$out/touch.log"
for report in "$out/first/report.log" "$out/cold/report.log"; do
    grep -Fxq 'FILE_TRIAL_EFI entry=y700-file.conf firmware_disk=/dev/vda1 sector=4096 options_preserved=1' "$report"
    grep -Eq '^FILE_TRIAL_LOOPS root=/dev/loop[0-9]+ boot=/dev/loop[0-9]+ parent=/dev/vda2 root_inode=verified esp_inode=verified writable=1$' "$report"
done
bash "$here/check-offline.sh" "$work" "$work/session.qcow2" | tee "$out/offline.log"
verify_sources | tee "$out/after.log"
echo FILE_TRIAL_POSITIVE_PASS
