"""Observe normal Onboard autostart and real GTK focus on the synthetic seat."""

import os
from pathlib import Path
import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk


CONTROL = Path("/run/onboard-presence/user/request")
DETECTION = "keyboard-device-detection-enabled"
ONBOARD_BUS = "org.onboard.Onboard"
ONBOARD_PATH = "/org/onboard/Onboard/Keyboard"
ONBOARD_IFACE = ONBOARD_BUS + ".Keyboard"


def wait(check, name, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        if check():
            return
        time.sleep(0.08)
    raise RuntimeError(name)


def request(name):
    pending = CONTROL.with_suffix(".pending")
    pending.write_text(name + "\n")
    pending.replace(CONTROL)
    wait(lambda: not CONTROL.exists(), f"guest did not complete {name}", 16)


def main():
    assert os.geteuid() != 0
    cmdline = Path("/proc/cmdline").read_text().split()
    touch = "y700.onboard_focus=touch" in cmdline
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    settings = Gio.Settings.new("org.onboard.auto-show")
    window = Gtk.Window(title="Y700 Onboard hotplug test")
    window.set_decorated(False)
    grid = Gtk.Grid(row_homogeneous=True, column_homogeneous=True)
    button = Gtk.Button(label="Ready")
    entry = Gtk.Entry()
    entry.set_placeholder_text("Touch to edit")
    # The shared emitter taps x=.245, y=.66 once. This field covers a
    # generous central-left band after the Xfce work area is applied.
    grid.attach(button, 1, 1, 5, 1)
    grid.attach(entry, 1, 4, 4, 2)
    grid.attach(Gtk.Box(), 9, 7, 1, 1)
    window.add(grid)

    dbus_error = None

    def call(destination, path, interface, method, parameters, signature):
        # Onboard can query this GTK process through AT-SPI while it handles
        # a focus change. Keep servicing GTK instead of blocking on Onboard.
        result = []

        def finished(connection, reply):
            try:
                result.append(connection.call_finish(reply).unpack())
            except GLib.Error as error:
                result.append(error)

        bus.call(destination, path, interface, method, parameters, GLib.VariantType.new(signature),
                 Gio.DBusCallFlags.NO_AUTO_START, 5000, None, finished)
        while not result:
            GLib.MainContext.default().iteration(True)
        if isinstance(result[0], GLib.Error):
            raise result[0]
        return result[0]

    def visible():
        nonlocal dbus_error
        try:
            owner, = call(
                "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                GLib.Variant("(s)", (ONBOARD_BUS,)), "(s)",
            )
            result, = call(
                owner, ONBOARD_PATH, "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", (ONBOARD_IFACE, "Visible")), "(v)",
            )
            dbus_error = None
            return result
        except GLib.Error as error:
            dbus_error = str(error)
            return None

    def expect_visibility(expected, label):
        stable_since = None

        def stable():
            nonlocal stable_since
            if visible() is not expected:
                stable_since = None
                return False
            now = time.monotonic()
            if stable_since is None:
                stable_since = now
            return now - stable_since >= 0.75

        try:
            wait(stable, label, 20)
        except RuntimeError as error:
            actual = visible()
            raise RuntimeError(f"Onboard visibility mismatch: {label}, expected {expected}, "
                               f"observed {actual}, D-Bus error {dbus_error}") from error

    def edit(expected, label):
        window.present()
        button.grab_focus()
        expect_visibility(False, "blur " + label)
        wait(lambda: window.is_active() and button.is_focus(), "non-editable focus was not established")
        if touch:
            request("tap")
        else:
            entry.grab_focus()
        wait(lambda: entry.is_focus() and window.is_active(), "editor did not receive focus")
        expect_visibility(expected, label)

    wait(lambda: visible() is False, "stock Onboard did not autostart hidden", 110)
    # Wait for the installed session and window manager to settle before the
    # initial map request, rather than positioning a window during login.
    window.maximize()
    window.show_all()
    window.maximize()
    button.grab_focus()
    window.present()
    wait(lambda: window.is_active() and window.get_scale_factor() == 2 and
         window.get_window().get_state() & Gdk.WindowState.MAXIMIZED,
         "GTK desktop did not initialize an active maximized window at 200%", 30)
    assert settings.get_boolean("enabled")
    detection = settings.get_boolean(DETECTION)
    saved = settings.get_user_value(DETECTION)
    if "y700.onboard_profile=external-off" in cmdline:
        assert saved is not None and saved.unpack() is False and not detection
        print("ONBOARD_PROFILE user_value=false preserved=1", flush=True)
    else:
        assert saved is None
    source = "uinput" if touch else "gtk"
    print(f"ONBOARD_PROFILE scale=2 auto_show=true detection={str(detection).lower()} focus_source={source}", flush=True)
    edit(True, "no external input devices")
    request("mouse-on")
    edit(True, "mouse only")
    print("ONBOARD_MOUSE_ONLY editor_focused=1 visible=1", flush=True)

    request("keyboard-on")
    expect_visibility(not detection, "keyboard attached while focused")
    assert entry.is_focus() and window.is_active()
    edit(not detection, "keyboard present")
    print(f"ONBOARD_KEYBOARD editor_focused=1 visible={int(not detection)}", flush=True)
    request("keyboard-off")
    expect_visibility(True, "keyboard disconnected while focused")
    edit(True, "new focus after keyboard removal")
    request("mouse-off")
    edit(True, "mouse removed")
    print("ONBOARD_KEYBOARD_REMOVED editor_focused=1 visible=1", flush=True)

    button.grab_focus()
    expect_visibility(False, "blur before disabling auto-show")
    assert settings.set_boolean("enabled", False)
    Gio.Settings.sync()
    # Stock Onboard opens its manually controlled keyboard when the user
    # switches off auto-show. Dismiss it before checking future focus changes.
    expect_visibility(True, "manual keyboard after disabling auto-show")
    call(ONBOARD_BUS, ONBOARD_PATH, ONBOARD_IFACE, "Hide", None, "()")
    expect_visibility(False, "manual keyboard dismissed")
    assert settings.get_boolean(DETECTION) == detection
    request("keyboard-on")
    edit(False, "auto-show explicitly disabled")
    request("keyboard-off")
    edit(False, "auto-show disabled after removal")
    assert settings.get_user_value("enabled").unpack() is False
    print("ONBOARD_AUTO_SHOW_OPT_OUT user_value=false editor_focused=1 visible=0", flush=True)
    print(f"ONBOARD_PRESENCE_PASS detection={str(detection).lower()}", flush=True)

    if detection or saved is not None:
        settings.reset("enabled")
        Gio.Settings.sync()
        edit(True, "auto-show re-enabled")
        request("keyboard-on")
        expect_visibility(not detection, "keyboard already connected before toggles")
        assert settings.set_boolean(DETECTION, False)
        Gio.Settings.sync()
        expect_visibility(True, "live disabled while keyboard attached and editor focused")
        assert entry.is_focus() and window.is_active()
        assert settings.get_user_value(DETECTION).unpack() is False
        assert settings.set_boolean(DETECTION, True)
        Gio.Settings.sync()
        expect_visibility(False, "live enabled while keyboard attached and editor focused")
        assert entry.is_focus() and window.is_active()
        assert settings.set_boolean(DETECTION, False)
        Gio.Settings.sync()
        expect_visibility(True, "live disabled again while keyboard attached and editor focused")
        button.grab_focus()
        expect_visibility(False, "blur after live changes")
        assert settings.set_boolean(DETECTION, True)
        Gio.Settings.sync()
        expect_visibility(False, "live enabled without a focused entry")
        assert settings.set_boolean(DETECTION, False)
        Gio.Settings.sync()
        expect_visibility(False, "live disabled without a focused entry")
        request("keyboard-off")
        print("ONBOARD_RUNTIME_DETECTION_PASS focused=1 attached=1 hidden_again=1", flush=True)


if __name__ == "__main__":
    main()
