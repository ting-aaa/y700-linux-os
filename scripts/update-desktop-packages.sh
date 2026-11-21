#!/bin/bash
# Run from the extracted desktop-update bundle. Both directions work offline.
set -euo pipefail
export LC_ALL=C
die() { echo "$*" >&2; exit 1; }
[[ $EUID == 0 && $# == 1 && $1 =~ ^(install|rollback|check)$ ]] ||
    die 'Usage as root: bash update.sh install|check|rollback'
action=$1
cd -- "$(dirname -- "$0")"
exec 9>/run/y700-desktop-packages.lock
flock -n 9 || die 'Another desktop update is running.'
[[ $(dpkg --print-architecture) == arm64 ]] || die 'ARM64 Debian is required.'

# SHA256SUMS contains the six .deb rows from the original three release locks.
printf '%s  SHA256SUMS\n' 5cebbba0681c8c996423c55589c30a797b8dd6499032c55919fbc5ebe8f95425 |
    sha256sum --strict --quiet -c -
sha256sum --strict --quiet -c SHA256SUMS
packages=(y700-camera-qcam blueman ibus)
declare -A old=([y700-camera-qcam]='0.7.2-1~bpo13+1.y7005' [blueman]='2.4.4-1+y7002' [ibus]='1.5.32-2')
declare -A new=([y700-camera-qcam]='0.7.2-1~bpo13+1.y7007' [blueman]='2.4.4-1+y7003' [ibus]='1.5.32-2+0y7001')
archive() { printf './%s_%s_arm64.deb' "$1" "$2"; }
status() { dpkg-query -W -f='${db:Status-Status} ${Version} ${Architecture}\n' "$1:arm64"; }
verify_files() {
    local package=$1 version=$2 file
    local -a files
    case $package in
        y700-camera-qcam) files=(/opt/y700-camera/bin/qcam) ;;
        blueman) files=(/usr/lib/python3/dist-packages/blueman/main/{Manager.py,applet/BluezAgent.py}
                       /usr/share/blueman/ui/manager-main.ui) ;;
        ibus) files=(/usr/libexec/ibus-ui-gtk3) ;;
    esac
    for file in "${files[@]}"; do
        [[ -f $file && ! -L $file ]] || die "Missing installed file: $file"
        dpkg-deb --fsys-tarfile "$(archive "$package" "$version")" | tar -xOf - ".$file" | cmp - "$file" ||
            die "Installed file differs from the package: $file"
    done
}

target=updated
[[ $action != rollback ]] || target=original
pending=()
declare -A desired
for package in "${packages[@]}"; do
    for version in "${old[$package]}" "${new[$package]}"; do
        file=$(archive "$package" "$version")
        [[ -f $file && ! -L $file &&
           $(dpkg-deb -W --showformat='${Package} ${Version} ${Architecture}' "$file") == "$package $version arm64" ]] ||
            die "Unexpected package archive: $file"
    done
    read -r state version arch <<<"$(status "$package")"
    [[ $arch == arm64 && ( $version == "${old[$package]}" || $version == "${new[$package]}" ) ]] ||
        die "Unsupported installed version of $package: $version"
    case $state in
        installed) verify_files "$package" "$version" ;;
        unpacked|half-configured|half-installed|triggers-awaited|triggers-pending)
            [[ $action != check ]] || die "$package needs configuration. Run install or rollback." ;;
        *) die "Unexpected package state: $package $state" ;;
    esac
    if [[ $action == check ]]; then
        state=updated
        [[ $version != "${old[$package]}" ]] || state=original
        [[ $package == "${packages[0]}" || $target == "$state" ]] ||
            die 'Mixed package versions. Run install or rollback to finish.'
        target=$state
        continue
    fi
    desired[$package]=${new[$package]}
    [[ $target != original ]] || desired[$package]=${old[$package]}
    if [[ $state != installed || $version != "${desired[$package]}" ]]; then
        # Debian ibus postinst removes this obsolete path. Preserve any local copy.
        if [[ $package == ibus && ( -e /etc/xdg/autostart/ibus.desktop || -L /etc/xdg/autostart/ibus.desktop ) ]]; then
            die 'Preserve and move the local /etc/xdg/autostart/ibus.desktop before updating IBus.'
        fi
        pending+=("$(archive "$package" "${desired[$package]}")")
    fi
done
transaction=0
if (( ${#pending[@]} )); then
    dpkg --force-confold --install "${pending[@]}"
    transaction=1
    for package in "${packages[@]}"; do
        [[ $(status "$package") == "installed ${desired[$package]} arm64" ]] ||
            die "Incomplete transaction for $package. Run install or rollback."
        verify_files "$package" "${desired[$package]}"
    done
fi
apt-get --simulate --no-download check >/dev/null
printf 'DESKTOP_UPDATE transaction=%d action=%s state=%s\n' "$transaction" "$action" "$target"
