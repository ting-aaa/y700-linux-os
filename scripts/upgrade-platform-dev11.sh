#!/usr/bin/env bash
# Upgrade the qualified dev10 tablet and preserve its previously unowned speaker profile.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
umask 077
usage() { echo 'Usage: upgrade-platform-dev11.sh install DEV10.deb DEV11.1.deb | rollback' >&2; exit 2; }
fail() { echo "$1" >&2; exit 1; }
old=y700-platform_0.1.0~dev10_all.deb
new=y700-platform_0.1.0~dev11.1_all.deb
old_sha=8a670313ed52c48f7615b415246757fa069cd99527c65c0a16309ac56f884233
new_sha=f322973f3bc774d2ce14e18f279a4bfdb49999ef7cc680fa50a4b5d7a928bb1d
profile=/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf
stock=1ba9c514c4aae63f849e8bd64c1d90d2541ae45854379101db65896630770110
fixed=a3fa9c79d3c0233825d34c3dfd5376d0243e02e1af3445a80d73d50c8d09cd36
base=/var/backups
saved=$base/y700-platform-dev10-to-dev11

case ${1:-} in
    install) (( $# == 3 )) || usage ;;
    rollback) (( $# == 1 )) || usage ;;
    *) usage ;;
esac
(( EUID == 0 )) || fail 'Run as root on the installed tablet.'
[[ $(dpkg --print-architecture) == arm64 ]] || fail 'An ARM64 Debian installation is required.'
exec 9>/run/lock/y700-platform-dev11.lock
flock -n 9 || fail 'Another dev11 upgrade or rollback is running.'
hash() { sha256sum < "$1" | cut -d' ' -f1; }
owner() { dpkg-query -S "$profile" 2>/dev/null || :; }
version() { dpkg-query -W -f='${Version}' y700-platform; }
ready() { [[ $(dpkg-query -W -f='${db:Status-Status}' y700-platform) == installed ]]; }
verified() {
    local files audit
    ready && files=$(dpkg -V y700-platform) && [[ -z $files ]] &&
        audit=$(dpkg --audit) && [[ -z $audit ]] && apt-get check >/dev/null
}
intact() {
    [[ -f $profile && ! -L $profile && $(stat -c '%u:%g:%a' -- "$profile") == 0:0:644 && $(hash "$profile") == "$1" ]]
}
temp=
replacement=
cleanup() {
    if [[ -n $replacement ]]; then rm -f -- "$replacement"; fi
    if [[ -n $temp ]]; then rm -rf -- "$temp"; fi
}
trap cleanup EXIT

case $(version) in '0.1.0~dev10'|'0.1.0~dev11'|'0.1.0~dev11.1') ;; *) fail 'Expected the qualified dev10 or dev11 series.' ;; esac
if [[ $1 == install ]]; then
    [[ $(hash "$2") == "$old_sha" && $(hash "$3") == "$new_sha" ]] || fail 'Package checksum mismatch.'
    if [[ ! -e $saved && ! -L $saved ]]; then
        [[ $(version) == '0.1.0~dev10' ]] && verified && intact "$stock" && [[ -z $(owner) ]] ||
            fail 'The original dev10 package and unowned speaker profile must be intact.'
        temp=$(mktemp -d "$base/.y700-platform-dev11.XXXXXXXX")
        cp -- "$2" "$temp/$old"
        cp -- "$3" "$temp/$new"
        cp -- "$profile" "$temp/HiFi.conf"
        [[ $(hash "$temp/$old") == "$old_sha" && $(hash "$temp/$new") == "$new_sha" &&
           $(hash "$temp/HiFi.conf") == "$stock" ]] || fail 'Backup copy verification failed.'
        mv -T -- "$temp" "$saved"
        temp=
    fi
fi
[[ -d $saved && ! -L $saved && $(stat -c '%u:%g:%a' -- "$saved") == 0:0:700 ]] || fail 'Missing private dev10 backup.'
[[ $(hash "$saved/$old") == "$old_sha" && $(hash "$saved/HiFi.conf") == "$stock" ]] || fail 'Stored rollback files differ.'
if [[ -e $profile || -L $profile ]]; then
    intact "$stock" || intact "$fixed" || fail 'The speaker profile has local changes.'
fi
case $1 in
    install)
        if [[ ! -e $saved/$new ]]; then
            replacement=$(mktemp "$saved/.new-package.XXXXXXXX")
            cp -- "$3" "$replacement"
            [[ $(hash "$replacement") == "$new_sha" ]] || fail 'Dev11.1 archive copy failed.'
            mv -T -- "$replacement" "$saved/$new"
            replacement=
        fi
        [[ $(hash "$saved/$new") == "$new_sha" ]] || fail 'Stored dev11.1 archive differs.'
        if ! ready || [[ $(version) != '0.1.0~dev11.1' ]] || ! intact "$fixed"; then
            dpkg --force-confold -i "$saved/$new"
        fi
        intact "$fixed" && [[ $(owner) == "y700-platform: $profile" ]] && verified ||
            fail 'Dev11 verification failed. The dev10 rollback files are available.'
        echo 'Dev11.1 installed and verified.'
        ;;
    rollback)
        if ! ready || [[ $(version) != '0.1.0~dev10' ]]; then
            dpkg --force-confold -i "$saved/$old"
        fi
        [[ -z $(owner) ]] || fail 'Another package owns the speaker profile.'
        if ! intact "$stock"; then
            replacement=$(mktemp "$(dirname -- "$profile")/.HiFi.conf.XXXXXXXX")
            install -m644 -- "$saved/HiFi.conf" "$replacement"
            mv -T -- "$replacement" "$profile"
            replacement=
        fi
        intact "$stock" && verified || fail 'Dev10 restoration did not verify.'
        echo 'Dev10 and its original speaker profile restored.'
        ;;
esac
