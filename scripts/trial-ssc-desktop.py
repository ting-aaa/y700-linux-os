"""Read an initial desktop sensor snapshot under the seat owner's normal policy."""

import math
import os
import time

from gi.repository import Gio, GLib


SERVICE = "net.hadess.SensorProxy"
PATH = "/net/hadess/SensorProxy"
FLAGS = Gio.DBusCallFlags.NO_AUTO_START


def snapshot(bus, owner):
    def call(interface, method, args=None, timeout=3000):
        return bus.call_sync(owner, PATH, interface, method, args, None, FLAGS, timeout, None).unpack()

    kinds = ("Accelerometer", "Light", "Proximity")
    claimed = []
    changes = set()

    def changed(_bus, _sender, _path, _iface, _signal, payload):
        iface, update, _ = payload.unpack()
        if iface == SERVICE:
            changes.update(update)

    watch = bus.signal_subscribe(owner, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                 PATH, SERVICE, Gio.DBusSignalFlags.NONE, changed)
    try:
        for kind in kinds:
            call(SERVICE, "Claim" + kind, timeout=4000)
            claimed.append(kind)
        until = time.monotonic() + 2
        context = GLib.MainContext.default()
        while time.monotonic() < until:
            while context.iteration(False):
                pass
            time.sleep(.05)
        data, = call("org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", (SERVICE,)))
        for key in ("HasAccelerometer", "HasAmbientLight", "HasProximity"):
            if data.get(key) is not True:
                raise RuntimeError(f"The proxy reports {key} unavailable")
        pose = data["AccelerometerOrientation"]
        tilt = data.get("AccelerometerTilt", "undefined")
        if pose not in ("normal", "left-up", "right-up", "bottom-up", "undefined"):
            raise ValueError("Unexpected orientation")
        near = data["ProximityNear"]
        level = data["LightLevel"]
        if type(near) is not bool or not math.isfinite(level) or level < 0:
            raise ValueError("Invalid proximity or light level")
        print(f"SSC_DESKTOP uid={os.getuid()} orientation={pose} tilt={tilt} "
              f"light={level:g} unit={data['LightLevelUnit']} proximity_near={near}", flush=True)
        print("SSC_DESKTOP changes=" + ",".join(sorted(changes)), flush=True)
        if pose == "undefined" and tilt not in ("face-up", "face-down"):
            raise RuntimeError("No classified pose or flat tilt was available")
    finally:
        try:
            for kind in reversed(claimed):
                call(SERVICE, "Release" + kind, timeout=1500)
        finally:
            bus.signal_unsubscribe(watch)
    print("SSC_DESKTOP released=Accelerometer,Light,Proximity", flush=True)


def main():
    if os.getuid() == 0:
        raise SystemExit("Run from the local desktop account.")
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    owner, = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                           "org.freedesktop.DBus", "GetNameOwner", GLib.Variant("(s)", (SERVICE,)),
                           None, FLAGS, 1500, None).unpack()
    snapshot(bus, owner)


if __name__ == "__main__":
    main()
