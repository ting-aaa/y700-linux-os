#!/bin/bash
set -euo pipefail
[[ $# == 5 ]] || { echo 'Usage: run.sh PINNED_USB_SSH RELEASE_BASE ARM64_HELPERS VIRTUAL_CAMERA_LIBDIR LIBYUV_DEB' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ssh=$(realpath -e "$1")
entry=$(realpath -e "$2")
helpers=$(realpath -e "$3")
virtual=$(realpath -e "$4")
libyuv=$(realpath -e "$5")
local_stage=$(mktemp -d /var/tmp/y700-dev1213-physical.XXXXXXXX)
stage=
cleanup() {
    rc=$?
    if [[ $stage =~ ^/run/y700-1213-settings\.[[:alnum:]]{8}$ ]]; then
        bash "$ssh" bash -s -- "$stage" <<'CLEAN' || rc=1
set -euo pipefail
stage=$1
[[ $(realpath -e "$stage") == "$stage" && $(findmnt -nro FSTYPE -T "$stage") == tmpfs ]]
if [[ -f $stage/before ]]; then bash "$stage/snapshot.sh" >"$stage/after"; fi
matched=yes
if [[ -f $stage/before ]] && ! cmp -s "$stage/before" "$stage/after"; then
    matched=no
    paste "$stage/before" "$stage/after" | awk -F '\t' '$1!=$2 {print "CHANGED baseline_field=" NR}' >&2
fi
[[ -z $(losetup -j "$stage/root.ext4") ]]
if grep -Fq "$stage/" /proc/self/mountinfo; then echo 'private mount remains'; exit 1; fi
if [[ -s $stage/private-mnt ]]; then
   own_ns=$(cat "$stage/private-mnt")
   if [[ $(lsns -t mnt -n -o NS) =~ (^|[[:space:]])$own_ns($|[[:space:]]) ]]; then echo 'private namespace remains'; exit 1; fi
fi
rm -r --one-file-system -- "$stage"
[[ ! -e $stage ]]
echo "DEV1213_CLEANUP boot_seat_lock_services_backlight_mounts_swap_network_cameras_same=$matched staging_removed=1 leaked_loop=0 leaked_mount_namespace=0"
awk '/^MemAvailable:/ {print "DEV1213_POST memory_available_kib=" $2}' /proc/meminfo
[[ $matched == yes ]]
CLEAN
    fi
    rm -r --one-file-system -- "$local_stage"
    exit "$rc"
}
trap cleanup EXIT
[[ $(stat -c %s "$entry/root.ext4.zst") == 1334361111 ]]
echo "508b438978db4db54be127cbe7b2f197eded2fa17b60bcf44db5f32d6386d057  $entry/root.ext4.zst" | sha256sum --strict -c -
mkdir "$local_stage/tools"
for name in Xvfb xdotool uv; do install -m755 "$helpers/bin/$name" "$local_stage/tools"; done
install -m644 "$helpers/lib/libxdo.so.3" "$local_stage/tools"
install -m644 "$here"/{ns.sh,snapshot.sh,tablet-apps.sh,chooser.py} "$local_stage/"
install -m644 "$repo/tests/ram-userspace/desktop.sh" "$repo/tests/qcam-photo/"{board-chooser.py,virtual-shutter.py} "$local_stage/"
install -m644 "$repo/tests/qcam-photo/virtual-cameras.yaml" "$local_stage/"
(cd "$virtual" && sha256sum --strict -c "$here/virtual-libs.sha256")
install -m755 "$virtual"/{libcamera,libcamera-base}.so.0.7.2 "$local_stage/tools/"
echo "ab0e0a3bbfb0340d7adbb47c8a622e661256f0ceb205c6a299b34f58cdcee805  $libyuv" | sha256sum --strict -c -
dpkg-deb --fsys-tarfile "$libyuv" | tar -xOf - --wildcards './usr/lib/aarch64-linux-gnu/libyuv.so.0.*' >"$local_stage/tools/libyuv.so.0"
for a in "$local_stage"/*.sh; do bash -n "$a"; done
stage=$(bash "$ssh" bash -s <<'PRE'
set -euo pipefail
[[ $(uname -m) == aarch64 && $(findmnt -nro FSTYPE -T /run) == tmpfs && $(wc -l </proc/swaps) == 1 ]]
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq lenovo,asphalt
tr '\0' '\n' </proc/device-tree/compatible | grep -Fxq qcom,sm8475
grep -Fxq IMAGE_VERSION=dev12.11 /etc/os-release
awk '/MemAvailable:/ {exit !($2 >= 11*1024*1024)}' /proc/meminfo
df -Pk /run | awk 'NR==2 {exit !($4 >= 6900*1024)}'
for p in / /run/initramfs/backing; do
    [[ $(findmnt -nro FSTYPE,OPTIONS -T "$p") == 'ext4 rw,'* ]]
done
for f in /sys/fs/ext4/*/errors_count; do [[ $(cat "$f") == 0 ]]; done
lenses=0
for name in /sys/bus/i2c/devices/*/name; do
    case $(cat "$name") in hi1339|s5k4h7|sc202cs)
        [[ $(cat "$(dirname "$name")/power/runtime_status") == suspended ]]
        lenses=$((lenses+1));;
    esac
done
[[ $lenses == 3 ]] && ! pgrep -x qcam >/dev/null || exit 1
while IFS= read -r fd; do
    pid=${fd#/proc/}; pid=${pid%%/*}
    program=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
    case $program in pipewire|wireplumber) ;; *) echo 'Camera device held by another client' >&2; exit 1;; esac
done < <(find /proc/[0-9]*/fd -maxdepth 1 \( -lname '/dev/video*' -o -lname '/dev/media*' -o -lname '/dev/v4l-subdev*' \) -print 2>/dev/null)
uid=$(id -u y700)
setpriv --reuid="$uid" --regid="$(id -g y700)" --clear-groups env -i PATH=/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$uid" pw-dump |
    perl -MJSON::PP -0777 -ne 'my @n=grep { $_->{type} eq "PipeWire:Interface:Node" && (($_->{info}{props}{"media.class"} // "") =~ m{^Video/Source}) } @{decode_json($_)}; exit 1 if grep { $_->{info}{state} eq "running" } @n; print STDERR "DEV1213_CAMERA_PREFLIGHT suspended_lenses=3 active_video_sources=0\n"'
awk '/^MemAvailable:/ {print "DEV1213_PRE memory_available_kib=" $2}' /proc/meminfo >&2
umask 077
mktemp -d /run/y700-1213-settings.XXXXXXXX
PRE
)
[[ $stage =~ ^/run/y700-1213-settings\.[[:alnum:]]{8}$ ]]
tar -C "$local_stage" -cf - . | timeout 45 bash "$ssh" "umask 077; tar -C '$stage' -xf -"
bash "$ssh" "bash '$stage/snapshot.sh' >'$stage/before'"
start=$SECONDS
timeout 230 bash "$ssh" "umask 077; ulimit -f 6291456; exec nice -n 15 zstd -q -d --sparse -o '$stage/root.ext4' -" < "$entry/root.ext4.zst"
printf 'DEV1213_USB compressed_bytes=%s seconds=%s\n' "$(stat -c %s "$entry/root.ext4.zst")" "$((SECONDS-start))"
bash "$ssh" bash -s -- "$stage" <<'RUN'
set -euo pipefail
stage=$1
cd "$stage"
chmod 400 root.ext4
awk '/MemAvailable:/ {exit !($2 >= 6*1024*1024)}' /proc/meminfo
for ns in mnt net pid ipc; do readlink "/proc/self/ns/$ns" > "host-$ns"; done
timeout --kill-after=5s 200s nice -n 15 unshare --mount --propagation private --pid --fork --kill-child --ipc --net bash -ec '
stat -Lc %i /proc/self/ns/mnt > "$1/private-mnt"; exec bash "$1/ns.sh" "$1"' bash "$stage"
RUN
