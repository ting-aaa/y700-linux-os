#!/bin/bash
set -euo pipefail
umask 077
[[ $(id -un) == y700 && -z $(ls -A /sys) && ! -e /dev/input && ! -e /dev/dri && ! -e /dev/snd ]]
[[ ! -e /run/dbus/system_bus_socket && -z $(find /dev -type b -print -quit) ]]
[[ $(awk '/CapEff:/ {print $2}' /proc/self/status) == 0000000000000000 ]]
export XAUTHORITY="$XDG_RUNTIME_DIR/Xauthority"
{ printf '\377\377\000\000\000\00273\000\022MIT-MAGIC-COOKIE-1\000\020'; head -c 16 /dev/urandom; } >"$XAUTHORITY"
Xvfb "$DISPLAY" -screen 0 2560x1600x24 -auth "$XAUTHORITY" -nolisten tcp >"$XDG_RUNTIME_DIR/xvfb.log" 2>&1 &
xserver=$!
cleanup() {
    local rc=$?
    if (( rc )); then
        xwininfo -root -tree 2>/dev/null | grep -Ei 'Thunar|Onboard' | head -12 >&2 || :
        tail -12 "$XDG_RUNTIME_DIR/thunar.log" >&2 2>/dev/null || :
        ls -A "$HOME/Y700-RAM-check" >&2 2>/dev/null || :
    fi
    kill "$xserver" 2>/dev/null || :
}
trap cleanup EXIT
trap 'echo "RAM_USERSPACE desktop_failed_at_line=$LINENO" >&2' ERR
for _ in {1..60}; do xdpyinfo >/dev/null 2>&1 && break; kill -0 "$xserver"; sleep .1; done
xdpyinfo | awk '/dimensions:/ {found=($2=="2560x1600")} END {exit !found}'
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_SCALE
xfce4-session >"$XDG_RUNTIME_DIR/session.log" 2>&1 &
xfce=$!
for process in xfwm4 xfce4-panel xfdesktop onboard; do
    for _ in {1..120}; do pgrep -x "$process" >/dev/null && break; kill -0 "$xfce"; sleep .2; done
    if ! pgrep -x "$process" >/dev/null; then
        echo "Missing candidate desktop process $process" >&2
        tail -35 "$XDG_RUNTIME_DIR/session.log" >&2
        exit 1
    fi
done
echo 'RAM_USERSPACE ordinary_xfce=xfwm4,panel,xfdesktop,onboard display=2560x1600 gtk_scale=2'
keyboard_visible() {
    local owner
    owner=$(gdbus call --session --timeout 1 --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.onboard.Onboard 2>/dev/null |
        sed -nE "s/^\('(:[0-9.]+)',\)$/\1/p")
    [[ -n $owner ]] || return 1
    gdbus call --session --timeout 1 --dest "$owner" --object-path /org/onboard/Onboard/Keyboard \
        --method org.freedesktop.DBus.Properties.Get org.onboard.Onboard.Keyboard Visible 2>/dev/null
}
for _ in {1..150}; do [[ $(keyboard_visible) == '(<false>,)' ]] && break; sleep .2; done
[[ $(keyboard_visible) == '(<false>,)' ]]
mkdir "$HOME/Y700-RAM-check"
thunar "$HOME/Y700-RAM-check" >"$XDG_RUNTIME_DIR/thunar.log" 2>&1 &
window=$(timeout 20 xdotool search --sync --onlyvisible --name '^Y700-RAM-check - Thunar$' | head -1)
xdotool windowactivate --sync "$window"
xdotool key ctrl+shift+n
dialog=$(timeout 12 xdotool search --sync --onlyvisible --name '^Create New Folder$' | head -1)
xdotool windowactivate --sync "$dialog"
for _ in {1..80}; do [[ $(keyboard_visible) == '(<true>,)' ]] && break; sleep .1; done
[[ $(keyboard_visible) == '(<true>,)' ]]
keyboard=
while read -r candidate; do
    read -r width height < <(xdotool getwindowgeometry --shell "$candidate" |
        awk -F= '$1=="WIDTH"{w=$2} $1=="HEIGHT"{h=$2} END{print w,h}')
    if (( width > 250 && height > 70 )); then keyboard=$candidate; break; fi
done < <(xdotool search --onlyvisible --class '^Onboard$')
[[ -n $keyboard ]]
# Compact layout centres in the mapped keyboard, expressed in thousandths.
for key in '448 500' '251 300' '631 500' '631 500' '616 300'; do
    read -r kx ky <<<"$key"
    xdotool mousemove --window "$keyboard" "$((width*kx/1000))" "$((height*ky/1000))" click 1
done
xdotool key Return
for _ in {1..60}; do [[ -d $HOME/Y700-RAM-check/hello ]] && break; sleep .1; done
test -d "$HOME/Y700-RAM-check/hello"
echo 'RAM_USERSPACE thunar=create-folder onboard_auto_show=true onboard_pointer_keys=hello folder_verified=true'
