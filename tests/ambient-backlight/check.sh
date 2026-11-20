#!/bin/sh
# Private D-Bus services, a disposable dconf profile and ordinary files for sysfs.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
root=${1:-"$repo/packaging/root"}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
uv=$(command -v uv)
mkdir -m700 "$work/run" "$work/config" "$work/home" "$work/schemas"
export XDG_RUNTIME_DIR="$work/run" XDG_CONFIG_HOME="$work/config" HOME="$work/home"
export XDG_DATA_HOME="$work/data" GSETTINGS_SCHEMA_DIR="$work/schemas" GSETTINGS_BACKEND=dconf
cp "$root/usr/share/glib-2.0/schemas/org.y700.tablet.gschema.xml" "$work/schemas/"
glib-compile-schemas --strict "$work/schemas"
printf 'user-db:user\n' > "$work/profile"
export DCONF_PROFILE="$work/profile" XDG_SESSION_ID=c42 XDG_SESSION_TYPE=x11
mkdir -p "$XDG_DATA_HOME/dbus-1/services"
for name in net.hadess.SensorProxy org.freedesktop.login1 org.xfce.ScreenSaver; do
    printf '[D-BUS Service]\nName=%s\nExec=/usr/bin/touch %s/activated\n' "$name" "$work" \
        > "$XDG_DATA_HOME/dbus-1/services/$name.service"
done
unset DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS
dbus-run-session -- sh -ec '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    unset DBUS_SESSION_BUS_ADDRESS
    exec dbus-run-session -- "$@"
' sh "$uv" run --no-project --offline --python /usr/bin/python3 python -B \
    "$repo/tests/ambient-backlight/check.py" "$root/usr/libexec/y700-ambient-backlight" "$work"
