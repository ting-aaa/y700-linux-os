#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.combined_efi=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
wait_for() {
    local budget=$1 label=$2 end
    shift 2
    end=$((SECONDS + budget))
    until "$@"; do
        if (( SECONDS >= end )); then echo "COMBINED_FAIL timeout=$label"; return 1; fi
        sleep .35
    done
}
wait_for 30 report test -c /dev/virtio-ports/org.y700.qa
exec >/dev/virtio-ports/org.y700.qa 2>&1
trap 'echo "COMBINED_FAIL line=$LINENO"; systemctl --no-block poweroff' ERR
state() { /usr/libexec/y700-firstboot-drm/enroll --state; }
locked() { [[ $(passwd -S y700 | awk '{print $2}') == L && $(state) == new && ! -e /etc/y700/user-configured ]]; }
configured() { [[ $(passwd -S y700 | awk '{print $2}') == P && $(state) == active && -e /etc/y700/user-configured ]]; }
audio_marker=/home/y700/.local/state/y700/panel-audio-v1
if [[ $1 == setup ]]; then
    [[ $(uname -r) == 7.3.4-asphalt-prc && $(cat /proc/1/comm) == systemd && -d /sys/firmware/efi ]]
    [[ $(findmnt -nro SOURCE,FSTYPE /) == '/dev/vda2 ext4' && $(findmnt -nro SOURCE,FSTYPE /boot) == '/dev/vda1 vfat' ]]
    [[ $(findmnt -nro UUID /) == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
    [[ $(cat /etc/y700/image-id) == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
    [[ $(systemctl get-default) == graphical.target ]]
    [[ $(cat /sys/module/drm_kms_helper/parameters/fbdev_emulation) == N && ! -e /dev/fb0 ]]
    printf '%s  /sys/kernel/notes\n' c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564 | sha256sum --strict -c -
    if locked; then
        account=locked
        test ! -e "$audio_marker"
    else
        configured
        account=configured
        test -f "$audio_marker"
    fi
    test -z "$(dpkg --audit)"
    inventory=$(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | LC_ALL=C sort)
    count=1112
    expected=ae129edd690fcd72820e3c286c6010474a70cefea622d53f4fe88b53f94afb21
    platform='0.1.0~dev12.5'
    camera='0.7.2-1~bpo13+1.y7003'
    if [[ -f /boot/lock-mode && $(cat /boot/lock-mode) == installed ]]; then
        count=1115
        expected=a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98
        platform='0.1.0~dev12.6'
        camera='0.7.2-1~bpo13+1.y7004'
        test ! -e /boot/lock-archives
        echo '5079a43e218503018b28bec9e22a0960824204623db866e17b98dfab48718a99  /usr/lib/y700/rotation_session.py' | sha256sum --strict -c -
    fi
    [[ $(wc -l <<<"$inventory") == "$count" ]]
    digest=$(printf '%s\n' "$inventory" | sha256sum)
    [[ ${digest%% *} == "$expected" ]]
    for item in 'onboard 1.4.1-10+y7002 arm64' "y700-platform $platform all" \
        "y700-camera-qcam $camera arm64" 'y700-ssc-runtime 0.1.3 arm64'; do
        read -r name version arch <<<"$item"
        [[ $(dpkg-query -W -f='${Version} ${Architecture}' "$name") == "$version $arch" ]]
        printf 'COMBINED_PACKAGE name=%s version=%s architecture=%s\n' "$name" "$version" "$arch"
    done
    test -z "$(dpkg -V onboard y700-platform y700-camera-qcam y700-ssc-runtime y700-firstboot-drm y700-warm-greeter)"
    echo "COMBINED_EFI root=/dev/vda2 esp=/dev/vda1 pid1=systemd packages=$count digest=${digest%% *} account=$account"
    if [[ -d /boot/lock-archives ]]; then
        dpkg --install /boot/lock-archives/*.deb
    fi
    if [[ -f /boot/lock-witness.py ]]; then
        apt-get check
        [[ -z $(dpkg --audit) && -z $(dpkg -V xfce4-screensaver y700-touch-lock) ]]
        install -m755 /boot/lock-test-uv /run/y700-lock-test-uv
        install -m644 /boot/lock-witness.py /run/y700-lock-witness.py
    fi
    printf 'COMBINED_BOOT_ID id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
    if grep -qw y700.combined_regdb=1 /proc/cmdline; then
        test -d /sys/module/cfg80211
        [[ $(readlink -f /lib/firmware/regulatory.db) == /usr/lib/firmware/regulatory.db-upstream ]]
        [[ $(readlink -f /lib/firmware/regulatory.db.p7s) == /usr/lib/firmware/regulatory.db.p7s-upstream ]]
        printf '%s  %s\n' \
            2fb33ca0074db573e05ef7dd50bb45b63c0ff98b7e852e1105ebad536fae8e6b /lib/firmware/regulatory.db \
            c941c08f51c93e46722293b85631604c3740d86c3de0c75f79aef50d2e919179 /lib/firmware/regulatory.db.p7s |
            sha256sum --strict -c -
        # dmesg contains the early firmware messages, before the observer runs.
        if dmesg | grep -Ei 'regulatory\.db.*(failed|malformed|invalid)|failed.*regulatory\.db'; then false; fi
        install -m755 /boot/combined-iw /run/y700-combined-iw
        test -z "$(/run/y700-combined-iw dev)"
        /run/y700-combined-iw reg get | grep -Eq '^country CN:'
        echo 'COMBINED_REGDB cfg80211=1 load_errors=0 runtime_pair=upstream global_country=CN radios=0'
    fi
    systemctl show y700-firstboot -p ExecStart | grep -Fq /usr/libexec/y700-firstboot-drm/firstboot
    /usr/sbin/lightdm --show-config 2>&1 | grep -Fq greeter-session=arctica-greeter
    wait_for 25 contact-port test -c /dev/virtio-ports/org.y700.enroll
    install -m755 /boot/combined-touch /run/y700-combined-touch
    systemd-run --no-block --quiet --unit=y700-combined-taps /run/y700-combined-touch
    wait_for 25 touch-device grep -Fq 'Y700 QEMU enrollment touchscreen' /proc/bus/input/devices
    udevadm settle --timeout=15
    echo 'COMBINED_TOUCH device=direct_type_b no_keyboard=1'
    systemd-run --no-block --quiet --unit=y700-combined-observer /bin/bash /boot/combined-observe.sh "$account"
    exit 0
fi
if [[ $1 == locked ]]; then
    wait_for 150 firstboot pgrep -x unl0kr >/dev/null
    echo COMBINED_FIRSTBOOT_READY
    retry() { pgrep -f '^/usr/libexec/y700-firstboot-drm/enroll --retry$' >/dev/null && pgrep -x unl0kr >/dev/null; }
    wait_for 270 mismatch retry
    locked
    echo COMBINED_MISMATCH_STILL_LOCKED
    wait_for 270 matching test -e /etc/y700/user-configured
    configured
else
    [[ $1 == configured ]]
    configured
fi
greeter() { pgrep -u lightdm -x arctica-greeter >/dev/null && pgrep -u lightdm -x onboard >/dev/null; }
wait_for 200 greeter greeter
[[ $(systemctl is-active lightdm) == active && $(systemctl show y700-firstboot -p Result --value) == success ]]
if [[ $1 == locked ]]; then
    echo COMBINED_MATCH_GREETER
else
    if pgrep -x unl0kr >/dev/null; then false; fi
    if journalctl -b -u y700-firstboot -q -o cat | grep -E 'Begin.*enroll|unl0kr\['; then false; fi
    echo 'COMBINED_COLD_GREETER enrollment_skipped=1 account=configured'
fi
desktop() {
    for name in xfce4-session xfwm4 xfce4-panel xfdesktop; do pgrep -u y700 -x "$name" >/dev/null || return 1; done
}
wait_for 300 desktop desktop
uid=$(id -u y700)
pid=$(pgrep -o -u y700 -x xfce4-session)
sid=$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^XDG_SESSION_ID=//p')
[[ -n $sid && $uid != 0 ]]
property() { loginctl show-session "$sid" -p "$1" --value; }
[[ $(property User) == "$uid" && $(property Type) == x11 && $(property Service) == lightdm ]]
[[ $(property Active) == yes && $(property Remote) == no && $(property Class) == user && $(property Seat) == seat0 ]]
systemctl is-active --quiet graphical.target
echo 'COMBINED_PAM_XFCE account=y700 ordinary=1 active=1 local=1 seat=seat0 type=x11'
asuser() {
    setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env HOME=/home/y700 \
        XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_CURRENT_DESKTOP=XFCE "$@"
}
onboard_ready() {
    asuser gdbus call --session --timeout 3 --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.onboard.Onboard | grep -Fxq '(true,)'
}
wait_for 220 onboard onboard_ready
[[ $(asuser gsettings get org.onboard.auto-show enabled) == true ]]
[[ $(asuser gsettings get org.onboard.auto-show keyboard-device-detection-enabled) == true ]]
echo 'COMBINED_ONBOARD ordinary=1 autostart=1 auto_show=1 detect_keyboard=1'
scale=$(asuser xfconf-query -c xsettings -p /Gdk/WindowScalingFactor 2>/dev/null || :)
printf 'COMBINED_XFCE_SCALE factor=%s virtual_display=1024x768\n' "${scale:-default}"
wait_for 190 panel-marker test -f "$audio_marker"
[[ $(asuser xfconf-query -c xfce4-panel -p /plugins/plugin-19) == pulseaudio ]]
ids=$(asuser xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids | awk '/^[0-9]+$/{printf "%s ",$0}')
[[ $ids == '1 2 3 4 5 6 19 7 8 9 10 ' ]]
wrapper=$(pgrep -o -u "$uid" -f '^/usr/lib/[^ ]+/xfce4/panel/wrapper-2\.0 .*/libpulseaudio-plugin\.so 19( |$)')
grep -Fq '/libpulseaudio-plugin.so' "/proc/$wrapper/maps"
echo 'COMBINED_AUDIO_PANEL ordinary=1 marker=1 top_panel=1 mapped_wrapper=1'
if [[ -f /boot/lock-mode ]]; then
    if [[ $(cat /boot/lock-mode) == installed ]]; then
        saver_started() {
            asuser gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
                --method org.freedesktop.DBus.NameHasOwner org.xfce.ScreenSaver | grep -Fxq '(true,)'
        }
        wait_for 40 saver-autostart saver_started
        pgrep -u "$uid" -f '^(/usr/bin/python3 )?/usr/lib/y700/y700-auto-rotate.py --session$' >/dev/null
        [[ $(asuser gsettings get org.y700.tablet auto-rotate) == false ]]
        echo 'COMBINED_SAVER_AUTOSTART rotation=running auto_rotate=false'
    fi
    bash /boot/observe-lock.sh "$(cat /boot/lock-mode)" "$sid" "$pid"
fi
echo COMBINED_PASS
systemctl --no-block poweroff
