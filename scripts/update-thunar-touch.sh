#!/bin/bash
# Both Debian packages stay together for offline installation and rollback.
set -euo pipefail
export LC_ALL=C
die() { echo "$*" >&2; exit 1; }
[[ $# == 1 && $1 =~ ^(check|install|reinstall|rollback|verify-archives)$ ]] ||
    die 'Usage: update-thunar-touch.sh check|install|reinstall|rollback|verify-archives'
action=$1
cd -- "$(dirname -- "$0")"
original=4.20.2-1+deb13u1
updated=$original+y7001
archive() { printf './thunar_%s_arm64.deb' "$1"; }
for version in "$original" "$updated"; do
    deb=$(archive "$version")
    [[ -f $deb && ! -L $deb ]] || die "Missing archive $deb."
    [[ $(dpkg-deb -W --showformat='${Package} ${Version} ${Architecture}' "$deb") == "thunar $version arm64" ]] ||
        die "Unexpected package metadata in $deb."
done
printf '%s  %s\n' \
    f390240509b742d58c35a50bad12d31e9168e557ddb6dcf708e26724c4a33ea7 "$(archive "$original")" \
    f0ecf50c5fbbd36acdeaab07efc3787bdef7be853fc06a4e94747b4aa67b9dee "$(archive "$updated")" |
    sha256sum --strict --quiet -c -
if [[ $action == verify-archives ]]; then echo THUNAR_ARCHIVES_OK; exit 0; fi
[[ $EUID == 0 && $(dpkg --print-architecture) == arm64 ]] || die 'Run as root on ARM64 Debian.'

# apt/dpkg use a POSIX fcntl lock here. Linux OFD locks conflict with it;
# hold one from the version check through dpkg, including deliberate rollback.
exec 9<>/var/lib/dpkg/lock-frontend
flock --fcntl --nonblock 9 || die 'The package manager is busy. Retry when it finishes.'
state() { dpkg-query -W -f='${db:Status-Status} ${Version} ${Architecture}\n' "$1"; }
verify_binary() {
    [[ -x /usr/bin/thunar && ! -L /usr/bin/thunar && $(readlink /usr/bin/Thunar) == thunar ]] || return 1
    dpkg-deb --fsys-tarfile "$(archive "$1")" | tar -xOf - ./usr/bin/thunar | cmp - /usr/bin/thunar
}
[[ $(state thunar-data) == "installed $original all" ]] || die 'The matching Debian thunar-data revision is required.'
read -r status current arch <<<"$(state thunar:arm64)"
[[ $arch == arm64 && ( $current == "$original" || $current == "$updated" ) ]] ||
    die 'Unsupported installed Thunar version. Keep the newer or locally managed package.'
case $status in
    installed) if [[ $action != reinstall ]]; then verify_binary "$current" || die 'Thunar files differ. Use reinstall to restore the installed version.'; fi ;;
    unpacked|half-installed|half-configured|triggers-pending|triggers-awaited)
        [[ $action != check ]] || die "Thunar is $status. Run install or rollback to finish." ;;
    *) die "Unsupported package state: $status." ;;
esac
target=$current
case $action in
    install) target=$updated ;;
    rollback) target=$original ;;
esac
transaction=0
if [[ $target != "$current" || $status != installed || $action == reinstall ]]; then
    DPKG_FRONTEND_LOCKED=1 dpkg --force-confold --install "$(archive "$target")" 9>&-
    transaction=1
fi
[[ $(state thunar:arm64) == "installed $target arm64" ]]
verify_binary "$target"
printf 'THUNAR_UPDATE action=%s transaction=%s version=%s\n' "$action" "$transaction" "$target"
