#!/bin/bash
# Disposable dev12.11 overlay; ARGV recording replaces only the eventual browser ELF.
set -euo pipefail
if [[ ${1:-} != --inside ]]; then
    [[ $EUID == 0 && $# == 4 ]] || { echo "Usage: $0 DEV12.11_ROOT OLD_DEB NEW_DEB ARM64_QA_HELPERS" >&2; exit 2; }
    exec unshare --mount --propagation private --net --pid --fork --kill-child bash "$0" --inside "$@"
fi
shift
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
image=$(realpath -e "$1"); old=$(realpath -e "$2"); new=$(realpath -e "$3"); helpers=$(realpath -e "$4")
printf '%s  %s\n' 33ce23e8edac1d9c445c6b360a6355a189a151804352b032efe51320287d17a3 "$image" | sha256sum --strict -c -
w=$(mktemp -d /var/tmp/y700-chromium-graphics.XXXXXXXX); root=$w/root
mkdir "$w"/{lower,upper,work,root}
cleanup() {
    if mountpoint -q "$root"; then umount -R "$root" || return; fi
    if mountpoint -q "$w/lower"; then umount "$w/lower" || return; fi
    rm -r --one-file-system -- "$w"
}
trap cleanup EXIT
mount -o ro,noload,loop "$image" "$w/lower"
mount -t overlay overlay -o "lowerdir=$w/lower,upperdir=$w/upper,workdir=$w/work" "$root"
mount -t proc proc "$root/proc"
mount -t tmpfs -o mode=0755 tmpfs "$root/dev"
for pair in null:3 zero:5 random:8 urandom:9; do mknod -m666 "$root/dev/${pair%:*}" c 1 "${pair#*:}"; done
mkdir "$root/dev/shm"; chmod 1777 "$root/dev/shm"; ln -s /proc/self/fd "$root/dev/fd"
mkdir -p "$root"/{qa/bin,qa/lib,qa/tests/chromium-graphics,qa/tests/brightness}
cp "$helpers"/bin/{Xvfb,xdotool,uv} "$root/qa/bin/"; cp "$helpers/lib/libxdo.so.3" "$root/qa/lib/"
cp "$repo/tests/brightness/probe.py" "$root/qa/tests/brightness/"
cp "$repo/tests/chromium-graphics/check.py" "$root/qa/tests/chromium-graphics/"
cp "$repo/scripts/update-chromium-graphics.sh" "$root/qa/"
cp "$old" "$root/qa/old.deb"; cp "$new" "$root/qa/new.deb"
chroot "$root" dbus-uuidgen >"$root/etc/machine-id"
for path in /tmp/.X11-unix /tmp/.ICE-unix; do install -d -m1777 "$root$path"; done
printf '#!/bin/sh\nprintf "%%s\\0" "$@"\n' >"$w/capture"
chmod 755 "$w/capture"
mount --bind "$w/capture" "$root/usr/lib/chromium/chromium"
transaction=(chroot "$root" bash /qa/update-chromium-graphics.sh)
run_transaction() { "${transaction[@]}" "$1" /qa/old.deb /qa/new.deb; }
hook="$root/etc/chromium.d/99-y700-software-rendering"
cp "$hook" "$w/original-hook"
echo '# Local administrator setting' >>"$hook"
if run_transaction install; then echo 'Unexpectedly replaced a local change' >&2; exit 1; fi
grep -Fxq '# Local administrator setting' "$hook"
cp "$w/original-hook" "$hook"
run_transaction install
run_transaction install
for uid in 1000 65534; do
    install -m700 -d -o "$uid" -g "$uid" "$root/tmp/user$uid" "$root/tmp/runtime$uid"
done
as_user() {
    local uid=$1; shift
    chroot --userspec="$uid:$uid" "$root" env -i PATH=/qa/bin:/usr/bin:/bin LD_LIBRARY_PATH=/qa/lib \
        HOME="/tmp/user$uid" XDG_RUNTIME_DIR="/tmp/runtime$uid" UV_CACHE_DIR="/tmp/user$uid/uv" \
        LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 \
        GDK_SCALE=2 DISPLAY=:88 XDG_DATA_DIRS=/usr/local/share:/usr/share "$@"
}
as_user 1000 bash -ec '
    mkdir -p "$HOME/.config/chromium"
    printf "%s" "{\"other-pref\":37}" >"$HOME/.config/chromium/Local State"
    Xvfb "$DISPLAY" -screen 0 1600x1200x24 -nolisten tcp >"$HOME/xvfb.log" 2>&1 &
    server=$!; trap "kill $server 2>/dev/null || :; wait $server || :" EXIT
    for _ in {1..50}; do if xdpyinfo >/dev/null 2>&1; then break; fi; sleep .2; done
    xdpyinfo >/dev/null
    timeout -k 5 90 dbus-run-session -- uv run --offline --no-project --python /usr/bin/python3 python -B /qa/tests/chromium-graphics/check.py gui
    test "$(cat "$HOME/.config/chromium/Local State")" = "{\"other-pref\":37}"
'
as_user 1000 gsettings get org.y700.chromium hardware-acceleration | grep -Fx true
as_user 65534 uv run --offline --no-project --python /usr/bin/python3 python -B /qa/tests/chromium-graphics/check.py software
run_transaction rollback
run_transaction rollback
as_user 1000 uv run --offline --no-project --python /usr/bin/python3 python -B /qa/tests/chromium-graphics/check.py software
echo CHROMIUM_GRAPHICS_LIFECYCLE_PASS
