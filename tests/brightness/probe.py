"""Observe and tap the real GTK controls on a private X11 display."""

import os
from pathlib import Path
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Atspi, Gdk, Gio, GLib


BACKLIGHT = Path("/sys/class/backlight/ktz8866-backlight")
LABELS = {
    "en": ("Tablet brightness", "Increase brightness", "Decrease brightness", "Restore opening level"),
    "zh": ("平板屏幕亮度", "提高亮度", "降低亮度", "恢复打开时的亮度"),
}


def wait_for(read, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(0.1)
    raise TimeoutError(description)


def nodes(root):
    if root is not None:
        yield root
        for index in range(root.get_child_count()):
            yield from nodes(root.get_child_at_index(index))


def named(root, role, title):
    for node in nodes(root):
        if node.get_role() == role and node.get_name() == title:
            if node.get_state_set().contains(Atspi.StateType.SHOWING):
                return node
    return None


def value(name):
    return int((BACKLIGHT / name).read_text())


def current_session():
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    result = bus.call_sync(
        "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
        "org.freedesktop.DBus.Properties", "GetAll",
        GLib.Variant("(s)", ("org.freedesktop.login1.Session",)), None,
        Gio.DBusCallFlags.NONE, 3000, None,
    ).unpack()[0]
    assert result["Active"] and not result["LockedHint"] and not result["Remote"]
    assert result["Seat"][0] == "seat0" and result["User"][0] == os.getuid()
    assert result["Class"] == "user" and result["Type"] == "x11"
    return result["Id"]


def check_layout(lang):
    title, *buttons = LABELS[lang]
    frame = wait_for(lambda: named(Atspi.get_desktop(0), Atspi.Role.FRAME, title), title)
    names = buttons + [f"Set brightness to {p}%" if lang == "en" else f"将亮度设为 {p}%"
                       for p in (5, 25, 50, 75, 100)]
    controls = []
    for caption in names:
        control = named(frame, Atspi.Role.PUSH_BUTTON, caption)
        assert control is not None, caption
        bounds = control.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        assert bounds.width >= 50 and bounds.height >= 56, caption
        controls.append((control, bounds))
    print(f"BRIGHTNESS_UI locale={lang} controls={len(names)} gtk_scale=2 min_logical_target=50x56", flush=True)
    return controls


def tap(control, bounds):
    assert control.get_state_set().contains(Atspi.StateType.SENSITIVE)
    x = bounds.x * 2 + bounds.width
    y = bounds.y * 2 + bounds.height
    subprocess.run(["xdotool", "mousemove", str(x), str(y), "click", "1"], check=True, timeout=5)


def main():
    if os.getuid() == 0:
        raise SystemExit("Run the UI probe as the ordinary seat owner")
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    display = Gdk.Display.get_default()
    assert display and display.get_monitor(0).get_scale_factor() == 2
    controls = check_layout(sys.argv[1])
    if len(sys.argv) == 2:
        return

    # The host harness is responsible for scheduling an independent restore
    # before opting in to a bounded write on an already powered-down panel.
    assert sys.argv[1] == "en" and len(sys.argv) == 5
    original, candidate = map(int, sys.argv[2:4])
    session = sys.argv[4]
    maximum = value("max_brightness")
    assert 0 < original < candidate < maximum
    assert candidate - original == max(1, round(maximum / 100))
    assert value("bl_power") == 4 and value("brightness") == original
    assert current_session() == session
    tap(*controls[0])
    wait_for(lambda: value("brightness") == candidate, "small requested brightness step")
    assert value("bl_power") == 4
    assert value("actual_brightness") == candidate
    print(f"BRIGHTNESS_STEP raw={original}->{candidate} max={maximum} bl_power=4 seat0_owner=yes", flush=True)
    wait_for(lambda: controls[2][0].get_state_set().contains(Atspi.StateType.SENSITIVE),
             "restore control ready after login1 reply")
    tap(*controls[2])
    wait_for(lambda: value("brightness") == original, "exact opening brightness restore")
    assert value("bl_power") == 4 and value("actual_brightness") == original
    assert current_session() == session
    print(f"BRIGHTNESS_RESTORED raw={original} bl_power=4 session=original", flush=True)


if __name__ == "__main__":
    main()
