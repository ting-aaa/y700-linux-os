"""Measure actual Parole widgets through AT-SPI and exercise the Play/Pause button on X11."""
import os
from pathlib import Path
import runpy
import subprocess
import sys

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Atspi, Gdk, Gio, GLib, Gtk


def main():
    # The same geometry conversion is used by the 2x transport regression.
    playback = runpy.run_path(str(Path(__file__).with_name("parole-transport.py")))
    scale = int(os.environ["GDK_SCALE"])
    version = subprocess.check_output(["dpkg-query", "-W", "-f=${Version}", "parole"], text=True)
    Gtk.init([])
    Atspi.init()
    assert os.getuid() != 0 and Gdk.get_default_root_window().get_scale_factor() == scale
    clip = Path(sys.argv[1]).resolve(strict=True)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    subprocess.run(["gio", "open", str(clip)], check=True, timeout=20)

    def player_pid():
        try:
            pid, = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                 "GetConnectionUnixProcessID", GLib.Variant("(s)", (playback["PLAYER"],)),
                                 None, Gio.DBusCallFlags.NO_AUTO_START, 2000, None).unpack()
        except GLib.Error:
            return None
        cmdline = (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
        return pid if os.fsencode(clip) in cmdline or clip.as_uri().encode() in cmdline else None

    until = playback["until"]
    pid = until(player_pid, 70, "no desktop-launched Parole with the expected file")
    widgets = until(lambda: playback["controls"](pid), 30, "missing playback controls")
    box = until(lambda: playback["windows_for"](pid, scale), 10, "missing Parole X11 window")
    button, slider, tap, _ = playback["pointer_controls"](widgets, box, scale)
    # The File menu shares the same Parole window but lies outside the transport row.
    pending = [widgets[0]]
    while pending:
        item = pending.pop()
        if item.get_role() == Atspi.Role.MENU_BAR:
            menu = item.get_child_at_index(0).get_extents(Atspi.CoordType.SCREEN)
            break
        pending.extend(child for i in range(item.get_child_count())
                       if (child := item.get_child_at_index(i)) is not None)
    else:
        raise RuntimeError("no File menu in the Parole window")
    theme = Gtk.Settings.get_default().get_property("gtk-theme-name")
    if os.environ.get("Y700_PAROLE_TEST_THEME"):
        assert theme == os.environ["Y700_PAROLE_TEST_THEME"], theme
    assert menu.width > 0 and menu.height > 0
    tap(playback["PLAY"])
    tap(playback["PAUSE"])
    assert player_pid() == pid
    if version.endswith("+y7001") and scale == 2:
        assert min(*button, slider[1]) >= 96, (button, slider)
    print(f"PAROLE_SIZE version={version} scale={scale} button={button[0]}x{button[1]} "
          f"slider={slider[0]}x{slider[1]} menu_atk={menu.width}x{menu.height} theme={theme} "
          f"pointer_pause_resume=pass", flush=True)


if __name__ == "__main__":
    main()
