#!/bin/bash
# Migrate one TB320FC_PRC installation into its independently staged dev12.10 root.
set -Eeuo pipefail
set +x
umask 077
export LC_ALL=C
trap 'echo "Installation preparation stopped at line $LINENO" >&2' ERR
if [[ $EUID != 0 || $# != 0 ]]; then echo 'Run as root on the installed PRC Debian baseline.' >&2; exit 2; fi
if [[ ${Y700_INSTALL_NS:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_INSTALL_NS=1 bash "$0"
fi
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
[[ $(findmnt -nro UUID -M /) == ef306764-2315-4235-8796-69e2c9b61946 ]]
[[ $(findmnt -nro UUID -M /boot) == B6D4-FA81 && $(cat /etc/y700/image-id) == asphalt-prc-debian13-xfce-7.3.4-v1 ]]
dir=/var/lib/y700-trial/dev12.10
image=$dir/root.ext4
[[ $(realpath -e "$image") == "$image" && $(findmnt -nro TARGET -T "$image") == / ]]
[[ $(stat -c '%u:%g:%a:%h' "$image") == 0:0:600:1 && $(stat -c '%u:%g:%a' "$dir") == 0:0:700 ]]
exec {lock}<"$dir"
flock -n "$lock"
[[ -z $(losetup -j "$image") && ! -e $dir/installed.ok && ! -L $dir/installed.ok ]]
[[ $(findmnt -nro FSTYPE -T /run) == tmpfs && $(df -B1 --output=avail /run | tail -1) -gt $(du -s -B1 /home/y700 | cut -f1)+134217728 ]]
[[ $(id -u y700):$(id -g y700) == 1000:1000 && $(passwd -S y700 | cut -d' ' -f2) == P ]]
[[ -f /etc/y700/user-configured ]]
original=18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd
if [[ ! -e $dir/resize-source.sha256 ]]; then
    printf '%s  %s\n' "$original" "$image" | sha256sum --strict -c -
    printf '%s\n' "$original" > "$dir/resize-source.sha256"
fi
[[ $(cat "$dir/resize-source.sha256") == "$original" ]]
size=$(stat -c %s "$image")
[[ $size == 6442450944 || $size == 34359738368 ]]
[[ $(blkid -p -o value -s UUID "$image") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
e2fsck -fn "$image" >/dev/null
fallocate -l 34359738368 "$image"
fsck_rc=0
e2fsck -fp "$image" >/dev/null || fsck_rc=$?
[[ $fsck_rc == 0 || $fsck_rc == 1 ]]
resize2fs "$image" >/dev/null
e2fsck -fn "$image" >/dev/null
tmp=$(mktemp -d /run/y700-install-personal.XXXXXXXX)
new=$tmp/root
mkdir "$new"
cleanup() {
    if mountpoint -q "$new"; then umount -R "$new"; fi
    if ! mountpoint -q "$new"; then rm -r --one-file-system -- "$tmp"; fi
}
trap cleanup EXIT
mount -o loop,rw "$image" "$new"
[[ $(cat "$new/etc/y700/image-id") == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
[[ $(sha256sum "$new/var/lib/y700/build/video-player.lock.json" | cut -d' ' -f1) == 39cd516bc47679ba3c7980dc3ed43a43c1bac80e40fba690c85d33d9794fd5eb ]]
[[ $(chroot "$new" id -u y700):$(chroot "$new" id -g y700) == 1000:1000 ]]
for path in etc etc/ssh home root var/lib; do [[ $(realpath -e "$new/$path") == "$new/$path" ]]; done
mount -t tmpfs -o nosuid tmpfs "$new/dev"
for node in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$new/dev/${node%:*}" c 1 "${node#*:}"; done
mount -t tmpfs -o nosuid,nodev tmpfs "$new/run"
mount -t proc -o nosuid,nodev,noexec proc "$new/proc"
install -d -m755 "$new/run/sshd"

# Archive on the tablet so user files and device credentials stay on this device.
tar --one-file-system --numeric-owner --acls --xattrs --xattrs-include='*' \
    -cf "$tmp/home.tar" -C /home y700
tar --numeric-owner --acls --xattrs --xattrs-include='*' -xpf "$tmp/home.tar" -C "$new/home"
tar --numeric-owner --acls --xattrs --xattrs-include='*' -df "$tmp/home.tar" -C "$new/home" > "$tmp/home-diff"
[[ ! -s $tmp/home-diff ]]
copy_path() {
    local path=$1
    [[ -e /$path && ! -L /$path && $(realpath -e "/$path") == "/$path" ]]
    [[ ! -L $new/$path ]]
    mkdir -p -- "$new/${path%/*}"
    if [[ -d /$path ]]; then
        mkdir -p -- "$new/$path"
        cp -aT -- "/$path" "$new/$path"
        diff -qr --no-dereference "/$path" "$new/$path" > "$tmp/compare"
    else
        cp -a -- "/$path" "$new/$path"
        cmp "/$path" "$new/$path"
    fi
}
# The generic image masks the previous board's USB service until a device is provisioned.
systemctl --root="$new" unmask asphalt-usb-maintenance.service ssh.service
for path in etc/machine-id etc/hostname etc/hosts etc/y700/user-configured etc/y700/bluetooth-address \
    etc/NetworkManager/system-connections etc/NetworkManager/conf.d/20-y700-usb-maintenance.conf \
    etc/systemd/system/asphalt-usb-maintenance.service etc/systemd/system/ssh.service.d/usb-maintenance.conf \
    usr/local/sbin/asphalt-usb-maintenance etc/ssh/sshd_config.d/00-y700-usb-maintenance.conf \
    root/.ssh/authorized_keys; do copy_path "$path"; done
chmod 700 "$new/root/.ssh"
for path in var/lib/NetworkManager/secret_key var/lib/bluetooth var/lib/y700-ssc; do
    if [[ -e /$path ]]; then copy_path "$path"; fi
done
for key in /etc/ssh/ssh_host_*_key; do copy_path "${key#/}"; copy_path "${key#/}.pub"; done
# Retain the existing user's password, age and expiry without exposing its hash.
awk -F: 'NR==FNR {if ($1=="y700") u=$0; next}
    $1=="y700" {if (!u || seen++) exit 2; print u; next} {print}
    END {if (seen!=1) exit 3}' /etc/shadow "$new/etc/shadow" > "$tmp/shadow"
cat "$tmp/shadow" > "$new/etc/shadow"
[[ $(chroot "$new" passwd -S y700 | cut -d' ' -f2) == P ]]
for group in $(id -Gn y700); do
    if chroot "$new" getent group "$group" >/dev/null; then chroot "$new" usermod -aG "$group" y700; fi
done
systemctl --root="$new" disable y700-usb-maintenance.service y700-maintenance-sshd.service
systemctl --root="$new" enable asphalt-usb-maintenance.service ssh.service
chroot "$new" /usr/sbin/sshd -t
chroot "$new" /usr/sbin/sshd -T > "$tmp/sshd"
[[ $(grep -c '^listenaddress ' "$tmp/sshd") == 1 ]]
if grep -Eq '^listenaddress (0\.0\.0\.0|\[::\])' "$tmp/sshd"; then
    echo 'The maintenance SSH configuration would listen on a wildcard address.' >&2
    exit 1
fi
chroot "$new" dpkg-query -W -f='${Version}\n' parole | grep -Fxq '4.18.2-1+y7002'
[[ -z $(chroot "$new" dpkg --audit) ]]
sync -f "$new"
umount -R "$new"
[[ -z $(losetup -j "$image") ]]
e2fsck -fn "$image" >/dev/null
printf '%s\n' 'dev12.10 personal files verified, USB identity retained' > "$dir/installed.ok"
sync -f "$dir"
echo 'Y700_INSTALL_PERSONAL_PASS root_size_gib=32 home=verified account=retained wifi=verified bluetooth=verified usb_ssh=validated'
