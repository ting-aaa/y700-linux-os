#!/usr/bin/env bash
set -eu
grep -qw y700.wifi_fixture=1 /proc/cmdline
tr '\000' '\n' </proc/device-tree/compatible | grep -Fxq linux,dummy-virt
test "$(cat /sys/block/vda/ro)" = 1
finish() {
    local result=$?
    trap - EXIT
    printf 'WIFI_VM_EXIT=%s\n' "$result"
    # The disposable overlay is in memory. Skip guest shutdown jobs and sync.
    /opt/wifi-test/bin/busybox poweroff -n -f
}
trap finish EXIT
trap 'exit 143' TERM
# systemd can prefix the first console write with tty reset escapes.
printf '\n'
bash /opt/wifi-test/fixture-guest.sh
