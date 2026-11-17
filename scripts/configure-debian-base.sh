#!/usr/bin/env bash
# Prepare a newly built package base, not a live installation.
# Derived from the historical configure-rootfs recipe; image access is explicit.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
root=$(realpath -e "${1:?fresh base root directory}")
test "$(id -u)" -eq 0
test "$root" != /
test -f "$root/.y700-base-packages-complete"
test -f "$root/.y700-disposable-build-root"
test ! -e "$root/etc/y700/base-configured"
test ! -d "$root/run/systemd/system"
install -d "$root/etc/y700" "$root/usr/local/sbin" "$root/etc/systemd/system"
printf 'y700-linux\n' > "$root/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 y700-linux\n::1 localhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
printf 'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\n' > "$root/etc/locale.gen"
chroot "$root" locale-gen
printf 'LANG=en_US.UTF-8\n' > "$root/etc/default/locale"
ln -sfn /usr/share/zoneinfo/Asia/Shanghai "$root/etc/localtime"
printf 'Asia/Shanghai\n' > "$root/etc/timezone"
ln -sfn /run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
chroot "$root" useradd -m -s /bin/bash -G sudo,audio,video,input,render,netdev,bluetooth y700
chroot "$root" passwd -l root
chroot "$root" passwd -l y700
printf '# Board-specific storage and boot configuration is a later image stage.\n' > "$root/etc/fstab"
printf 'y700-debian13-development\n' > "$root/etc/y700/image-id"
# Retain the explicit, unsatisfied touch-only enrollment gate: this historical
# console setup is reproducible but is not the final product onboarding UX.
install -m755 "$repo/reference/y700-linux/rootfs-overlay/y700-firstboot" "$root/usr/local/sbin/y700-firstboot"
install -m644 "$repo/reference/y700-linux/rootfs-overlay/y700-firstboot.service" "$root/etc/systemd/system/"
systemctl --root="$root" enable NetworkManager.service bluetooth.service lightdm.service y700-firstboot.service
systemctl --root="$root" set-default graphical.target
systemctl --root="$root" disable docker.service docker.socket containerd.service
: > "$root/etc/machine-id"
if [[ -f "$root/var/lib/dbus/machine-id" && ! -L "$root/var/lib/dbus/machine-id" ]]; then
    rm -- "$root/var/lib/dbus/machine-id"
fi
ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
touch "$root/etc/y700/base-configured"
echo 'Fresh base configured; board image assembly and touch-only enrollment remain separate gates.'
