#!/usr/bin/env bash
# The product root is attached read-only; all network changes are in the guest RAM.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
: "${KERNEL_IMAGE:?}" "${RAW_ROOT:?}" "${HWSIM_MODULE:?}" "${WIFI_DEBS:?}" "${X11_DEBS:?}"
: "${QEMU:?}" "${QEMU_DATA:?}" "${ARM64_BUSYBOX:?}" "${ARM64_UV:?}"
root_format=${ROOT_FORMAT:-raw}
case $root_format in raw|qcow2) ;; *) exit 2;; esac
security=${WIFI_SECURITY:-open}
case $security in open|wpa2|sae) ;; *) exit 2;; esac
attempt=${WIFI_ATTEMPT:-retry}
case $attempt in retry|fresh) ;; editor|onboard|chooser|blocked|cancel) [[ $security == sae && ${WIFI_ACTOR:-root} == seat ]] || exit 2;; *) exit 2;; esac
touch=${WIFI_TOUCHSCREEN:-0}
[[ $touch == 0 || ( $touch == 1 && $attempt =~ ^(chooser|blocked|cancel)$ ) ]] || exit 2
actor=${WIFI_ACTOR:-root}
case "$actor" in root|seat) ;; *) exit 2;; esac
rejoin=${WIFI_REJOIN:-0}
case $rejoin in
    0) ;;
    1|2|3) [[ $security == sae && $actor == seat && $attempt == fresh ]] || exit 2 ;;
    *) exit 2 ;;
esac
systemd_target=
if [[ $actor == seat ]]; then
    # This fixture attaches the root partition only, without the product ESP.
    systemd_target='fstab=no systemd.unit=y700-wifi-fixture.service systemd.show_status=no'
fi
keyboard=${WIFI_KEYBOARD:-onboard}
case $keyboard in
    onboard) ;;
    gtk) [[ $touch == 0 && $attempt =~ ^(chooser|blocked|cancel)$ ]] || exit 2
         systemd_target+=" y700.wifi_no_onboard=1" ;;
    *) exit 2 ;;
esac
tmp=$(realpath -e "${TMPDIR:-/tmp}")
work=$(mktemp -d -- "$tmp/y700-wifi-vm.XXXXXXXX")
[[ $(realpath -e "$work") == "$tmp"/y700-wifi-vm.???????? ]]
cleanup() { rm -r --one-file-system -- "$work"; }
trap cleanup EXIT
mkdir -p "$work/debian" "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test/bin,test/lib}
payload=$work/init/test
if [[ -n ${WIFI_CANDIDATE_DEBS:-} ]]; then
    [[ $actor == seat ]]
    mkdir "$payload/candidates"
    for deb in "$WIFI_CANDIDATE_DEBS"/*.deb; do
        case $(dpkg-deb -f "$deb" Package) in network-manager|wpasupplicant) ;; *) exit 2;; esac
        [[ $(dpkg-deb -f "$deb" Architecture) == arm64 ]]
        cp "$deb" "$payload/candidates/"
        sha256sum "$deb"
    done
fi
if [[ -n ${WIFI_AP_DEBS:-} ]]; then
    [[ $security == sae && $rejoin == 0 ]]
    modern=$(realpath -e "$WIFI_AP_DEBS")
    (cd "$modern" && sha256sum --quiet --strict -c "$here/hostapd-2.11.sha256")
    while read -r _ deb; do dpkg-deb -x "$modern/$deb" "$work/ap"; done < "$here/hostapd-2.11.sha256"
    mkdir -p "$payload/ap-2.11/lib"
    cp "$work/ap/usr/sbin/hostapd" "$payload/ap-2.11/"
    cp -a "$work/ap/usr/lib/aarch64-linux-gnu"/libnl*.so.200* "$payload/ap-2.11/lib/"
fi
if (( touch )); then
    printf '%s  %s\n' 5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "${DUMMY_DEB:?ARM64 Xorg dummy driver}" | sha256sum --strict -c -
    cp "$DUMMY_DEB" "$payload/dummy.deb"
    cp "$here/../video-player/dummy.conf" "$payload/xorg.conf"
    "${AARCH64_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -Wextra -Werror -static "$here/../touch-gestures/evdev-touch.c" -o "$payload/bin/evdev-touch"
    cp "$here/touch-display.sh" "$payload/"
    systemd_target+=" y700.touch_gesture_fixture=1 y700.wifi_touch=1"
fi
for deb in "$WIFI_DEBS/"{hostapd,dnsmasq-base,iw,libnftables1}_*.deb "$X11_DEBS/"{xvfb,xdotool,libxdo3}_*.deb; do
    dpkg-deb -x "$deb" "$work/debian"
done
cp -- "$work/debian/usr/bin/Xvfb" "$payload/bin/"
cp -- "$work/debian/usr/bin/xdotool" "$payload/bin/xdotool.real"
cp -L -- "$work/debian/usr/lib/aarch64-linux-gnu/libxdo.so.3" "$payload/lib/"
cp -L -- "$work/debian/usr/lib/aarch64-linux-gnu/libnftables.so.1" "$payload/lib/"
for binary in hostapd hostapd_cli dnsmasq iw; do
    if [[ -e $work/debian/usr/sbin/$binary ]]; then
        cp -- "$work/debian/usr/sbin/$binary" "$payload/bin/"
    else
        cp -- "$work/debian/usr/bin/$binary" "$payload/bin/"
    fi
done
cat > "$payload/bin/xdotool" <<'TOOL'
#!/bin/sh
exec /lib/ld-linux-aarch64.so.1 --library-path "${0%/*}/../lib" "${0%/*}/xdotool.real" "$@"
TOOL
chmod 755 "$payload/bin/xdotool"
install -m755 "$ARM64_UV" "$payload/bin/uv"
install -m755 "$ARM64_BUSYBOX" "$work/init/bin/busybox"
install -m755 "$here/fixture-init.sh" "$work/init/init"
install -m644 "$HWSIM_MODULE" "$payload/mac80211_hwsim.ko"
cp -- "$here/"{session.sh,xfce4-panel.xml,probe.py,fixture-guest.sh,prepare-ap.py} "$payload/"
install -m755 "$here/fixture-systemd.sh" "$here/seat-actor.sh" "$payload/"
cp -- "$here/fixture-seat.service" "$payload/"
if (( rejoin )); then
    install -m644 -D "$here/../wifi-rejoin/cycles.sh" "$payload/rejoin/cycles.sh"
    install -m644 "$here/../wifi-rejoin/observer.py" "$payload/rejoin/observer.py"
    if (( rejoin == 3 )); then
        install -m644 "$here/../wifi-rejoin/crossband.sh" "$here/../wifi-rejoin/stream.py" "$payload/rejoin/"
    fi
fi
(
    cd "$work/init"
    find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initramfs.cpio.gz"
)
budget=240
cpus=2
ram=1024
if [[ $attempt =~ ^(onboard|chooser|blocked|cancel)$ || $rejoin != 0 ]]; then budget=460; fi
if [[ $attempt =~ ^(chooser|blocked|cancel)$ ]]; then cpus=3; ram=1280; fi
timeout -k 5 "$budget" "$QEMU" -L "$QEMU_DATA" \
    -machine virt,gic-version=3 -cpu max -smp "$cpus" -m "$ram" \
    -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$KERNEL_IMAGE" -initrd "$work/initramfs.cpio.gz" \
    -append "console=ttyAMA0 quiet loglevel=3 panic=5 y700.wifi_fixture=1 y700.wifi_security=$security y700.wifi_attempt=$attempt y700.wifi_actor=$actor y700.wifi_rejoin=$rejoin $systemd_target" \
    -drive "if=none,id=root,format=$root_format,readonly=on,file=$RAW_ROOT" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'WIFI_VM_EXIT=0' "$work/guest.log"
if [[ $attempt == blocked ]]; then
    grep -Fxq 'WIFI_SEAT ordinary_uid=1 active=1 local=1 type=x11 network_control=yes' "$work/guest.log"
    grep -Fxq 'WIFI_STOCK_RETRY reselected=1 second_password=0 seconds=50 same_uuid=1 other_profiles_preserved=1' "$work/guest.log"
    grep -Fxq 'WIFI_BASELINE_PASS station_disconnected=1' "$work/guest.log"
    exit
fi
grep -Fxq 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1' "$work/guest.log"
if [[ $security != open ]]; then
    input=gtk-a11y
    if [[ $attempt =~ ^(onboard|chooser|cancel)$ && $keyboard == onboard ]]; then input=onboard; fi
    grep -Fxq "WIFI_SECURED_PASS security=$security input=$input attempt=$attempt" "$work/guest.log"
fi
if [[ $security == sae ]]; then grep -Fxq 'WIFI_SAE_NEGOTIATED akm=SAE pmf=1' "$work/guest.log"; fi
if [[ $attempt == editor || $attempt == onboard ]]; then
    grep -Eq '^WIFI_WRONG_REJECTED nm_state=120 nm_reason=[0-9]+$' "$work/guest.log"
    grep -Fxq 'WIFI_EDITOR saved=1 same_profile_uuid=1 other_profiles_preserved=1' "$work/guest.log"
fi
if [[ $attempt =~ ^(onboard|chooser|cancel)$ && $keyboard == onboard ]]; then
    source=pointer
    if (( touch )); then source=touch; fi
    [[ $(grep -Fxc "WIFI_ONBOARD masked_entry=1 ${source}_keys=16" "$work/guest.log") == 2 ]]
fi
if [[ $attempt == chooser || $attempt == cancel ]]; then
    grep -Eq '^WIFI_CHOOSER_RECOVERY prompt=(automatic|reselected) same_uuid=1 other_profiles_preserved=1$' "$work/guest.log"
    if [[ -n ${WIFI_CANDIDATE_DEBS:-} && -n ${WIFI_AP_DEBS:-} ]]; then
        grep -Fxq 'WIFI_SAE_PROPERTY AuthStatusCode=15' "$work/guest.log"
        grep -Eq '^WIFI_NM_PROMPTS automatic=[1-9][0-9]* explicit=0$' "$work/guest.log"
    fi
fi
if [[ $actor == seat ]]; then
    grep -Fxq 'WIFI_SEAT ordinary_uid=1 active=1 local=1 type=x11 network_control=yes' "$work/guest.log"
fi
if (( rejoin )); then
    if (( rejoin == 3 )); then
        grep -Fq 'WIFI_TCP_BANDS mhz=2412,5180,2412 one_connection=1' "$work/guest.log"
    else
        [[ $(grep -Ec '^WIFI_REJOIN_RECOVERED ' "$work/guest.log") == $((rejoin + 1)) ]]
    fi
    grep -Fxq 'WIFI_REJOIN_PASS no_prompt=1 no_manual_activation=1' "$work/guest.log"
fi
