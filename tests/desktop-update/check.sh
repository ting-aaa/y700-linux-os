#!/bin/bash
# Run on a PC with ARM64 binfmt support. Every dpkg call targets a disposable overlay.
set -euo pipefail
export LC_ALL=C

if [[ ${1:-} != --inside ]]; then
    if [[ $EUID != 0 || $# != 2 ]]; then
        echo 'Usage as root: check.sh SEALED_ROOT.ext4 OFFLINE.tar' >&2
        exit 2
    fi
    exec unshare --mount --propagation private --net --pid --fork --kill-child \
        bash "$0" --inside "$@"
fi
shift
[[ $$ == 1 ]] || { echo 'The fixture must run under its private PID namespace.' >&2; exit 1; }
root=$(realpath -e "$1")
archive=$(realpath -e "$2")
root_sha=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
archive_sha=d684a33b0a7cdfa420ba99c303eb0f1609f458871d543695a1405fa61ec69195
original=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
updated=073a8831c0a7aa8cda470b59208cbfb258f546cd5e39cd36a792367959fb7430
printf '%s  %s\n' "$root_sha" "$root" "$archive_sha" "$archive" | sha256sum --strict --status -c -
echo "INPUT_OK root=$root_sha bundle=$archive_sha"

w=$(mktemp -d /var/tmp/y700-desktop-update.XXXXXXXX)
r=$w/root
cleanup() {
    cd /
    if mountpoint -q "$r"; then umount -R "$r" || return 1; fi
    if mountpoint -q "$w/lower"; then umount "$w/lower" || return 1; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$r" "$w"/{lower,upper,work}
mount -t ext4 -o loop,ro,noload "$root" "$w/lower"
mount -t overlay overlay -o "lowerdir=$w/lower,upperdir=$w/upper,workdir=$w/work" "$r"
mount -t tmpfs -o mode=0755 tmpfs "$r/dev"
mknod -m 666 "$r/dev/null" c 1 3
mknod -m 666 "$r/dev/zero" c 1 5
mknod -m 666 "$r/dev/random" c 1 8
mknod -m 666 "$r/dev/urandom" c 1 9
ln -s /proc/self/fd "$r/dev/fd"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
mount -t tmpfs -o mode=0755 tmpfs "$r/run"
tar --no-same-owner -xf "$archive" -C "$r/run"
bundle=/run/desktop-update
cd "$r$bundle"
sha256sum --strict --status -c SHA256SUMS
debs=(*.deb)
[[ ${#debs[@]} == 6 ]]
guest() {
    chroot "$r" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
        SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive "$@"
}
[[ $(guest dpkg --print-architecture) == arm64 ]]
inventory() {
    local ledger=$w/ledger
    guest dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort >"$ledger"
    if [[ ${2:-} == with-extra ]]; then
        local extra=$'y700-qa-user-utility\t1.0\tall'
        [[ $(wc -l <"$ledger") == 1241 ]]
        grep -Fxq "$extra" "$ledger"
        echo "EXTRA_PACKAGE_OK count=1241 sha256=$(sha256sum "$ledger" | cut -d' ' -f1)"
        grep -Fvx "$extra" "$ledger" >"$w/base.tsv"
        ledger=$w/base.tsv
    fi
    [[ $(wc -l <"$ledger") == 1240 ]]
    printf '%s  %s\n' "$1" "$ledger" | sha256sum --status -c -
    echo "INVENTORY_OK count=1240 sha256=$1"
}
healthy() {
    guest dpkg --audit >"$w/audit"
    [[ ! -s $w/audit ]]
    guest apt-get --no-download check >/dev/null
}
apply() { guest /bin/bash "$bundle/update.sh" "$1"; }
verify_action() {
    if ! apply "$1" >"$w/result" 2>&1; then cat "$w/result" >&2; return 1; fi
    grep -Fx "DESKTOP_UPDATE transaction=$2 action=$1 state=$3" "$w/result"
}
dpkg_fingerprint() {
    sha256sum "$r/var/lib/dpkg/status"
    if [[ -f $r/var/log/dpkg.log ]]; then sha256sum "$r/var/log/dpkg.log"; fi
}
reject_without_transaction() {
    local before
    before=$(dpkg_fingerprint)
    if apply "$1" >"$w/result" 2>&1; then
        echo "Unexpected success: $1 $2" >&2
        return 1
    fi
    [[ $(dpkg_fingerprint) == "$before" ]]
    echo "REJECTION_OK action=$1 case=$2 dpkg_unchanged=1"
}
idempotent() {
    local before
    before=$(dpkg_fingerprint)
    verify_action "$1" 0 "$2"
    [[ $(dpkg_fingerprint) == "$before" ]]
    echo "IDEMPOTENT_OK action=$1 dpkg_unchanged=1"
}

inventory "$original"
healthy
verify_action check 0 original
conf=/etc/xdg/autostart/blueman.desktop
guest dpkg-query -W -f='${Conffiles}\n' blueman:arm64 | grep -Fq " $conf "
echo '# Site preference retained during desktop maintenance' >>"$r$conf"
conf_before=$(sha256sum "$r$conf")

new_ibus=ibus_1.5.32-2+0y7001_arm64.deb
cp "$new_ibus" "$r/run/pristine.deb"
printf X >>"$new_ibus"
reject_without_transaction install corrupt-deb
mv "$r/run/pristine.deb" "$new_ibus"
local_ibus=$r/etc/xdg/autostart/ibus.desktop
[[ ! -e $local_ibus && ! -L $local_ibus ]]
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Local IBus preference' >"$local_ibus"
local_ibus_before=$(sha256sum "$local_ibus")
reject_without_transaction install local-ibus-autostart
[[ $(sha256sum "$local_ibus") == "$local_ibus_before" ]]
mv "$local_ibus" "$r/run/retained-local-ibus.desktop"
inventory "$original"
verify_action install 1 updated
inventory "$updated"
verify_action check 0 updated
idempotent install updated
healthy
verify_action rollback 1 original
inventory "$original"
verify_action check 0 original
idempotent rollback original
healthy

guest dpkg --force-confold --install "$bundle/y700-camera-qcam_0.7.2-1~bpo13+1.y7007_arm64.deb" \
    >"$w/mixed.log" 2>&1
[[ $(guest dpkg-query -W -f='${db:Status-Status}/${Version}' y700-camera-qcam) == installed/0.7.2-1~bpo13+1.y7007 ]]
reject_without_transaction check mixed-installed
guest dpkg --force-confold --unpack "$bundle/$new_ibus" >"$w/partial.log" 2>&1
[[ $(guest dpkg-query -W -f='${db:Status-Status}' ibus:arm64) == unpacked ]]
reject_without_transaction check mixed-unpacked
verify_action install 1 updated
inventory "$updated"
healthy
verify_action check 0 updated
guest dpkg --force-confold --unpack "$bundle/blueman_2.4.4-1+y7002_arm64.deb" \
    >"$w/partial-back.log" 2>&1
[[ $(guest dpkg-query -W -f='${db:Status-Status}' blueman:arm64) == unpacked ]]
reject_without_transaction check rollback-unpacked
verify_action rollback 1 original
inventory "$original"
verify_action check 0 original
healthy
mkdir -p "$r/run/qa-extra/DEBIAN"
cat >"$r/run/qa-extra/DEBIAN/control" <<'EOF'
Package: y700-qa-user-utility
Version: 1.0
Architecture: all
Maintainer: Desktop Test <qa@example.invalid>
Description: Empty local package for the desktop maintenance test
EOF
guest dpkg-deb -b /run/qa-extra /run/qa-extra.deb >/dev/null
guest dpkg --install /run/qa-extra.deb >"$w/extra.log" 2>&1
inventory "$original" with-extra
verify_action check 0 original
verify_action install 1 updated
inventory "$updated" with-extra
verify_action check 0 updated
verify_action rollback 1 original
inventory "$original" with-extra
verify_action check 0 original
healthy
[[ $(sha256sum "$r$conf") == "$conf_before" ]]
[[ ! -e $w/lower/run/desktop-update ]]
echo 'CONFFILE_OK retained=1'
cleanup
trap - EXIT
[[ ! -e $w ]]
printf '%s  %s\n' "$root_sha" "$root" | sha256sum --strict --status -c -
echo 'DESKTOP_UPDATE_LIFECYCLE_PASS offline=1 read_only_lower=1 mount_cleanup=1'
