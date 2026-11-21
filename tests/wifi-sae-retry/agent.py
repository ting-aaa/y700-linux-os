"""Exercise NetworkManager's actual SecretAgent protocol on a local hwsim AP."""
import json
import os
from pathlib import Path
import sys
import time
import uuid

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

NM = "org.freedesktop.NetworkManager"
BASE = "/org/freedesktop/NetworkManager"
SETTINGS = NM + ".Settings"
SECURITY = "802-11-wireless-security"
AGENT = NM + ".SecretAgent"
SUPP = "fi.w1.wpa_supplicant1"


def report(event, **values):
    print("WIFI_AGENT", event, *(f"{key}={value}" for key, value in values.items()), flush=True)


class Retry(dbus.service.Object):
    def __init__(self, bus, mode, network):
        super().__init__(bus, BASE + "/SecretAgent")
        self.bus = bus
        self.mode = mode
        self.network = network
        self.uuid = str(uuid.uuid4())
        self.loop = GLib.MainLoop()
        self.deadline = time.monotonic() + (55 if mode == "absent" else 105)
        self.activations = self.failures = self.prompts = self.mismatches = 0
        self.statuses = set()
        self.configured = False
        self.path = self.device = self.ap = None
        self.ok = False
        self.nm = self.iface(BASE, NM)
        self.settings = self.iface(BASE + "/Settings", SETTINGS)

    def iface(self, path, interface):
        return dbus.Interface(self.bus.get_object(NM, path), interface)

    def prop(self, path, interface, key):
        return self.iface(path, dbus.PROPERTIES_IFACE).Get(interface, key)

    @dbus.service.method(AGENT, in_signature="a{sa{sv}}osasu", out_signature="a{sa{sv}}")
    def GetSecrets(self, connection, path, name, hints, flags):
        if (path != self.path or name != SECURITY or connection["connection"]["uuid"] != self.uuid
                or connection[SECURITY]["key-mgmt"] != "sae"):
            raise dbus.exceptions.DBusException("Unrelated profile", name=AGENT + ".Error.NoSecrets")
        new = (int(flags) & 3) == 3
        if new:
            self.prompts += 1
        report("get-secrets", request_new=int(new), flags=int(flags), activation=self.activations)
        return {name: {"psk": self.network["correct" if new and self.mode != "absent" else "wrong"]}}

    @dbus.service.method(AGENT, in_signature="os")
    def CancelGetSecrets(self, path, name):
        pass

    @dbus.service.method(AGENT, in_signature="a{sa{sv}}o")
    def SaveSecrets(self, connection, path):
        pass

    @dbus.service.method(AGENT, in_signature="a{sa{sv}}o")
    def DeleteSecrets(self, connection, path):
        pass

    def setup(self):
        station, = (p for p in self.nm.GetDevices() if self.prop(p, NM + ".Device", "DeviceType") == 2)
        self.device = station
        self.wireless = self.iface(station, NM + ".Device.Wireless")
        initial = self.other_profiles()
        assert initial, "unrelated profile missing"
        self.initial = initial
        self.iface(BASE + "/AgentManager", NM + ".AgentManager").RegisterWithCapabilities(
            "org.y700.fixture.SaeRetry", dbus.UInt32(0))
        self.bus.add_signal_receiver(self.state_change, "StateChanged", NM + ".Device",
                                     bus_name=NM, path=station)
        self.bus.add_signal_receiver(self.mismatch, "SaePasswordMismatch", SUPP + ".Interface",
                                     bus_name=SUPP)
        self.bus.add_signal_receiver(self.properties_changed, "PropertiesChanged",
                                     dbus.PROPERTIES_IFACE, bus_name=SUPP, arg0=SUPP + ".Interface")
        profile = {
            "connection": {"id": "Y700 Synthetic Retry", "uuid": self.uuid,
                           "type": "802-11-wireless", "autoconnect": dbus.Boolean(False),
                           "permissions": dbus.Array(["user:y700:"], signature="s")},
            "802-11-wireless": {"ssid": dbus.ByteArray(self.network["ssid"].encode()),
                                "mode": "infrastructure"},
            SECURITY: {"key-mgmt": "sae", "pmf": dbus.Int32(3), "psk": self.network["wrong"]},
            "ipv4": {"method": "auto"}, "ipv6": {"method": "disabled"}}
        if self.mode == "absent":
            profile["802-11-wireless"].update(
                ssid=dbus.ByteArray(("absent-" + self.uuid[:12]).encode()), hidden=dbus.Boolean(True))
        self.path = self.settings.AddConnectionUnsaved(profile)
        GLib.timeout_add(300, self.tick)
        self.loop.run()
        return self.ok

    def mismatch(self):
        self.mismatches += 1
        report("supplicant-mismatch", count=self.mismatches)

    def properties_changed(self, interface, changed, invalidated):
        status = int(changed.get("AuthStatusCode", 0))
        if status in (1, 15):
            self.statuses.add(status)
            report("station-auth-status", code=status)

    def other_profiles(self):
        return {p: self.iface(p, SETTINGS + ".Connection").GetSettings()
                for p in self.settings.ListConnections() if p != self.path}

    def state_change(self, state, old, reason):
        report("state", old=int(old), new=int(state), reason=int(reason))
        if state == 50:
            self.configured = True
        if state == 120:
            self.failures += 1
            self.failure_reason = int(reason)

    def select(self, aps):
        assert self.ap in aps
        self.activations += 1
        self.nm.ActivateConnection(self.path, self.device, self.ap)
        report("select", activation=self.activations, same_profile_and_ap=1)

    def tick(self):
        try:
            if time.monotonic() > self.deadline:
                raise TimeoutError()
            if self.mode == "absent":
                if not self.activations:
                    self.activations = 1
                    self.nm.ActivateConnection(self.path, self.device, "/")
                elif self.failures and self.prop(self.device, NM + ".Device", "State") == 30:
                    assert self.configured and self.failures == 1 and self.failure_reason == 53
                    assert self.prompts == self.mismatches == 0 and not self.statuses
                    assert self.other_profiles() == self.initial
                    self.iface(self.path, SETTINGS + ".Connection").Delete()
                    report("absent-PASS", failed_reason=53, replacement_requests=0, mismatch=0)
                    self.ok = True
                    self.loop.quit()
                    return False
                return True
            aps = list(self.wireless.GetAllAccessPoints())
            if not self.activations:
                matches = [p for p in aps if bytes(self.prop(p, NM + ".AccessPoint", "Ssid"))
                           == self.network["ssid"].encode()]
                if matches:
                    self.ap, = matches
                    self.select(aps)
                return True
            state = self.prop(self.device, NM + ".Device", "State")
            if state == 100:
                assert self.prompts == 1, "missing or duplicate replacement request"
                assert self.prop(self.device, NM + ".Device.Wireless", "ActiveAccessPoint") == self.ap
                active = self.prop(self.device, NM + ".Device", "ActiveConnection")
                assert self.prop(active, NM + ".Connection.Active", "Connection") == self.path
                assert self.prop(active, NM + ".Connection.Active", "Uuid") == self.uuid
                assert self.other_profiles() == self.initial
                saved = self.iface(self.path, SETTINGS + ".Connection").GetSettings()
                assert saved[SECURITY]["key-mgmt"] == "sae" and saved[SECURITY]["pmf"] == 3
                if self.mode == "legacy":
                    assert self.activations == 2 and self.failures == 1 and self.failure_reason == 53
                    assert self.mismatches == 0 and self.statuses == {1}
                else:
                    assert self.activations == 1 and self.failures == 0 and self.mismatches >= 1
                    assert self.statuses == {15}
                report("PASS", mode=self.mode, replacements=self.prompts, selections=self.activations,
                       same_profile_and_ap=1, unrelated_preserved=1)
                self.ok = True
                self.loop.quit()
                return False
            if self.mode == "legacy" and self.activations == 1 and self.failures and state == 30:
                self.select(aps)
            return True
        except Exception as error:
            report("FAIL", error=type(error).__name__, tick=1)
            self.loop.quit()
            return False


def main():
    assert os.getuid() != 0 and "y700.wifi_fixture=1" in Path("/proc/cmdline").read_text().split()
    assert b"linux,dummy-virt" in Path("/proc/device-tree/compatible").read_bytes().split(b"\0")
    mode = "modern" if Path("/opt/wifi-test/ap-2.11").is_dir() else "legacy"
    if sys.argv[1:] == ["--absent"]:
        mode = "absent"
    else:
        assert len(sys.argv) == 1
    network = json.loads(Path("/run/wifi-fixture/network.json").read_text())
    assert network["mode"] == "sae" and network["wrong"] != network["correct"]
    DBusGMainLoop(set_as_default=True)
    return Retry(dbus.SystemBus(), mode, network).setup()


if __name__ == "__main__":
    try:
        sys.exit(0 if main() else 1)
    except Exception as error:
        report("FAIL", error=type(error).__name__,
               method=error.get_dbus_name() if isinstance(error, dbus.DBusException) else "setup")
        sys.exit(1)
