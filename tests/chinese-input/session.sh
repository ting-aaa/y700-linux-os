#!/usr/bin/env bash
set -euo pipefail
export CHINESE_INPUT_TEST_DIR=/run/chinese-input
export CHINESE_INPUT_BUNDLE=${CHINESE_INPUT_BUNDLE:-/opt/chinese-input}
export PATH=$CHINESE_INPUT_BUNDLE/bin:$PATH
export HOME=$CHINESE_INPUT_TEST_DIR/home XDG_RUNTIME_DIR=$CHINESE_INPUT_TEST_DIR/user
export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache
export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state
# The virtual output represents the dev9 internal-panel scale profile.
export XDG_CONFIG_DIRS=/usr/share/y700/tablet-xdg:/etc/xdg
export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP=xfce
export GDK_BACKEND=x11 GTK_USE_PORTAL=0 LC_ALL=C.UTF-8 UV_OFFLINE=1 UV_CACHE_DIR=$XDG_CACHE_HOME/uv
unset LD_LIBRARY_PATH WAYLAND_DISPLAY DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS SESSION_MANAGER
unset GTK_IM_MODULE QT_IM_MODULE XMODIFIERS GDK_SCALE GDK_DPI_SCALE GSETTINGS_BACKEND
test "$(id -un)" = y700
test "$(dpkg --print-architecture)" = arm64
mkdir -m700 "$HOME" "$XDG_RUNTIME_DIR"
cd "$HOME"
dbus-run-session -- bash -s <<'SESSION'
set -euo pipefail
Xvfb -displayfd 3 -screen 0 2560x1600x24 -nolisten tcp 3>"$XDG_RUNTIME_DIR/display" \
    >"$CHINESE_INPUT_TEST_DIR/display.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in {1..100}; do [[ ! -s $XDG_RUNTIME_DIR/display ]] || break; sleep .1; done
export DISPLAY=:"$(cat "$XDG_RUNTIME_DIR/display")"
xdpyinfo >/dev/null
dbus-update-activation-environment DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR
rc=0
/etc/X11/Xsession "$CHINESE_INPUT_BUNDLE/desktop.sh" || rc=$?
if [[ -s $CHINESE_INPUT_TEST_DIR/result.log ]]; then
    cat "$CHINESE_INPUT_TEST_DIR/result.log"
else
    echo 'CHINESE_INPUT_ERROR no-session-result' >&2
fi
if (( rc != 0 )); then cp "$HOME/.xsession-errors" "$CHINESE_INPUT_TEST_DIR/xsession.log" || true; fi
exit "$rc"
SESSION
