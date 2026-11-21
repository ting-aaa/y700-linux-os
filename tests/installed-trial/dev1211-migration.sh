#!/bin/bash
# Exercise a real nested ARM64 desktop and its successor using synthetic owner data.
set -Eeuo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && $# == 5 ]] || { echo "Usage: sudo bash $0 SEALED_WIFI_ROOT OLD_ESP DEV1211_ROOT DEV1211_ESP NEW_WORKDIR" >&2; exit 2; }
    exec unshare --mount --net --ipc --pid --fork -- bash "$0" --inside "$@"
fi
shift
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
oldroot=$(realpath -e "$1"); oldfat=$(realpath -e "$2")
newroot=$(realpath -e "$3"); newfat=$(realpath -e "$4")
work=$(realpath -m "$5"); mkdir -m700 "$work"
mount --make-rprivate /
outer=$work/outer; running=$work/running; check=$work/check
store=$outer/var/lib/y700-trial; prior=$store/dev12.10
mkdir "$outer" "$running" "$check"
cleanup() {
    for path in "$check" "$running" "$outer"; do if mountpoint -q "$path"; then umount -R "$path"; fi; done
}
trap cleanup EXIT
truncate -s 54G "$work/outer.ext4"
mkfs.ext4 -q -U ef306764-2315-4235-8796-69e2c9b61946 "$work/outer.ext4"
mount -o loop "$work/outer.ext4" "$outer"
mkdir -p "$outer/etc/y700" "$outer/var/lib"
echo asphalt-prc-debian13-xfce-7.3.4-v1 >"$outer/etc/y700/image-id"
install -d -m700 "$store" "$prior"
cp --sparse=always "$oldroot" "$prior/root.ext4"; cp --sparse=always "$oldfat" "$prior/linux-boot.fat"
chmod 600 "$prior/"*
mount -o loop "$prior/root.ext4" "$running"; mount -o loop "$prior/linux-boot.fat" "$running/boot"
mount -t proc proc "$running/proc"; mount -t tmpfs tmpfs "$running/dev"; mount -t tmpfs tmpfs "$running/run"
mount -t sysfs -o ro sysfs "$running/sys"
for item in null:1:3 zero:1:5 random:1:8 urandom:1:9 loop-control:10:237; do
    IFS=: read -r name major minor <<<"$item"; mknod -m666 "$running/dev/$name" c "$major" "$minor"
done
for n in $(seq 0 255); do mknod -m600 "$running/dev/loop$n" b 7 "$n"; done
ln -s /proc/self/fd "$running/dev/fd"
mkdir -p "$running/run/initramfs/backing" "$running/run/qa"
mount --bind "$outer" "$running/run/initramfs/backing"
printf 'y700.media=file y700.release=dev12.10\n' >"$work/cmdline"
mount --bind "$work/cmdline" "$running/proc/cmdline"
install -m700 "$repo/scripts/personalize-file-install.sh" "$repo/scripts/arm-installed-trial.sh" "$running/run/qa/"
chroot "$running" /bin/bash -se <<'SETUP'
set -eu -o pipefail
umask 077
{ printf 'y700:'; head -c 24 /dev/urandom | base64; } | chpasswd
head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' >/etc/machine-id; echo >>/etc/machine-id
echo synthetic-machine >/etc/hostname
touch /etc/y700/user-configured
echo '02:ab:cd:ef:12:34' >/etc/y700/bluetooth-address
mkdir -p /etc/NetworkManager/{system-connections,conf.d} /etc/ssh/sshd_config.d \
    /etc/systemd/system/ssh.service.d /root/.ssh /var/lib/y700-ssc/registry /var/lib/bluetooth /var/lib/NetworkManager
for f in /etc/NetworkManager/system-connections/fixture /var/lib/NetworkManager/secret_key \
    /var/lib/y700-ssc/registry/fixture /var/lib/bluetooth/fixture /home/y700/saved; do head -c64 /dev/urandom >"$f"; done
chmod 640 /home/y700/saved; chown y700:y700 /home/y700/saved; ln /home/y700/saved /home/y700/hardlink
ln -s saved /home/y700/symlink; chown -h y700:y700 /home/y700/symlink
touch /etc/NetworkManager/conf.d/20-y700-usb-maintenance.conf /etc/systemd/system/ssh.service.d/usb-maintenance.conf
printf 'ListenAddress 127.0.0.1\n' >/etc/ssh/sshd_config.d/00-y700-usb-maintenance.conf
rm -f /etc/systemd/system/asphalt-usb-maintenance.service
printf '[Service]\nType=oneshot\nExecStart=/usr/local/sbin/asphalt-usb-maintenance\n[Install]\nWantedBy=multi-user.target\n' >/etc/systemd/system/asphalt-usb-maintenance.service
printf '#!/bin/sh\nexit 0\n' >/usr/local/sbin/asphalt-usb-maintenance; chmod 755 /usr/local/sbin/asphalt-usb-maintenance
ssh-keygen -A >/dev/null
cp /etc/ssh/ssh_host_ed25519_key.pub /root/.ssh/authorized_keys
SETUP
# A different candidate must never overwrite these original files.
if head -c 8192 "$newroot" | bash "$repo/scripts/stage-file-trial-images.sh" --dev12.11 "$outer" >"$work/short.log" 2>&1; then exit 1; fi
[[ ! -e $store/.dev12.11-input && ! -e $store/dev12.11 ]]
cat "$newroot" "$newfat" | bash "$repo/scripts/stage-file-trial-images.sh" --dev12.11 "$outer"
prep=$store/.dev12.11-preparing
mkdir -m700 "$prep"
printf '%s  %s\n' 33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3 root.ext4 \
    92d47c14c4606d106ebad21ece8f5e23f244bd5aecea0c377bbe8966f8261b36 linux-boot.fat >"$prep/sources.sha256"
chmod 600 "$prep/sources.sha256"
ln -s ../dev12.10/root.ext4 "$prep/root.ext4"
personal=(chroot "$running" bash /run/qa/personalize-file-install.sh --dev12.11 /run/qa/arm-installed-trial.sh)
if "${personal[@]}" >"$work/wrong-scratch.log" 2>&1; then exit 1; fi
[[ ! -e $store/dev12.11 && -L $prep/root.ext4 ]]; rm "$prep/root.ext4"
printf 'incomplete synthetic copy\n' >"$prep/root.ext4"; chmod 600 "$prep/root.ext4"
"${personal[@]}"
dest=$store/dev12.11
[[ $(cat "$dest/installed.ok") == 'dev12.11 personal files verified, USB identity retained' ]]
[[ $(stat -c %s "$dest/root.ext4") == 34359738368 &&
   $(blkid -p -s UUID -o value "$dest/root.ext4") == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e &&
   $(blkid -p -s UUID -o value "$dest/linux-boot.fat") == 31EC-3084 ]]
e2fsck -fn "$dest/root.ext4"; fsck.fat -n "$dest/linux-boot.fat"
mount -o loop,ro,noload "$dest/root.ext4" "$check"
for f in home/y700/saved home/y700/hardlink root/.ssh/authorized_keys etc/machine-id etc/y700/bluetooth-address \
    etc/NetworkManager/system-connections/fixture var/lib/y700-ssc/registry/fixture var/lib/bluetooth/fixture; do
    cmp -s "$running/$f" "$check/$f"
done
[[ "$check/home/y700/hardlink" -ef "$check/home/y700/saved" && $(stat -c '%u:%g:%a' "$check/home/y700/saved") == 1000:1000:640 ]]
[[ $(readlink "$check/home/y700/symlink") == saved ]]
[[ $(cat "$running/etc/y700/image-id") == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
[[ $(blkid -p -s UUID -o value "$prior/linux-boot.fat") == 171A-4ADB ]]
[[ $(cat "$check/etc/y700/image-id") == y700-prc-c0e447e4-82db-59ee-91d6-0e1ec9d5f45e ]]
grep -Fxq OnBootSec=4min "$check/etc/systemd/system/y700-installed-trial-deadline.timer"
if "${personal[@]}" >"$work/published.log" 2>&1; then exit 1; fi
echo 'PASS short stream and linked scratch rejected, partial work retried, owner identity and hardlinks preserved, new UUIDs, deadline, fsck and published-root protection'
