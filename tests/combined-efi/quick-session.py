"""Exercise the autostarted Quick Settings instance after a normal XFCE login."""

import os
from pathlib import Path
import re
import subprocess

from probe import Atspi, Gio, GLib, named, wait_for


def output(*args):
    return subprocess.check_output(args, text=True, timeout=8)


def geometry(wid):
    info = output("xwininfo", "-id", wid)
    def field(name):
        return int(re.search(r"(?m)^\s*" + re.escape(name) + r":\s*(-?\d+)\s*$", info)[1])
    return field("Absolute upper-left X"), field("Absolute upper-left Y"), field("Width"), field("Height")


def main():
    assert os.getuid() == 1000 and os.environ["XDG_CURRENT_DESKTOP"] == "XFCE"
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    service = "org.y700.QuickSettings"

    def dbus(method, name):
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                              "org.freedesktop.DBus", method, GLib.Variant("(s)", (name,)),
                              None, Gio.DBusCallFlags.NONE, 2000, None)
        return reply.unpack()[0]

    wait_for(lambda: dbus("NameHasOwner", service), "Quick Settings autostart", timeout=45)
    pid = dbus("GetConnectionUnixProcessID", service)
    assert b"--tray" in (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
    Atspi.init()
    screen = Atspi.get_desktop(0)

    def tray_icon():
        # GtkStatusIcon sets both the XEmbed property and its window title.
        for line in output("xwininfo", "-root", "-tree").splitlines():
            if not any(label in line for label in ("Quick settings", "快捷设置", "y700-quick-settings")):
                continue
            match = re.match(r"\s*(0x[0-9a-fA-F]+) ", line)
            if match:
                properties = output("xprop", "-id", match[1], "_XEMBED_INFO", "_NET_WM_PID")
                if re.search(r"_XEMBED_INFO\([^)]*\) = ", properties) and properties.split()[-1] == str(pid):
                    return match[1]
        return None

    x, y, width, height = geometry(wait_for(tray_icon, "embedded Quick Settings tray", timeout=45))
    assert width >= 12 and height >= 12
    print(f"COMBINED_QUICK_TRAY_BUTTON {x + width // 2} {y + height // 2}", flush=True)

    def active_panel():
        match = re.search(r"0x[0-9a-fA-F]+", output("xprop", "-root", "_NET_ACTIVE_WINDOW"))
        if not match or int(match[0], 16) == 0:
            return None
        wid = match[0]
        if output("xprop", "-id", wid, "_NET_WM_PID").split()[-1] != str(pid):
            return None
        return wid

    wid = wait_for(active_panel, "active Quick Settings window after tapping tray", timeout=40)

    def mapped_window():
        for index in range(screen.get_child_count()):
            app = screen.get_child_at_index(index)
            if app and app.get_process_id() == pid:
                for child in range(app.get_child_count()):
                    window = app.get_child_at_index(child)
                    if window.get_name() in ("Quick settings", "快捷设置") and window.get_role() in (
                            Atspi.Role.FRAME, Atspi.Role.DIALOG, Atspi.Role.WINDOW):
                        return window

    window = wait_for(mapped_window, "accessible Quick Settings window")

    def control(role, english, chinese):
        return wait_for(lambda: named(window, role, english) or named(window, role, chinese), english)

    control(Atspi.Role.SLIDER, "Brightness", "亮度")
    control(Atspi.Role.SLIDER, "Volume", "音量")
    control(Atspi.Role.TOGGLE_BUTTON, "Bluetooth", "蓝牙")
    rotate = control(Atspi.Role.TOGGLE_BUTTON, "Auto-rotate", "自动旋转")
    close = control(Atspi.Role.PUSH_BUTTON, "Close", "关闭")
    left, top, width, height = geometry(wid)
    frame = window.get_extents(Atspi.CoordType.SCREEN)
    sx, sy = width / frame.width, height / frame.height

    def tap(widget, label):
        rect = widget.get_extents(Atspi.CoordType.SCREEN)
        x = round(left + sx * (rect.x - frame.x + rect.width / 2))
        y = round(top + sy * (rect.y - frame.y + rect.height / 2))
        print(f"COMBINED_QUICK_{label}_BUTTON {x} {y}", flush=True)

    settings = Gio.Settings.new("org.y700.tablet")
    def rotated(value):
        # GSettings change notifications use this process's GLib main context.
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        return settings.get_boolean("auto-rotate") == value

    assert rotated(False)
    for value, label in ((True, "ON"), (False, "OFF")):
        tap(rotate, label)
        wait_for(lambda: rotated(value), f"touch rotate {label}", timeout=35)
    tap(close, "CLOSE")
    wait_for(lambda: not active_panel(), "close panel with touch")
    assert dbus("GetConnectionUnixProcessID", service) == pid
    print("COMBINED_QUICK autostart=1 controls=4 rotation_touch=on,off closed=1", flush=True)


if __name__ == "__main__":
    main()
