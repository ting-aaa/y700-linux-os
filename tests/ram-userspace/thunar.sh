#!/bin/bash
set -euo pipefail
step=thunar_start
trap 'echo "RAM_USERSPACE thunar_failed_at=$step line=$LINENO" >&2' ERR
keyboard_visible() {
    local owner
    owner=$(gdbus call --session --timeout 1 --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.onboard.Onboard 2>/dev/null |
        sed -nE "s/^\('(:[0-9.]+)',\)$/\1/p")
    [[ -n $owner ]] || return 1
    gdbus call --session --timeout 1 --dest "$owner" --object-path /org/onboard/Onboard/Keyboard \
        --method org.freedesktop.DBus.Properties.Get org.onboard.Onboard.Keyboard Visible 2>/dev/null
}
step=initial_onboard_visibility
for _ in {1..150}; do [[ $(keyboard_visible) == '(<false>,)' ]] && break; sleep .2; done
[[ $(keyboard_visible) == '(<false>,)' ]]
step=thunar_window
mkdir "$HOME/Y700-RAM-check"
thunar "$HOME/Y700-RAM-check" >"$XDG_RUNTIME_DIR/thunar.log" 2>&1 &
window=$(timeout 20 xdotool search --sync --onlyvisible --name '^Y700-RAM-check - Thunar$' | head -1)
timeout 8 xdotool windowactivate --sync "$window"
step=create_dialog
xdotool key ctrl+shift+n
dialog=$(timeout 12 xdotool search --sync --onlyvisible --name '^Create New Folder$' | head -1)
timeout 8 xdotool windowactivate --sync "$dialog"
step=onboard_auto_show
for _ in {1..80}; do [[ $(keyboard_visible) == '(<true>,)' ]] && break; sleep .1; done
[[ $(keyboard_visible) == '(<true>,)' ]]
# The D-Bus property can change before the keyboard window becomes viewable.
step=onboard_mapped_geometry
keyboard=
previous=
for _ in {1..80}; do
    while read -r candidate; do
        geometry=$(LC_ALL=C xwininfo -id "$candidate" 2>/dev/null | awk '
            $1=="Width:" {w=$2} $1=="Height:" {h=$2}
            $1=="Map" && $2=="State:" && $3=="IsViewable" {viewable=1}
            END {if (viewable) print w,h}') || geometry=
        [[ -n $geometry ]] || continue
        read -r width height <<<"$geometry"
        (( width > 250 && height > 70 )) || continue
        if [[ "$candidate $geometry" == "$previous" ]]; then
            keyboard=$((candidate))
            break 2
        fi
        previous="$candidate $geometry"
    done < <(LC_ALL=C xwininfo -root -tree 2>/dev/null |
        awk '$2=="\"Onboard\":" && $3=="(\"onboard\"" && $4=="\"Onboard\")" {print $1}')
    sleep .15
done
[[ -n $keyboard ]]
echo "RAM_USERSPACE onboard_mapped=${width}x${height}"
step=onboard_key_input
# Compact layout centres in the mapped keyboard, expressed in thousandths.
for key in '448 500' '251 300' '631 500' '631 500' '616 300'; do
    read -r kx ky <<<"$key"
    xdotool mousemove --window "$keyboard" "$((width*kx/1000))" "$((height*ky/1000))" click 1
done
step=verify_folder
xdotool key Return
for _ in {1..60}; do [[ -d $HOME/Y700-RAM-check/hello ]] && break; sleep .1; done
test -d "$HOME/Y700-RAM-check/hello"
echo 'RAM_USERSPACE thunar=create-folder onboard_auto_show=true onboard_pointer_keys=hello folder_verified=true'
