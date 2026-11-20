#!/bin/bash
set -euo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
mode=$(sed -n 's/.*y700.mic_fixture=\([a-z]*\).*/\1/p' /proc/cmdline)
case "$mode" in playback) capture=0 ;; capture) capture=1 ;; *) exit 2 ;; esac
test "$(cat /sys/block/vda/ro)" = 1
cd /opt/mic-fixture
profile=/usr/share/alsa/ucm2/Lenovo-Y700
ln -sf /proc/self/fd /dev/fd
mkdir -p /run/{udev,dbus}
systemd-machine-id-setup >/dev/null
/usr/lib/systemd/systemd-udevd --daemon
dbus-daemon --system --fork
modprobe snd-pcm
insmod ./snd-y700-fixture.ko id=LenovoY700 capture_pcm="$capture"
SYSTEMD_IN_CHROOT=0 udevadm settle --timeout=15
test "$(cat /proc/asound/card0/id)" = LenovoY700
test -c /dev/snd/pcmC0D0p && test -c /dev/snd/pcmC0D1p
if (( capture )); then
    test -c /dev/snd/pcmC0D2c
else
    [[ -z $(find /dev/snd -name 'pcm*c') ]]
fi
./controls
chgrp audio /dev/snd/{controlC0,pcmC0*}
chmod 660 /dev/snd/{controlC0,pcmC0*}
driver_dir=/usr/share/alsa/ucm2/conf.d/Y700Fixture
mkdir "$driver_dir"
ln -s ../../Lenovo-Y700/Lenovo-Y700.conf "$driver_dir/Y700Fixture.conf"
check_ucm() { alsaucm -c hw:LenovoY700 set _verb HiFi list _devices; }
before=$(check_ucm)
grep -wq Speaker <<< "$before"
if grep -wq Mic <<< "$before"; then exit 1; fi
speaker_hash=$(sha256sum "$profile/HiFi.conf")
install -m644 Lenovo-Y700.conf HiFi-Mic.conf Mic.conf "$profile/"
test "$(sha256sum "$profile/HiFi.conf")" = "$speaker_hash"
devices=$(check_ucm)
grep -wq Speaker <<< "$devices"
if (( capture )); then
    grep -wq Mic <<< "$devices"
    # The kernel test driver repeats these little-endian S16 patterns independently.
    { for _ in {1..24}; do printf '\000\040'; done; for _ in {1..24}; do printf '\000\340'; done; } > /sys/kernel/debug/pcmtest/fill_pattern0
    { for _ in {1..16}; do printf '\000\020'; done; for _ in {1..16}; do printf '\000\360'; done; } > /sys/kernel/debug/pcmtest/fill_pattern1
elif grep -wq Mic <<< "$devices"; then
    exit 1
fi
printf 'MIC_UCM mode=%s playback_pcms=2 capture_pcms=%s original_speaker_only=1 candidate_mic=%s speaker_untouched=1\n' "$mode" "$capture" "$capture"
dpkg-query -W -f='MIC_PACKAGE ${Package} ${Version}\n' pipewire pipewire-pulse wireplumber libasound2t64
uid=$(id -u y700)
install -d -m700 -o y700 -g y700 "/run/user/$uid"
runuser -u y700 -- env HOME=/home/y700 XDG_RUNTIME_DIR="/run/user/$uid" dbus-run-session -- \
    ./uv run --offline --no-project --python /usr/bin/python3 python -B session.py "$mode"
echo "MIC_CASE_PASS $mode"
