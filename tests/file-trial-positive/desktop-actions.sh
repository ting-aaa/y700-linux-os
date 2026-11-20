#!/usr/bin/env bash
# Drive only the synthetic 1024x768 EFI test seat. Both actors use the logged-in user's session.
set -euo pipefail
umask 077
grep -zFxq linux,dummy-virt /proc/device-tree/compatible
grep -qw y700.file_probe=1 /proc/cmdline
[[ $EUID == 0 && ${Y700_QA_UID:?} == "$(id -u y700)" && ${Y700_QA_UID} != 0 ]]
[[ -n ${XAUTHORITY:?} && -n ${DISPLAY:?} && -n ${DBUS_SESSION_BUS_ADDRESS:?} ]]
[[ ${XDG_RUNTIME_DIR:?} == /run/user/"$Y700_QA_UID" ]]
src=/run/y700-file-qa/desktop-actions
qa=$(mktemp -d /run/y700-desktop-actions.XXXXXXXX)
gid=$(id -g y700)
chgrp "$gid" "$qa"
chmod 0750 "$qa"
install -d -o "$Y700_QA_UID" -g "$gid" -m 0700 "$qa/user"
install -m 0755 "$src/uv-arm64" "$qa/uv"
install -m 0644 "$src/keyboard.py" "$src/panel.py" "$src/panel-gain.py" "$qa/"
mkfifo -m 0600 "$qa/user/request" "$qa/user/ack"
chown "$Y700_QA_UID:$gid" "$qa/user/request" "$qa/user/ack"

relay() {
    local count=0 action x y extra reply
    exec 7<>"$qa/user/request" 8<>"$qa/user/ack" 9<>/dev/virtio-ports/org.y700.login-phase
    while IFS=' ' read -r action x y extra <&7; do
        [[ $action == tap && -z $extra && $x =~ ^[0-9]{1,4}$ && $y =~ ^[0-9]{1,3}$ && $x -lt 1024 && $y -lt 768 ]] || return 1
        (( count += 1 ))
        printf 'DESKTOP_TAP %s %s %s\n' "$count" "$x" "$y"
        IFS= read -rt 45 reply <&9 && [[ $reply == "TAP_OK $count" ]] || return 1
        printf 'OK\n' >&8
    done
}
relay &
relay_pid=$!
trap 'kill "$relay_pid" 2>/dev/null || :; wait "$relay_pid" 2>/dev/null || :' EXIT

actor_env=()
while IFS= read -r -d '' item; do
    case ${item%%=*} in
        GTK_MODULES|GTK_IM_MODULE|XMODIFIERS|LANG|LANGUAGE|XDG_CONFIG_DIRS|XDG_DATA_DIRS|XDG_CURRENT_DESKTOP|DESKTOP_SESSION|AT_SPI_BUS_ADDRESS|GDK_SCALE|GDK_DPI_SCALE)
            actor_env+=("$item");;
    esac
done <"/proc/${Y700_QA_SESSION_PID:?}/environ"
panel_identity() {
    local pid args i entry display
    for pid in $(pgrep -u "$Y700_QA_UID" -f '/xfce4/panel/wrapper-2\.0 ' || :); do
        [[ -r /proc/$pid/cmdline && -r /proc/$pid/maps ]] || continue
        grep -Fq '/libpulseaudio-plugin.so' "/proc/$pid/maps" || continue
        mapfile -d '' -t args < "/proc/$pid/cmdline" || continue
        display=
        while IFS= read -r -d '' entry; do
            if [[ $entry == DISPLAY=* ]]; then display=${entry#DISPLAY=}; break; fi
        done <"/proc/$pid/environ"
        if [[ ${display%.0} != "${DISPLAY%.0}" ]]; then continue; fi
        for ((i=1; i+2<${#args[@]}; i++)); do
            if [[ ${args[i]} == */libpulseaudio-plugin.so && ${args[i+1]} == 19 && ${args[i+2]} =~ ^[0-9]+$ ]]; then
                actor_env+=("Y700_PANEL_WRAPPER_PID=$pid" "Y700_PANEL_SOCKET_XID=${args[i+2]}")
                printf 'DESKTOP_PANEL_WRAPPER uid=%s plugin=19 pid=%s socket=%s\n' "$Y700_QA_UID" "$pid" "${args[i+2]}"
                return 0
            fi
        done
    done
    return 1
}
overall=0
for actor in keyboard panel-gain; do
    echo "DESKTOP_ACTION_BEGIN actor=$actor"
    if [[ $actor == panel-gain ]]; then
        deadline=$((SECONDS + 70))
        until panel_identity; do
            if ((SECONDS >= deadline)); then echo 'DESKTOP_PANEL_WRAPPER ordinary_plugin=unconfirmed'; break; fi
            sleep 2
        done
    fi
    result=0
    timeout -k 5 360 setpriv --reuid="$Y700_QA_UID" --regid="$gid" --init-groups env -i \
        HOME=/home/y700 USER=y700 LOGNAME=y700 PATH=/usr/bin:/bin DISPLAY="$DISPLAY" \
        XAUTHORITY="$XAUTHORITY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        "${actor_env[@]}" Y700_TOUCH_REQUEST="$qa/user/request" Y700_TOUCH_ACK="$qa/user/ack" \
        PYTHONUNBUFFERED=1 UV_CACHE_DIR="$qa/user/uv" UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never \
        "$qa/uv" run --offline --no-project --python /usr/bin/python3 python -B "$qa/$actor.py" || result=$?
    printf 'DESKTOP_ACTION_RESULT actor=%s rc=%s\n' "$actor" "$result"
    if ((result != 0)); then overall=1; fi
done
exit "$overall"

