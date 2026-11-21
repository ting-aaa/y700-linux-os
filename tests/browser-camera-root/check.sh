#!/usr/bin/env bash
# Inspect the two released ext4 files offline without booting or modifying either.
set -euo pipefail
export LC_ALL=C
[[ $EUID == 0 && ( $# == 2 || ( $# == 3 && $1 == --dev12.15 ) ) ]] || { echo 'Usage (root): check.sh [--dev12.15] PRIOR_ROOT RELEASE_ROOT' >&2; exit 2; }
if [[ ${Y700_CAMERA_ROOT_QA:-} != 1 ]]; then
    exec unshare --mount --propagation private --net env Y700_CAMERA_ROOT_QA=1 bash "$0" "$@"
fi
native=false
if [[ $1 == --dev12.15 ]]; then native=true; shift; fi
old=$(realpath -e -- "$1"); new=$(realpath -e -- "$2")
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
oldhash=6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c
newhash=32896d21a07a1c9529db3d007df788bb8ddcf4e5b6b0782527737ac7af1a3259
if "$native"; then oldhash=$newhash; read -r newhash _ < "$repo/config/dev12.15-root.sha256"; fi
printf '%s  %s\n' "$oldhash" "$old" "$newhash" "$new" | sha256sum --strict -c -
if "$native"; then e2fsck -fn "$new" > /dev/null; fi
work=$(mktemp -d)
cleanup() {
    for m in "$work"/{new,old}; do if mountpoint -q "$m"; then umount "$m"; fi; done
    rm -r --one-file-system -- "$work"
}
trap cleanup EXIT
mkdir "$work"/{old,new}
for side in old new; do
    mount -o ro,noload,loop,nodev,nosuid,noexec "${!side}" "$work/$side"
    dpkg-query --admindir="$work/$side/var/lib/dpkg" -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' |
        awk -F'\t' 'BEGIN{OFS="\t"} $1=="installed" {print $2,$3,$4}' | sort > "$work/$side.tsv"
done
[[ $(wc -l < "$work/old.tsv") == 1241 ]]
if "$native"; then
    [[ $(wc -l < "$work/new.tsv") == 1248 && -z $(comm -23 "$work/"{old,new}.tsv) ]]
    jq -r '.packages[] | [.package,.version,.architecture] | @tsv' "$repo/config/native-desktop.lock.json" |
        sort | cmp - <(comm -13 "$work/"{old,new}.tsv)
else
    [[ $(wc -l < "$work/new.tsv") == 1241 ]]
    printf 'y700-camera-pipewire\t1.4.2-1+y700.4\tarm64\n' | cmp - <(comm -23 "$work/"{old,new}.tsv)
    printf 'y700-camera-pipewire\t1.4.2-1+y700.5\tarm64\n' | cmp - <(comm -13 "$work/"{old,new}.tsv)
    [[ $(comm -12 "$work/"{old,new}.tsv | wc -l) == 1240 ]]
fi
build=var/lib/y700/build
(cd "$work/old/$build"; sha256sum *.lock.json) > "$work/prior-locks"
(cd "$work/new/$build"; sha256sum --strict --quiet -c "$work/prior-locks")
cmp "$repo/config/browser-camera-desktop.lock.json" "$work/new/$build/browser-camera-desktop.lock.json"
cmp "$work/old/etc/shadow" "$work/new/etc/shadow"
[[ ! -s $work/new/etc/machine-id && ! -e $work/new/etc/y700/user-configured ]]
[[ $(readlink "$work/new/etc/systemd/system/graphical.target.wants/y700-firstboot.service") == /etc/systemd/system/y700-firstboot.service ]]
[[ -z $(find "$work/new/var/lib/bluetooth" -mindepth 1 -print -quit 2>/dev/null) ]]
for sensitive in etc/y700/bluetooth-address etc/y700/per-unit; do [[ ! -e $work/new/$sensitive ]]; done
"${UV_BIN:-uv}" run --offline --no-project --python /usr/bin/python3 python "$repo/scripts/verify-image-packages.py" \
    "$work/new" --camera-lock "$repo/config/camera-layer.lock.json" --platform-version '0.1.0~dev12.8+gpu1.2'
if "$native"; then
    echo "FRESH_ROOT installed=1248 unchanged=1241 added=7 inherited_locks=$(wc -l < "$work/prior-locks") shadow=unchanged enrollment=pending"
else
    echo "FRESH_ROOT installed=1241 unchanged=1240 replaced=1 inherited_locks=$(wc -l < "$work/prior-locks") shadow=unchanged enrollment=pending"
fi
