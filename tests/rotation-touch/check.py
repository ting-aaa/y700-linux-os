"""Drive the upstream QRTR mock and observe the installed desktop's response."""

import configparser
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk

from fixture import TAP_TARGETS


HERE = Path(__file__).parent
SENSOR = HERE / "ssc_server/data/sensor-accelerometer.json"
TOUCH = Path("/run/rotation-touch/touch")
AUTOSTART = "/etc/xdg/autostart/y700-rotation.desktop"
PROXY = "net.hadess.SensorProxy"
POSES = {
    # Calibrated Android device axes, in m/s²: X right, Y up, Z out.
    "normal": ((0, 9.81, 0), "normal", (1600, 2560)),
    "left": ((-9.81, 0, 0), "left-up", (2560, 1600)),
    "inverted": ((0, -9.81, 0), "bottom-up", (1600, 2560)),
    "right": ((9.81, 0, 0), "right-up", (2560, 1600)),
    "flat": ((0, 0, 9.81), None, None),
}


def pose(direction):
    sample = json.loads(SENSOR.read_text())
    # Nonidentity sensor placement must not rotate the calibrated reports again.
    sample["attributes"]["mount_matrix"]["value"] = [
        0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
    ]
    sample["measurements"] = [
        {"id": 1025, "acceleration": POSES[direction][0], "accuracy": 3}
    ]
    staged = SENSOR.with_suffix(".tmp")
    staged.write_text(json.dumps(sample))
    staged.replace(SENSOR)


def run(*args):
    return subprocess.check_output(args, text=True, timeout=4).strip()


def wait_for(check, label, seconds=18):
    stop = time.monotonic() + seconds
    while time.monotonic() < stop:
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        try:
            result = check()
            if result:
                return result
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"Timed out: {label}")


def display():
    line = next(line for line in run("xrandr", "--current").splitlines() if line.startswith("DSI-1 connected "))
    actual = line.split(" (", 1)[0].split()
    return (actual[-1] if actual[-1] in POSES else "normal"), line


def prop(name):
    return run("busctl", "--system", "--auto-start=no", "--timeout=2s", "get-property",
               PROXY, "/net/hadess/SensorProxy", PROXY, name)


def orientation(direction, size):
    active, line = display()
    if active == direction and f"{size[0]}x{size[1]}+0+0" in line:
        return line
    return None


def desktop():
    settings = ("gsettings",)
    key = ("org.y700.tablet", "auto-rotate")
    assert run(*settings, "get", *key) == "false", "fresh profile must start locked"
    wait_for(lambda: Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2, "GTK scale 2")
    # Use an unmanaged GTK surface so WM sizing is independent of the RandR
    # and coordinate transformations under test.
    window = Gtk.Window(type=Gtk.WindowType.POPUP)
    area = Gtk.DrawingArea()
    window.add(area)
    area.add_events(Gdk.EventMask.TOUCH_MASK)
    contacts = []

    def receive(_area, event):
        if event.type == Gdk.EventType.TOUCH_BEGIN:
            assert event.get_source_device().get_source() == Gdk.InputSource.TOUCHSCREEN
            valid, x, y = event.get_root_coords()
            if valid:
                contacts.append((x, y))
        return True

    area.connect("touch-event", receive)
    window.move(0, 0)
    window.show_all()
    entry = configparser.ConfigParser(interpolation=None)
    assert entry.read(AUTOSTART)
    args = shlex.split(entry["Desktop Entry"]["Exec"])
    assert args == ["/usr/lib/y700/y700-auto-rotate.py", "--session"]
    log = Path(os.environ["XDG_RUNTIME_DIR"]) / "rotation-bridge.log"
    with log.open("w") as output:
        bridge = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT)
    try:
        time.sleep(1.2)
        assert bridge.poll() is None
        assert orientation("right", POSES["right"][2]), "locked preference rotated the first pose"
        print("ROTATION_DEFAULT_LOCKED unchanged=right", flush=True)
        run(*settings, "set", *key, "true")
        for direction in ("normal", "left", "inverted", "right"):
            vector, name, size = POSES[direction]
            pose(direction)
            wait_for(lambda: prop("AccelerometerOrientation") == f's "{name}"', name)
            line = wait_for(lambda: orientation(direction, size), f"real RandR {direction}")
            # RandR is visible before the subsequent XInput request completes.
            wait_for(lambda: f"Display and touch mapped together: {direction}" in log.read_text().splitlines(),
                     f"installed helper completed {direction} display and touch mapping")
            matrix = next(line.strip() for line in run("xinput", "list-props", "NT36523N Capacitive Touchscreen").splitlines()
                          if line.lstrip().startswith("Coordinate Transformation Matrix "))
            logical = size[0] // 2, size[1] // 2
            window.resize(*logical)
            wait_for(lambda: tuple(window.get_size()) == logical, "GTK screen-sized input surface")
            print(f"ROTATION_POSE axis={vector} proxy={name} randr={direction} {line}", flush=True)
            print(f"ROTATION_MAPPING direction={direction} {matrix}", flush=True)
            contacts.clear()
            with TOUCH.open("w") as feed:
                feed.write(f"{direction} tap\n")
            wait_for(lambda: contacts, "real GTK touchscreen contact")
            [(x, y)] = contacts
            actual = x * 2 / size[0], y * 2 / size[1]
            expect = TAP_TARGETS[direction]
            assert all(abs(a - b) < 0.02 for a, b in zip(actual, expect)), (direction, actual, expect)
            print(f"ROTATION_TOUCH direction={direction} source=touchscreen scale=2 x={actual[0]:.4f} y={actual[1]:.4f}",
                  flush=True)
        pose("flat")
        wait_for(lambda: prop("AccelerometerTilt") == 's "face-up"', "face-up tilt")
        time.sleep(1.1)
        assert orientation("right", POSES["right"][2])
        print("ROTATION_FLAT unchanged=right tilt=face-up", flush=True)
        run(*settings, "set", *key, "false")
    finally:
        bridge.terminate()
        bridge.wait(timeout=8)
        print(log.read_text(), end="", flush=True)
    print("Y700_SSC_ROTATION_TOUCH_PASS", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "pose":
        pose(sys.argv[2])
    else:
        desktop()
