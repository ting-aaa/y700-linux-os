#!/usr/bin/env bash
# Native offline ARM64 rebuild on a disposable raw file using the parent's kernel and BusyBox.
set -euo pipefail
umask 077
if (( $# != 3 )); then
    echo "Usage: bash build-dev12.1-image.sh DEV11.1-BUNDLE DEV12.1.deb NEW-DIRECTORY" >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bundle=$(realpath -e -- "$1")
archive=$(realpath -e -- "$2")
target=$(realpath -m -- "$3")
[[ -d ${target%/*} && ! -e $target && ! -L $target && $target != / ]]
(
    cd -- "$bundle"
    echo 'ff01ef5dd5ee7fa8b1849d45087db18cc605caa29725a2884ee40d34e0d06dc1  SHA256SUMS' | sha256sum --strict -c -
    echo 'bd0358ef64776f0cec8efacdd022b8d6cc65740198c676f2a0770c56923412ce  TOOLS-SHA256SUMS' | sha256sum --strict -c -
    sha256sum --strict -c TOOLS-SHA256SUMS
)
printf '844a0996e6e9947ddc6859ef2896b91c3980816cf6b373e7335b22c07e2c6bbb  %s\n' "$archive" | sha256sum --strict -c -
scratch=$(mktemp -d --tmpdir="${target%/*}" .y700-dev12.1-build.XXXXXXXX)
trap 'rm -r --one-file-system -- "$scratch"' EXIT
bash "$bundle/unpack.sh" "$scratch/image"
cd -- "$scratch/image"
cmp SHA256SUMS "$bundle/RAW-SHA256SUMS"
echo '1ae52734b95e261fb4464ea127c7f59f0c9179b64da34de66f974c316697409b  root.ext4' | sha256sum --strict -c -
mcopy -i linux-boot.fat ::/EFI/debian/kernel.efi "$scratch/Image"
mcopy -i linux-boot.fat ::/EFI/debian/initrd "$scratch/board-initrd"
cd -- "$scratch"
sha256sum --strict -c <<'SUM'
4e23cb29a382da7d66f4476d72fd8ac3b11960749649875b00cd8453f4aa3bf1  Image
f6d5675b9f8534b96c7fc973c25747722527220c9d728260a520542fc3003427  board-initrd
SUM
mkdir -p root/{bin,dev,proc,sys,target,payload}
gzip -dc board-initrd | cpio --extract --to-stdout --quiet bin/busybox > root/bin/busybox
echo '7d93682be37cf6ed46699f6fff546b80bf133cf8ec342c2d04bc23387f78bc34  root/bin/busybox' | sha256sum --strict -c -
chmod 755 root/bin/busybox
cp -- "$here/upgrade-dev12.1-root.sh" root/payload/upgrade.sh
cp -- "$archive" root/payload/platform.deb
cat > root/init <<'GUEST'
#!/bin/busybox sh
set -eu
export PATH=/bin
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
exec </dev/console >/dev/console 2>&1
finish() {
    rc=$?
    trap - EXIT
    sync
    for d in /box/tmp /box/sys /box/proc /box/dev /box/mnt /box/etc /box/usr /target; do
        if grep -Fq " $d " /proc/mounts; then umount "$d" || rc=1; fi
    done
    sync
    echo "Y700_OFFLINE_UPGRADE_EXIT=$rc"
    poweroff -f
    while :; do sleep 1; done
}
trap finish EXIT
grep -Fq 'linux,dummy-virt' /proc/device-tree/compatible
test "$(cat /sys/block/vda/size)" = 12582912
test "$(cat /sys/block/vda/ro)" = 0
test ! -e /sys/block/vdb
mount -t ext4 /dev/vda /target
# Keep the tooling chroot on tmpfs, separate from the target ext4.
mkdir /box
for d in usr etc dev proc sys mnt tmp; do mkdir "/box/$d"; done
for d in bin sbin lib; do ln -s "usr/$d" "/box/$d"; done
mount --bind /target/usr /box/usr
mount --bind /target/etc /box/etc
mount --bind /target /box/mnt
for d in dev proc sys; do mount --bind "/$d" "/box/$d"; done
mount --bind /payload /box/tmp
chroot /box /bin/bash /tmp/upgrade.sh /mnt /tmp/platform.deb
GUEST
chmod 755 root/init
(cd root && find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --quiet | gzip -n > "$scratch/qa-initrd")
timeout -k 10 600 qemu-system-aarch64 -machine virt,gic-version=3 -cpu max -smp 2 -m 1350 \
    -nodefaults -no-user-config -display none -monitor none -serial stdio -nic none -no-reboot \
    -kernel Image -initrd qa-initrd -append 'console=ttyAMA0 loglevel=4 panic=5' \
    -drive 'file=image/root.ext4,format=raw,if=none,id=target' -device virtio-blk-device,drive=target |
    tr -d '\r' | tee upgrade.log
grep -Fxq 'Y700_OFFLINE_UPGRADE_EXIT=0' upgrade.log
grep -Fxq 'DEV12P1_SINGLE_PACKAGE_UPGRADE_PASS' upgrade.log
digest=67345abdae49f42ab640b4eef44bb10d4009f1e8d9755dd963b6c36f8bea804c
grep -Fxq "package_digest=$digest" upgrade.log
cd image
sed -i "s/^package_digest=.*/package_digest=$digest/" identity.txt
grep -Fxq 'package_count=1112' identity.txt
e2fsck -fn root.ext4
sha256sum asphalt-prc-u-boot.img linux-boot.fat root.ext4 identity.txt > SHA256SUMS
sha256sum --strict -c SHA256SUMS
cd ..
mv -T --no-clobber -- image "$target"
[[ ! -e image ]]
echo "Rebuilt dev12.1 raw board image: $target"
