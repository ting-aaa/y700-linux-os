#!/bin/bash
# Exercise historical selectors on a disposable overlay over the dev12.8 root.
set -euo pipefail
if [[ $EUID != 0 || $# != 4 ]]; then
    echo 'Usage (root): image-layer-preflight.sh DEV12.8_ROOT STOCK_BLUEMAN.deb OLD_BLUEMAN_ARCHIVES PLATFORM_ARCHIVES' >&2
    exit 2
fi
if [[ ${Y700_PREFLIGHT_PRIVATE:-} != 1 ]]; then
    exec unshare --mount --propagation private --net --pid --fork env Y700_PREFLIGHT_PRIVATE=1 bash "$0" "$@"
fi
[[ $$ == 1 && $(findmnt -nro PROPAGATION /) == private ]]
export UV_PYTHON=${UV_PYTHON:-/usr/bin/python3} UV_OFFLINE=1 LC_ALL=C
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
raw=$(realpath -e "$1")
stock=$(realpath -e "$2")
old=$(realpath -e "$3")
platform=$(realpath -e "$4")
w=$(mktemp -d /var/tmp/y700-layer-preflight.XXXXXXXX)
r=$w/root
cleanup() {
    if mountpoint -q "$r"; then umount -R "$r"; fi
    if mountpoint -q "$w/base"; then umount "$w/base"; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mkdir "$w"/{root,base,upper,work}
mount -o loop,ro,noload,nodev,nosuid "$raw" "$w/base"
mount -t overlay overlay -o "lowerdir=$w/base,upperdir=$w/upper,workdir=$w/work,nodev,nosuid" "$r"
touch "$r/.y700-disposable-build-root"
mount -o remount,ro "$r"
[[ ,$(findmnt -nro OPTIONS --target "$r"), == *,ro,* ]]
add=(bash "$repo/scripts/add-board-layer.sh")
reject() {
    local message=$1
    shift
    if "${add[@]}" "$@" >"$w/rejection" 2>&1; then echo 'Unexpected acceptance' >&2; exit 1; fi
    grep -F -- "$message" "$w/rejection"
}
reject 'accepts no sealed-layer overrides' --platform-version '0.1.0~dev12.6' platform "$r" "$platform"
reject 'Selected platform version differs' --platform-version '0.1.0~dev12.6' blueman "$r" "$old"
reject 'Unexpected installed blueman:arm64' --sealed-blueman-y7001 blueman "$r" "$old"
reject 'Unexpected platform receipt for the sealed platform' platform "$r" "$platform"
echo 'PREFLIGHT_REFUSED_BEFORE_WRITE root=read-only'

# A fresh image can deliberately select old Blueman while retaining the current
# platform. Recreate its Debian stock parent on this temporary upper layer.
mount -o remount,rw "$r"
mount -t proc -o nosuid,nodev,noexec proc "$r/proc"
for path in run sys dev; do mount -t tmpfs -o nosuid,mode=755 tmpfs "$r/$path"; done
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$r/dev/${pair%:*}" c 1 "${pair#*:}"; done
ln -s /proc/self/fd "$r/dev/fd"
hash=$("${UV_BIN:-uv}" run --offline --no-project --python "$UV_PYTHON" python -c \
    'import json,sys; print(next(p["sha256"] for p in json.load(open(sys.argv[1]))["packages"] if (p["package"], p["version"], p["architecture"]) == ("blueman", "2.4.4-1", "arm64")))' \
    "$repo/config/debian-base.lock.json")
printf '%s  %s\n' "$hash" "$stock" | sha256sum --strict -c -
[[ ! -e $r/usr/sbin/policy-rc.d && ! -L $r/usr/sbin/policy-rc.d ]]
printf '#!/bin/sh\nexit 101\n' >"$r/usr/sbin/policy-rc.d"
chmod 755 "$r/usr/sbin/policy-rc.d"
install -m644 "$stock" "$r/tmp/stock-blueman.deb"
chroot "$r" env SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/stock-blueman.deb
rm -- "$r/tmp/stock-blueman.deb" "$r/usr/sbin/policy-rc.d" "$r/var/lib/y700/build/blueman.lock.json"
"${add[@]}" --sealed-blueman-y7001 blueman "$r" "$old"
[[ $(chroot "$r" dpkg-query -W -f='${Version}' y700-platform) == '0.1.0~dev12.8' ]]
[[ $(chroot "$r" dpkg-query -W -f='${Version}' blueman) == '2.4.4-1+y7001' ]]
echo 'INDEPENDENT_BLUEMAN_SELECTOR_PASS platform=dev12.8 blueman=y7001'
