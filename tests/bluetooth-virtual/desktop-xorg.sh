# Sourced only by the marked guest after its private system bus is running.
dpkg-deb -x dummy.deb /
export DISPLAY=:1 GDK_BACKEND=x11 XDG_RUNTIME_DIR=/run/y700-gtk-hid Y700_GTK_HID=1
install -d -m 700 -o y700 -g y700 "$XDG_RUNTIME_DIR"
export XAUTHORITY=$XDG_RUNTIME_DIR/Xauthority
umask 077
# Xau FamilyWild record for display 1 with a fresh MIT-MAGIC-COOKIE-1.
{
    printf '\377\377\000\000\000\0011\000\022MIT-MAGIC-COOKIE-1\000\020'
    head -c 16 /dev/urandom
} > "$XAUTHORITY"
chown y700:y700 "$XAUTHORITY"
umask 022
mkdir -p /run/udev
/usr/lib/systemd/systemd-udevd --daemon
Xorg "$DISPLAY" -config /opt/y700-virtual-hid/dummy.conf -auth "$XAUTHORITY" -nolisten tcp -noreset \
    -logfile /run/Xorg.log >/run/Xorg.stderr 2>&1 & pids+=($!)
wait_for xrandr -q >/dev/null 2>&1
