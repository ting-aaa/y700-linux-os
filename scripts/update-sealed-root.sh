#!/bin/bash
# Apply one locked layer to a copy of its sealed generic predecessor.
set -euo pipefail
if (( EUID != 0 || $# != 4 )); then
    echo 'Usage (root): update-sealed-root.sh power-desktop|blueman|platform SEALED_ROOT.ext4 LOCKED_ARCHIVES NEW_LINUX_DIRECTORY' >&2
    exit 2
fi
if [[ ${Y700_POWER_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork --ipc env Y700_POWER_PRIVATE=1 bash "$0" "$@"
fi
layer=$1
shift
prior_args=(--sealed-blueman-y7001)
case $layer in
    power-desktop)
        parent_sha=74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd
        inventory_sha=bbb696086ce1bb4a425dbf63876f12548e7e6a6048ed89415e64cb6a793eba6a
        lock_args=(--sealed-blueman-y7001)
        ;;
    blueman)
        parent_sha=dd885eb7bc88e3fb87b0567ff7f382afbe079363910d6f0fd5b4bb41935e220a
        inventory_sha=685d01f30932a5dd7df5ccbf99c66f3908e29c5cdeda2b7abe91d727f9c09511
        lock_args=(--platform-version '0.1.0~dev12.6')
        ;;
    platform)
        parent_sha=869745fbe9e9eacb2eb981731b2b8bc6ad162756282a2244f297063a7f79a5a4
        inventory_sha=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
        prior_args=(--platform-version '0.1.0~dev12.6')
        lock_args=()
        ;;
    *) echo "Unsupported image layer: $layer" >&2; exit 2 ;;
esac
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
parent=$(realpath -e "$1")
archives=$(realpath -e "$2")
out=$(realpath -m "$3")
[[ -f $parent && -d ${out%/*} && ! -e $out && ! -L $3 ]]
export LC_ALL=C UV_OFFLINE=1 UV_PYTHON=${UV_PYTHON:-/usr/bin/python3}
echo "$parent_sha  $parent" | sha256sum --strict -c -
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
check=("${UV_BIN:-uv}" run --offline --no-project --python "$UV_PYTHON" python
    "$repo/scripts/verify-image-packages.py" "$root" --camera-lock "$repo/config/camera-layer.lock.json")
"${check[@]}" "${prior_args[@]}" > "$w/result/parent-inventory.log"
mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
for path in run sys dev; do mount -t tmpfs -o nosuid,mode=755 tmpfs "$root/$path"; done
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$root/dev/fd"
touch "$root/.y700-disposable-build-root"
bash "$repo/scripts/add-board-layer.sh" "${lock_args[@]}" "$layer" "$root" "$archives" | tee "$w/result/install.log"
rm -- "$root/.y700-disposable-build-root"
chmod 644 "$root/var/lib/y700/build/packages.tsv"
"${check[@]}" "${lock_args[@]}" | tee "$w/result/inventory.log"
grep -Fxq "package_digest=$inventory_sha" "$w/result/inventory.log"
if [[ $layer == blueman || $layer == platform ]]; then
    package=blueman
    if [[ $layer == platform ]]; then package=y700-platform; fi
    [[ -z $(chroot "$root" dpkg -V "$package") ]]
    cmp "$repo/config/$layer.lock.json" "$root/var/lib/y700/build/$layer.lock.json"
fi
for path in "$root"/{etc/NetworkManager/system-connections,var/lib/bluetooth,var/lib/y700-ssc}; do
    [[ ! -d $path || -z $(find "$path" -mindepth 1 -print -quit) ]]
done
[[ -f $root/etc/machine-id && ! -s $root/etc/machine-id ]]
[[ $(chroot "$root" passwd -S y700 | cut -d' ' -f2) == L ]]
for path in "$root"/{etc/y700/maintenance*,etc/y700/bluetooth-address,etc/y700/user-configured,etc/ssh/ssh_host_*,home/y700/.ssh,root/.ssh,var/lib/y700-ssc/registry}; do
    [[ ! -e $path && ! -L $path ]]
done
umount -R "$root"
e2fsck -fn "$raw" >"$w/result/filesystem-check.log"
chmod 400 "$raw"
(cd "$w/result" && sha256sum root.ext4 >SHA256SUMS)
echo "$parent_sha  $parent" | sha256sum --strict -c -
mv -T --no-clobber "$w/result" "$out"
test ! -e "$w/result"
cat "$out/SHA256SUMS"
