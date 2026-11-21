"""Device controls used by the Y700 Xfce quick settings panel."""
import os
from pathlib import Path
import re
import subprocess

from gi.repository import Gio, GLib


BACKLIGHT = Path("/sys/class/backlight/ktz8866-backlight")
DEFAULT_SINK = "@DEFAULT_AUDIO_SINK@"
PROPS = "org.freedesktop.DBus.Properties"
ADAPTER = "org.bluez.Adapter1"


def system_call(bus_name, path, interface, method, args=None):
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    return bus.call_sync(bus_name, path, interface, method, args, None,
                         Gio.DBusCallFlags.NONE, 2500, None).unpack()


def backlight(value=None):
    maximum = int((BACKLIGHT / "max_brightness").read_text())
    current = int((BACKLIGHT / "brightness").read_text())
    if not 0 <= current <= maximum or maximum < 1:
        raise ValueError("Invalid backlight range")
    if value is not None:
        target = max(1, maximum * max(5, min(100, int(value))) // 100)
        if target != current:
            system_call("org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
                        "org.freedesktop.login1.Session", "SetBrightness",
                        GLib.Variant("(ssu)", ("backlight", BACKLIGHT.name, target)))
            current = int((BACKLIGHT / "brightness").read_text())
    return round(current * 100 / maximum)


def wpctl(*args):
    return subprocess.run(["wpctl", *args], text=True, capture_output=True, check=True,
                          timeout=3, env={**os.environ, "LC_ALL": "C"}).stdout.strip()


def audio(changes=None):
    for key, value in (changes or {}).items():
        if key == "volume":
            wpctl("set-volume", "-l", "1.0", DEFAULT_SINK, f"{max(0, min(100, int(value)))}%")
        elif key == "mute":
            wpctl("set-mute", DEFAULT_SINK, "1" if value else "0")
    state = re.fullmatch(r"Volume:\s+([0-9]+(?:\.[0-9]+)?)(\s+\[MUTED\])?", wpctl("get-volume", DEFAULT_SINK))
    if not state:
        raise ValueError("Unknown WirePlumber volume")
    return round(float(state[1]) * 100), bool(state[2])


def bluetooth(value=None):
    managed, = system_call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
    radios = [p for p, interfaces in managed.items() if ADAPTER in interfaces]
    if len(radios) > 1:
        onboard = []
        for adapter in radios:
            compatible = Path("/sys/class/bluetooth") / Path(adapter).name / "device/of_node/compatible"
            try:
                if b"qcom,wcn6855-bt" in compatible.read_bytes().split(b"\0"):
                    onboard.append(adapter)
            except OSError:
                continue
        radios = onboard
    if len(radios) != 1:
        raise RuntimeError("No unique Bluetooth adapter")
    path = radios[0]
    powered = bool(managed[path][ADAPTER]["Powered"])
    if value is not None and bool(value) != powered:
        system_call("org.bluez", path, PROPS, "Set",
                    GLib.Variant("(ssv)", (ADAPTER, "Powered", GLib.Variant("b", bool(value)))))
        powered, = system_call("org.bluez", path, PROPS, "Get", GLib.Variant("(ss)", (ADAPTER, "Powered")))
    return bool(powered)
