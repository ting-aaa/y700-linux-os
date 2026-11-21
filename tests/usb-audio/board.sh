#!/bin/bash
# Bounded no-accessory qualification on the qualified .11 daily root.
# Invoke in a root-owned private staging directory containing rollback.sh and the .deb.
set -euo pipefail
export LC_ALL=C
[[ $# == 1 && $EUID == 0 ]] || exit 2
case "$1" in --qualify) passes=(first final);; --finalize) passes=(final);; *) exit 2;; esac
here=$(cd "$(dirname "$0")" && pwd -P)
cd "$here"
pkg=y700-usb-audio-modules
deb=${pkg}_7.3.4-1_arm64.deb
release=7.3.4-asphalt-prc
base=a652f024df73eb7386043cf11fa3fde1a1eb81a9f78a572c7bce808b0f1979fb
updated=bdace256c575450952627840971d910231b0b6426f5e799310a93c98ca14ab27
. /etc/os-release
[[ $IMAGE_VERSION == dev12.11 && $(uname -r) == "$release" ]]
grep -azFxq lenovo,asphalt /proc/device-tree/compatible
[[ $(tr -d '\0' </proc/device-tree/region_country) == PRC ]]
notes=$(sha256sum /sys/kernel/notes)
[[ ${notes%% *} == 35442a692d818843fc1a1b2b1d9208f18942211021595a1abb26d8655e8a39f6 ]]
echo "87450f08290edab544d0ac104f4b5475cc17212bb8a1d6342b711bb60c03ab8d  $deb" | sha256sum --strict -c -
shopt -s nullglob
health() {
    local m dev opts path
    for m in / /run/initramfs/backing; do
        dev=$(findmnt -nro SOURCE -M "$m"); opts=$(findmnt -nro OPTIONS -M "$m")
        [[ ,$opts, == *,rw,* && $(cat "/sys/fs/ext4/${dev##*/}/errors_count") == 0 ]] || return 1
    done
    for path in /sys/bus/usb/devices/*/bInterfaceClass; do [[ $(<"$path") != 01 ]] || return 1; done
    for path in /proc/asound/card*/pcm*/sub*/status; do [[ $(<"$path") == closed ]] || return 1; done
    local cards=(/sys/class/sound/card[0-9]*) play=(/dev/snd/pcm*p) cap=(/dev/snd/pcm*c)
    [[ ${#cards[@]} == 1 && $(cat /proc/asound/card0/id) == LenovoY700 && ${#play[@]} == 2 && ${#cap[@]} == 0 ]]
}
snapshot() {
    health || return 1
    cat /proc/sys/kernel/random/boot_id /proc/asound/pcm
    local unit name control sk rd user sockets=0
    for unit in display-manager ssh NetworkManager bluetooth; do
        systemctl is-active --quiet "$unit" || return 1
        systemctl show -p MainPID --value "$unit"
    done
    for name in pipewire wireplumber pipewire-pulse; do pgrep -x "$name" | sort -n || return 1; done
    for control in 'Digital PCM Volume' 'AMP Enable Switch' 'DSP1 Preload Switch' 'DACPCM Source'; do
        for side in SPK1 SPK2; do
            amixer -c LenovoY700 cget "name=$side $control" || return 1
        done
    done
    for sk in /run/user/*/pipewire-0; do
        [[ -S $sk ]] || continue
        sockets=$((sockets + 1))
        rd=${sk%/*}; user=$(getent passwd "${rd##*/}" | cut -d: -f1)
        stat -c '%d %i' "$sk"
        runuser -u "$user" -- env XDG_RUNTIME_DIR="$rd" timeout 5 pw-cli ls Node |
            awk '/node.name = "alsa_(input|output)/ {print; if (/alsa_output/) sinks++; else sources++} END {if (sinks!=1 || sources) exit 1}' || return 1
    done
    [[ $sockets -gt 0 ]]
}
inventory() {
    local expected=$1 count=$2 rows sum
    rows=$(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n' | sed -n 's/^installed\t//p' | sort)
    sum=$(printf '%s\n' "$rows" | sha256sum)
    [[ ${sum%% *} == "$expected" && $(printf '%s\n' "$rows" | wc -l) == "$count" ]]
}
health
[[ -z $(dpkg --audit) ]]
inventory "$base" 1241
baseline=$(snapshot)
same_state() {
    local current
    current=$(snapshot) || return 1
    [[ $current == "$baseline" ]]
}
sid=$(loginctl show-seat seat0 -p ActiveSession --value)
seat=$(loginctl show-session "$sid" -p Class --value)
[[ $seat == greeter || $seat == user ]]
modules=(snd-usb-audio snd-usbmidi-lib snd-rawmidi snd-hwdep)
for name in "${modules[@]}"; do
    [[ ! -e /sys/module/${name//-/_} ]]
    if modinfo "$name" >/dev/null 2>&1; then exit 1; fi
done
echo "UAC_BOARD before=1241 before_sha=$base kernel_notes=${notes%% *} seat=$seat usb_audio=0 pcm_clients=0"
parent=/var/lib/y700/updates
target=$parent/usb-audio-7.3.4-1
[[ -d $parent && $(realpath -e "$parent") == "$parent" ]]
if [[ ! -e $target ]]; then
    new=$(mktemp -d "$parent/.usb-audio.XXXXXXXX")
    install -m600 "$deb" "$new/$deb"
    install -m700 rollback.sh "$new/rollback.sh"
    mv -T "$new" "$target"
fi
[[ $(stat -c '%u:%g:%a' "$target") == 0:0:700 && ! -L $target ]]
cmp "$deb" "$target/$deb"; cmp rollback.sh "$target/rollback.sh"
changed=0
failure() {
    local rc=$?
    if (( rc && changed )); then
        echo 'UAC_BOARD qualification_incomplete=1 attempting_guarded_rollback=1' >&2
        bash "$target/rollback.sh" || echo "Review $target/rollback.sh" >&2
    fi
    return "$rc"
}
trap failure EXIT
trap 'echo "UAC_BOARD failed_line=$LINENO" >&2' ERR
changed=1
for pass in "${passes[@]}"; do
    health
    dpkg -i "$target/$deb"
    [[ -z $(dpkg -V "$pkg") ]]
    inventory "$updated" 1242
    modprobe snd-usb-audio
    for name in "${modules[@]}"; do
        [[ -d /sys/module/${name//-/_} ]]
        path=$(realpath -e "$(modinfo -n "$name")")
        [[ $path == "/usr/lib/modules/$release/updates/$pkg/$name.ko.zst" && $(dpkg-query -S "$path") == "$pkg: $path" ]]
    done
    same_state
    echo "UAC_BOARD phase=$pass loaded_owned_modules=4 pcm=2p_0c closed=1 speaker_controls_unchanged=8 service_processes_same=1 sink_same=1 boot_same=1"
    if [[ $pass == first ]]; then
        bash "$target/rollback.sh"
        inventory "$base" 1241
        same_state
        echo "UAC_BOARD purge_restored_packages=1241 sha=$base"
    else
        for name in "${modules[@]}"; do
            if [[ -d /sys/module/${name//-/_} ]]; then
                rmmod "${name//-/_}"
                echo "UAC_BOARD idle_unloaded=$name"
            fi
            [[ ! -e /sys/module/${name//-/_} ]]
        done
        inventory "$updated" 1242
        same_state
        [[ -z $(dpkg --audit) ]]
    fi
done
changed=0
echo "UAC_BOARD_PASS final=installed modules_idle=unloaded packages=1242 sha=$updated rollback=$target/rollback.sh"
