"""Operate the sealed brightness window in the private, hardware-free Xfce session."""
import os
import signal
import subprocess
from pathlib import Path

from probe import Atspi, Gdk, Gio, GLib, named, tap, wait_for


def application_window(pid):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(index)
            if app and app.get_process_id() == pid:
                return named(app, Atspi.Role.FRAME, "Tablet brightness")
        except GLib.Error:
            # A just-registered AT-SPI application can still be starting.
            continue
    return None


def brightness_pid(bus):
    try:
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.y700.TabletBrightness",)),
                              GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NO_AUTO_START, 1000, None)
    except GLib.Error as error:
        if Gio.DBusError.get_remote_error(error) == "org.freedesktop.DBus.Error.NameHasNoOwner":
            return None
        raise
    return reply.unpack()[0]


def main():
    assert os.getuid() != 0 and os.environ["DISPLAY"] == ":73"
    assert not any(Path("/sys").iterdir()) and not Path("/run/dbus/system_bus_socket").exists()
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    settings = Gio.Settings.new("org.y700.tablet")
    key = "automatic-brightness"
    assert not settings.get_boolean(key)
    Atspi.init()
    Atspi.set_timeout(2000, 2000)
    entry = Gio.DesktopAppInfo.new("y700-tablet-brightness.desktop")
    assert entry and entry.get_executable() == "/usr/libexec/y700-tablet-brightness"
    assert entry.launch([], Gdk.Display.get_default().get_app_launch_context())
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    pid = wait_for(lambda: brightness_pid(bus), "brightness application bus owner", timeout=25)
    fd = os.pidfd_open(pid)
    try:
        check_window(pid, key)
    finally:
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(fd)


def check_window(pid, key):
    frame = wait_for(lambda: application_window(pid), "brightness window", timeout=25)
    toggle = wait_for(lambda: named(frame, Atspi.Role.CHECK_BOX, "Automatic brightness"), "automatic checkbox")
    assert named(frame, Atspi.Role.LABEL, "Internal backlight unavailable.")
    for enabled in (True, False):
        bounds = toggle.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        assert bounds.width >= 50 and bounds.height >= 56
        tap(toggle, bounds)
        wait_for(lambda: toggle.get_state_set().contains(Atspi.StateType.CHECKED) == enabled
                 and subprocess.check_output(["gsettings", "get", "org.y700.tablet", key],
                                             text=True, timeout=3).strip() == str(enabled).lower(),
                 f"automatic brightness {enabled}")
        if enabled:
            wait_for(lambda: named(frame, Atspi.Role.LABEL, "Waiting for the ambient light sensor."),
                     "no-sensor feedback")
    print("RAM_USERSPACE brightness=desktop-entry ordinary=1 checkbox=off-on-off "
          "private_dconf=confirmed feedback=missing-sensor physical_backlight=hidden", flush=True)


if __name__ == "__main__":
    main()
