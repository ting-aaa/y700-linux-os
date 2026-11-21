#!/bin/bash
# Exercise the tablet's desktop stack on a private X server. The optional
# Debian archive supplies only /usr/bin/thunar inside the test namespace.
set -euo pipefail
if [[ $# != 4 && $# != 5 ]]; then
    echo 'Usage: run.sh PINNED_USB_SSH XORG_INPUTTEST_HEADER ARM64_DUMMY.deb ARM64_UV [THUNAR.deb]' >&2
    exit 2
fi
ssh=$(realpath -e "$1")
header=$(realpath -e "$2")
dummy=$(realpath -e "$3")
uv=$(realpath -e "$4")
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
remote=
cleanup() {
    if [[ $remote =~ ^/run/y700-thunar-xi\.[[:alnum:]]{8}$ ]]; then
        bash "$ssh" "test ! -L '$remote' && ! mountpoint -q '$remote/root' && rm -rf --one-file-system -- '$remote'" </dev/null
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
printf '%s  %s\n' 73dfa96e1fb2016c1d43f17a7df4e332d21a2bda720c0a7f91c1df3c9969da51 "$header" \
    5ed4d469b062060a051d7d0e5edaaf5f1d3c93d9abc3f7989e1beee018cc0c5d "$dummy" | sha256sum --strict -c -
[[ ${header##*/} == xf86-input-inputtest-protocol.h ]]
mkdir -p "$tmp/data/modules/drivers"
install -m755 "$uv" "$tmp/data/uv"
aarch64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -I"$(dirname "$header")" "$here/touch.c" -o "$tmp/data/touch"
dpkg-deb --fsys-tarfile "$dummy" | tar -xOf - ./usr/lib/xorg/modules/drivers/dummy_drv.so >"$tmp/data/modules/drivers/dummy_drv.so"
install -m755 "$here/"{adapter.sh,session.sh,user.sh} "$tmp/data/"
install -m644 "$here/dummy.conf" "$here/../thunar-touch/exercise.py" \
    "$here/../file-trial-positive/desktop-actions/keyboard.py" "$tmp/data/"
if [[ ${Y700_THUNAR_STOCK:-0} == 1 ]]; then touch "$tmp/data/expect-stock"; fi
install -m700 "$here/namespace.sh" "$tmp/"
if [[ $# == 5 ]]; then
    [[ $(dpkg-deb -W --showformat='${Package} ${Architecture}' "$5") == 'thunar arm64' ]]
    dpkg-deb --fsys-tarfile "$5" | tar -xOf - ./usr/bin/thunar >"$tmp/data/candidate"
    chmod 755 "$tmp/data/candidate"
fi
(cd "$tmp" && find data namespace.sh -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
remote=$(bash "$ssh" 'set -eu; test "$(findmnt -nro FSTYPE -T /run)" = tmpfs; umask 077; mktemp -d /run/y700-thunar-xi.XXXXXXXX' </dev/null)
[[ $remote =~ ^/run/y700-thunar-xi\.[[:alnum:]]{8}$ ]]
tar -C "$tmp" -czf - namespace.sh SHA256SUMS data | bash "$ssh" "umask 077; tar -C '$remote' -xzf -"
bash "$ssh" "bash -s -- '$remote'" <<'BOARD'
set -euo pipefail
cd "$1"
sha256sum --strict --quiet -c SHA256SUMS
snapshot() {
    cat /proc/sys/kernel/random/boot_id
    loginctl show-seat seat0 -p ActiveSession
    systemctl show lightdm bluetooth NetworkManager ssh -p InvocationID
    dpkg-query -W -f='${binary:Package} ${Version}\n' | LC_ALL=C sort | sha256sum
    sha256sum /usr/bin/thunar
}
snapshot >before
rc=0
timeout --kill-after=4 190 unshare --mount --pid --fork --kill-child --ipc --net --propagation private bash ./namespace.sh "$PWD" || rc=$?
snapshot >after
cmp before after
if mountpoint -q root; then echo 'The private root is still mounted.' >&2; exit 1; fi
echo "THUNAR_BOARD same_boot_seat_services_packages_binary=1 actor_exit=$rc"
exit "$rc"
BOARD
