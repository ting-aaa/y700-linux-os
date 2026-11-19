#!/usr/bin/env bash
# Exercise the installed Xsession fragment with captured and synthetic RandR topologies.
set -eu
hook=${1:-/etc/X11/Xsession.d/60y700_tablet_scale}
profile=/usr/share/y700/tablet-xdg
native='DSI-1 connected primary 1600x2560+0+0 (normal left inverted right x axis y axis) 0mm x 0mm'
rotated='DSI-1 connected 2560x1600+0+0 left (normal left inverted right x axis y axis) 118mm x 190mm'
external='DP-1 connected 1920x1080+2560+0 (normal left inverted right x axis y axis)'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
check() (
    BASESTARTUP=$1
    printf '%s\0qcom,sm8475\0' "$2" > "$work/compatible"
    topology=$3
    XDG_CONFIG_DIRS=$4
    expected=$5
    grep() {
        [[ ${!#} == /proc/device-tree/compatible ]]
        command grep "${@:1:$#-1}" "$work/compatible"
    }
    xrandr() {
        [[ $* == --current ]]
        printf '%s\n' "$topology"
    }
    . "$hook"
    [[ $XDG_CONFIG_DIRS == "$expected" ]]
)
check startxfce4 lenovo,asphalt "$native" '' "$profile:/etc/xdg"
check xfce4-session lenovo,asphalt "$rotated"$'\n''DP-1 connected (normal left)' /opt/site:/etc/xdg "$profile:/opt/site:/etc/xdg"
check startxfce4 lenovo,asphalt "$rotated"$'\n'"$external" /opt/site /opt/site
check startxfce4 lenovo,asphalt "$external" '' ''
check startxfce4 lenovo,asphalt 'DSI-1 connected 800x1280+0+0' '' ''
check startxfce4 lenovo,asphalt '' '' ''
check startxfce4 qcom,another-board "$native" '' ''
check gnome-session lenovo,asphalt "$native" /etc/xdg /etc/xdg
echo 'PASS Xsession topology, desktop, board and XDG search path'
