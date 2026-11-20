#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) != 0 ]]
for name in org.xfce.Panel org.xfce.Xfconf org.xfce.PowerManager; do
    [[ $(gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus -m org.freedesktop.DBus.NameHasOwner "$name") == '(false,)' ]]
done
work=$(mktemp -d -- "${XDG_RUNTIME_DIR:?}/y700-tray.XXXXXXXX")
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config XDG_DATA_HOME=$work/home/.local/share XDG_CACHE_HOME=$work/home/.cache
cd "$work"
screen=${Y700_TRAY_SCREEN:-1024x768}
export GDK_SCALE=${GDK_SCALE:-1}
panel_size=${Y700_TRAY_PANEL_SIZE:-40}
[[ $screen =~ ^[0-9]{3,4}x[0-9]{3,4}$ && $GDK_SCALE =~ ^[12]$ && $panel_size =~ ^[1-9][0-9]?$ ]]
expected_primary=${Y700_TRAY_EXPECT_PRIMARY:-auto}
if [[ $expected_primary == auto ]]; then
    case $(dpkg-query -W -f='${Version}' xfce4-power-manager) in
        4.20.0-1) expected_primary=absent ;;
        4.20.0-1+y7001) expected_primary=visible ;;
        *) echo 'Set Y700_TRAY_EXPECT_PRIMARY for this manager version' >&2; exit 2 ;;
    esac
fi
expected_context=${Y700_TRAY_EXPECT_CONTEXT:-visible}
[[ $expected_primary =~ ^(visible|absent)$ && $expected_context =~ ^(visible|absent)$ ]]
export DISPLAY=:74 XAUTHORITY=$HOME/Xauthority XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
export GTK_USE_PORTAL=0 XDG_CONFIG_DIRS=/etc/xdg:/usr/share/y700/power-xdg
mkdir -p "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
cp /run/panel.xml "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
# FamilyWild, empty address, display 74, and a random MIT-MAGIC-COOKIE-1.
(umask 077; { printf '\377\377\000\000\000\00274\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c16 /dev/urandom; } > "$XAUTHORITY")
Xvfb "$DISPLAY" -auth "$XAUTHORITY" -screen 0 "${screen}x24" -nolisten tcp > xvfb.log 2>&1 & xp=$!
panel= manager=
cleanup_tray() {
    for pid in "$manager" "$panel" "$xp"; do
        [[ -z $pid ]] || kill "$pid" 2>/dev/null || :
    done
    wait || :
    rm -r --one-file-system -- "$work"
}
trap cleanup_tray EXIT
wait_for() {
    local end=$((SECONDS + 25))
    until "$@"; do
        if (( SECONDS >= end )); then cat panel.log manager.log xvfb.log 2>/dev/null >&2 || :; xwininfo -root -tree >&2 || :; return 1; fi
        sleep .2
    done
}
ready() { xdpyinfo >/dev/null 2>&1; }
wait_for ready
dbus-update-activation-environment DISPLAY XAUTHORITY HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME \
    XDG_CONFIG_DIRS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_SCALE
xfce4-panel --disable-wm-check >panel.log 2>&1 & panel=$!
timeout 25 gdbus wait --session org.xfce.Panel
pref=(xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/show-tray-icon)
[[ $("${pref[@]}") == true ]]
start_manager() { xfce4-power-manager --debug >manager.log 2>&1 & manager=$!; }
start_manager
windows() {
    xwininfo -root -tree | awk 'tolower($0) ~ /xfce4-power-manager/ && $1 ~ /^0x/ {print $1}'
}
mapped() { xwininfo -id "$1" 2>/dev/null | grep -q 'Map State: IsViewable'; }
icon() {
    local wid
    for wid in $(windows); do
        if mapped "$wid" && xprop -id "$wid" _XEMBED_INFO | grep -q ' = '; then
            echo "$wid"; return 0
        fi
    done
    return 1
}
menu() {
    local wid
    for wid in $(windows); do
        if mapped "$wid" && xprop -id "$wid" _NET_WM_WINDOW_TYPE | grep -Eq '_NET_WM_WINDOW_TYPE_(POPUP|DROPDOWN)_MENU'; then
            echo "$wid"; return 0
        fi
    done
    return 1
}
wait_for icon
id=$(icon)
[[ $(xprop -id "$id" _NET_WM_PID) == *"= $manager" ]]
owner=$id
for ((depth=0; depth<12; depth++)); do
    if [[ $(xprop -id "$owner" _NET_WM_PID) == *"= $panel" ]]; then break; fi
    owner=$(xwininfo -id "$owner" -tree | awk '/Parent window id:/ {print $4}')
    [[ $owner =~ ^0x[0-9a-f]+$ && $owner != 0x0 ]]
done
[[ $(xprop -id "$owner" _NET_WM_PID) == *"= $panel" ]]
geometry() { xwininfo -id "$1" | awk '
    /Absolute upper-left X:/ {x=$NF} /Absolute upper-left Y:/ {y=$NF}
    /Width:/ {w=$NF} /Height:/ {h=$NF} END{print x,y,w,h}'; }
read -r x y w h < <(geometry "$id")
(( x>=0 && y>=0 && w>4 && h>4 && y+h<=panel_size*GDK_SCALE ))
echo "TRAY_DOCKED screen=$screen scale=$GDK_SCALE icon=$id manager=$manager geometry=$x,$y,$w,$h"
xdotool mousemove "$((x+w/2))" "$((y+h/2))" click 1
click_result() {
    local expected=$1 label=$2 actual=absent
    for ((i=0;i<12;i++)); do
        if menu >/dev/null; then actual=visible; break; fi
        sleep .1
    done
    echo "TRAY_$label menu=$actual"
    [[ $actual == "$expected" ]]
    if [[ $actual == visible ]]; then
        local popup mx my mw mh sid spid
        popup=$(menu)
        [[ $(xprop -id "$popup" _NET_WM_PID) == *"= $manager" ]]
        read -r mx my mw mh < <(geometry "$popup")
        echo "TRAY_POPUP id=$popup owner_pid=$manager geometry=$mx,$my,$mw,$mh type=$(xprop -id "$popup" _NET_WM_WINDOW_TYPE | awk '{print $NF}')"
        (( mx>=0 && my>=0 && mw>30 && mh>30 && mx+mw<=${screen%x*} && my+mh<=${screen#*x} ))
        # Settings is the last item in the stock manager's own GTK menu.
        xdotool key End Return
        wait_for settings_window
        sid=$(settings_window); spid=$(xdotool getwindowpid "$sid")
        echo "TRAY_SETTINGS_FROM_MENU window=$sid process=$spid"
        kill "$spid"
        wait_for closed
    fi
}
closed() { ! menu >/dev/null; }
settings_window() {
    local wid pid
    for wid in $(xdotool search --onlyvisible --class 'xfce4-power-manager-settings' 2>/dev/null || :); do
        pid=$(xdotool getwindowpid "$wid") || continue
        if [[ -r /proc/$pid/cmdline ]] && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Eq '(^|/)xfce4-power-manager-settings$'; then
            echo "$wid"; return 0
        fi
    done
    return 1
}
click_result "$expected_primary" PRIMARY
xdotool click 3
click_result "$expected_context" CONTEXT
if [[ ${Y700_TRAY_CHECK_RETURN:-0} == 1 ]]; then
    xdotool windowfocus --sync "$id"
    [[ $(xdotool getwindowfocus -f) == "$((id))" ]]
    xdotool key Return
    click_result visible FOCUSED_RETURN
fi
absent() { ! icon >/dev/null; }
"${pref[@]}" -s false
wait_for absent
kill "$manager"
wait "$manager" || :
start_manager
timeout 25 gdbus wait --session org.xfce.PowerManager
[[ $("${pref[@]}") == false ]] && absent
"${pref[@]}" -s true
wait_for icon
echo TRAY_USER_OVERRIDE_AND_RESTORE_PASS
