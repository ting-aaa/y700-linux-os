"""Match both endpoints of a genuine SMP comparison in the two-controller ARM guest."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from gi.repository import Gio, GLib
import probe
from probe import Atspi, Gdk
from central import HID, control, inputs_for, verify_evdev

BLUEZ = "org.bluez"
DEVICE = BLUEZ + ".Device1"
ADAPTER = BLUEZ + ".Adapter1"
AGENT = BLUEZ + ".Agent1"
AGENTS = BLUEZ + ".AgentManager1"
PEER_AGENT = "/org/y700/test/peer"
XML = """<node><interface name="org.bluez.Agent1">
 <method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
 <method name="Release"/><method name="Cancel"/>
</interface></node>"""


def dbus_call(bus, path, interface, method, data=None):
    return bus.call_sync(BLUEZ, path, interface, method, data, None,
                         Gio.DBusCallFlags.NONE, 25000, None).unpack()


def props(bus, path, interface):
    return dbus_call(bus, path, "org.freedesktop.DBus.Properties", "GetAll", GLib.Variant("(s)", (interface,)))[0]


def discover(bus, adapter, condition):
    dbus_call(bus, adapter, ADAPTER, "SetDiscoveryFilter",
              GLib.Variant("(a{sv})", ({"Transport": GLib.Variant("s", "le")},)))
    dbus_call(bus, adapter, ADAPTER, "StartDiscovery")
    try:
        probe.await_value(condition, "advertising-peer-not-discovered", 18)
    finally:
        dbus_call(bus, adapter, ADAPTER, "StopDiscovery")


def tap(button, dialog):
    # Xorg has no window decorations in this isolated display.
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
    ids = re.findall(r'^\s*(0x[\da-f]+) "Bluetooth":', tree, re.M)
    assert len(ids) == 1, "expected one Blueman dialog"
    x, y, width, height = probe.bounds(ids[0])
    box = dialog.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    hit = button.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    sx, sy = width / box.width, height / box.height
    assert abs(sx - sy) < .06 and .94 < sx < 2.06
    px = x + round((hit.x - box.x + hit.width / 2) * sx)
    py = y + round((hit.y - box.y + hit.height / 2) * sy)
    assert x < px < x + width and y < py < y + height and hit.width > 0 and hit.height > 0
    assert Atspi.generate_mouse_event(px, py, "b1c")


def desktop_and_accessory(bus, applet):
    assert Gdk.Display.get_default().get_monitor(0).get_scale_factor() == 2
    session = Gio.bus_get_sync(Gio.BusType.SESSION)
    def is_registered():
        if applet.poll() is not None:
            raise RuntimeError("applet exited before registration")
        return Path("/run/blueman-default-ready").is_file() and probe.pid(session, "org.blueman.Applet") == applet.pid
    probe.await_value(is_registered, "blueman-not-registered-as-default", 50)
    print("BLUEMAN_READY uid=1000 gtk_scale=2 system_bus=product", flush=True)
    desktop_adapter = "/org/bluez/hci0"
    peer_adapter = "/org/bluez/hci1"
    peer_address = props(bus, peer_adapter, ADAPTER)["Address"]
    desktop_address = props(bus, desktop_adapter, ADAPTER)["Address"]
    desktop_device = desktop_adapter + "/dev_" + peer_address.replace(":", "_")
    peer_device = peer_adapter + "/dev_" + desktop_address.replace(":", "_")
    def accessory_seen():
        device = props(bus, desktop_device, DEVICE)
        return device["Address"] == peer_address and HID in device.get("UUIDs", [])
    discover(bus, desktop_adapter, accessory_seen)
    discover(bus, peer_adapter, lambda: props(bus, peer_device, DEVICE)["Address"] == desktop_address)
    assert not props(bus, peer_device, DEVICE)["Paired"] and not props(bus, peer_device, DEVICE)["Connected"]
    print("VIRTUAL_DESKTOP_DISCOVERED unbonded=1", flush=True)
    return desktop_device, peer_device, peer_address


def run(bus, applet):
    desktop_device, peer_device, peer_address = desktop_and_accessory(bus, applet)
    pending, outcome = {}, {}
    owner = probe.owner(bus, BLUEZ)
    def remote_agent(conn, sender, path, interface, member, arguments, invocation):
        if sender == owner and member == "RequestConfirmation":
            device, number = arguments.unpack()
            if device == peer_device and "reply" not in pending:
                pending.update(code=number, reply=invocation)
                return
        if sender == owner and member in ("Cancel", "Release"):
            invocation.return_value(None)
        else:
            invocation.return_dbus_error("org.bluez.Error.Rejected", "Unexpected peer or request")

    info = Gio.DBusNodeInfo.new_for_xml(XML)
    registration = bus.register_object(PEER_AGENT, info.interfaces[0], remote_agent, None, None)
    dbus_call(bus, "/org/bluez", AGENTS, "RegisterAgent", GLib.Variant("(os)", (PEER_AGENT, "DisplayYesNo")))
    def paired(conn, result):
        try:
            conn.call_finish(result)
            outcome["success"] = True
        except GLib.Error as error:
            outcome["failure"] = Gio.DBusError.get_remote_error(error) or "local"

    bus.call(BLUEZ, peer_device, DEVICE, "Pair", None, None, Gio.DBusCallFlags.NONE, 85000, None, paired)
    def requested():
        if outcome:
            raise RuntimeError("Pair ended before numeric comparison: " + str(outcome))
        return pending.get("reply")
    probe.await_value(requested, "no-peer-numeric-comparison", 32)
    print("REAL_PEER_CONFIRMATION source=bluez exact_peer=1", flush=True)
    label = probe.await_value(lambda: probe.matching_label(applet.pid, pending["code"]), "applet-code-did-not-match", 25)
    dialog = probe.pairing_dialog(label)
    deny = "y700.blueman_deny=1" in Path("/proc/cmdline").read_text().split()
    button = probe.control(dialog, Atspi.Role.PUSH_BUTTON, "Deny" if deny else "Confirm")
    assert button and not outcome
    pending.pop("reply").return_value(None)
    pending.clear()
    tap(button, dialog)
    probe.await_value(lambda: outcome, "pair-result-missing", 25)
    dbus_call(bus, "/org/bluez", AGENTS, "UnregisterAgent", GLib.Variant("(o)", (PEER_AGENT,)))
    bus.unregister_object(registration)
    if deny:
        assert outcome.get("failure") in ("org.bluez.Error.AuthenticationFailed", "org.bluez.Error.AuthenticationRejected",
                                          "org.bluez.Error.AuthenticationCanceled"), outcome
        objects = dbus_call(bus, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")[0]
        for path in (desktop_device, peer_device):
            device = objects.get(path, {}).get(DEVICE, {})
            assert not device.get("Bonded") and not device.get("Paired")
        assert not control(b"ready") and not list(inputs_for(peer_address))
        print("BLUEMAN_NUMERIC_MATCH six_digits=1 clicked=deny bonded=0 hid=0", flush=True)
        return
    assert outcome == {"success": True}, outcome
    assert all(props(bus, path, DEVICE)["Bonded"] for path in (desktop_device, peer_device))
    print("BLUEMAN_NUMERIC_MATCH six_digits=1 clicked=confirm bonded_on_both=1", flush=True)
    reconnect_and_test_input(bus, desktop_device, peer_address)


def reconnect_and_test_input(bus, desktop_device, peer_address, require_unsubscribed=True):
    # The accessory initiated this link. Reconnect from the desktop for HoG.
    if props(bus, desktop_device, DEVICE)["Connected"]:
        dbus_call(bus, desktop_device, DEVICE, "Disconnect")
        probe.await_value(lambda: not props(bus, desktop_device, DEVICE)["Connected"], "link-not-disconnected")
    assert not props(bus, desktop_device, DEVICE)["Connected"] and props(bus, desktop_device, DEVICE)["Bonded"]
    if require_unsubscribed:
        probe.await_value(lambda: not list(inputs_for(peer_address)) and not control(b"ready"), "old-reports-still-active")
    control(b"advertise")
    discover(bus, desktop_device.rsplit("/", 1)[0],
             lambda: HID in props(bus, desktop_device, DEVICE).get("UUIDs", []))
    dbus_call(bus, desktop_device, DEVICE, "Connect")
    probe.await_value(lambda: props(bus, desktop_device, DEVICE)["ServicesResolved"], "hid-service-not-resolved", 20)
    probe.await_value(lambda: control(b"ready") and list(inputs_for(peer_address)), "hid-reports-unavailable", 20)
    with tempfile.TemporaryDirectory(dir=os.environ["XDG_RUNTIME_DIR"]) as tmp:
        ready = Path(tmp, "ready")
        with subprocess.Popen([sys.executable, "-B", "desktop.py", peer_address, ready]) as window:
            try:
                probe.await_value(ready.is_file, "gtk-input-window-not-ready", 25)
                verify_evdev(peer_address, lambda: control(b"emit"))
                assert window.wait(timeout=20) == 0
            finally:
                if window.poll() is None:
                    window.terminate()


if __name__ == "__main__":
    assert "y700.blueman_pair=1" in Path("/proc/cmdline").read_text().split()
    assert os.getuid() == 1000 and os.environ["DISPLAY"] == ":1"
    Atspi.init()
    Atspi.set_timeout(2500, 2500)
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
    with subprocess.Popen(["blueman-applet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as applet:
        try:
            run(bus, applet)
        finally:
            if applet.poll() is None:
                applet.terminate()
