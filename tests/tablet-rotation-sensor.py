"""Private SensorProxy double for the GTK rotation status test."""

import sys
from pathlib import Path

from gi.repository import Gio, GLib


SENSOR = "net.hadess.SensorProxy"
PATH = "/net/hadess/SensorProxy"
API = """
<node>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
    </method>
  </interface>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimAccelerometer"/><method name="ReleaseAccelerometer"/>
  </interface>
  <interface name="org.y700.Test.Sensor">
    <method name="SetAvailable"><arg type="b" direction="in"/></method>
    <method name="Hold"/><method name="DropOwner"/><method name="SendHeldReply"/>
  </interface>
</node>
"""


class Sensor:
    def __init__(self, work):
        self.work = work
        self.available = False
        self.hold = False
        self.held = None
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        api = Gio.DBusNodeInfo.new_for_xml(API)
        for interface in api.interfaces:
            self.bus.register_object(PATH, interface, self.method, None, None)
        self.name_call("RequestName", GLib.Variant("(su)", (SENSOR, 4)))
        (work / "calls").touch()
        (work / "peer.tmp").write_text(self.bus.get_unique_name())
        (work / "peer.tmp").rename(work / "peer")

    def name_call(self, method, parameters):
        result = self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            method, parameters, None, Gio.DBusCallFlags.NONE, 3000, None,
        )
        assert result.unpack() == (1,)

    def method(self, _bus, _sender, _path, _interface, method, args, reply):
        if method in ("Get", "ClaimAccelerometer", "ReleaseAccelerometer"):
            with (self.work / "calls").open("a") as calls:
                calls.write(method + "\n")
        if method == "Get":
            assert args.unpack() == (SENSOR, "HasAccelerometer")
            value = GLib.Variant("(v)", (GLib.Variant("b", self.available),))
            if self.hold:
                self.held = reply, value
                self.hold = False
                (self.work / "held").touch()
            else:
                reply.return_value(value)
            return
        if method == "SetAvailable":
            self.available, = args.unpack()
        if method == "Hold":
            self.hold = True
        if method == "DropOwner":
            self.name_call("ReleaseName", GLib.Variant("(s)", (SENSOR,)))
        if method == "SendHeldReply":
            previous, value = self.held
            previous.return_value(value)
            self.held = None
        reply.return_value(None)


if __name__ == "__main__":
    sensor = Sensor(Path(sys.argv[1]))
    GLib.MainLoop().run()
