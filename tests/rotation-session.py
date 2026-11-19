"""Real GSettings and D-Bus integration for the rotation bridge. Run rotation-session.sh."""
import os
import subprocess
import sys
import time
from pathlib import Path

from gi.repository import Gio, GLib


SENSOR = "net.hadess.SensorProxy"
LOGIN = "org.freedesktop.login1"
LOGIN_PATH = "/org/freedesktop/login1"
SESSION_PATH = LOGIN_PATH + "/session/c42"
SETTLE = 0.6

# Subsets of iio-sensor-proxy 3.9 src/net.hadess.SensorProxy.xml and login1.
SENSOR_API = """
    <method name="ClaimAccelerometer"/><method name="ReleaseAccelerometer"/>
    <property name="HasAccelerometer" type="b" access="read"/>
    <property name="AccelerometerOrientation" type="s" access="read"/>
    <property name="AccelerometerTilt" type="s" access="read"/>
"""
MANAGER_API = """
    <method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
"""
SESSION_API = """
    <property name="Active" type="b" access="read"/>
    <property name="LockedHint" type="b" access="read"/>
"""


class Provider:
    def __init__(self, name):
        self.name = name
        self.calls = []
        self.reads = []
        self.claimants = set()
        self.delay_claim = False
        self.deny_release = False
        self.pending_claim = None
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        self.bus = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SYSTEM_BUS_ADDRESS"], flags, None, None)
        if name == SENSOR:
            self.bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                                      "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE, self.owner_changed)

    def owner_changed(self, _bus, _sender, _path, _iface, _signal, params):
        name, _, owner = params.unpack()
        if not owner:
            self.claimants.discard(name)

    def publish(self):
        reply = self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", (self.name, 4)), None, Gio.DBusCallFlags.NONE, 3000, None,
        )
        assert reply.unpack() == (1,), (self.name, reply)

    def withdraw(self):
        reply = self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
            GLib.Variant("(s)", (self.name,)), None, Gio.DBusCallFlags.NONE, 3000, None,
        )
        assert reply.unpack() == (1,)

    def method(self, _bus, sender, _path, _iface, method, arguments, invocation):
        self.calls.append((method, sender))
        if method == "GetSession":
            if arguments.unpack() != (os.environ["XDG_SESSION_ID"],):
                invocation.return_dbus_error(LOGIN + ".NoSuchSession", "Unknown test session")
                return
            invocation.return_value(GLib.Variant("(o)", (SESSION_PATH,)))
        else:
            if method == "ClaimAccelerometer":
                self.claimants.add(sender)
                if self.delay_claim:
                    self.delay_claim = False
                    self.pending_claim = invocation
                    return
            if method == "ReleaseAccelerometer":
                if self.deny_release:
                    invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Session inactive")
                    return
                self.claimants.discard(sender)
            invocation.return_value(None)

    def finish_claim(self):
        self.pending_claim.return_value(None)
        self.pending_claim = None

    def object(self, path, interface, api, **initial):
        info = Gio.DBusNodeInfo.new_for_xml(f'<node><interface name="{interface}">{api}</interface></node>')
        properties = {key: GLib.Variant("b" if isinstance(value, bool) else "s", value)
                      for key, value in initial.items()}

        def get(_bus, _sender, _path, _iface, key):
            self.reads.append(key)
            return properties[key]

        self.bus.register_object_with_closures2(path, info.interfaces[0], self.method, get, None)

        def update(*, invalidate=(), **values):
            changed = {}
            for key, value in values.items():
                properties[key] = GLib.Variant(properties[key].get_type_string(), value)
                if key not in invalidate:
                    changed[key] = properties[key]
            # iio-sensor-proxy 3.9 send_dbus_event() only notifies claimants.
            destinations = self.claimants if self.name == SENSOR else [None]
            for destination in destinations:
                self.bus.emit_signal(destination, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                     GLib.Variant("(sa{sv}as)", (interface, changed, invalidate)))
            self.bus.flush_sync(None)

        return update

    def count(self, method):
        return sum(name == method for name, _ in self.calls)


def sensor_with(pose):
    sensor = Provider(SENSOR)
    update = sensor.object("/net/hadess/SensorProxy", SENSOR, SENSOR_API,
                           HasAccelerometer=True, AccelerometerOrientation=pose, AccelerometerTilt="vertical")
    sensor.publish()
    return sensor, update


class Checks:
    def __init__(self, client, log):
        self.client = client
        self.log = log
        self.expected = []

    def pump(self):
        assert self.client.poll() is None, f"rotation client exited {self.client.returncode}"
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)
        time.sleep(0.01)

    def until(self, condition, label, timeout=6):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() >= deadline:
                raise AssertionError(f"Timed out waiting for {label}. Helper log: {self.log.read_text()}")
            self.pump()

    def wait(self, seconds):
        deadline = time.monotonic() + seconds
        self.until(lambda: time.monotonic() >= deadline, "settle interval", seconds + 1)

    def entries(self):
        return [line.split() for line in self.log.read_text().splitlines()]

    def verify(self):
        actual = [row[1:] for row in self.entries()]
        assert actual == self.expected, (self.expected, actual)

    def applied(self, pose, status=0, timeout=6):
        self.expected.append(["--rotate", pose, str(status)])
        self.until(lambda: len(self.entries()) >= len(self.expected), f"{pose} with exit {status}", timeout)
        self.verify()
        return float(self.entries()[-1][0])

    def unchanged(self):
        self.wait(SETTLE + 0.28)
        self.verify()


def run(client_path, work):
    assert os.environ["DBUS_SYSTEM_BUS_ADDRESS"] != os.environ["DBUS_SESSION_BUS_ADDRESS"]
    login = Provider(LOGIN)
    login.object(LOGIN_PATH, LOGIN + ".Manager", MANAGER_API)
    session = login.object(SESSION_PATH, LOGIN + ".Session", SESSION_API, Active=True, LockedHint=False)
    login.publish()
    sensor, pose = sensor_with("left-up")
    settings = Gio.Settings.new("org.y700.tablet")

    def enable(enabled):
        assert settings.set_boolean("auto-rotate", enabled)
        Gio.Settings.sync()

    log = work / "calls"
    log.touch()
    helper = work / "y700-display"
    helper.write_text("""#!/bin/sh
set -eu
work=${0%/*}
result=0
if [ -f "$work/fail-next" ]; then rm "$work/fail-next"; result=1; fi
read -r stamp idle < /proc/uptime
printf '%s %s %s %s\\n' "$stamp" "$1" "$2" "$result" >> "$work/calls"
exit "$result"
""")
    helper.chmod(0o755)
    env = dict(os.environ, PATH=f"{work}:{os.environ['PATH']}", PYTHONDONTWRITEBYTECODE="1")
    client = subprocess.Popen([sys.executable, client_path, "--session", "--settle", str(SETTLE)], env=env)
    check = Checks(client, log)
    try:
        check.until(lambda: login.count("GetSession") > 0, "real client login lookup")
        assert not settings.get_boolean("auto-rotate")
        check.unchanged()
        assert sensor.count("ClaimAccelerometer") == 0
        enable(True)
        check.applied("left")
        assert sensor.count("ClaimAccelerometer") == 1
        check.unchanged()
        print("PASS  default opt-out, claim and existing pose without a signal, duplicate suppression")

        pose(AccelerometerOrientation="right-up")
        check.wait(0.15)
        pose(AccelerometerOrientation="undefined", invalidate=["AccelerometerOrientation"])
        check.unchanged()
        pose(AccelerometerOrientation="bottom-up")
        check.wait(0.15)
        sensor.claimants.clear()  # Driver vanished before the proxy could notify its former claimants.
        before = sensor.reads.count("HasAccelerometer")
        pose(HasAccelerometer=False)
        check.unchanged()
        assert sensor.reads.count("HasAccelerometer") > before, "pending apply must re-read live availability"
        pose(HasAccelerometer=True)
        check.applied("inverted", timeout=27)
        assert sensor.claimants, "silent device return must acquire a fresh claim"
        before = sensor.reads.count("AccelerometerOrientation")
        check.until(lambda: sensor.reads.count("AccelerometerOrientation") > before, "passive refresh", timeout=27)
        check.unchanged()
        print("PASS  invalidated pose, silent loss before apply, passive reacquire and stable pose suppression")

        # Both transitions complete before the next probe. HasAccelerometer
        # reads true throughout from the client's perspective, but iio-sensor-proxy
        # erased its client table on removal and has no recipients on return.
        sensor.claimants.clear()
        pose(HasAccelerometer=False, AccelerometerOrientation="undefined")
        pose(HasAccelerometer=True)
        sensor.delay_claim = True
        check.until(lambda: sensor.pending_claim is not None, "same-owner reacquire after quick replug", timeout=27)
        pose(AccelerometerOrientation="normal")
        check.unchanged()
        pose(AccelerometerOrientation="bottom-up")
        sensor.finish_claim()
        check.unchanged()
        assert sensor.claimants
        print("PASS  silent same-owner replug reacquired, first-reading wait blocked rotation, stable pose preserved")

        for tilt in ("face-up", "face-down"):
            pose(AccelerometerOrientation="left-up")
            check.wait(0.15)
            pose(AccelerometerTilt=tilt)
            check.unchanged()
            pose(AccelerometerOrientation="bottom-up", AccelerometerTilt="vertical")
            check.unchanged()
        print("PASS  changes to a flat face-up or face-down pose cancel pending rotation")

        pose(AccelerometerOrientation="left-up")
        check.wait(0.15)
        sensor.bus.close_sync(None)
        check.unchanged()
        sensor, pose = sensor_with("normal")
        check.applied("normal")
        assert sensor.count("ClaimAccelerometer") == 1
        print("PASS  provider disconnect cancels pending rotation, replacement claimed with fresh initial pose")

        for label, suspend, resume in (
            ("GSettings rotation switch", lambda: enable(False), lambda: enable(True)),
            ("logind lock", lambda: session(LockedHint=True), lambda: session(LockedHint=False)),
            ("logind inactive session", lambda: session(Active=False), lambda: session(Active=True)),
        ):
            released = sensor.count("ReleaseAccelerometer")
            claimed = sensor.count("ClaimAccelerometer")
            pose(AccelerometerOrientation="left-up")
            check.wait(0.15)
            # A seat transition may also remove permission to call Release.
            sensor.deny_release = label == "logind inactive session"
            suspend()
            check.until(lambda: sensor.count("ReleaseAccelerometer") > released, f"{label} release")
            check.until(lambda: not sensor.claimants, f"{label} ended the sensor lease")
            sensor.deny_release = False
            pose(AccelerometerOrientation="right-up")
            check.unchanged()
            resume()
            check.applied("right")
            assert sensor.count("ClaimAccelerometer") == claimed + 1, label
            print(f"PASS  {label} releases claim, cancels pending rotation and resumes at current pose")

        enable(False)
        check.until(lambda: not sensor.claimants, "opt-out before delayed claim")
        sensor.delay_claim = True
        enable(True)
        check.until(lambda: sensor.pending_claim is not None, "first reading wait")
        enable(False)
        check.until(lambda: not sensor.claimants, "release before first reading", timeout=2)
        sensor.finish_claim()
        check.unchanged()

        sensor.delay_claim = True
        enable(True)
        check.until(lambda: sensor.pending_claim is not None, "old owner waiting for first reading")
        previous = sensor
        previous.withdraw()
        sensor, pose = sensor_with("normal")
        check.applied("normal")
        previous.finish_claim()
        check.unchanged()
        previous.bus.close_sync(None)
        assert sensor.claimants and sensor.count("ReleaseAccelerometer") == 0
        print("PASS  opt-out during delayed claim and late reply from replaced owner preserve new owner's claim")

        (work / "fail-next").touch()
        pose(AccelerometerOrientation="bottom-up")
        failed = check.applied("inverted", 1)
        check.unchanged()
        retried = check.applied("inverted")
        assert retried - failed >= 1.9, (failed, retried)
        check.unchanged()
        print(f"PASS  nonzero display exit retried after {retried - failed:.2f}s; success suppressed repeats")

        pose(AccelerometerOrientation="left-up")
        check.wait(0.15)
        released = sensor.count("ReleaseAccelerometer")
        pose(HasAccelerometer=False)
        check.until(lambda: sensor.count("ReleaseAccelerometer") > released, "accelerometer availability loss")
        check.unchanged()
        print("PASS  explicit HasAccelerometer loss releases the sensor and cancels the pending pose")
    finally:
        client.terminate()
        deadline = time.monotonic() + 4
        context = GLib.MainContext.default()
        while client.poll() is None and time.monotonic() < deadline:
            context.iteration(False)
            time.sleep(0.01)
        if client.poll() is None:
            client.kill()
        client.wait()
        sensor.bus.close_sync(None)
        login.bus.close_sync(None)


if __name__ == "__main__":
    run(sys.argv[1], Path(sys.argv[2]))
