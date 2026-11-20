"""Type a word on the installed Onboard in an ordinary, authenticated EFI desktop."""

import ctypes
import os
import re
import subprocess
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import GdkX11, Gio, GLib, Gtk


BUS = "org.freedesktop.DBus"
BUS_PATH = "/org/freedesktop/DBus"
ONBOARD = "org.onboard.Onboard"
KEYBOARD = "/org/onboard/Onboard/Keyboard"
# Centres of the letter keys in the shipped Compact layout.
KEYS = {"h": (0.448, 0.50), "e": (0.251, 0.30),
        "l": (0.631, 0.50), "o": (0.616, 0.30)}


def wait_until(read, label, seconds):
    deadline = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        for _ in range(24):
            if not context.iteration(False):
                break
        result = read()
        if result:
            return result
        time.sleep(0.15)
    raise RuntimeError(f"Timed out waiting for {label}")


def dbus_call(bus, target, path, interface, method, parameters=None):
    # Onboard can call this application's accessibility bridge during a focus
    # change. Continue dispatching GTK while awaiting its D-Bus reply.
    result = []

    def received(connection, response):
        try:
            result.append(connection.call_finish(response).unpack())
        except GLib.Error as error:
            result.append(error)

    bus.call(target, path, interface, method, parameters, None,
             Gio.DBusCallFlags.NO_AUTO_START, 12000, None, received)
    wait_until(lambda: result, method, 20)
    if isinstance(result[0], GLib.Error):
        raise result[0]
    return result[0][0]


def mapped_bounds(wid):
    reply = subprocess.run(["xwininfo", "-id", str(wid)], capture_output=True, text=True, timeout=12)
    if reply.returncode or "Map State: IsViewable" not in reply.stdout:
        return None
    bounds = {k: int(v) for k, v in re.findall(
        r"^\s*(Absolute upper-left X|Absolute upper-left Y|Width|Height):\s+(-?\d+)", reply.stdout, re.M)}
    return tuple(bounds[k] for k in ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"))


def window_geometry():
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True, timeout=12)
    for line in tree.splitlines():
        if not re.search(r'\("[^"]*" "Onboard"\)', line, re.I):
            continue
        wid = re.match(r"\s*(0x[0-9a-f]+)", line, re.I)
        if not wid:
            continue
        bounds = mapped_bounds(wid[1])
        if bounds and bounds[2] > 250 and bounds[3] > 70:
            return bounds
    return None


def tap(x, y):
    if not (0 <= x < 1024 and 0 <= y < 768):
        raise ValueError(f"Touch outside virtual panel at {x},{y}")
    with open(os.environ["Y700_TOUCH_REQUEST"], "w") as pipe:
        pipe.write(f"tap {x} {y}\n")
    with open(os.environ["Y700_TOUCH_ACK"]) as pipe:
        if pipe.readline().rstrip("\n") != "OK":
            raise RuntimeError("Type-B touch was not acknowledged")


def tap_widget(window, widget):
    allocation = widget.get_allocation()
    x, y = widget.translate_coordinates(window, allocation.width // 2, allocation.height // 2)
    scale = window.get_scale_factor()
    xid = GdkX11.X11Window.get_xid(window.get_window())
    # Xfwm can configure a new client after GTK considers it mapped. Query the
    # actual topmost X window under this point so an early tap cannot hit a panel.
    xlib = ctypes.CDLL("libX11.so.6")
    display_t, xid_t, point_t = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int
    xlib.XOpenDisplay.argtypes, xlib.XOpenDisplay.restype = [ctypes.c_char_p], display_t
    xlib.XDefaultRootWindow.argtypes, xlib.XDefaultRootWindow.restype = [display_t], xid_t
    xlib.XTranslateCoordinates.argtypes = [display_t, xid_t, xid_t, point_t, point_t,
                                           ctypes.POINTER(point_t), ctypes.POINTER(point_t), ctypes.POINTER(xid_t)]
    xlib.XCloseDisplay.argtypes = [display_t]
    display = xlib.XOpenDisplay(None)
    if not display:
        raise RuntimeError("Cannot examine the authenticated X11 display")
    root = xlib.XDefaultRootWindow(display)

    def target():
        bounds = mapped_bounds(xid)
        if not bounds:
            return None
        px, py = bounds[0] + x * scale, bounds[1] + y * scale
        current = root
        child, local_x, local_y = xid_t(), point_t(), point_t()
        while current:
            if current == xid:
                return px, py
            if not xlib.XTranslateCoordinates(display, root, current, px, py, ctypes.byref(local_x),
                                              ctypes.byref(local_y), ctypes.byref(child)):
                break
            current = child.value
        return None

    try:
        px, py = wait_until(target, "unobscured GTK control on the X11 output", 40)
        print(f"DESKTOP_KEYBOARD target={widget.__class__.__name__} x={px} y={py}", flush=True)
        tap(px, py)
    finally:
        xlib.XCloseDisplay(display)


def main():
    if os.getuid() == 0:
        raise RuntimeError("The desktop actor must be an ordinary user")
    print("DESKTOP_KEYBOARD stage=connect", flush=True)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    args = GLib.Variant("(s)", (ONBOARD,))
    wait_until(lambda: dbus_call(bus, BUS, BUS_PATH, BUS, "NameHasOwner", args),
               "ordinary Onboard session-bus owner", 125)
    pid = dbus_call(bus, BUS, BUS_PATH, BUS, "GetConnectionUnixProcessID", args)
    proc = Path(f"/proc/{pid}")
    if proc.stat().st_uid != os.getuid() or (proc / "comm").read_text().strip() != "onboard":
        raise RuntimeError("Unexpected Onboard owner process or user")
    layout = Gio.Settings.new("org.onboard").get_string("layout")
    if layout and Path(layout).stem != "Compact":
        raise RuntimeError(f"Expected the shipped Compact layout, got {layout!r}")
    print("DESKTOP_KEYBOARD owner=ordinary-onboard layout=Compact", flush=True)

    wait_start = time.monotonic()
    seen_errors = set()

    def visible():
        prop = GLib.Variant("(ss)", (ONBOARD + ".Keyboard", "Visible"))
        try:
            owner = dbus_call(bus, BUS, BUS_PATH, BUS, "GetNameOwner", args)
            return dbus_call(bus, owner, KEYBOARD, "org.freedesktop.DBus.Properties", "Get", prop)
        except GLib.Error as error:
            # Onboard takes its well-known name before its keyboard object has
            # been exported. Missing the object cannot prove hidden or visible.
            remote = Gio.DBusError.get_remote_error(error)
            if remote not in {"org.freedesktop.DBus.Error.UnknownMethod", "org.freedesktop.DBus.Error.UnknownObject",
                              "org.freedesktop.DBus.Error.NameHasNoOwner", "org.freedesktop.DBus.Error.NoReply"}:
                raise
            if remote not in seen_errors:
                print(f"DESKTOP_KEYBOARD awaiting_object={remote}", flush=True)
                seen_errors.add(remote)
            return None

    window = Gtk.Window(title="Y700 touch typing")
    window.set_default_size(320, 120)
    window.move(35, 100)
    window.set_keep_above(True)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    button = Gtk.Button(label="Ready")
    button_taps = []
    button.connect("clicked", lambda *_: button_taps.append(True))
    entry = Gtk.Entry()
    entry.get_accessible().set_name("Y700 text entry")
    initial = "sample "
    entry.set_text(initial)
    box.pack_start(button, True, True, 0)
    box.pack_start(entry, True, True, 0)
    window.add(box)
    window.set_focus(button)
    window.show_all()
    window.present()
    try:
        wait_until(lambda: button.get_mapped() and entry.get_mapped(), "mapped GTK controls", 45)
        tap_widget(window, button)
        wait_until(lambda: button_taps and window.is_active(), "touch to activate the application", 35)
        wait_until(lambda: visible() is False, "exported keyboard hidden before touch", 155)
        print(f"DESKTOP_KEYBOARD exported=1 hidden=1 wait_seconds={time.monotonic() - wait_start:.1f}", flush=True)
        tap_widget(window, entry)
        wait_until(entry.is_focus, "entry to acquire focus from touch", 20)
        wait_until(lambda: visible() is True, "automatic on-screen keyboard after touching entry", 65)
        x, y, width, height = wait_until(window_geometry, "mapped Onboard window", 25)
        print(f"DESKTOP_KEYBOARD touch_focus=1 visible=1 geometry={x},{y},{width},{height}", flush=True)
        expected = initial
        for letter in "hello":
            dx, dy = KEYS[letter]
            tap(x + round(dx * width), y + round(dy * height))
            expected += letter
            try:
                wait_until(lambda: entry.get_text() == expected, f"GTK entry to receive {letter!r}", 12)
            except RuntimeError:
                print(f"DESKTOP_KEYBOARD text_expected={expected!r} synthetic_entry={entry.get_text()!r}", flush=True)
                raise
        print("DESKTOP_KEYBOARD_PASS source=type-b committed=hello auto_show=1", flush=True)
    finally:
        window.destroy()
        GLib.MainContext.default().iteration(False)


if __name__ == "__main__":
    main()
