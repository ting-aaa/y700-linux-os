"""HID over GATT test peripheral for the marked two-controller QEMU guest."""
import socket
import sys
import time
from pathlib import Path

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

import adv
import classic
import gatt
import keyboard

BLUEZ = "org.bluez"
HID = "00001812-0000-1000-8000-00805f9b34fb"
CONTROL = "/run/y700-virtual-hid.sock"


def uuid(short):
    return "0000" + short + "-0000-1000-8000-00805f9b34fb"


class ReportReference(gatt.Descriptor):
    def __init__(self, bus, report_id, characteristic):
        super().__init__(bus, 0, uuid("2908"), ["read"], characteristic)
        self.report_id = report_id

    def ReadValue(self, options):
        return dbus.ByteArray([self.report_id, 1])


class Characteristic(gatt.Characteristic):
    def __init__(self, bus, service, short, flags, value, report_id=0):
        super().__init__(bus, len(service.characteristics), uuid(short), flags, service)
        self.value = value
        self.notifying = False
        if report_id:
            self.add_descriptor(ReportReference(bus, report_id, self))
        service.add_characteristic(self)

    def ReadValue(self, options):
        return dbus.ByteArray(self.value[int(options.get("offset", 0)):])

    def WriteValue(self, value, options):
        if "write-without-response" not in self.flags:
            raise gatt.NotPermittedException()
        self.value = bytes(value)

    def StartNotify(self):
        self.notifying = True

    def StopNotify(self):
        self.notifying = False

    def send(self, value):
        if not self.notifying:
            raise gatt.NotPermittedException("Input report has no subscriber")
        self.value = bytes(value)
        self.PropertiesChanged(gatt.GATT_CHRC_IFACE, {"Value": dbus.ByteArray(value)}, [])


class HidApplication(gatt.Application):
    def __init__(self, bus):
        self.path, self.services = "/org/y700/hid", []
        dbus.service.Object.__init__(self, bus, self.path)
        service = gatt.Service(bus, 0, HID, True)
        self.add_service(service)
        Characteristic(bus, service, "2a4a", ["read"], b"\x11\x01\x00\x02")
        Characteristic(bus, service, "2a4b", ["read"], keyboard.REPORT_MAP)
        Characteristic(bus, service, "2a4c", ["write-without-response"], b"\x00")
        self.key = Characteristic(bus, service, "2a4d", ["encrypt-read", "notify"], keyboard.CLEAR, 1)
        self.mouse = Characteristic(bus, service, "2a4d", ["encrypt-read", "notify"], bytes(4), 2)

    def handle_control(self, listener, condition, advertise_again):
        client, _ = listener.accept()
        with client:
            client.settimeout(1)
            command = client.recv(32)
            ready = self.key.notifying and self.mouse.notifying
            if command == b"advertise":
                advertise_again()
                client.sendall(b"resuming")
                return True
            if command == b"emit" and ready:
                self.key.send(keyboard.report(keyboard.F15))
                self.key.send(keyboard.CLEAR)
                self.mouse.send([1, 7, 253, 1])
                self.mouse.send([0, 0, 0, 0])
            if command.startswith(b"type:") and ready:
                for report in keyboard.typing_reports(command[5:].decode("ascii")):
                    self.key.send(report)
                    time.sleep(.025)
            client.sendall(b"ready" if ready else b"waiting")
        return True


class VirtualAgent(dbus.service.Object):
    """Just Works test agent for the two adapters in this instance only."""

    def __init__(self, bus):
        self.path = "/org/y700/agent"
        super().__init__(bus, self.path)
        addresses = [
            str(dbus.Interface(bus.get_object(BLUEZ, "/org/bluez/hci" + str(i)),
                               dbus.PROPERTIES_IFACE).Get(BLUEZ + ".Adapter1", "Address"))
            for i in (0, 1)
        ]
        self.peers = {"/org/bluez/hci%d/dev_%s" % (i, addresses[1-i].replace(":", "_"))
                      for i in (0, 1)}

    def check(self, device):
        if str(device) not in self.peers:
            raise gatt.NotPermittedException("Outside virtual pair")

    @dbus.service.method(BLUEZ + ".Agent1", in_signature="o")
    def RequestAuthorization(self, device):
        self.check(device)

    @dbus.service.method(BLUEZ + ".Agent1", in_signature="os")
    def AuthorizeService(self, device, uuid):
        self.check(device)
        if str(uuid) not in (HID, classic.HID):
            raise gatt.NotPermittedException("Outside virtual HID service")

    @dbus.service.method(BLUEZ + ".Agent1")
    def Cancel(self):
        pass


def main():
    if "y700.virtual_hid=1" not in Path("/proc/cmdline").read_text().split():
        raise RuntimeError("Requires the marked VM")
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    if "resume" not in sys.argv[1:]:
        agent = VirtualAgent(bus)
        agent_manager = dbus.Interface(bus.get_object(BLUEZ, "/org/bluez"), BLUEZ + ".AgentManager1")
        agent_manager.RegisterAgent(agent.path, "NoInputNoOutput")
        agent_manager.RequestDefaultAgent(agent.path)
    if "classic" in sys.argv[1:]:
        obj = bus.get_object(BLUEZ, "/org/bluez/hci1")
        addr = dbus.Interface(obj, dbus.PROPERTIES_IFACE).Get(BLUEZ + ".Adapter1", "Address")
        with classic.registered(str(addr), keyboard.REPORT_MAP):
            print("PEER_READY", flush=True)
            GLib.MainLoop().run()
        return
    # All exported objects must be below the ObjectManager root.
    gatt.Service.PATH_BASE = "/org/y700/hid/service"
    app = HidApplication(bus)
    control = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    control.bind(CONTROL)
    control.listen(1)
    advertisement = adv.Advertisement(bus, 0, "peripheral")
    advertisement.add_service_uuid(HID)
    advertisement.add_local_name("Y700 Virtual HID")
    adapter = bus.get_object(BLUEZ, "/org/bluez/hci1")
    loop = GLib.MainLoop()
    failures = []

    def failed(error):
        failures.append(error)
        loop.quit()

    def registered():
        dbus.Interface(adapter, BLUEZ + ".LEAdvertisingManager1").RegisterAdvertisement(
            advertisement.get_path(), {}, reply_handler=lambda: print("PEER_READY", flush=True),
            error_handler=failed)

    def advertise_again():
        # Real peripherals explicitly restart connectable advertising after boot.
        dbus.Interface(adapter, BLUEZ + ".LEAdvertisingManager1").UnregisterAdvertisement(
            advertisement.get_path(), reply_handler=registered,
            error_handler=after_unregister_error)

    def after_unregister_error(error):
        if error.get_dbus_name() == "org.bluez.Error.DoesNotExist":
            registered()
        else:
            failed(error)

    GLib.io_add_watch(control, GLib.IO_IN, app.handle_control, advertise_again)
    dbus.Interface(adapter, BLUEZ + ".GattManager1").RegisterApplication(
        app.get_path(), {}, reply_handler=registered, error_handler=failed)
    loop.run()
    if failures:
        sys.exit(str(failures[0]))


if __name__ == "__main__":
    main()
