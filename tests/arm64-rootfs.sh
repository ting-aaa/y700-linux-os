#!/usr/bin/env bash
# Runtime verification via ARM64 QEMU user emulation, never starts SSH or GPU.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
root=$(realpath -e "${1:?disposable integrated rootfs}")
test "$(id -u)" -eq 0
test "$root" != / && test -f "$root/.y700-disposable-build-root"
for path in etc/y700/maintenance.env etc/y700/maintenance-sshd.conf \
    etc/y700/maintenance-authorized-keys etc/NetworkManager/conf.d/20-y700-maintenance.conf; do
    test ! -e "$root/$path" && test ! -L "$root/$path"
done
test ! -e "$root/var/lib/y700/ssh"
temp=$(mktemp -d)
cleanup() {
    rm -rf -- "$temp" "$root/var/lib/y700/ssh"
    rm -f -- "$root/etc/y700/maintenance.env" "$root/etc/y700/maintenance-sshd.conf" \
        "$root/etc/y700/maintenance-authorized-keys" "$root/etc/NetworkManager/conf.d/20-y700-maintenance.conf"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -C y700-build-test -f "$temp/client"
"${UV_BIN:-uv}" run --python "${UV_PYTHON:-3.13}" --no-project python "$repo/scripts/provision-maintenance.py" \
    --output "$temp/overlay" --device-cidr 192.0.2.1/24 --host-address 192.0.2.2 \
    --user y700 --public-key "$temp/client.pub"
cp -a "$temp/overlay/." "$root/"
install -d -m755 "$root/run/sshd"
install -d -m700 "$root/run/y700-build-test"
chroot "$root" /usr/libexec/y700-maintenance-hostkey
first=$(sha256sum "$root/var/lib/y700/ssh/ssh_host_ed25519_key")
chroot "$root" /usr/libexec/y700-maintenance-hostkey
test "$first" = "$(sha256sum "$root/var/lib/y700/ssh/ssh_host_ed25519_key")"
chroot "$root" sshd -t -f /etc/y700/maintenance-sshd.conf
chroot "$root" sshd -T -f /etc/y700/maintenance-sshd.conf > "$temp/policy"
grep -Fxq 'listenaddress 192.0.2.1:22' "$temp/policy"
grep -Fxq 'permitrootlogin no' "$temp/policy"
grep -Fxq 'passwordauthentication no' "$temp/policy"
grep -Fxq 'disableforwarding yes' "$temp/policy"
grep -Fxq 'allowusers y700@192.0.2.2' "$temp/policy"
test "$(readlink "$root/etc/systemd/system/ssh.service")" = /dev/null
test "$(readlink "$root/etc/systemd/system/ssh.socket")" = /dev/null
test "$(stat -c %a "$root/usr/lib/systemd/system/y700-usb-maintenance.service")" = 644
chroot "$root" apt-get check
test -z "$(chroot "$root" dpkg --audit)"
systemd-analyze --root="$root" verify y700-usb-maintenance.service y700-maintenance-sshd.service
chroot "$root" env XDG_RUNTIME_DIR=/run/y700-build-test dbus-run-session -- sh -c 'gsettings set org.onboard.window.landscape dock-height 420; test "$(gsettings get org.onboard.window.landscape dock-height)" = 420'
echo 'PASS: ARM64 package dependencies, SSH effective policy/host-key persistence, systemd units, keyboard settings.'
echo 'No listener, desktop, USB gadget, GPU, sensor or board boot was exercised.'
