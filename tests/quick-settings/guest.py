"""Exercise the installed GTK code, Xfce tray and emulated direct touchscreen."""
from pathlib import Path
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, "/usr/libexec/y700-quick-settings")
import devices
import panel
from gi.repository import Gdk, GdkX11, Gio, GLib

assert os.getuid() != 0
assert Path("/proc/device-tree/compatible").read_bytes().startswith(b"linux,dummy-virt")
devices.BACKLIGHT = Path(os.environ["XDG_RUNTIME_DIR"]) / devices.BACKLIGHT.name
devices.BACKLIGHT.mkdir()
(devices.BACKLIGHT / "brightness").write_text("400")
(devices.BACKLIGHT / "max_brightness").write_text("2000")
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
for name in ("org.freedesktop.login1", "org.bluez"):
    ans, = devices.system_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                               "RequestName", GLib.Variant("(su)", (name, 0)))
    assert ans == 1

blue = False


def request(_bus, _sender, _path, _interface, method, arguments, invocation):
    args = arguments.unpack()
    if method == "SetBrightness":
        subsystem, device, raw = args
        assert subsystem == "backlight" and device == devices.BACKLIGHT.name and 100 <= raw <= 2000
        (devices.BACKLIGHT / "brightness").write_text(str(raw))
        answer = None
    elif method == "GetManagedObjects":
        answer = GLib.Variant("(a{oa{sa{sv}}})", ({"/org/bluez/hci0": {
            "org.bluez.Adapter1": {"Powered": GLib.Variant("b", blue)}}},))
    else:
        raise AssertionError(method)
    invocation.return_value(answer)


def register(path, interface, methods):
    info = Gio.DBusNodeInfo.new_for_xml(f"<node><interface name='{interface}'>{methods}</interface></node>")
    bus.register_object(path, info.interfaces[0], request, None, None)


register("/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session",
         "<method name='SetBrightness'><arg type='s'/><arg type='s'/><arg type='u'/></method>")
register("/", "org.freedesktop.DBus.ObjectManager",
         "<method name='GetManagedObjects'><arg type='a{oa{sa{sv}}}' direction='out'/></method>")


def radio_property(_bus, _sender, _path, _interface, _property):
    return GLib.Variant("b", blue)


def set_radio_property(_bus, _sender, _path, _interface, _property, value):
    global blue
    blue = value.unpack()
    return True


iface = Gio.DBusNodeInfo.new_for_xml("<node><interface name='org.bluez.Adapter1'>"
    "<property name='Powered' type='b' access='readwrite'/></interface></node>")
bus.register_object("/org/bluez/hci0", iface.interfaces[0], None, radio_property, set_radio_property)

context = GLib.MainContext.default()
def wait(test, label):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for _ in range(50):
            if not context.pending():
                break
            context.iteration(False)
        if test():
            return
        time.sleep(.02)
    win = app.window
    if win:
        pointer = Gdk.Display.get_default().get_default_seat().get_pointer()
        print("POINTER", pointer.get_position(), pointer.get_window_at_position(), flush=True)
        print(subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)[-7000:], flush=True)
        print("XFWM", Path(os.environ["XDG_RUNTIME_DIR"], "wm.log").read_text()[-1600:], flush=True)
        print(f"STATE visible={win.get_visible()} active={win.is_active()} pos={win.get_position()} size={win.get_size()} "
              f"state={win.states} errors={win.failed_write} radio={win.radio.get_active()}", flush=True)
    raise AssertionError(label)


class ObservedQuickSettings(panel.QuickSettings):
    releases = 0

    def tray_release(self, icon, event):
        self.releases += 1
        return super().tray_release(icon, event)


app = ObservedQuickSettings()
assert app.register(None)
app.ensure_tray()
wait(lambda: app.tray.is_embedded() and app.tray.get_geometry()[2].width > 0, "Xfce tray")
screen = Gdk.Screen.get_default()
factor = screen.get_monitor_scale_factor(0)
assert factor == 2


def send(action, *points):
    coordinates = []
    for x, y in points:
        coordinates.extend((round(x * 16000 / screen.get_width()), round(y * 25600 / screen.get_height())))
    with open("/run/topology/feed", "w") as feed:
        print(action, *coordinates, file=feed)
        print(f"INPUT {action} logical={points!r} ABS={coordinates!r}", flush=True)


def origin():
    # Xfwm may reparent the client before GTK updates its cached position.
    xid = GdkX11.X11Window.get_xid(app.window.get_window())
    geometry = subprocess.check_output(["xwininfo", "-id", hex(xid)], text=True, env={**os.environ, "LC_ALL": "C"})
    if "Map State: IsViewable" not in geometry:
        return None
    ox = int(re.search(r"Absolute upper-left X:\s*(-?\d+)", geometry)[1]) / factor
    oy = int(re.search(r"Absolute upper-left Y:\s*(-?\d+)", geometry)[1]) / factor
    return ox, oy


def point(widget, fraction=.5):
    ox, oy = origin()
    x, y = widget.translate_coordinates(app.window, 0, 0)
    return ox + x + fraction * widget.get_allocated_width(), oy + y + widget.get_allocated_height() / 2


def tray_point():
    _, _, rect, _ = app.tray.get_geometry()
    return rect.x + rect.width / 2, rect.y + rect.height / 2


x, y = tray_point()
print(f"TRAY geometry={x},{y} root={screen.get_width()},{screen.get_height()} scale={factor}", flush=True)
send("slide", (x, y), (x, y + 64))
wait(lambda: app.window and app.window.get_visible(), "downward touch gesture on the tray")
win = app.window
wait(lambda: win.states.get("audio") is not None and win.states.get("bluetooth") is not None and
     win.states.get("brightness") == 20, "initial backend status")
print("QUICK_SETTINGS gesture=down scale=2 backend=ready", flush=True)
wait(lambda: (pos := origin()) is not None and pos[1] >= tray_point()[1], "window below the tray")
wait(lambda: win.radio.get_allocated_width() >= 56 and win.radio.get_allocated_height() >= 50, "panel layout")
send("tap", point(win.radio))
wait(lambda: blue and win.radio.get_active() and "bluetooth" not in win.busy, "turn Bluetooth on")
send("tap", point(win.radio))
wait(lambda: not blue and not win.radio.get_active(), "turn Bluetooth off")
initial_rotation = win.rotation.get_boolean("auto-rotate")
send("tap", point(win.rotate))
wait(lambda: win.rotation.get_boolean("auto-rotate") != initial_rotation, "rotation switch")
win.rotation.set_boolean("auto-rotate", initial_rotation)
wait(lambda: win.rotate.get_active() == initial_rotation, "external rotation state")
light = win.levels["brightness"].scale
send("slide", point(light, .20), point(light, .70))
wait(lambda: 1150 < int((devices.BACKLIGHT / "brightness").read_text()) < 1650, "drag backlight")
volume = win.levels["volume"].scale
send("tap", point(volume, .68))
wait(lambda: .50 <= float(devices.wpctl("get-volume", devices.DEFAULT_SINK).split()[1]) <= .80,
     "PipeWire volume")
send("tap", point(win.mute))
wait(lambda: "[MUTED]" in devices.wpctl("get-volume", devices.DEFAULT_SINK), "PipeWire mute")
devices.wpctl("set-mute", devices.DEFAULT_SINK, "0")
wait(lambda: not win.mute.get_active(), "external mute")
win.hide()
wait(lambda: not win.get_visible(), "dismiss")
send("tap", tray_point())
wait(lambda: win.get_visible(), "tap to reopen")
app.set_locked(True)
assert not win.get_visible()
previous_releases = app.releases
send("tap", tray_point())
wait(lambda: app.releases > previous_releases, "tray touch while locked")
assert not win.get_visible()
app.set_locked(False)
print("QUICK_SETTINGS controls=4 mute=1 sync=1 tap=1 drag=1 lock=1", flush=True)
win.destroy()
app.tray.set_visible(False)
