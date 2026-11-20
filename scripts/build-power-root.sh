#!/bin/bash
# Add the locked battery desktop to a copy of the generic dev12.6 filesystem.
set -euo pipefail
if [[ $EUID != 0 || $# != 3 ]]; then
    echo 'Usage (root): build-power-root.sh DEV12.6.ext4 POWER_ARCHIVES NEW_LINUX_DIRECTORY' >&2
    exit 2
fi
if [[ ${Y700_POWER_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_POWER_PRIVATE=1 bash "$0" "$@"
fi
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
parent=$(realpath -e "$1")
archives=$(realpath -e "$2")
out=$(realpath -m "$3")
[[ -f $parent && -d ${out%/*} && ! -e $out && ! -L $3 ]]
export LC_ALL=C UV_OFFLINE=1 UV_PYTHON=${UV_PYTHON:-/usr/bin/python3}
echo "74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd  $parent" | sha256sum --strict -c -
w=$(mktemp -d "${out%/*}/.y700-power-build.XXXXXXXX")
root=$w/root
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root"; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$w"/{root,result}
raw=$w/result/root.ext4
cp --sparse=always --reflink=auto -- "$parent" "$raw"
chmod 600 "$raw"
mount -o loop,nosuid,nodev "$raw" "$root"
mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
for path in run sys dev; do mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/$path"; done
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
touch "$root/.y700-disposable-build-root"
bash "$repo/scripts/add-board-layer.sh" power-desktop "$root" "$archives" | tee "$w/result/install.log"
rm -- "$root/.y700-disposable-build-root"
chmod 644 "$root/var/lib/y700/build/packages.tsv"
[[ -f $root/etc/machine-id && ! -s $root/etc/machine-id ]]
[[ $(chroot "$root" passwd -S y700 | cut -d' ' -f2) == L ]]
for path in "$root"/{etc/y700/maintenance*,etc/y700/bluetooth-address,etc/y700/user-configured,etc/ssh/ssh_host_*,home/y700/.ssh,root/.ssh,var/lib/y700-ssc/registry}; do
    [[ ! -e $path && ! -L $path ]]
done
umount -R "$root"
e2fsck -fn "$raw" >"$w/result/filesystem-check.log"
chmod 400 "$raw"
(cd "$w/result" && sha256sum root.ext4 >SHA256SUMS)
mv -T --no-clobber "$w/result" "$out"
test ! -e "$w/result"
cat "$out/SHA256SUMS"
