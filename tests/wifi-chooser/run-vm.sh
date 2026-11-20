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
case $attempt in retry|fresh) ;; editor|onboard) [[ $security == sae && ${WIFI_ACTOR:-root} == seat ]] || exit 2;; *) exit 2;; esac
actor=${WIFI_ACTOR:-root}
case "$actor" in root|seat) ;; *) exit 2;; esac
rejoin=${WIFI_REJOIN:-0}
case $rejoin in
    0) ;;
    1|2) [[ $security == sae && $actor == seat && $attempt == fresh ]] || exit 2 ;;
    *) exit 2 ;;
esac
systemd_target=
if [[ $actor == seat ]]; then
    # This fixture attaches the root partition only, without the product ESP.
    systemd_target='fstab=no systemd.unit=y700-wifi-fixture.service systemd.show_status=no'
fi
work=$(mktemp -d /tmp/y700-wifi-vm.XXXXXXXX)
[[ $(realpath -e "$work") =~ ^/tmp/y700-wifi-vm\.[a-zA-Z0-9]{8}$ ]]
cleanup() { rm -r --one-file-system -- "$work"; }
trap cleanup EXIT
mkdir -p "$work/debian" "$work/init/"{bin,proc,sys,dev,lower,runtime,guest,test/bin,test/lib}
payload=$work/init/test
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
fi
(
    cd "$work/init"
    find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initramfs.cpio.gz"
)
budget=240
if [[ $attempt == onboard || $rejoin != 0 ]]; then budget=360; fi
timeout -k 5 "$budget" "$QEMU" -L "$QEMU_DATA" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1024 \
    -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$KERNEL_IMAGE" -initrd "$work/initramfs.cpio.gz" \
    -append "console=ttyAMA0 quiet loglevel=3 panic=5 y700.wifi_fixture=1 y700.wifi_security=$security y700.wifi_attempt=$attempt y700.wifi_actor=$actor y700.wifi_rejoin=$rejoin $systemd_target" \
    -drive "if=none,id=root,format=$root_format,readonly=on,file=$RAW_ROOT" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'WIFI_VM_EXIT=0' "$work/guest.log"
grep -Fxq 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1' "$work/guest.log"
if [[ $security != open ]]; then
    input=gtk-a11y
    if [[ $attempt == onboard ]]; then input=onboard; fi
    grep -Fxq "WIFI_SECURED_PASS security=$security input=$input attempt=$attempt" "$work/guest.log"
fi
if [[ $security == sae ]]; then grep -Fxq 'WIFI_SAE_NEGOTIATED akm=SAE pmf=1' "$work/guest.log"; fi
if [[ $attempt == editor || $attempt == onboard ]]; then
    grep -Eq '^WIFI_WRONG_REJECTED nm_state=120 nm_reason=[0-9]+$' "$work/guest.log"
    grep -Fxq 'WIFI_EDITOR saved=1 same_profile_uuid=1 other_profiles_preserved=1' "$work/guest.log"
fi
if [[ $attempt == onboard ]]; then
    [[ $(grep -Fxc 'WIFI_ONBOARD masked_entry=1 pointer_keys=16' "$work/guest.log") == 2 ]]
fi
if [[ $actor == seat ]]; then
    grep -Fxq 'WIFI_SEAT ordinary_uid=1 active=1 local=1 type=x11 network_control=yes' "$work/guest.log"
fi
if (( rejoin )); then
    [[ $(grep -Ec '^WIFI_REJOIN_RECOVERED ' "$work/guest.log") == $((rejoin + 1)) ]]
    grep -Fxq 'WIFI_REJOIN_PASS no_prompt=1 no_manual_activation=1' "$work/guest.log"
fi
