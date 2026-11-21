#!/bin/bash
set -euo pipefail
[[ $(id -u) == 1000 && -z $(ls -A /sys) ]]
for pattern in '/dev/video*' '/dev/media*' '/dev/dri*' '/dev/udmabuf'; do
    if compgen -G "$pattern" >/dev/null; then exit 1; fi
done
name=org.y700.QuickSettings
bus=(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus)
for _ in {1..80}; do
    if [[ $("${bus[@]}" --method org.freedesktop.DBus.NameHasOwner "$name") == '(true,)' ]]; then break; fi
    sleep .25
done
answer=$("${bus[@]}" --method org.freedesktop.DBus.GetConnectionUnixProcessID "$name")
[[ $answer =~ uint32[[:space:]]+([0-9]+) ]]
pid=${BASH_REMATCH[1]}
tr '\0' '\n' <"/proc/$pid/cmdline" | grep -Fxq -- --tray
[[ $(stat -c %u "/proc/$pid") == 1000 ]]
tag=DEV1213
[[ ${1:-dev12.13} != dev12.15 ]] || tag=DEV1215
echo "${tag}_QUICK_SETTINGS xdg_autostart=1 uid=1000 session_bus_owner=1 tray_process=1 scale=2"
export UV_CACHE_DIR="$XDG_RUNTIME_DIR/uv" UV_PYTHON_DOWNLOADS=never
if [[ ${1:-dev12.13} == dev12.15 ]]; then
    uv run --offline --no-project --python /usr/bin/python3 python -B /qa/observe.py --expect-no-service
else
    uv run --offline --no-project --python /usr/bin/python3 python -B /qa/chooser.py
fi
