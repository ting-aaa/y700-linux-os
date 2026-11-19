#!/usr/bin/env bash
# Install one optional, locked archive set in an offline Debian build root.
set -euo pipefail
if (( $# != 3 )); then
    echo 'Usage: add-board-layer.sh firstboot-touch|firstboot-drm|warm-greeter|ssc|blueman|chinese-ime|xorg-dsi|camera-qcam|camera-pipewire|camera-portal DISPOSABLE_ARM64_ROOT ARCHIVES' >&2
    exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
layer=$1
case $layer in firstboot-touch|firstboot-drm|warm-greeter|ssc|blueman|chinese-ime|xorg-dsi|camera-qcam|camera-pipewire|camera-portal) ;; *) echo 'Unknown board layer' >&2; exit 2 ;; esac
root=$(realpath -e -- "$2")
archives=$(realpath -e -- "$3")
lock=$repo/config/$layer.lock.json
test "$(id -u)" = 0
test "$root" != /
test -f "$root/.y700-disposable-build-root"
test ! -L "$root/.y700-disposable-build-root"
test ! -d "$root/run/systemd/system"
test "$(chroot "$root" dpkg --print-architecture)" = arm64
test -d "$root/tmp"
test ! -L "$root/tmp"
record=$root/var/lib/y700/build
case $layer in
    firstboot-touch|firstboot-drm)
        test -x "$root/usr/local/sbin/y700-firstboot"
        test -f "$root/etc/systemd/system/y700-firstboot.service"
        if [[ $layer == firstboot-drm ]]; then
            test -s "$record/firstboot-touch.lock.json"
            test -x "$root/usr/libexec/y700-firstboot/with-keyboard"
        fi
        ;;
    camera-qcam|camera-pipewire)
        test -s "$record/camera-layer.lock.json"
        test -x "$root/opt/y700-camera/bin/cam"
        ;;
esac
py=("${UV_BIN:-uv}" run --no-project --python "${UV_PYTHON:-3.13}" python)
stage=$(mktemp -d "$root/tmp/y700-board-layer.XXXXXXXX")
policy=$root/usr/sbin/policy-rc.d
cleanup() {
    if [[ $stage/no-service-starts -ef $policy ]]; then rm -f -- "$policy"; fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
cp -- "$archives/"*.deb "$stage/"
"${py[@]}" "$repo/scripts/repair-inputs.py" verify "$stage" "$lock"
if [[ $layer == blueman || $layer == xorg-dsi ]]; then
    "${py[@]}" "$repo/scripts/verify-image-packages.py" "$root" --check-upgrade "$layer"
fi
debs=()
for path in "$stage/"*.deb; do debs+=("${path#"$root"}"); done
printf '#!/bin/sh\nexit 101\n' > "$stage/no-service-starts"
chmod 755 "$stage/no-service-starts"
# The hard link claims the path exclusively, including against a dangling symlink.
ln -- "$stage/no-service-starts" "$policy"
chroot "$root" env SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
chroot "$root" apt-get check
test -z "$(chroot "$root" dpkg --audit)"
case $layer in
    chinese-ime)
        test -x "$root/usr/bin/ibus-daemon"
        test -x "$root/usr/libexec/ibus-x11"
        test -x "$root/usr/libexec/ibus-engine-libpinyin"
        test -x "$root/usr/libexec/y700-display-language"
        test -f "$root/usr/share/applications/y700-display-language.desktop"
        test -s "$root/etc/X11/Xsession.d/35y700_account_language"
        test -s "$root/etc/X11/Xsession.d/70im-config_launch"
        test -s "$root/usr/lib/aarch64-linux-gnu/gtk-3.0/3.0.0/immodules/im-ibus.so"
        grep -Fq '<name>libpinyin</name>' "$root/usr/share/ibus/component/libpinyin.xml"
        ;;
    blueman)
        test -x "$root/usr/bin/blueman-applet"
        test -s "$root/etc/xdg/autostart/blueman.desktop"
        ;;
    xorg-dsi)
        test -x "$root/usr/lib/xorg/Xorg"
        test -s "$root/usr/lib/xorg/modules/drivers/modesetting_drv.so"
        ;;
    firstboot-touch)
        test -x "$root/usr/libexec/y700-firstboot/with-keyboard"
        test -x "$root/usr/libexec/y700-firstboot/buffyboard"
        ;;
    firstboot-drm)
        test -x "$root/usr/libexec/y700-firstboot-drm/firstboot"
        test -x "$root/usr/libexec/y700-firstboot-drm/unl0kr"
        test -x "$root/usr/libexec/y700-firstboot-drm/enroll"
        grep -Fxq 'ExecStart=/usr/libexec/y700-firstboot-drm/firstboot' \
            "$root/usr/lib/systemd/system/y700-firstboot.service.d/60-drm-keyboard.conf"
        ;;
    warm-greeter)
        test -s "$root/usr/share/xgreeters/arctica-greeter.desktop"
        selection=$(chroot "$root" /usr/sbin/lightdm --show-config 2>&1)
        grep -Fq 'greeter-session=arctica-greeter' <<< "$selection"
        ;;
    ssc)
        test -x "$root/usr/libexec/y700-ssc/sdsprpcd"
        test -x "$root/usr/libexec/y700-ssc/import-calibration"
        test -s "$root/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/slpi.mdt"
        test ! -L "$root/etc/systemd/system/multi-user.target.wants/y700-ssc.service"
        ;;
    camera-qcam)
        test -x "$root/usr/bin/y700-camera"
        test -x "$root/opt/y700-camera/bin/qcam"
        test -s "$root/usr/share/applications/org.y700.Camera.desktop"
        ;;
    camera-pipewire)
        plugin=/usr/lib/aarch64-linux-gnu/spa-0.2/libcamera/libspa-libcamera.so
        libraries=$(chroot "$root" env -u LD_LIBRARY_PATH ldd "$plugin")
        for lib in libcamera.so.0.7 libcamera-base.so.0.7; do
            grep -Fq "$lib => /opt/y700-camera/lib/$lib " <<< "$libraries"
        done
        if grep -Fq 'not found' <<< "$libraries"; then
            echo "Unresolved camera plugin dependency: $libraries" >&2
            exit 1
        fi
        test -s "$root/etc/chromium.d/zz-y700-camera"
        test -s "$root/opt/y700-camera/etc/libcamera/configuration.yaml"
        test -s "$root/usr/share/wireplumber/wireplumber.conf.d/65-y700-camera.conf"
        ;;
    camera-portal)
        test -x "$root/usr/libexec/xdg-desktop-portal"
        test -x "$root/usr/libexec/xdg-desktop-portal-gtk"
        grep -Fq 'org.freedesktop.impl.portal.Access' "$root/usr/share/xdg-desktop-portal/portals/gtk.portal"
        ;;
esac
install -d "$record"
install -m644 "$lock" "$stage/$layer.lock.json"
mv -T -- "$stage/$layer.lock.json" "$record/$layer.lock.json"
chroot "$root" dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > "$stage/packages.tsv"
mv -T -- "$stage/packages.tsv" "$record/packages.tsv"
"${py[@]}" "$repo/scripts/verify-image-packages.py" "$root"
