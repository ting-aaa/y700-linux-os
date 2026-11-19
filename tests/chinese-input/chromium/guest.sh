#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
grep -qw y700.chinese_input_browser=1 /proc/cmdline
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
test "$(dpkg --print-architecture)" = arm64
test "$(dpkg-query -W -f='${Version}' y700-input-pinyin)" = '0.1.0~dev3'
ip link set lo up
mkdir -p /dev/shm /run/dbus
mount -t tmpfs -o mode=1777 tmpfs /dev/shm
dbus-daemon --system --fork
for deb in /opt/chinese-input/archives/*.deb; do dpkg-deb -x "$deb" /; done
install -d -m700 -o y700 -g y700 /run/chinese-input
runuser -u y700 -- unshare --user --map-root-user true
printf 'CHINESE_INPUT_CHROMIUM_VERSION %s\n' "$(chromium --version)"
export CHINESE_INPUT_DISCOVERY=1
timeout -k 5 330 runuser -u y700 -- bash /opt/chinese-input/session.sh &
session=$!
sandbox() {
    local renderer browser
    browser=$(pgrep -u y700 -xo chromium) || return 1
    renderer=$(pgrep -u y700 -f '^/usr/lib/chromium/chromium .*--type=renderer' | head -n1)
    test -n "$renderer" || return 1
    grep -Eq '^Seccomp:[[:blank:]]+2$' "/proc/$renderer/status" || return 1
    grep -Eq '^NoNewPrivs:[[:blank:]]+1$' "/proc/$renderer/status" || return 1
    test "$(readlink "/proc/$renderer/ns/pid")" != "$(readlink "/proc/$browser/ns/pid")"
}
sandbox_confirmed=0
for _ in {1..300}; do
    if sandbox; then
        echo 'CHINESE_INPUT_CHROMIUM_SANDBOX seccomp=2 no_new_privileges=1 separate_pid_namespace=1'
        sandbox_confirmed=1
        break
    fi
    kill -0 "$session" 2>/dev/null || break
    sleep .5
done
(( sandbox_confirmed == 1 ))
wait "$session"
