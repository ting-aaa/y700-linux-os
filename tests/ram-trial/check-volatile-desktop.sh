#!/bin/bash
set -euo pipefail
uid=$(id -u y700)
gid=$(id -g y700)
[[ $uid != 0 ]]
asuser=(setpriv --reuid="$uid" --regid="$gid" --init-groups env HOME=/home/y700
    XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus")
for _ in {1..180}; do
    pgrep -u "$uid" -f '^(/usr/bin/python3 )?/usr/libexec/y700-ambient-backlight$' >/dev/null && break
    sleep .4
done
pgrep -u "$uid" -f '^(/usr/bin/python3 )?/usr/libexec/y700-ambient-backlight$' >/dev/null
[[ $("${asuser[@]}" gsettings get org.y700.tablet automatic-brightness) == false ]]
canary=/home/y700/ram-trial-user-file.txt
[[ ! -e $canary && ! -e /run/y700-ram/lower$canary && ! -e /run/y700-ram/changes/upper$canary ]]
"${asuser[@]}" sh -c 'umask 077; cat /proc/sys/kernel/random/boot_id > "$1"' sh "$canary"
cmp "$canary" "/run/y700-ram/changes/upper$canary"
[[ $(stat -c %u "$canary") == "$uid" && ! -e /run/y700-ram/lower$canary ]]
echo 'RAM_TRIAL_DESKTOP fresh=1 canary=upper-only ambient_client=ordinary auto_brightness=false'
