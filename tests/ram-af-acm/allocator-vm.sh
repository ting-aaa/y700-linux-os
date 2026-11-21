#!/usr/bin/env bash
# The virtual guest has a real kernel udmabuf device and no camera.
set -euo pipefail
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.ram_af_virtual=1 /proc/cmdline
source /run/y700-af-acm/private-allocator.sh
node=/dev/udmabuf
host_state=$(stat -c %i:%u:%g:%a:%t:%T "$node")
units=(systemd-run --quiet --collect --wait --pipe --uid=y700 -p PrivateDevices=no -p ProtectSystem=strict
       -p ProtectHome=yes -p PrivateNetwork=yes -p NoNewPrivileges=yes)
access='[[ -c /dev/udmabuf ]] && exec 3<>/dev/udmabuf'
if "${units[@]}" /bin/bash -c "$access" 2>/dev/null; then exit 1; fi
probe() {
    printf '%s\n' "$Y700_AF_PRIVATE_NODE" > /run/y700-af-acm/vm-alias
    "${units[@]}" -p "BindPaths=$Y700_AF_PRIVATE_NODE:/dev/udmabuf" /bin/bash -c "$access"
}
with_private_allocator probe
alias=$(cat /run/y700-af-acm/vm-alias)
[[ ! -e ${alias%/*} && $(stat -c %i:%u:%g:%a:%t:%T "$node") == "$host_state" ]]
unshare --mount --propagation private /bin/bash -ec '
    mount --bind /dev/null /dev/udmabuf
    source /run/y700-af-acm/private-allocator.sh
    if with_private_allocator /bin/true; then exit 1; fi
'
echo 'AF_TEST allocator_private=1 baseline_denied=1 original_preserved=1 cleanup=1 wrong_device_refused=1 camera_access=0'
