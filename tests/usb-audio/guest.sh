#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
test "$(cat /sys/block/vda/ro)" = 1
grep -qw 'y700.test_uac=1' /proc/cmdline
cd /opt/mic-fixture
export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$PWD UV_CACHE_DIR=/run/uv-cache
py=(./uv run --offline --no-project --python /usr/bin/python3 python -B)
mkdir -p /run/{udev,dbus}
ln -sf /proc/self/fd /dev/fd
systemd-machine-id-setup >/dev/null
/usr/lib/systemd/systemd-udevd --daemon
dbus-daemon --system --fork
pkg=y700-usb-audio-modules
modules=/usr/lib/modules/$(uname -r)
digest() {
    dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort | sha256sum | cut -d' ' -f1
}
before=$(digest)
[[ $before == 5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098 ]]
notes=$(sha256sum /sys/kernel/notes); echo "UAC_KERNEL notes=${notes%% *}"
if modprobe -n snd-usb-audio >/dev/null 2>&1; then exit 1; fi
insmod usbip-core.ko
insmod vhci-hcd.ko
peer=
failure() {
    cat /run/peer.log >&2 || :
    dmesg | tail -30 >&2
    if [[ -n $peer ]]; then kill "$peer" 2>/dev/null || :; fi
}
trap failure EXIT
usb() { grep -lFx 1209 /sys/bus/usb/devices/*/idVendor | grep -q .; }
pcm() { [[ -c /dev/snd/pcmC0D0c && -c /dev/snd/pcmC0D0p ]]; }
wait_for() { for ((t=0;t<150;t++)); do "$@" && return 0; sleep .1; done; return 1; }
attach() {
    "${py[@]}" device.py > /run/peer.log 2>&1 & peer=$!
    wait_for usb
    usbdir=$(dirname "$(grep -lFx 1209 /sys/bus/usb/devices/*/idVendor)")
    test "$(cat "$usbdir/idProduct")" = 7001
}
detach() {
    kill "$peer"; wait "$peer"; peer=
    wait_for test ! -e "$usbdir"
    wait_for test ! -e /dev/snd/pcmC0D0c
    wait_for test ! -e /dev/snd/pcmC0D0p
}
attach
[[ ! -e /dev/snd/pcmC0D0c && ! -e /dev/snd/pcmC0D0p ]]
echo 'UAC_BASELINE standard_device=1 module=absent playback=0 capture=0'
detach
dpkg-deb -e ./*.deb /run/uac-debian
printf 'unknown kernel' > /run/uac-other-notes
if unshare -m --propagation private sh -ec 'mount --bind /run/uac-other-notes /sys/kernel/notes; exec /run/uac-debian/preinst install' > /run/reject 2>&1; then exit 1; fi
grep -Fxq 'USB audio package refused: kernel_notes' /run/reject
foreign=$modules/updates/$pkg/snd-rawmidi.ko.zst
test ! -e "$foreign"
mkdir -p "$(dirname "$foreign")"; printf 'fixture\n' > "$foreign"
if /run/uac-debian/preinst install > /run/reject 2>&1; then exit 1; fi
grep -Fxq 'USB audio package refused: file_ownership' /run/reject
grep -Fxq fixture "$foreign"; rm "$foreign"
echo 'UAC_GUARD unknown_notes_refused=1 unowned_existing_file_retained=1'
dpkg -i ./*.deb
test -z "$(dpkg -V "$pkg")"
dpkg -i ./*.deb
after=$(digest)
[[ $after == fb6dcd2c9f7aec2a970ae9f1a8768c0effdf610871ba72ffa313079df3aea94b ]]
echo "UAC_INVENTORY baseline=$before updated=$after"
modprobe snd-usb-audio
test -d /sys/module/snd_usb_audio
[[ ! -e /dev/snd/pcmC0D0c && ! -e /dev/snd/pcmC0D0p ]]
modprobe -r snd-usb-audio
test ! -e /sys/module/snd_usb_audio
echo 'UAC_IDLE no_accessory=1 capture=0 playback=0 unload=1'
# Driver autoload through udev on a newly connected class-compliant interface.
attach
wait_for pcm
test "$(basename "$(readlink -f "$usbdir:1.0/driver")")" = snd-usb-audio
test "$(cat /sys/class/sound/card0/device/../idVendor)" = 1209
SYSTEMD_IN_CHROOT=0 udevadm settle --timeout=12
useradd -m -G audio fixture
install -d -m700 -o fixture -g fixture /run/uac-session
runuser -u fixture -- env UV_CACHE_DIR=/tmp/uv-fixture "${py[@]}" check-tone.py alsa
timeout 50 runuser -u fixture -- env XDG_RUNTIME_DIR=/run/uac-session UV_CACHE_DIR=/tmp/uv-fixture dbus-run-session -- "${py[@]}" check-tone.py desktop
detach
modprobe -r snd-usb-audio
dpkg --purge "$pkg"
if modprobe -n snd-usb-audio >/dev/null 2>&1; then exit 1; fi
[[ $(digest) == "$before" ]]
trap - EXIT
echo 'UAC_PASS hotplug_autoload=1 desktop=1 playback_pcm=1 unplug=1 rollback_inventory_restored=1'
