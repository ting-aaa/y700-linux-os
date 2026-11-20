#!/bin/sh
# Run on Linux with uv, python3-gi, dconf, dbus-daemon and GLib 2.84+ with its schema compiler.
# An optional argument tests the client and schema from an extracted Debian package.
# Y700_ROTATION_CASE=lock runs just the lock transitions, sensor the original lifecycle matrix.
set -eu
mode=${Y700_ROTATION_CASE:-all}
case $mode in all|lock|sensor) ;; *) exit 2 ;; esac
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
client="$repo/src/sensors/y700-auto-rotate.py"
schemas="$repo/packaging/root/usr/share/glib-2.0/schemas"
if [ "$#" -eq 1 ]; then
    client="$1/usr/lib/y700/y700-auto-rotate.py"
    schemas="$1/usr/share/glib-2.0/schemas"
elif [ "$#" -gt 1 ]; then
    exit 2
fi
uv=$(command -v uv)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m 700 "$work/home" "$work/config" "$work/run" "$work/schemas"
cp "$schemas/org.y700.tablet.gschema.xml" "$work/schemas/"
glib-compile-schemas --strict "$work/schemas"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_RUNTIME_DIR="$work/run"
export XDG_DATA_HOME="$work/data"
services=$XDG_DATA_HOME/dbus-1/services
mkdir -p "$services"
cat >"$work/activation-sentinel" <<'SENTINEL'
#!/bin/sh
echo "$1" >> "${0%/*}/activated"
exit 1
SENTINEL
chmod +x "$work/activation-sentinel"
for name in org.xfce.ScreenSaver org.freedesktop.login1 net.hadess.SensorProxy; do
    cat >"$services/$name.service" <<EOF
[D-BUS Service]
Name=$name
Exec="$work/activation-sentinel" $name
EOF
done
export GSETTINGS_SCHEMA_DIR="$work/schemas" GSETTINGS_BACKEND=dconf
printf '%s\n' 'user-db:user' > "$work/dconf-profile"
export DCONF_PROFILE="$work/dconf-profile"
export XDG_SESSION_TYPE=x11 XDG_SESSION_ID=c42 DISPLAY=:4242
unset DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS

# The fake system bus only hosts the two providers. The private session bus
# activates dconf with the same isolated profile as the rotation client.
dbus-run-session -- sh -ec '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    unset DBUS_SESSION_BUS_ADDRESS
    exec dbus-run-session -- "$@"
' sh "$uv" run --offline --no-project --python /usr/bin/python3 python \
    "$repo/tests/rotation-session.py" "$client" "$work" "$mode"
