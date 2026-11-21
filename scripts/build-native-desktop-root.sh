#!/usr/bin/env bash
# Install the dev12.15 layer under the same kernel that will load its ALSA modules.
set -euo pipefail
[[ $EUID == 0 && $# == 5 ]] || { echo 'Usage as root: build-native-desktop-root.sh DEV12.14_ROOT PRIMARY_KERNEL ARM64_BUSYBOX DEBS NEW_DIRECTORY' >&2; exit 2; }
if [[ ${Y700_NATIVE_PRIVATE:-0} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_NATIVE_PRIVATE=1 bash "$0" "$@"
fi
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
umask 077
export LC_ALL=C
repo=$(cd "$(dirname "$0")/.." && pwd -P)
base=$(realpath -e "$1"); kernel=$(realpath -e "$2"); busybox=$(realpath -e "$3"); debs=$(realpath -e "$4")
parent=$(cd "$(dirname "$5")" && pwd -P); out=$parent/$(basename "$5")
[[ ! -e $out && ! -L $out ]]
source "$repo/scripts/build-storage-guard.sh" root "$parent"
lock=$repo/config/native-desktop.lock.json
basehash=32896d21a07a1c9529db3d007df788bb8ddcf4e5b6b0782527737ac7af1a3259
[[ $(jq -er .parent_root_sha256 "$lock") == "$basehash" ]]
printf '%s  %s\n' "$basehash" "$base" 0c92b63a708441d44b3e93e90f85f3f5462c08d92ffc8e224248ef7e419def60 "$kernel" \
    7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34 "$busybox" | sha256sum --strict -c -
w=$(mktemp -d "$parent/.y700-native-root.XXXXXXXX")
cleanup() {
    if mountpoint -q "$w/root"; then umount "$w/root"; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir -p "$w/init"/{bin,dev,guest,proc,sys,packages} "$w"/{root,result}
check=("${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python -B
    "$repo/scripts/verify-image-packages.py" "$w/root" --camera-lock "$repo/config/camera-layer.lock.json"
    --platform-version '0.1.0~dev12.8+gpu1.2')
mount -o loop,ro,noload,nodev,nosuid "$base" "$w/root"
"${check[@]}" > "$w/result/parent-inventory.log"
grep -Fxq 'package_digest=a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb' "$w/result/parent-inventory.log"
(cd "$w/root/var/lib/y700/build"; sha256sum *.lock.json) > "$w/result/inherited-SHA256SUMS"
umount "$w/root"
raw=$w/result/root.ext4
cp --sparse=always --reflink=auto "$base" "$raw"
chmod 600 "$raw"
cd "$w/init/packages"
while IFS=$'\t' read -r name version arch size sha; do
    file=${name}_${version}_${arch}.deb
    cp "$debs/$file" .
    [[ $(stat -c %s "$file") == "$size" && $(dpkg-deb -W --showformat='${Package}_${Version}_${Architecture}.deb' "$file") == "$file" ]]
    printf '%s  %s\n' "$sha" "$file" >> DEBS.sha256
done < <(jq -r '.packages[] | [.package,.version,.architecture,.size,.sha256] | @tsv' "$lock")
[[ $(wc -l < DEBS.sha256) == 7 ]]
sha256sum --strict -c DEBS.sha256
install -m644 "$lock" .
cd "$w/init"
install -m755 "$busybox" bin/busybox
install -m755 "$repo/scripts/native-desktop-install.init" init
find . -print0 | cpio --null --quiet -o -H newc | gzip -1 > "$w/initrd"
qemu=("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}")
if [[ -n ${QEMU_FIRMWARE_DIR:-} ]]; then qemu+=(-L "$QEMU_FIRMWARE_DIR"); fi
timeout -k 5 360 "${qemu[@]}" -machine virt,gic-version=3 -cpu max -smp 3 -m 1024 -nodefaults -no-user-config \
    -display none -nic none -serial stdio -monitor none -no-reboot -kernel "$kernel" -initrd "$w/initrd" \
    -append 'console=ttyAMA0 panic=3 loglevel=3' -drive "if=none,id=root,format=raw,file=$raw" \
    -device virtio-blk-device,drive=root </dev/null 2>&1 | tr -d '\r' | tee "$w/result/native-install.log"
grep -Fxq 'Y700_NATIVE_INSTALL_EXIT=0' "$w/result/native-install.log"
e2fsck -fn "$raw" > "$w/result/filesystem-check.log"
mount -o loop,ro,noload,nodev,nosuid "$raw" "$w/root"
"${check[@]}" | tee "$w/result/inventory.log"
grep -Fxq "package_digest=$(jq -r .package_digest "$lock")" "$w/result/inventory.log"
(cd "$w/root/var/lib/y700/build"; sha256sum --strict -c "$w/result/inherited-SHA256SUMS"; cp packages.tsv "$w/result/") > "$w/result/inherited-check.log"
(
  cd "$w/root"
  [[ $(blkid -p -s UUID -o value "$raw") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
  grep -Fxq y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f etc/y700/image-id
  [[ -f etc/machine-id && ! -s etc/machine-id && ! -L etc/machine-id && $(readlink var/lib/dbus/machine-id) == /etc/machine-id ]]
  [[ -f etc/y700/base-configured && -x usr/libexec/y700-firstboot-drm/firstboot ]]
  [[ $(readlink etc/systemd/system/graphical.target.wants/y700-firstboot.service) == /etc/systemd/system/y700-firstboot.service ]]
  [[ $(readlink etc/systemd/system/default.target) == /usr/lib/systemd/system/graphical.target ]]
  [[ $(readlink etc/systemd/system/display-manager.service) == /lib/systemd/system/lightdm.service ]]
  grep -Fxq 'ConditionPathExists=!/etc/y700/user-configured' etc/systemd/system/y700-firstboot.service
  grep -Eq '^y700:[!*]:' etc/shadow
  for path in etc/NetworkManager/system-connections var/lib/bluetooth var/lib/y700-ssc; do
      [[ ! -d $path || -z $(find "$path" -mindepth 1 -print -quit) ]]
  done
  for path in etc/y700/{maintenance*,bluetooth-address,user-configured} etc/ssh/ssh_host_* home/y700/.ssh root/.ssh \
      var/lib/{alsa/asound.state,y700/ssh,systemd/random-seed,systemd/credential.secret,NetworkManager/secret_key} \
      etc/policy-rc.d usr/sbin/policy-rc.d run/{native-build,y700-speaker-calibration} persist mnt/vendor/persist; do
      [[ ! -e $path && ! -L $path ]]
  done
  echo 'NATIVE_IMAGE_IDENTITY firstboot=drm locked_user=1 generic=1 private_material=absent'
) | tee "$w/result/identity.log"
umount "$w/root"
chmod 400 "$raw"
(cd "$w/result"; sha256sum root.ext4 > SHA256SUMS)
echo "$basehash  $base" | sha256sum --strict -c -
mv -T --no-clobber "$w/result" "$out"; [[ ! -e $w/result ]]
