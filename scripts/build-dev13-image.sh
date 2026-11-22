#!/usr/bin/env bash
# Assemble the unified full-hardware TB320FC_PRC Debian 13 (dev13.0) standalone release archive
# from the sealed dev12.13 + dev12.15 desktop base and the verified hw-bringup-02 kernel/modules/topology/UCM2.
set -euo pipefail
export LC_ALL=C TZ=UTC
umask 077

if [[ $# != 5 || $EUID != 0 ]]; then
    echo 'Usage as root: build-dev13-image.sh DEV1213_TAR DEV1215_TAR HW_BUILD_DIR TX3_TPLG NEW_OUT_DIR' >&2
    exit 2
fi

dev1213_tar=$(realpath -e -- "$1")
dev1215_tar=$(realpath -e -- "$2")
hw_build=$(realpath -e -- "$3")
tx3_tplg=$(realpath -e -- "$4")
out=$(realpath -m -- "$5")
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
epoch=${SOURCE_DATE_EPOCH:-1795219200}

[[ -f $dev1213_tar && -f $dev1215_tar && -d $hw_build && -f $tx3_tplg ]]
[[ ! -e $out && ! -L $out && -d ${out%/*} ]]

source "$repo/scripts/build-storage-guard.sh" board "${out%/*}"

# 1. Verify hardware inputs
(cd "$hw_build" && sha256sum --strict --quiet -c SHA256SUMS)
[[ $(sha256sum "$tx3_tplg" | awk '{print $1}') == aa6d0c1a904bafa20915528cae810ee08560d262f174c52465c386629e1b6422 ]]
for f in Lenovo-Y700.conf HiFi-Mic.conf Mic.conf; do
    [[ -f "$repo/packaging/microphone/$f" ]]
done
[[ -f "$repo/docs/DEV13.0-IMAGE.md" ]]

work=$(mktemp -d -- "${out%/*}/.y700-dev13-build.XXXXXXXX")
mnt=$work/mnt
cleanup() {
    cd /
    if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
    if [[ -d $work ]]; then rm -r --one-file-system -- "$work"; fi
}
trap cleanup EXIT

mkdir -p "$work/d15" "$mnt" "$work/efi_stage" "$work/result"

echo "=== [1/5] Unpacking sealed dev12.15 base image (dev12.13 + dev12.15 delta) ==="
tar -xf "$dev1215_tar" -C "$work/d15"
bash "$work/d15/y700-tb320fc-prc-debian-dev12.15/unpack.sh" "$dev1213_tar" "$work/images"
(cd "$work/images" && sha256sum --strict -c SHA256SUMS)
chmod u+w "$work/images/root.ext4" "$work/images/linux-boot.fat"

boot="$work/images/asphalt-prc-u-boot.img"
esp="$work/images/linux-boot.fat"
root="$work/images/root.ext4"
boot_sha=$(sha256sum "$boot" | awk '{print $1}')
[[ $boot_sha == f6c60193471b75f930f792e46aa832999d59403b9083c582a3d7e132beac34a8 ]]

echo "=== [2/5] Updating EFI FAT32 partition with unified full-hardware kernel + DTB + fallback ==="
export MTOOLSRC=/dev/null
mcopy -i "$esp" ::/EFI/debian/kernel.efi "$work/efi_stage/kernel-dev12.efi"
mcopy -i "$esp" ::/EFI/debian/board.dtb "$work/efi_stage/board-dev12.dtb"
mcopy -i "$esp" ::/loader/entries/debian.conf "$work/efi_stage/debian.orig.conf"

cp "$hw_build/kernel.efi" "$work/efi_stage/kernel.efi"
cp "$hw_build/board.dtb" "$work/efi_stage/board.dtb"

sed '1c title Y700 dev13.0 (Full Hardware: 60/120 Hz, Mic, Dual Haptics, Flash, AF)' \
    "$work/efi_stage/debian.orig.conf" > "$work/efi_stage/debian.conf"

sed -e '1c title Y700 dev13.0 (Fallback dev12.15 kernel)' \
    -e 's|^linux .*|linux /EFI/debian/kernel-dev12.efi|' \
    -e 's|^devicetree .*|devicetree /EFI/debian/board-dev12.dtb|' \
    -e 's/^sort-key debian$/sort-key debian-fallback/' \
    "$work/efi_stage/debian.orig.conf" > "$work/efi_stage/debian-fallback.conf"

touch -d "@$epoch" "$work/efi_stage"/{kernel.efi,board.dtb,kernel-dev12.efi,board-dev12.dtb,debian.conf,debian-fallback.conf}
mcopy -o -m -i "$esp" "$work/efi_stage/kernel.efi" ::/EFI/debian/kernel.efi
mcopy -o -m -i "$esp" "$work/efi_stage/board.dtb" ::/EFI/debian/board.dtb
mcopy -o -m -i "$esp" "$work/efi_stage/kernel-dev12.efi" ::/EFI/debian/kernel-dev12.efi
mcopy -o -m -i "$esp" "$work/efi_stage/board-dev12.dtb" ::/EFI/debian/board-dev12.dtb
mcopy -o -m -i "$esp" "$work/efi_stage/debian.conf" ::/loader/entries/debian.conf
mcopy -o -m -i "$esp" "$work/efi_stage/debian-fallback.conf" ::/loader/entries/debian-fallback.conf
mdel -i "$esp" ::/loader/entries/debian-120.conf 2>/dev/null || true

[[ $(stat -c %s "$esp") == 1073741824 && $(blkid -p -s UUID -o value "$esp") == 171A-4ADB ]]
fsck.fat -n "$esp"

echo "=== [3/5] Installing 15 kernel modules, AudioReach TX3 topology, and fixed UCM2 into root.ext4 ==="
mount -o loop "$root" "$mnt"

modroot="$mnt/usr/lib/modules/7.3.4-asphalt-prc"
[[ -d "$modroot/kernel" ]]
while IFS= read -r -d '' ko; do
    rel=${ko#"$hw_build/modules/"}
    mkdir -p "$modroot/kernel/$(dirname "$rel")"
    zstd --quiet -f -19 "$ko" -o "$modroot/kernel/${rel}.zst"
    chmod 0644 "$modroot/kernel/${rel}.zst"
done < <(find "$hw_build/modules" -name '*.ko' -type f -print0 | sort -z)

depmod -b "$mnt" 7.3.4-asphalt-prc

install -Dm644 "$tx3_tplg" "$mnt/usr/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin"
mkdir -p "$mnt/usr/share/alsa/ucm2/Lenovo-Y700"
install -m644 "$repo/packaging/microphone/Lenovo-Y700.conf" "$mnt/usr/share/alsa/ucm2/Lenovo-Y700/Lenovo-Y700.conf"
install -m644 "$repo/packaging/microphone/HiFi-Mic.conf" "$mnt/usr/share/alsa/ucm2/Lenovo-Y700/HiFi-Mic.conf"
install -m644 "$repo/packaging/microphone/Mic.conf" "$mnt/usr/share/alsa/ucm2/Lenovo-Y700/Mic.conf"

mkdir -p "$mnt/etc/modules-load.d"
cat > "$mnt/etc/modules-load.d/y700-hw-dev13.conf" <<'MODS'
# Unified Y700 TB320FC_PRC hardware drivers verified in dev13.0
aw86927
v4l2-flash-led-class
leds-qcom-flash
soundwire-qcom
snd-soc-wcd938x-sdw
snd-soc-wcd938x
MODS
chmod 0644 "$mnt/etc/modules-load.d/y700-hw-dev13.conf"

sed -i 's/^IMAGE_VERSION=.*/IMAGE_VERSION=dev13.0/' "$mnt/etc/os-release"
grep -Fxq 'IMAGE_VERSION=dev13.0' "$mnt/etc/os-release"

mkdir -p "$mnt/var/lib/y700/build"
(
    cd "$mnt"
    sha256sum \
        usr/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin \
        usr/share/alsa/ucm2/Lenovo-Y700/Lenovo-Y700.conf \
        usr/share/alsa/ucm2/Lenovo-Y700/HiFi-Mic.conf \
        usr/share/alsa/ucm2/Lenovo-Y700/Mic.conf \
        etc/modules-load.d/y700-hw-dev13.conf \
        $(find "$hw_build/modules" -name '*.ko' -type f | sed "s|^$hw_build/modules/|usr/lib/modules/7.3.4-asphalt-prc/kernel/|; s|$|.zst|" | sort) \
        > "$mnt/var/lib/y700/build/dev13.0-hardware.sha256"
)
cp "$hw_build/notes" "$mnt/var/lib/y700/build/dev13.0-kernel.notes"
chmod 0644 "$mnt/var/lib/y700/build/dev13.0-hardware.sha256" "$mnt/var/lib/y700/build/dev13.0-kernel.notes"

# Export package ledger from dpkg inside root
dpkg-query --admindir="$mnt/var/lib/dpkg" -W '-f=${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
    sed -n 's/^installed\t//p' | sort > "$work/packages.tsv"
package_count=$(wc -l < "$work/packages.tsv")
package_sha=$(sha256sum "$work/packages.tsv" | awk '{print $1}')

sync
umount "$mnt"

echo "=== [4/5] Verifying root.ext4 generic-image and first-boot invariants ==="
[[ $(stat -c %s "$root") == 6442450944 ]]
[[ $(blkid -p -o value -s UUID "$root") == 171a4adb-916b-4763-9e6f-722b4a99988f ]]
e2fsck -fy "$root" || [[ $? == 1 ]]
e2fsck -fn "$root"
[[ $(debugfs -R 'cat /etc/y700/image-id' "$root" 2>/dev/null) == y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f ]]
debugfs -R "dump /etc/machine-id $work/machine-id" "$root" >/dev/null 2>&1
[[ -f "$work/machine-id" && ! -s "$work/machine-id" ]]
for priv in /etc/y700/bluetooth-address /etc/y700/user-configured /var/lib/y700-ssc/registry; do
    msg=$(debugfs -R "stat $priv" "$root" 2>&1 | tail -1)
    [[ ${msg% } == "$priv: File not found by ext2_lookup" ]]
done
debugfs -R 'cat /etc/shadow' "$root" 2>/dev/null | awk -F: '$1=="y700"{locked=($2 ~ /^[!*]/)} END{exit !locked}'

root_sha=$(sha256sum "$root" | awk '{print $1}')
esp_sha=$(sha256sum "$esp" | awk '{print $1}')
notes_sha=$(sha256sum "$hw_build/notes" | awk '{print $1}')

echo "=== [5/5] Packaging standalone reproducible y700-tb320fc-prc-debian-dev13.0.tar ==="
name=y700-tb320fc-prc-debian-dev13.0
bundle="$work/$name"
base="$bundle/base"
mkdir -p "$bundle" "$base"

cat > "$base/identity.txt" <<EOF
image_id=y700-prc-171a4adb-916b-4763-9e6f-722b4a99988f
root_uuid=171a4adb-916b-4763-9e6f-722b4a99988f
image_version=dev13.0
package_count=$package_count
package_digest=$package_sha
kernel_notes_sha256=$notes_sha
fbdev_emulation=0
EOF

cd "$base"
zstd -q -T4 -3 "$boot" -o asphalt-prc-u-boot.img.zst
zstd -q -T4 -3 "$esp" -o linux-boot.fat.zst
zstd -q -T4 -3 "$root" -o root.ext4.zst
chmod 600 -- *.zst
{
    printf '%s  %s\n' "$boot_sha" asphalt-prc-u-boot.img "$esp_sha" linux-boot.fat "$root_sha" root.ext4
    sha256sum identity.txt
} > RAW-SHA256SUMS
sha256sum asphalt-prc-u-boot.img.zst linux-boot.fat.zst root.ext4.zst identity.txt RAW-SHA256SUMS > SHA256SUMS
install -m755 "$repo/scripts/unpack-kms-image.sh" unpack.sh

cd "$bundle"
install -m755 "$repo/scripts/unpack-kms-update.sh" unpack.sh
install -m644 "$repo/scripts/prepare-bluetooth-identity.py" .
install -m644 "$repo/docs/DEV13.0-IMAGE.md" README.md
sha256sum base/SHA256SUMS base/unpack.sh unpack.sh prepare-bluetooth-identity.py README.md > SHA256SUMS
bash unpack.sh --verify

cd "$work/result"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$epoch" \
    -cf "$name.tar" -C "$work" "$name"
install -m644 "$work/packages.tsv" packages.tsv
cp "$base/RAW-SHA256SUMS" RAW-SHA256SUMS
cp "$base/identity.txt" identity.txt
sha256sum "$name.tar" packages.tsv > SHA256SUMS
sha256sum --strict -c SHA256SUMS

cd /
mv -T --no-clobber -- "$work/result" "$out"
echo "DEV13_IMAGE_PACK_PASS out=$out packages=$package_count root_sha=$root_sha esp_sha=$esp_sha"
cat "$out/SHA256SUMS"
cat "$out/RAW-SHA256SUMS"
