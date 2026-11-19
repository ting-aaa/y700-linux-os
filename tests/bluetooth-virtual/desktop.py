"""Observe the paired Bluetooth input from a normal-user GTK3 X11 window."""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk


def matching_sources(display, address):
    sources = {}
    xorg_log = Path("/run/Xorg.log").read_text()
    for device in display.get_default_seat().get_slaves(Gdk.SeatCapabilities.ALL):
        name = device.get_name()
        if f"Using input driver 'libinput' for '{name}'" not in xorg_log:
            continue
        ids = subprocess.run(["xinput", "list", "--id-only", name], text=True,
                             capture_output=True, check=False).stdout.split()
        if len(ids) != 1 or not ids[0].isdigit():
            continue
        props = subprocess.check_output(["xinput", "list-props", ids[0]], text=True)
        node = re.search(r'Device Node \(\d+\):\s*"/dev/input/(event\d+)"', props)
        if not node:
            continue
        sysfs = Path("/sys/class/input", node.group(1), "device")
        if (sysfs / "id/bustype").read_text().strip() != "0005":
            continue
        if (sysfs / "uniq").read_text().strip().upper() == address:
            sources[name] = {"id": int(ids[0]), "node": node.group(1),
                             "keyboard": device.get_source() == Gdk.InputSource.KEYBOARD}
    return sources


def main(address, ready_path):
    uid = os.getuid()
    if uid == 0 or pwd.getpwuid(uid).pw_name != "y700":
        raise RuntimeError("GTK window must run as the regular y700 account")
    display = Gdk.Display.get_default()
    if not display or display.get_name() != ":1":
        raise RuntimeError("Expected private X11 display")
    monitor = display.get_monitor(0).get_geometry()
    window = Gtk.Window(title="Y700 Bluetooth input")
    window.set_default_size(monitor.width, monitor.height)
    window.move(0, 0)
    window.add_events(Gdk.EventMask.ALL_EVENTS_MASK)
    pointer = display.get_default_seat().get_pointer()
    sources = {}
    baseline = []
    events = {}
    required = {"f15-down", "f15-up", "left-down", "left-up", "motion", "wheel-up"}
    complete = False
    received = []

    def arm():
        if not window.get_mapped():
            return True
        window.get_window().focus(Gdk.CURRENT_TIME)
        display.sync()
        if not window.has_toplevel_focus():
            return True
        sources.update(matching_sources(display, address))
        if {s["keyboard"] for s in sources.values()} != {True, False}:
            return True
        root = window.get_screen().get_root_window()
        _, x, y, _ = root.get_device_position_double(pointer)
        baseline.extend((x, y))
        print("GTK_SOURCES", json.dumps({"uid": uid, "remote": address, "baseline": baseline,
                                         "devices": sources}, sort_keys=True), flush=True)
        ready_path.touch()
        GLib.timeout_add_seconds(7, Gtk.main_quit)
        return False

    def observe(widget, event):
        nonlocal complete
        if not baseline or event.send_event:
            return False
        source = event.get_source_device()
        if len(received) < 24:
            received.append([event.type.value_nick, source.get_name() if source else None])
        if source is None or source.get_name() not in sources:
            return False
        dev = sources[source.get_name()]
        kind = event.type
        label = None
        details = []
        if dev["keyboard"] and kind in (Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE):
            present, code = event.get_keycode()
            if present and code == 185 + 8:  # Linux KEY_F15 + Xorg's evdev keycode offset
                label = "f15-down" if kind == Gdk.EventType.KEY_PRESS else "f15-up"
                details = [code, Gdk.keyval_name(event.get_keyval()[1])]
        elif not dev["keyboard"]:
            if kind in (Gdk.EventType.BUTTON_PRESS, Gdk.EventType.BUTTON_RELEASE) and event.get_button() == (True, 1):
                label = "left-down" if kind == Gdk.EventType.BUTTON_PRESS else "left-up"
            elif kind == Gdk.EventType.MOTION_NOTIFY:
                dx, dy = event.x_root - baseline[0], event.y_root - baseline[1]
                if dx > 0 and dy < 0:
                    label, details = "motion", [dx, dy]
            elif kind == Gdk.EventType.SCROLL:
                smooth, dx, dy = event.get_scroll_deltas()
                if event.direction == Gdk.ScrollDirection.UP or (smooth and dy < 0):
                    label, details = "wheel-up", [dy if smooth else -1]
        if label:
            events[label] = [event.get_time(), dev["id"], *details]
        if required == events.keys():
            for down, up in (("f15-down", "f15-up"), ("left-down", "left-up")):
                if events[down][0] > events[up][0]:
                    return False
            complete = True
            Gtk.main_quit()
        return False

    window.connect("event", observe)
    window.show_all()
    window.present()
    GLib.timeout_add(180, arm)
    GLib.timeout_add_seconds(45, Gtk.main_quit)
    Gtk.main()
    print("GTK_WINDOW_EVENTS", json.dumps(events, sort_keys=True), flush=True)
    if not complete:
        print("GTK_RECEIVED", json.dumps(received), flush=True)
        raise RuntimeError("Missing GTK events: " + ", ".join(sorted(required - events.keys())))
    print("Y700_GTK_HID_INPUT_PASS", flush=True)


if __name__ == "__main__":
    main(sys.argv[1].upper(), Path(sys.argv[2]))
