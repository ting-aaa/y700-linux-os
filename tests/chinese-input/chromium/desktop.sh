#!/usr/bin/env bash
set -euo pipefail
bundle=$CHINESE_INPUT_BUNDLE
export PATH=$bundle/bin:$PATH
root=$CHINESE_INPUT_TEST_DIR
py=("$bundle/uv" run --offline --no-project --python /usr/bin/python3 python)
exec >"$root/result.log" 2>&1
session= target= server=
cleanup() {
    local status=$?
    if (( status != 0 )); then
        tail -25 "$root/target.log" || true
        xwininfo -root -tree | tail -40 || true
    fi
    for pid in "$target" "$server" "$session"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    done
}
trap cleanup EXIT
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null
xfce4-session >"$root/xfce.log" 2>&1 &
session=$!
timeout 80 gdbus wait --session org.onboard.Onboard
timeout 30 gdbus wait --session org.xfce.SettingsDaemon
echo "CHINESE_INPUT_XSESSION gtk=${GTK_IM_MODULE:-unset} xmodifiers=${XMODIFIERS:-unset}"
[[ ${GTK_IM_MODULE:-} == ibus && ${XMODIFIERS:-} == @im=ibus ]]
"${py[@]}" "$bundle/browser-target.py" >"$root/server.log" 2>&1 &
server=$!
for _ in {1..100}; do [[ ! -e $root/browser-server ]] || break; sleep .1; done
test -f "$root/browser-server"
chromium --user-data-dir="$HOME/chromium-fixture" --no-first-run --no-default-browser-check \
    --disable-background-networking --disable-gpu --ozone-platform=x11 --force-renderer-accessibility \
    --window-position=140,0 --window-size=960,270 --app=http://127.0.0.1:8938/ >"$root/target.log" 2>&1 &
target=$!
for _ in {1..180}; do [[ ! -e $root/browser.json ]] || break; sleep .2; done
test -f "$root/browser.json"
"${py[@]}" "$bundle/browser-probe.py"
