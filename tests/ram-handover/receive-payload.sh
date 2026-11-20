#!/bin/sh
# The kernel has mounted devtmpfs, proc and sysfs in the QEMU-only first stage.
set -eu
bb=/bin/busybox
port=
for attempt in $($bb seq 1 100); do
    for path in /sys/class/virtio-ports/*; do
        [ -r "$path/name" ] || continue
        read -r name < "$path/name"
        [ "$name" = org.y700.boot-payload ] || continue
        port=/dev/${path##*/}
        break
    done
    [ -z "$port" ] || break
    $bb sleep .1
done
[ -c "$port" ]
exec 3<>"$port"
exec /y700-ram-trial-init receive
