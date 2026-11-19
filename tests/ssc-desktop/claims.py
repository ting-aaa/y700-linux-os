"""Exercise SensorProxy claims on a single long-lived system D-Bus connection."""
import math
import time

from gi.repository import Gio, GLib

SERVICE = 'net.hadess.SensorProxy'
OBJECT = '/net/hadess/SensorProxy'
PROPERTIES = ('AccelerometerOrientation', 'LightLevel', 'ProximityNear')
KINDS = ('Accelerometer', 'Light', 'Proximity')


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    changes = {name: set() for name in PROPERTIES}

    def invoke(method):
        bus.call_sync(SERVICE, OBJECT, SERVICE, method, None, None,
                      Gio.DBusCallFlags.NO_AUTO_START, 7000, None)

    def property_changed(_bus, _sender, _path, _iface, _signal, arguments):
        interface, updated, _ = arguments.unpack()
        if interface == SERVICE:
            for name in changes.keys() & updated.keys():
                changes[name].add(updated[name])

    subscription = bus.signal_subscribe(
        SERVICE, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', OBJECT,
        SERVICE, Gio.DBusSignalFlags.NONE, property_changed)
    acquired = []
    try:
        for kind in KINDS:
            invoke('Claim' + kind)
            acquired.append(kind)
        deadline = time.monotonic() + 22
        context = GLib.MainContext.default()
        while time.monotonic() < deadline:
            while context.iteration(False):
                pass
            if all(len(values) >= 2 for values in changes.values()):
                break
            time.sleep(0.04)
    finally:
        for kind in reversed(acquired):
            invoke('Release' + kind)
        bus.signal_unsubscribe(subscription)

    print('Desktop property changes:', {name: sorted(values) for name, values in changes.items()})
    orientations = changes['AccelerometerOrientation'] & {'normal', 'left-up', 'right-up', 'bottom-up'}
    lux = {value for value in changes['LightLevel'] if math.isfinite(value) and value >= 0}
    if len(orientations) < 2 or len(lux) < 2 or changes['ProximityNear'] != {False, True}:
        raise SystemExit('Missing expected orientation, lux or proximity transitions')


if __name__ == '__main__':
    main()
