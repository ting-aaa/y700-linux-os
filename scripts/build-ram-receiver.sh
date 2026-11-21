#!/usr/bin/env bash
# Split the verified diskless boot into an early USB receiver and a sealed SquashFS payload.
set -euo pipefail
export LC_ALL=C
umask 077
[[ $# == 3 || $# == 5 ]] || { echo 'Usage: build-ram-receiver.sh RELEASE_IMAGES DISKLESS_BUNDLE NEW_DIRECTORY [AF_ADDON_CPIO ADDON_SHA256]' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
images=$(realpath -e -- "$1")
full=$(realpath -e -- "$2")
dest=$(realpath -m -- "$3")
[[ ! -e $dest && ! -L $dest ]]
source "$repo/scripts/build-storage-guard.sh" receiver "${dest%/*}"
work=$(mktemp -d -- "$(dirname -- "$dest")/.y700-ram-receive.XXXXXXXX")
trap 'rm -r -- "$work"' EXIT
out=$work/bundle
extra=$work/newc
mkdir -p "$out" "$extra/ram-receive/modules"
( cd "$full"; echo '2cdddecb410b4aa3d9b63b229fc8df5fc8de61b00ed3a209a34c633d82adb453  SHA256SUMS' | sha256sum --quiet -c -; sha256sum --strict --quiet -c SHA256SUMS )
( cd "$images"; printf '%s  %s\n' 5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3 root.ext4 1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091 linux-boot.fat | sha256sum --quiet -c - )
mcopy -i "$images/linux-boot.fat" ::/EFI/debian/initrd "$out/initrd"
echo "6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce  $out/initrd" | sha256sum --quiet -c -
size=$(stat -c %s "$out/initrd")
offset=$(( (size + 3) / 4 * 4 ))
cmp -n "$size" "$out/initrd" "$full/initrd"
tail -c "+$((offset+1))" "$full/initrd" | (cd "$extra" && cpio --quiet -id y700-ram-trial-init y700-root.squashfs)
mv -- "$extra/y700-root.squashfs" "$out/carrier.squashfs"
echo "ce527192a32b47eff9a5f41682e058db88f8ef4bb9421afc737655783fb0229a  $out/carrier.squashfs" | sha256sum --quiet -c -
install -m755 "$repo/src/boot/ram-receive-init" "$extra/y700-ram-receive-init"
install -m755 "$repo/src/boot/ram-receive-transfer" "$extra/ram-receive/transfer"
install -m644 "$repo/src/boot/ram-trial-storage-check" "$extra/ram-receive/storage-check"
modules=/usr/lib/modules/7.3.4-asphalt-prc
debugfs -R "cat $modules/modules.dep" "$images/root.ext4" >"$work/modules.dep"
for name in qcom_glink_smem aux-hpd-bridge fsa4480 pmic_glink pmic_glink_altmode typec_ucsi ucsi_glink; do
    mapfile -t paths < <(awk -F: -v n="/$name.ko.zst" 'substr($1,length($1)-length(n)+1)==n {print $1}' "$work/modules.dep")
    [[ ${#paths[@]} == 1 ]]
    debugfs -R "dump $modules/${paths[0]} $work/module.zst" "$images/root.ext4"
    zstd -dc "$work/module.zst" >"$extra/ram-receive/modules/$name.ko"
    rm "$work/module.zst"
    echo "$name.ko" >>"$extra/ram-receive/modules/order"
done
truncate -s "$offset" "$out/initrd"
(cd "$extra"; find . -exec touch -h -d @1795150416 {} +; find . -mindepth 1 -printf '%P\n' | sort | cpio --quiet --reproducible --owner 0:0 -o -H newc) >>"$out/initrd"
cp "$full/board.dtb" "$full/kernel.efi" "$out/"
grep -Fq 'rdinit=/y700-ram-trial-init ' "$full/cmdline.txt"
sed 's|rdinit=/y700-ram-trial-init |rdinit=/y700-ram-receive-init |' "$full/cmdline.txt" >"$out/cmdline.txt"
if [[ $# == 5 ]]; then
    [[ $5 =~ ^[a-f0-9]{64}$ && -f $4 && ! -L $4 ]]
    printf '%s  %s\n' "$5" "$4" | sha256sum --quiet -c -
    names=$(cpio -it --quiet <"$4")
    grep -Fxq y700-af-acm-init <<<"$names"
    cat -- "$4" >>"$out/initrd"
    sed -i 's/$/ y700.ram_af_acm=1/' "$out/cmdline.txt"
fi
[[ $(stat -c %s "$out/initrd") -lt 67108864 ]]
(cd "$out"; sha256sum kernel.efi board.dtb initrd cmdline.txt carrier.squashfs >SHA256SUMS)
mv -Tn -- "$out" "$dest"
[[ ! -d $out ]]
