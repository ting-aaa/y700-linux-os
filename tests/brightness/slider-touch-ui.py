"""Observe GTK at 2x. All UI actions come from a single kernel Type-B contact."""
from contextlib import contextmanager
import os
from pathlib import Path
import struct
import subprocess
import sys
import time

from probe import Atspi, Gdk, Gio, LABELS, check_layout, named, value, wait_for


@contextmanager
def child(command, **options):
    proc = subprocess.Popen(command, **options)
    try:
        yield proc
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=8)


def send(action, points):
    coords = []
    for x, y in points:
        assert 0 <= x < 1600 and 0 <= y < 2560
        coords.extend((str(round(x * 16000 / 1600)), str(round(y * 25600 / 2560))))
    with open("/run/topology/feed", "w") as feed:
        print(action, *coords, file=feed)


def centre(box, fraction):
    return (round(2 * (box.x + box.width * fraction)), 2 * box.y + box.height)


def capture_contacts(device):
    # Read the guest evdev queue without grabbing the device or taking XI2
    # touch ownership from GTK. Xorg and libinput continue to receive events.
    packet = device.read()
    record = struct.Struct("@llHHi")
    assert packet and len(packet) % record.size == 0
    ends = []
    x = y = None
    begins = updates = 0
    for _, _, kind, code, number in record.iter_unpack(packet):
        if kind == 0 and code == 3:  # SYN_DROPPED
            raise AssertionError("Kernel input observer overran its event queue")
        if kind != 3:  # EV_ABS
            continue
        if code == 0x39:  # ABS_MT_TRACKING_ID
            if number >= 0:
                begins += 1
            else:
                ends.append((x, y))
        elif code == 0x35:  # ABS_MT_POSITION_X
            x = number
            updates += 1
        elif code == 0x36:
            y = number
    return begins, updates, ends


def main():
    assert os.getuid() == 1000
    Atspi.init()
    Atspi.set_timeout(5000, 5000)
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    assert "current 1600 x 2560" in subprocess.check_output(["xrandr", "--current"], text=True)
    assert not Gio.Settings.new("org.y700.tablet").get_boolean("automatic-brightness")
    work = Path("/run/slider-case")
    worker = "/usr/libexec/y700-ambient-backlight"
    desktop = Gio.DesktopAppInfo.new_from_filename("/usr/share/applications/y700-tablet-brightness.desktop")
    assert desktop.get_executable() == "/usr/libexec/y700-tablet-brightness"
    touch_id = subprocess.check_output(["xinput", "list", "--id-only", "NT36523N Capacitive Touchscreen"],
                                       text=True).strip()
    assert touch_id.isdigit()
    capabilities = subprocess.check_output(["xinput", "list", "--long", touch_id], text=True)
    assert "Touch mode: direct" in capabilities and "Max number of touches: 10" in capabilities
    with child([sys.executable, "-B", "ambient-backlight/check.py", worker, str(work), "--serve"]):
        wait_for(lambda: (work / "ready").exists(), "mock logind")
        with child([desktop.get_executable()]):
            buttons = check_layout("en")
            frame = named(Atspi.get_desktop(0), Atspi.Role.FRAME, LABELS["en"][0])
            scale = named(frame, Atspi.Role.SLIDER, "Screen brightness")
            slider = scale.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
            assert slider.width >= 180 and slider.height >= 56
            restore, button = buttons[2]
            def selected():
                return round(scale.get_value_iface().get_current_value())
            def raw():
                return value("brightness")
            original, maximum = raw(), value("max_brightness")
            assert (original, maximum, selected()) == (400, 2047, 20)
            source, = [p for p in Path("/sys/class/input").glob("event*")
                       if (p / "device/name").read_text().strip() == "NT36523N Capacitive Touchscreen"]
            start, target, left, reset = centre(slider, .18), centre(slider, .77), centre(slider, .008), centre(button, .5)
            with open(Path("/dev/input") / source.name, "rb", buffering=0) as device:
                os.set_blocking(device.fileno(), False)
                send("tap", [target])
                wait_for(lambda: 74 <= selected() <= 83 and raw() == maximum * selected() // 100, "trough tap")
                forward, forward_raw = selected(), raw()
                send("tap", [reset])
                wait_for(lambda: raw() == original, "tap restore before drag")
                send("slide", [start, target])
                try:
                    wait_for(lambda: selected() == forward and raw() == forward_raw, "drag ends at same target as tap")
                except TimeoutError:
                    print(f"BRIGHTNESS_DRAG_MISMATCH tap_percent={forward} tap_raw={forward_raw} "
                          f"drag_percent={selected()} drag_raw={raw()} pixel={target}", flush=True)
                    send("tap", [reset])
                    wait_for(lambda: raw() == original, "restore after failed drag")
                    raise
                send("slide", [target, left])
                wait_for(lambda: selected() == 5 and raw() == maximum * 5 // 100, "lower end stop")
                wait_for(lambda: restore.get_state_set().contains(Atspi.StateType.SENSITIVE), "restore ready")
                time.sleep(.4)
                send("tap", [reset])
                wait_for(lambda: raw() == original and selected() == 20, "restore opening raw value")
                time.sleep(.4)
                assert raw() == original and not restore.get_state_set().contains(Atspi.StateType.SENSITIVE)
                begins, updates, ends = capture_contacts(device)
            expected = [(10*x, 10*y) for x, y in (target, reset, target, left, reset)]
            assert begins == 5 and ends == expected and updates >= 40, (begins, updates, ends, expected)
            iface = "org.y700.AmbientFixture"
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            claims, writes = bus.call_sync(iface, "/org/y700/AmbientFixture", iface, "State", None, None,
                                           Gio.DBusCallFlags.NO_AUTO_START, 2000, None).unpack()
            version = Path("expected-version").read_text().strip()
            if version.endswith("+gpu1.2"):
                assert (claims, writes) == (0, 5), (claims, writes)
            else:
                assert version.endswith("+gpu1.1") and claims == 0, (version, claims)
            print(f"BRIGHTNESS_SLIDER_TYPEB_PASS xorg=1600x2560 scale=2 slider_logical={slider.width}x{slider.height} "
                  f"restore_logical={button.width}x{button.height} evdev_begin_xupdates_end={begins}/{updates}/{len(ends)} "
                  f"device_id={touch_id} logind_calls={writes} start={original} forward_percent={forward} forward_raw={forward_raw} "
                  f"back_percent=5 back_raw={maximum * 5 // 100} restored={raw()} max={maximum}", flush=True)


if __name__ == "__main__":
    main()
