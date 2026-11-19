#!/usr/bin/env bash
# Entered by Debian Xsession so the test app inherits the installed IM configuration.
set -euo pipefail
bundle=$CHINESE_INPUT_BUNDLE
export PATH=$bundle/bin:$PATH
py=("$bundle/uv" run --offline --no-project --python /usr/bin/python3 python)
root=$CHINESE_INPUT_TEST_DIR
exec >"$root/result.log" 2>&1
session= target=
cleanup() {
    for pid in "$target" "$session"; do
        if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    done
}
trap cleanup EXIT
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null
xfce4-session >"$root/xfce.log" 2>&1 &
session=$!
timeout 35 gdbus wait --session org.onboard.Onboard
timeout 15 gdbus wait --session org.xfce.SettingsDaemon
echo "CHINESE_INPUT_XSESSION gtk=${GTK_IM_MODULE:-unset} xmodifiers=${XMODIFIERS:-unset}"
[[ ${GTK_IM_MODULE:-} == ibus && ${XMODIFIERS:-} == @im=ibus ]]
"${py[@]}" "$bundle/gtk-target.py" >"$root/target.log" 2>&1 &
target=$!
"${py[@]}" "$bundle/probe.py"
