#!/bin/bash
# Offline removal of this optional package. Keep the verified archive for reinstall.
set -euo pipefail
export LC_ALL=C
pkg=y700-usb-audio-modules
release=7.3.4-asphalt-prc
here=$(cd "$(dirname "$0")" && pwd -P)
[[ $EUID == 0 && $(uname -r) == "$release" ]]
grep -azFxq lenovo,asphalt /proc/device-tree/compatible
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
cd "$here"
deb=${pkg}_7.3.4-1_arm64.deb
echo "87450f08290edab544d0ac104f4b5475cc17212bb8a1d6342b711bb60c03ab8d  $deb" | sha256sum --strict -c - >/dev/null
status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || :)
case $status in ''|not-installed) echo 'UAC_ROLLBACK already_absent=1'; exit 0 ;; esac
[[ $(dpkg-query -W -f='${Version} ${Architecture}' "$pkg") == '7.3.4-1 arm64' ]]
notes=$(sha256sum /sys/kernel/notes)
case ${notes%% *} in
    35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6|c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063) ;;
    *) echo 'Unexpected running kernel' >&2; exit 1 ;;
esac
shopt -s nullglob
for path in /sys/bus/usb/devices/*/bInterfaceClass; do
    [[ $(<"$path") != 01 ]] || { echo 'Disconnect the USB audio accessory first' >&2; exit 1; }
done
if [[ $status == installed ]]; then
    [[ -z $(dpkg -V "$pkg") ]] || { echo 'Package files differ. Review before removing.' >&2; exit 1; }
fi
for name in snd-usb-audio snd-usbmidi-lib snd-rawmidi snd-hwdep; do
    if [[ -d /sys/module/${name//-/_} ]]; then
        file=$(modinfo -n "$name")
        [[ $(realpath -e "$file") == "/usr/lib/modules/$release/updates/$pkg/$name.ko.zst" ]]
        [[ $(dpkg-query -S "$(realpath "$file")") == "$pkg: $(realpath "$file")" ]]
        # Remove only the verified package-owned module. Busy modules fail normally.
        rmmod "${name//-/_}"
    fi
done
dpkg --purge "$pkg"
if modinfo snd-usb-audio >/dev/null 2>&1; then echo 'Driver still available' >&2; exit 1; fi
echo 'UAC_ROLLBACK absent=1 archive_retained=1'
