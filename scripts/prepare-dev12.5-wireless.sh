#!/usr/bin/env bash
# Apply the board's wireless-regdb selection to copies of the sealed dev12.5 root and ESP.
set -euo pipefail
if [[ $EUID != 0 || $# != 3 ]]; then
    echo 'Usage (root): prepare-dev12.5-wireless.sh FOUR_PACKAGE_ROOT.ext4 DEV12.4_ESP.fat NEW_DIRECTORY' >&2
    exit 2
fi
if [[ ${Y700_WIRELESS_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net env Y700_WIRELESS_PRIVATE=1 bash "$0" "$@"
fi
export LC_ALL=C TZ=UTC
umask 077
repo=$(cd -- "$(dirname "$0")/.." && pwd)
root=$(realpath -e -- "$1")
esp=$(realpath -e -- "$2")
out=$(realpath -m -- "$3")
[[ -f $root && -f $esp && -d ${out%/*} && ! -e $out && ! -L $out ]]
verify_sources() {
    printf '%s  %s\n' \
        ed41792877f6beac36248ae8a8314836400082d7ba22cdd55fa80085389e1410 "$root" \
        9c7dbadfe9dca55f6a5da34d564a6004a99f90ad403d1323ec6bf561ec196a22 "$esp" |
        sha256sum --strict -c -
}
verify_sources
work=$(mktemp -d -- "${out%/*}/.y700-wireless.XXXXXXXX")
cleanup() {
    for dir in mounted/run mounted original; do
        if mountpoint -q -- "$work/$dir"; then umount -- "$work/$dir"; fi
    done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{mounted,original,initrd,old-esp,new-esp,output}
cd "$work/output"
cp --sparse=always --reflink=auto -- "$root" root.ext4
cp --sparse=always --reflink=auto -- "$esp" linux-boot.fat
chmod u+w root.ext4 linux-boot.fat
mount -o loop,ro,noload,nosuid,nodev "$root" "$work/original"
mount -o loop,nosuid,nodev root.ext4 "$work/mounted"
# Nodev prevents use of the image's /dev/null. The transaction log is private tmpfs.
mount -t tmpfs -o size=1m,nodev,nosuid tmpfs "$work/mounted/run"
chroot "$work/mounted" update-alternatives --log /run/alternatives.log --set regulatory.db /lib/firmware/regulatory.db-upstream
umount "$work/mounted/run"
for name in regulatory.db regulatory.db.p7s; do
    test "$(chroot "$work/mounted" readlink -f "/lib/firmware/$name")" = "/usr/lib/firmware/$name-upstream"
    test "$(readlink "$work/original/etc/alternatives/$name")" = "/lib/firmware/$name-debian"
done
record=var/lib/dpkg/alternatives/regulatory.db
sed '1s/^auto$/manual/' "$work/original/$record" | cmp - "$work/mounted/$record"
rsync -aHAXnci --no-times --numeric-ids --delete --out-format='%n' "$work/original/" "$work/mounted/" |
    LC_ALL=C sort > "$work/root-diff"
printf '%s\n' etc/alternatives/regulatory.db etc/alternatives/regulatory.db.p7s "$record" | cmp - "$work/root-diff"
mcopy -s -i "$esp" ::/EFI ::/loader "$work/old-esp/"
initrd=EFI/debian/initrd
printf '%s  %s\n' f6d5675b9f8534b96c7fc973c25747722527220c9d728260a520542fc3003427 "$work/old-esp/$initrd" | sha256sum --strict -c -
(cd "$work/initrd"; gzip -dc "$work/old-esp/$initrd" | cpio --quiet -idm --no-absolute-filenames)
test ! -e "$work/initrd/lib/firmware/regulatory.db"
test ! -e "$work/initrd/lib/firmware/regulatory.db.p7s"
bash "$repo/scripts/stage-initrd-regdb.sh" "$work/mounted" "$work/initrd/lib/firmware"
# Pin the populated directories and new files to the published dev12.5 build time.
# GNU cpio extraction otherwise leaves populated directory mtimes at wall-clock time.
epoch=1795150416
find "$work/initrd" -type d ! -empty -exec touch -d "@$epoch" {} +
touch -d "@$epoch" "$work/initrd/lib/firmware"/regulatory.db{,.p7s}
(cd "$work/initrd"; find . -print0 | LC_ALL=C sort -z | cpio --quiet --reproducible --null -o -H newc --owner 0:0 | gzip -n -2) > "$work/new-initrd"
printf '%s  %s\n' 6d3832e03eaea523a55c6bf12f90e1cf1146a34df1a264bdeefec9c8398d00ce "$work/new-initrd" | sha256sum --strict -c -
touch -t 202611200000 "$work/new-initrd"
mcopy -o -m -i linux-boot.fat "$work/new-initrd" "::/$initrd"
fsck.fat -vn linux-boot.fat > "$work/fat-check"
mcopy -s -i linux-boot.fat ::/EFI ::/loader "$work/new-esp/"
cmp "$work/new-initrd" "$work/new-esp/$initrd"
mkdir "$work/readback"
(cd "$work/readback"; gzip -dc "$work/new-esp/$initrd" | cpio --quiet -idm --no-absolute-filenames)
rsync -aHAXnci --no-times --delete "$work/initrd/" "$work/readback/" > "$work/initrd-diff"
test ! -s "$work/initrd-diff"
for part in old-esp new-esp; do
    (cd "$work/$part"; find . -type f ! -path "./$initrd" -print0 | sort -z | xargs -0 sha256sum) > "$work/$part.sha"
done
cmp "$work/old-esp.sha" "$work/new-esp.sha"
umount "$work/mounted" "$work/original"
e2fsck -fn root.ext4
verify_sources
sha256sum linux-boot.fat root.ext4 > SHA256SUMS
sha256sum "$work/new-initrd" | cut -d' ' -f1 > initrd.sha256
cat SHA256SUMS
mv -nT -- "$work/output" "$out"
test ! -e "$work/output"
