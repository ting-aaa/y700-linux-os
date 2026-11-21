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
    notes=c9fbc259802dfc4570c14df56043d37f1c08e9769341de3d7cde08f9be6f1564
    if [[ -f /boot/camera-autofocus.lock.json ]]; then notes=35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6; fi
    if [[ -f /boot/platform-desktop-update.lock.json ]]; then notes=c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063; fi
    printf '%s  /sys/kernel/notes\n' "$notes" | sha256sum --strict -c -
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
    if grep -qw y700.combined_power=1 /proc/cmdline; then
        count=1124
        expected=bbb696086ce1bb4a425dbf63876f12548e7e6a6048ed89415e64cb6a793eba6a
        platform='0.1.0~dev12.6'
        camera='0.7.2-1~bpo13+1.y7004'
        [[ $(dpkg-query -W -f='${Version}' xfce4-power-manager) == '4.20.0-1+y7001' ]]
        [[ -z $(dpkg -V xfce4-power-manager xfce4-power-manager-data upower y700-power-desktop) ]]
        if [[ -f /boot/blueman-tested.lock ]]; then
            expected=685d01f30932a5dd7df5ccbf99c66f3908e29c5cdeda2b7abe91d727f9c09511
            cmp /boot/blueman-tested.lock /var/lib/y700/build/blueman.lock.json
            blueman_version=2.4.4-1+y7002
            if [[ -f /boot/tablet-desktop.lock.json ]]; then blueman_version=2.4.4-1+y7003; fi
            [[ $(dpkg-query -W -f='${Version} ${Architecture}' blueman) == "$blueman_version arm64" ]]
            [[ -z $(dpkg -V blueman) ]]
            echo "COMBINED_BLUEMAN version=$blueman_version architecture=arm64 receipt=verified files=verified"
            if [[ -f /boot/platform-tested.lock ]]; then
                platform='0.1.0~dev12.8'
                expected=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
                cmp /boot/platform-tested.lock /var/lib/y700/build/platform.lock.json
            fi
        fi
    fi
    if [[ -f /boot/media-tested.lock ]]; then
        [[ $platform == '0.1.0~dev12.8' ]]
        count=1240
        expected=89aa7038cac0d6591b9977608f137e1412bebdd52f6125ac2521d882f8633d1d
        if [[ -f /boot/media-update-tested.lock ]]; then
            cmp /boot/media-update-tested.lock /var/lib/y700/build/video-player-update.lock.json
            cmp /boot/media-update-tested.lock /var/lib/y700/build/video-player.lock.json
            cmp /boot/media-tested.lock /var/lib/y700/build/video-player-dev12.9.lock.json
            expected=ffb8818f1fd41efb3b7c7a14782abd62b37bf5dd687cfaa923d3419d785f51c3
            [[ $(dpkg-query -W -f='${Version} ${Architecture}' parole) == '4.18.2-1+y7002 arm64' ]]
            [[ -z $(dpkg -V parole) ]]
            echo 'COMBINED_MEDIA_UPDATE edition=dev12.10 parole=4.18.2-1+y7002 package_files=verified'
        else
            cmp /boot/media-tested.lock /var/lib/y700/build/video-player.lock.json
        fi
    fi
    if [[ -f /boot/camera-autofocus.lock.json ]]; then
        [[ $count == 1240 && -f /boot/media-update-tested.lock ]]
        cmp /boot/camera-autofocus.lock.json /var/lib/y700/build/camera-autofocus.lock.json
        cmp /boot/wifi-sae-update.lock.json /var/lib/y700/build/wifi-sae-update.lock.json
        expected=be0f181db24f72e2166b418e7b4e38999a672ffc89cb735a5afb7fd9a931941d
        camera='0.7.2-1~bpo13+1.y7005'
        test -z "$(dpkg -V y700-camera-runtime y700-camera-pipewire network-manager wpasupplicant)"
        if [[ -f /boot/platform-desktop-update.lock.json ]]; then
            cmp /boot/platform-desktop-update.lock.json /var/lib/y700/build/platform-desktop-update.lock.json
            platform='0.1.0~dev12.8+gpu1.2'
            if [[ -f /boot/tablet-desktop.lock.json ]]; then
                cmp /boot/tablet-desktop.lock.json /var/lib/y700/build/tablet-desktop.lock.json
                count=1241
                expected=5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098
                if [[ -f /boot/browser-camera-desktop.lock.json ]]; then
                    grep -Fxq IMAGE_VERSION=dev12.14 /etc/os-release
                    cmp /boot/browser-camera-desktop.lock.json /var/lib/y700/build/browser-camera-desktop.lock.json
                    [[ $(dpkg-query -W -f='${Version}' y700-camera-pipewire) == 1.4.2-1+y700.5 ]]
                    expected=a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb
                else
                    grep -Fxq IMAGE_VERSION=dev12.13 /etc/os-release
                fi
                camera='0.7.2-1~bpo13+1.y7008'
                [[ $(dpkg-query -W -f='${Version}' y700-quick-settings) == 0.1.0 ]]
                [[ $(dpkg-query -W -f='${Version}' ibus) == '1.5.32-2+0y7001' ]]
                [[ -z $(dpkg -V ibus y700-quick-settings) ]]
            else
                grep -Fxq IMAGE_VERSION=dev12.12 /etc/os-release
                expected=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
            fi
        else
            grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
        fi
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
if grep -qw y700.combined_power=1 /proc/cmdline; then
    asuser timeout 45 gdbus wait --session org.xfce.PowerManager
    manager=$(asuser gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID org.xfce.PowerManager | sed -nE 's/^\(uint32 ([0-9]+),\)$/\1/p')
    [[ $manager =~ ^[0-9]+$ && $(stat -c %u "/proc/$manager") == "$uid" ]]
    [[ $(readlink -f "/proc/$manager/exe") == /usr/bin/xfce4-power-manager ]]
    systemctl is-active --quiet upower.service
    echo 'COMBINED_POWER packaged=1 ordinary_manager=1 system_upower=active'
fi
if [[ -f /boot/platform-tested.lock ]]; then
    [[ $(asuser gsettings get org.y700.tablet automatic-brightness) == false ]]
    ambient_pid() { pgrep -u "$uid" -f '^(/usr/bin/python3 )?/usr/libexec/y700-ambient-backlight$'; }
    wait_for 60 ambient-autostart ambient_pid >/dev/null
    test -x /usr/libexec/y700-ambient-backlight
    echo 'COMBINED_ADAPTIVE ordinary_daemon=1 automatic_brightness=false'
fi
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
if [[ -f /boot/media-tested.lock ]]; then
    media=/run/y700-media-witness
    install -d -m755 "$media"
    install -m755 /boot/media-uv "$media/uv"
    install -m644 /boot/media-{session.py,pixels.py,clip.mp4} "$media/"
    media_edition=dev12.9
    if [[ -f /boot/media-update-tested.lock ]]; then media_edition=dev12.10; fi
    mapfile -d '' -t desktop_environment < "/proc/$pid/environ"
    if [[ -f /boot/platform-desktop-update.lock.json ]]; then
        install -m644 /boot/{desktop-settings,probe}.py "$media/"
        setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env -i "${desktop_environment[@]}" \
            LANGUAGE=en LC_ALL=C.UTF-8 GDK_SCALE=2 UV_CACHE_DIR="/run/user/$uid/uv-media-check" \
            timeout 160 "$media/uv" run --offline --no-project --python /usr/bin/python3 python -B "$media/desktop-settings.py"
    fi
    if [[ -f /boot/quick-session.py ]]; then
        install -m644 /boot/quick-session.py "$media/"
        setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env -i "${desktop_environment[@]}" \
            UV_CACHE_DIR="/run/user/$uid/uv-media-check" timeout 170 "$media/uv" run --offline --no-project \
            --python /usr/bin/python3 python -B "$media/quick-session.py"
    fi
    if [[ -f /boot/camera-autofocus.lock.json ]]; then
        install -m644 /boot/camera-session.py "$media/"
        setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env -i "${desktop_environment[@]}" \
            UV_CACHE_DIR="/run/user/$uid/uv-media-check" timeout 150 "$media/uv" run --offline --no-project \
            --python /usr/bin/python3 python -B "$media/camera-session.py"
    fi
    setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env -i "${desktop_environment[@]}" \
        UV_CACHE_DIR="/run/user/$uid/uv-media-check" timeout 160 "$media/uv" run --offline --no-project \
        --python /usr/bin/python3 python -B "$media/media-session.py" "$media/media-clip.mp4" "$media_edition"
fi
if [[ -f /boot/browser-camera-desktop.lock.json ]]; then
    # This witness inherits the enrolled LightDM/Xfce user's live session.
    setpriv --reuid="$uid" --regid="$(id -g y700)" --init-groups env -i "${desktop_environment[@]}" \
        chromium --user-data-dir="/run/user/$uid/first-browser-profile" --no-first-run \
        --disable-background-networking about:blank >/run/y700-first-browser.log 2>&1 &
    browser_job=$!
    renderer() { pgrep -u "$uid" -f '^/usr/lib/chromium/chromium .*--type=renderer' | head -n1; }
    wait_for 90 chromium-renderer renderer >/dev/null
    renderer_pid=$(renderer)
    [[ $(readlink -f "/proc/$renderer_pid/exe") == /usr/lib/chromium/chromium ]]
    grep -Eq '^Seccomp:[[:blank:]]+2$' "/proc/$renderer_pid/status"
    grep -Eq '^NoNewPrivs:[[:blank:]]+1$' "/proc/$renderer_pid/status"
    kill -TERM "$browser_job"
    wait "$browser_job" || :
    echo 'COMBINED_BROWSER_CAMERA version=.5 ordinary=1 renderer=1'
fi
echo COMBINED_PASS
systemctl --no-block poweroff
