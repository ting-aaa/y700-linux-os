#!/bin/bash
# Collect the counted boot locally, without depending on USB or SSH.
set -eu -o pipefail
export LC_ALL=C DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0
umask 077
base=/var/tmp/y700-panel60-run-a
id=${1:?missing trial ID}
[[ $id =~ ^[a-z0-9][a-z0-9-]{0,23}$ && $EUID == 0 ]]
read -ra bootargs </proc/cmdline
has_bootarg() {
    local arg
    for arg in "${bootargs[@]}"; do [[ $arg != "$1" ]] || return 0; done
    return 1
}
has_bootarg "y700.installed_trial=$id"
has_bootarg y700.panel_probe=60hz
[[ $(findmnt -nro UUID -M /) == c0e447e4-82db-59ee-91d6-0e1ec9d5f45e &&
   $(realpath -e "$base") == "$base" && $(stat -c %u "$base") == 0 ]]
[[ -z $(find "$base" -maxdepth 0 -perm /022) ]]
dir=$(mktemp -d "$base/observer-$id.XXXXXXXX")
log=$dir/result.log
touch "$log"; exec >>"$log" 2>&1
finish() { local rc=$?; echo "PANEL_LOCAL_EXIT status=$rc"; sync -f "$log"; }
trap finish EXIT
printf 'PANEL_LOCAL_START id=%s\n' "$id"
sync -f "$log"
[[ $(sha256sum /sys/kernel/notes | cut -d' ' -f1) == c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063 ]]
cd "$base"
sha256sum --strict -c <<'HASHES'
3aeabafe22c33d9811dbddbd586b5bde7367ff2c04e0b1a979bc04b71ed9b481  board-scanout.sh
042955b2afc3709b00236c2addfc201e242be4eb3881a4204d19479db3623a81  dpu-vblank
HASHES
timer=y700-installed-trial-deadline.timer
snapshot() {
    local unit udc=missing iface addr=0 carrier=unknown ssh=0 state sub result
    printf 'PANEL_LOCAL_UPTIME seconds=%s\n' "$(cut -d. -f1 /proc/uptime)"
    for unit in asphalt-usb-maintenance.service ssh.service lightdm.service "$timer"; do
        state=$(systemctl show -p ActiveState --value "$unit") || state=unknown
        sub=$(systemctl show -p SubState --value "$unit") || sub=unknown
        result=$(systemctl show -p Result --value "$unit") || result=unknown
        printf 'PANEL_LOCAL_UNIT unit=%s state=%s sub=%s result=%s\n' "$unit" "$state" "$sub" "$result"
    done
    if [[ -r /sys/class/udc/a600000.usb/state ]]; then udc=$(cat /sys/class/udc/a600000.usb/state); fi
    iface=$(cat /sys/kernel/config/usb_gadget/asphalt-maintenance/functions/ncm.usb0/ifname 2>/dev/null || :)
    if [[ $iface =~ ^[a-zA-Z0-9_.:-]+$ && -e /sys/class/net/$iface ]]; then
        carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null) || carrier=unknown
        if ip -4 -o address show dev "$iface" | awk '$4=="172.16.43.1/24"{s=1} END{exit !s}'; then addr=1; fi
        iface=present
    else iface=missing; fi
    if ss -H -4lnt | awk '$4=="172.16.43.1:22"{s=1} END{exit !s}'; then ssh=1; fi
    printf 'PANEL_LOCAL_USB udc=%s netdev=%s carrier=%s address_present=%d ssh_listener=%d\n' "$udc" "$iface" "$carrier" "$addr" "$ssh"
    sync -f "$log"
}
deadline=$((SECONDS + 80))
count=0
while (( SECONDS < deadline )); do
    if (( count % 4 == 0 )); then snapshot; fi
    ((count+=1))
    sid=$(loginctl show-seat seat0 -p ActiveSession --value) || sid=
    if [[ -n $sid ]]; then
        class=$(loginctl show-session "$sid" -p Class --value) || class=unknown
        [[ $class == greeter || $class == unknown ]] || { echo PANEL_LOCAL_ACTIVE_USER; exit 1; }
        if [[ $class == greeter && $(loginctl show-seat seat0 -p Sessions --value) == "$sid" &&
            $(loginctl show-session "$sid" -p Type --value) == x11 ]] &&
            systemctl is-active --quiet "$timer" && systemctl is-active --quiet lightdm &&
            [[ $(cat /sys/class/backlight/ktz8866-backlight/bl_power 2>/dev/null) == 0 &&
               $(cat /sys/class/backlight/ktz8866-backlight/actual_brightness 2>/dev/null) -gt 0 ]] &&
            timeout 3 xset q | awk '/Monitor is/{lit=($3=="On")}END{exit !lit}'; then
            echo PANEL_LOCAL_READY
            sync -f "$log"
            rc=0; bash ./board-scanout.sh ./dpu-vblank || rc=$?
            snapshot; exit "$rc"
        fi
    fi
    sleep 2
done
echo PANEL_LOCAL_NO_READY_GREETER
snapshot; exit 1
