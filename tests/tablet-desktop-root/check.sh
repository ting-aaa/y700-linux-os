#!/bin/bash
# Independently open both sealed filesystems read-only and verify the exported ledger.
set -euo pipefail
[[ $EUID == 0 && $# == 2 ]] || { echo 'Usage (root): check.sh DEV12.12_ROOT.ext4 DEV12.13_RESULT_DIR' >&2; exit 2; }
if [[ ${Y700_DESKTOP_CHECK_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net env Y700_DESKTOP_CHECK_PRIVATE=1 bash "$0" "$@"
fi
export LC_ALL=C
rootfs=$(realpath -e "$1")
output=$(realpath -e "$2")
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
cleanup() {
    for dir in trial old new; do
        if mountpoint -q "$work/$dir"; then umount "$work/$dir"; fi
    done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work/old" "$work/new"
lock=$repo/config/tablet-desktop.lock.json
echo "$(jq -r .parent_root_sha256 "$lock")  $rootfs" | sha256sum --strict -c -
(cd "$output" && sha256sum --strict -c SHA256SUMS)
mount -o loop,ro,noload "$rootfs" "$work/old"
mount -o loop,ro,noload "$output/root.ext4" "$work/new"
uv=("${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python)
for dir in old new; do
    "${uv[@]}" "$repo/scripts/verify-image-packages.py" "$work/$dir" --camera-lock "$repo/config/camera-layer.lock.json"
done
cmp "$lock" "$output/tablet-desktop.lock.json"
cmp "$output/packages.tsv" "$work/new/var/lib/y700/build/packages.tsv"
for rel in etc/apt etc/ssh etc/NetworkManager/system-connections var/lib/bluetooth etc/y700 etc/lightdm home/y700; do
    diff --no-dereference -qr "$work/old/$rel" "$work/new/$rel"
done
"${uv[@]}" "$(dirname "$0")/inherited.py" "$work/old" "$work/new"
mkdir "$work"/{trial,upper,overlay-work}
mount -t overlay overlay -o "lowerdir=$work/new,upperdir=$work/upper,workdir=$work/overlay-work" "$work/trial"
reject() {
    if "${uv[@]}" "$repo/scripts/verify-image-packages.py" "$work/trial" >"$work/rejection" 2>&1; then
        echo "Incorrectly accepted $1" >&2
        return 1
    fi
    grep -Fq "$2" "$work/rejection"
    echo "REJECTED $1"
}
camera=opt/y700-camera/bin/qcam
cp "$work/old/$camera" "$work/trial/$camera"
reject parent_qcam_binary "Autofocus package file differs from the release: $camera"
cp "$work/new/$camera" "$work/trial/$camera"
program=usr/libexec/y700-quick-settings/panel.py
chmod 0644 "$work/trial/$program"
reject nonexecutable_quick_settings "Tablet desktop file owner or mode differs from the release: $program"
chmod 0755 "$work/trial/$program"
entry=usr/bin/y700-quick-settings
ln -sfn /usr/bin/true "$work/trial/$entry"
reject wrong_launcher_target "Tablet desktop symlink differs from the release: $entry"
ln -sfn "$(readlink "$work/new/$entry")" "$work/trial/$entry"
"${uv[@]}" "$repo/scripts/verify-image-packages.py" "$work/trial" >/dev/null
echo 'SEALED_DESKTOP_ROOT_PASS package_ledger=exact generic_identity=preserved'
