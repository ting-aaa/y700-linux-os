#!/bin/bash
# Exercise the sealed desktop plus the offline player layer entirely in RAM.
set -euo pipefail
umask 077
[[ $# == 5 || $# == 6 ]] || { echo 'Usage: run-parole-tablet.sh USB_SSH RAM_BUNDLE PLAYER_TAR_GZ|--preinstalled SYNTHETIC_CLIPS DEVICE_XVFB_USR [SEPARATE_V4L2_SO]' >&2; exit 2; }
access=$(realpath -e "$1")
bundle=$(realpath -e "$2")
player=
clips=$(realpath -e "$4")
helper=$5
plugin=
trace=${IRIS_PAROLE_TRACE:-}
[[ -z $trace || (! -e $trace && -d $(dirname "$trace")) ]]
[[ $helper =~ ^/var/tmp/[A-Za-z0-9._/-]+/usr$ && $helper != */../* ]]
here=$(cd "$(dirname "$0")" && pwd)
ramtests="$here/../ram-userspace"
source "$ramtests/profiles.sh"
initrd_sha=$(sha256sum "$bundle/initrd" | cut -d' ' -f1)
ram_profile "$initrd_sha"
if [[ $3 == --preinstalled ]]; then
    [[ $release == dev12.9 && $# == 5 ]]
else
    [[ $release == dev12.8 && ${PAROLE_BUNDLE_SHA256:-} =~ ^[0-9a-f]{64}$ ]]
    player=$(realpath -e "$3")
    printf '%s  %s\n' "$PAROLE_BUNDLE_SHA256" "$player" | sha256sum -c --strict --status -
fi
if [[ $# == 6 ]]; then
    plugin=$(realpath -e "$6")
    [[ ${IRIS_V4L2_SHA256:-} =~ ^[0-9a-f]{64}$ ]]
    printf '%s  %s\n' "$IRIS_V4L2_SHA256" "$plugin" | sha256sum -c --strict --status -
fi
stage=$(bash "$access" bash -s <<'PREFLIGHT'
set -eu
test "$(findmnt -nro FSTYPE -T /run)" = tmpfs
test "$(wc -l </proc/swaps)" = 1
grep -zFxq lenovo,asphalt /proc/device-tree/compatible
awk '/MemAvailable:/ {exit !($2 > 8*1024*1024)}' /proc/meminfo
df -Pk /run | awk 'NR==2 {exit !($4 > 4*1024*1024)}'
umask 077
mktemp -d /run/y700-player.XXXXXXXX
PREFLIGHT
)
[[ $stage =~ ^/run/y700-player\.[[:alnum:]]{8}$ ]]
cleanup() {
    bash "$access" "cd / && ! grep -Fq '$stage/' /proc/self/mountinfo && rm -r --one-file-system -- '$stage' && test ! -e '$stage'" ||
        { echo 'Failed to verify cleanup of the player RAM directory' >&2; exit 1; }
}
trap cleanup EXIT
tar -cf - -C "$ramtests" device.sh profiles.sh -C "$here" parole-namespace.sh parole-desktop.sh \
    -C "$clips" h264.mp4 hevc.mp4 vp9.webm |
    bash "$access" "tar -xf - -C '$stage' && mv '$stage/parole-namespace.sh' '$stage/namespace.sh'"
if [[ -n $plugin ]]; then
    bash "$access" "cd '$stage' && cat >plugin.so && echo '$IRIS_V4L2_SHA256  plugin.so' | sha256sum -c --strict --status -" <"$plugin"
fi
if [[ -n $player ]]; then
    bash "$access" "cd '$stage' && cat >player.tgz && echo '$PAROLE_BUNDLE_SHA256  player.tgz' | sha256sum -c --strict --status -" <"$player"
fi
timeout 150 bash "$access" "cat >'$stage/initrd'" <"$bundle/initrd"
probe="$here/../video-player/check-x11.py"
probe_hash=$(sha256sum "$probe" | cut -d' ' -f1)
bash "$access" "cd '$stage' && cat >check-x11.py && echo '$probe_hash  check-x11.py' | sha256sum --strict --status -c -" <"$probe"
if [[ -n $trace ]]; then bash "$access" "touch '$stage/save-player-trace'"; fi
rc=0
bash "$access" bash "$stage/device.sh" "$stage" "$helper" "$initrd_sha" || rc=$?
if [[ -n $trace ]] && bash "$access" "test -s '$stage/player-trace.tar.gz'"; then
    (set -o noclobber; bash "$access" "cat '$stage/player-trace.tar.gz'" >"$trace")
fi
exit "$rc"
