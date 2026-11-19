#!/bin/bash
# Exercise the installed package only in a disposable EFI snapshot of a fresh image.
set -eu
grep -qw y700.gpu_enroll_vm=1 /proc/cmdline
grep -zFxq 'linux,dummy-virt' /proc/device-tree/compatible
bin=/usr/libexec/y700-firstboot-drm
marker=/etc/y700/user-configured
test "$(id -u)" = 0
test ! -e "$marker"
test "$("$bin/enroll" --state)" = new
for lock in '!!' '!synthetic-test-hash' '*'; do
    usermod -p "$lock" y700
    test "$("$bin/enroll" --state)" = locked
    if "$bin/firstboot"; then exit 1; fi
    test ! -e "$marker"
    test "$(getent shadow y700 | cut -d: -f2)" = "$lock"
done
usermod -p '!' y700
test "$("$bin/enroll" --state)" = new
touch "$marker"
"$bin/firstboot"
test "$("$bin/enroll" --state)" = new
rm -- "$marker"
printf 'PASS: administrative locks and configured fixture protected. Factory state restored.\n'
