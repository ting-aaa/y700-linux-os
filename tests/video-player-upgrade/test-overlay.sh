#!/bin/bash
# Exercise the actual archive with Debian arm64 dpkg on a disposable dev12.9 layer.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $# == 2 && $EUID == 0 ]] || { echo 'Usage: test-overlay.sh DEV12.9_ROOT.ext4 UPDATE.tar.gz' >&2; exit 2; }
    exec unshare --mount --pid --fork --mount-proc --net bash "$0" --inside "$@"
fi
shift
[[ $$ == 1 ]]
mount --make-rprivate /
work=$(mktemp -d "${TMPDIR:-/var/tmp}/y700-player-update.XXXXXXXX")
root=$work/root
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root"; fi
    if mountpoint -q "$work/base"; then umount "$work/base"; fi
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
echo "e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb  $1" | sha256sum -c -
mkdir "$root" "$work"/{upper,work,base}
mount -o loop,ro,noload "$1" "$work/base"
mount -t overlay overlay -o "lowerdir=$work/base,upperdir=$work/upper,workdir=$work/work" "$root"
mount -t proc proc "$root/proc"
mount -t tmpfs -o nosuid tmpfs "$root/run"
mount -t tmpfs tmpfs "$root/dev"
for x in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${x%:*}" c 1 "${x#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
tar -xzf "$2" -C "$root/run"
chroot "$root" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C bash -eu <<'TEST'
set -o pipefail
cd /run/y700-player-update
plugin=/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so
status=/var/lib/dpkg/status
identity() { stat -c '%i:%Y:%s' "$plugin" "$status"; }
reject() { if bash install.sh "$1"; then echo "Unexpected success: $1" >&2; exit 1; fi; }
bash install.sh check
bash install.sh verify-stock
reject verify
baseline=$(identity)
# Reject a corrupted bundle, a locally replaced destination, and a missing inherited receipt.
printf 'z' >> candidate/libgstvideo4linux2.so
reject install
truncate -s -1 candidate/libgstvideo4linux2.so
[[ $(identity) == "$baseline" ]]
mv "$plugin" "$plugin.orig"
ln -s "$plugin.orig" "$plugin"
reject install
rm "$plugin"
printf 'unknown' > "$plugin"
reject install
mv -fT "$plugin.orig" "$plugin"
receipt=/var/lib/y700/build/video-player.lock.json
mv "$receipt" "$receipt.hold"
reject install
mv "$receipt.hold" "$receipt"
[[ $(identity) == "$baseline" ]]
echo 'NEGATIVE_PASS corrupt_archive redirected_private_ELF unknown_private_ELF missing_image_receipt'
# Simulate a stopped update at a real dpkg unpack boundary; the following call configures it.
mv /usr/bin/dpkg /usr/bin/dpkg.qa-real
cat >/usr/bin/dpkg <<'WRAP'
#!/bin/sh
if [ "$1" = --force-confold ] && [ "$2" = -i ] && [ -e /run/interrupt-unpack ]; then
    rm /run/interrupt-unpack
    /usr/bin/dpkg.qa-real --force-confold --unpack "$3" || exit $?
    exit 73
fi
exec /usr/bin/dpkg.qa-real "$@"
WRAP
chmod 755 /usr/bin/dpkg
touch /run/interrupt-unpack
set +e
bash install.sh install
rc=$?
set -e
[[ $rc == 73 && $(dpkg-query -W '-f=${db:Status-Status}' parole) == unpacked ]]
cmp stock/libgstvideo4linux2.so "$plugin"
mv -fT /usr/bin/dpkg.qa-real /usr/bin/dpkg
reject verify
old_mtime=$(stat -c %Y "$plugin")
bash install.sh install &
first=$!
bash install.sh install &
second=$!
wait "$first"
wait "$second"
bash install.sh verify
reject verify-stock
[[ $(stat -c %Y "$plugin") -gt $old_mtime && $(stat -c '%u:%g:%a:%h' "$plugin") == 0:0:644:1 ]]
current=$(identity)
bash install.sh install
[[ $(identity) == "$current" ]]
echo 'RETRY_PASS unpacked_package configured concurrent_install idempotent same_size_ELF_mtime_advanced'
candidate_mtime=$(stat -c %Y "$plugin")
bash install.sh rollback
bash install.sh verify-stock
[[ $(stat -c %Y "$plugin") -gt $candidate_mtime ]]
before=$(identity)
bash install.sh rollback
[[ $(identity) == "$before" ]]
[[ ! -e /var/lib/y700/build/.y700-player-update-pending ]]
apt-get check
echo 'ROLLBACK_PASS stock_package_inventory private_r2 launcher system_plugin stock_receipt'
TEST
cmp "$root/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so" "$work/base/usr/local/lib/y700-parole/gstreamer-1.0/libgstvideo4linux2.so"
echo 'PLAYER_UPDATE_OVERLAY_PASS'
