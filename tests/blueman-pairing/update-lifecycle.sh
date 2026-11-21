#!/bin/bash
# PC/WSL ARM64 binfmt fixture. The tested root is always the read-only lower.
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && $# == 3 ]] || { echo 'Usage as root: update-lifecycle.sh DEV1212_EXT4 BUNDLE.tar QCAM7.deb' >&2; exit 2; }
    exec unshare --mount --propagation private --net --pid --fork bash "$0" --inside "$@"
fi
shift
root=$(realpath -e "$1")
bundle=$(realpath -e "$2")
camera=$(realpath -e "$3")
printf '%s  %s\n' \
    5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3 "$root" \
    3bfbc1bf91892b621af6a2ccf86b7ef4a137583f7edcf0e0cb40c2a2f353244f "$camera" | sha256sum --strict -c -
w=$(mktemp -d /var/tmp/y700-blueman-lifecycle.XXXXXXXX)
r=$w/root
clean() {
    cd /
    if mountpoint -q "$r"; then umount -R "$r"; fi
    if mountpoint -q "$w/lower"; then umount "$w/lower"; fi
    rm -r --one-file-system -- "$w"
}
trap clean EXIT
mkdir -p "$w"/{root,lower,upper,work}
mount -t ext4 -o loop,ro,noload "$root" "$w/lower"
mount -t overlay overlay -o "lowerdir=$w/lower,upperdir=$w/upper,workdir=$w/work" "$r"
mount -t tmpfs tmpfs "$r/dev"
mknod -m666 "$r/dev/null" c 1 3
mknod -m666 "$r/dev/urandom" c 1 9
ln -s /proc/self/fd "$r/dev/fd"
mount -t proc proc "$r/proc"
mount -t tmpfs tmpfs "$r/run"
tar -xf "$bundle" -C "$r/run"
cd "$r/run/blueman-update"
sha256sum --strict -c SHA256SUMS
cp -- "$camera" "$r/run/qcam7.deb"
guest() { chroot "$r" env LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"; }
apply() { guest bash /run/blueman-update/update-blueman-manager.sh "$@"; }
inventory() {
    local ledger=$w/packages.tsv
    guest dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        sed -n 's/^installed\t//p' | sort >"$ledger"
    [[ $(wc -l <"$ledger") == 1240 ]]
    printf '%s  %s\n' "$1" "$ledger" | sha256sum --status -c -
    echo "INVENTORY_OK count=1240 sha256=$1"
}
healthy() { [[ -z $(guest dpkg --audit) ]]; guest apt-get check >/dev/null; }
qcam5_old=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
qcam5_new=9b797dbfa8759fb6e58fc567b7a502a8fd6eb8cf9fce32e4ae8f7d0918980c45
qcam7_old=a49b13a679ea89313e61858bfc139cae5f0752eedf9579e2c49a80244552792f
qcam7_new=a434ec3c41bbac02cf67df6ef0a2be3b671da0a6c92ba8bd6a68ede97157c88a
prev=blueman_2.4.4-1+y7002_arm64.deb
next=blueman_2.4.4-1+y7003_arm64.deb
inventory "$qcam5_old"
apply check
conffile=/etc/xdg/autostart/blueman.desktop
guest dpkg-query -W -f='${Conffiles}\n' blueman:arm64 | grep -Fq " $conffile "
echo '# Local autostart preference retained across the test' >>"$r$conffile"
conf_hash=$(sha256sum "$r$conffile")
cp "$next" "$r/run/original.deb"
printf X >>"$next"
if apply install; then echo 'Corrupt package was accepted' >&2; exit 1; fi
mv "$r/run/original.deb" "$next"
inventory "$qcam5_old"
apply install
inventory "$qcam5_new"
apply install >"$w/repeat"
if grep -Fxq BLUEMAN_DPKG_TRANSACTION "$w/repeat"; then exit 1; fi
grep -Fxq BLUEMAN_MANAGER_OK\ version=2.4.4-1+y7003 "$w/repeat"
apply reinstall >"$w/reinstall"
grep -Fxq BLUEMAN_DPKG_TRANSACTION "$w/reinstall"
inventory "$qcam5_new"
healthy
apply rollback
inventory "$qcam5_old"
for pair in "$next install $qcam5_new" "$prev rollback $qcam5_old"; do
    read -r deb action expected <<<"$pair"
    guest dpkg --unpack "/run/blueman-update/$deb"
    [[ $(guest dpkg-query -W -f='${db:Status-Status}' blueman:arm64) == unpacked ]]
    if apply check; then echo 'Unconfigured package was accepted' >&2; exit 1; fi
    apply "$action"
    inventory "$expected"
    healthy
done
guest dpkg --install /run/qcam7.deb
inventory "$qcam7_old"
apply install
inventory "$qcam7_new"
healthy
apply rollback
inventory "$qcam7_old"
healthy
[[ $(sha256sum "$r$conffile") == "$conf_hash" ]]
clean
trap - EXIT
[[ ! -e $w ]]
echo BLUEMAN_LIFECYCLE_PASS
