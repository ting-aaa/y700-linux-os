#!/usr/bin/env bash
# The product root is attached read-only; all network changes are in the guest RAM.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
: "${KERNEL_IMAGE:?}" "${RAW_ROOT:?}" "${HWSIM_MODULE:?}" "${WIFI_DEBS:?}" "${X11_DEBS:?}"
: "${QEMU:?}" "${QEMU_DATA:?}" "${ARM64_BUSYBOX:?}" "${ARM64_UV:?}"
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
cp -- "$here/"{session.sh,xfce4-panel.xml,probe.py,fixture-guest.sh} "$payload/"
(
    cd "$work/init"
    find . -print0 | cpio --null -o -H newc --quiet | gzip -1 > "$work/initramfs.cpio.gz"
)
timeout -k 5 175 "$QEMU" -L "$QEMU_DATA" \
    -machine virt,gic-version=3 -cpu max -smp 2 -m 1024 \
    -nodefaults -no-user-config -monitor none -display none -serial stdio -nic none -no-reboot \
    -kernel "$KERNEL_IMAGE" -initrd "$work/initramfs.cpio.gz" \
    -append 'console=ttyAMA0 quiet loglevel=3 panic=5 y700.wifi_fixture=1' \
    -drive "if=none,id=root,format=raw,readonly=on,file=$RAW_ROOT" -device virtio-blk-device,drive=root \
    2>&1 | tr -d '\r' | tee "$work/guest.log"
grep -Fxq 'WIFI_VM_EXIT=0' "$work/guest.log"
grep -Fxq 'WIFI_FIXTURE_PASS nm_connected=1 nl80211_associated=1 local_dhcp=1 local_ping=1' "$work/guest.log"
