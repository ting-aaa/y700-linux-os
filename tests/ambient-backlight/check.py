"""Exercise the installed policy on real private D-Bus connections as an ordinary UID."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from gi.repository import Gio, GLib


HERE = Path(__file__).resolve().parent
service_source, work = sys.argv[1:3]
work = Path(work)
assert work.is_absolute() and work.stat().st_uid == os.getuid()
assert os.environ["DBUS_SYSTEM_BUS_ADDRESS"] != os.environ["DBUS_SESSION_BUS_ADDRESS"]
assert "/run/dbus/system_bus_socket" not in os.environ["DBUS_SYSTEM_BUS_ADDRESS"]
loader = importlib.machinery.SourceFileLoader("ambient", service_source)
spec = importlib.util.spec_from_loader(loader.name, loader)
ambient = importlib.util.module_from_spec(spec)
loader.exec_module(ambient)
ambient.BACKLIGHT = work / "sys/class/backlight/ktz8866-backlight"
ambient.DRM = work / "sys/class/drm"
if sys.argv[3:] == ["--client-production-timing"]:
    ambient.main()
    sys.exit()
ambient.TICK_MS, ambient.SETTLE = 90, 0.35
ambient.QUIET_RENEW = 1.3
if sys.argv[3:] == ["--client"]:
    ambient.main()
    sys.exit()

# Reuse the real registry, private sender tracking and name-handover fixture.
spec = importlib.util.spec_from_file_location("rotation_fixture", HERE.parent / "rotation-session.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
API = {
    "HasAmbientLight": "b", "LightLevel": "d", "LightLevelUnit": "s",
    "Active": "b", "LockedHint": "b", "State": "s", "Class": "s",
    "Remote": "b", "Type": "s", "Seat": "(so)", "User": "(uo)",
}


class Provider(fixture.Provider):
    def export(self, path, interface, values, methods):
        self.values = values
        self.paused_claim = False
        props = "".join(f'<property name="{k}" type="{API[k]}" access="read"/>' for k in values)
        info = Gio.DBusNodeInfo.new_for_xml(f'<node><interface name="{interface}">{methods}{props}</interface></node>')
        def read(_bus, _who, _path, _iface, key):
            self.reads.append(key)
            return GLib.Variant(API[key], self.values[key])
        self.bus.register_object_with_closures2(path, info.interfaces[0], self.method, read, None)

    def method(self, bus, sender, path, interface, name, args, invocation):
        if name == "GetSession":
            return super().method(bus, sender, path, interface, name, args, invocation)
        self.calls.append((name, sender))
        if name == "ClaimLight":
            self.claimants.add(sender)
            if self.paused_claim:
                self.pending_claim = invocation
                return
        if name == "ReleaseLight":
            if self.deny_release:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "Inactive")
                return
            self.claimants.discard(sender)
        if name == "SetBrightness":
            subsystem, device, raw = args.unpack()
            assert (subsystem, device) == ("backlight", "ktz8866-backlight")
            assert path in (fixture.SESSION_PATH, ambient.MANAGER + "/session/auto")
            levels.append(raw)
            write(ambient.BACKLIGHT, "brightness", raw)
        invocation.return_value(None)

    def emit_lux(self, value):
        self.values["LightLevel"] = value
        args = GLib.Variant("(sa{sv}as)", (ambient.SENSOR, {"LightLevel": GLib.Variant("d", value)}, []))
        for owner in self.claimants:
            self.bus.emit_signal(owner, ambient.SENSOR_PATH, ambient.PROPS, "PropertiesChanged", args)
        self.bus.flush_sync(None)


def write(directory, name, value):
    # A sysfs reader always receives a whole attribute value, even as a write completes.
    pending = directory / (name + ".new")
    pending.write_text(str(value) + "\n")
    pending.replace(directory / name)


def until(condition, label, timeout=4):
    deadline = time.monotonic() + timeout
    while not condition():
        assert time.monotonic() < deadline, f"Timeout: {label}, writes {levels}"
        assert client.poll() is None, f"Client exited: {client.returncode}"
        context.iteration(False)
        time.sleep(.003)


def pause(duration=.55):
    target = time.monotonic() + duration
    until(lambda: time.monotonic() >= target, "settle", duration + 1)


def unchanged():
    before = list(levels)
    pause()
    assert levels == before


def sensor():
    peer = Provider(ambient.SENSOR)
    peer.export(ambient.SENSOR_PATH, ambient.SENSOR,
                {"HasAmbientLight": True, "LightLevel": 0.0, "LightLevelUnit": "lux"},
                '<method name="ClaimLight"/><method name="ReleaseLight"/>')
    peer.publish()
    return peer


def stop():
    client.send_signal(signal.SIGTERM)
    deadline = time.monotonic() + 3
    while client.poll() is None and time.monotonic() < deadline:
        context.iteration(False)
        time.sleep(.003)
    assert client.poll() == 0


def serve(peer):
    # This interface exists only on the test's private system bus. GUI callers
    # and the installed worker can use their normal launchers and sysfs paths.
    interface = "org.y700.AmbientFixture"
    controller = fixture.Provider(interface)
    api = ('<method name="Lux"><arg type="d" direction="in"/></method>'
           '<method name="Panel"><arg type="b" direction="in"/></method>'
           '<method name="Locked"><arg type="b" direction="in"/></method>'
           '<method name="State"><arg type="u" direction="out"/><arg type="u" direction="out"/></method>')
    info = Gio.DBusNodeInfo.new_for_xml(f'<node><interface name="{interface}">{api}</interface></node>')
    def handle(_bus, _who, _path, _iface, name, args, invocation):
        result = None
        if name == "Lux":
            peer.emit_lux(args.unpack()[0])
        elif name == "Panel":
            write(connector, "dpms", "On" if args.unpack()[0] else "Off")
        elif name == "Locked":
            saver.change(args.unpack()[0])
        elif name == "State":
            result = GLib.Variant("(uu)", (len(peer.claimants), len(levels)))
        invocation.return_value(result)
    controller.bus.register_object_with_closures2("/org/y700/AmbientFixture", info.interfaces[0], handle, None, None)
    controller.publish()
    peer.emit_lux(10)
    (work / "ready").touch()
    loop = GLib.MainLoop()
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, loop.quit)
    loop.run()


assert os.getuid() != 0
assert [ambient.target_level(lux) for lux in (0, 10, 60, 210, 350, 420, 1000, 1001, 40000)] == [
    20, 20, 51, 77, 153, 214, 250, 255, 255]
assert ambient.target_level(35) == 35.5 and ambient.target_level(1000.5) == 252.5
assert ambient.target_level(-1) is None and ambient.target_level(float("inf")) is None
settings = Gio.Settings.new("org.y700.tablet")
assert not settings.get_boolean(ambient.KEY)
levels = []
context = GLib.MainContext.default()
connector = ambient.DRM / "card2-DSI-1"
connector.mkdir(parents=True, exist_ok=True)
ambient.BACKLIGHT.mkdir(parents=True, exist_ok=True)
for name, value in (("status", "connected"), ("enabled", "enabled"), ("dpms", "On")):
    write(connector, name, value)
for name, value in (("bl_power", 0), ("max_brightness", 2047), ("brightness", 400)):
    write(ambient.BACKLIGHT, name, value)

login = Provider(ambient.LOGIN)
login.object(ambient.MANAGER, ambient.LOGIN + ".Manager", fixture.MANAGER_API)
for path in (fixture.SESSION_PATH, ambient.MANAGER + "/session/auto"):
    login.export(path, ambient.LOGIN + ".Session",
                 {"User": (os.getuid(), "/user"), "Type": "x11", "Seat": ("seat0", "/seat"),
                  "Active": True, "LockedHint": False, "Class": "user", "Remote": False, "State": "active"},
                 '<method name="SetBrightness"><arg type="s" direction="in"/><arg type="s" direction="in"/>'
                 '<arg type="u" direction="in"/></method>')
login.publish()
saver = fixture.Locker(False)
saver.publish()
if sys.argv[3:] == ["--serve"]:
    serve(sensor())
    sys.exit()
client = subprocess.Popen([sys.executable, "-B", __file__, service_source, str(work), "--client"])
try:
    unchanged()
    assert not login.calls and not saver.calls
    assert settings.set_boolean(ambient.KEY, True)
    pause()
    assert not (work / "activated").exists() and not levels
    peer = sensor()
    until(lambda: len(levels) == 1, "low-lux level")
    assert levels == [161]
    assert len(peer.claimants) == 1
    bright = 2047
    peer.emit_lux(10000)
    pause(.15)
    peer.emit_lux(0)
    unchanged()
    peer.emit_lux(10000)
    until(lambda: levels[-1] == bright, "stable light")
    peer.emit_lux(1000.8)
    unchanged()
    for sample in (99.5, 100.4, 99.9, 100.1, 99.5, 100.2):
        peer.emit_lux(sample)
        pause(.09)
    assert 460 <= levels[-1] <= 470 and len(levels) == 3
    write(ambient.BACKLIGHT, "brightness", 450)
    unchanged()  # External adjustment does not feed back into a same-band write.
    print("LUX stable, noisy, hysteresis, manual level and exact logind device verified")

    for directory, key, off, on in ((connector, "dpms", "Off", "On"),
                                    (connector, "enabled", "disabled", "enabled"),
                                    (connector, "status", "disconnected", "connected"),
                                    (ambient.BACKLIGHT, "bl_power", 4, 0),
                                    (ambient.BACKLIGHT, "brightness", 0, 450)):
        write(directory, key, off)
        until(lambda: not peer.claimants, key + " released")
        unchanged()
        write(directory, key, on)
        until(lambda: peer.claimants, key + " recovered")
    for key, off in (("Active", False), ("LockedHint", True), ("State", "closing"),
                     ("Remote", True), ("Type", "tty"), ("Class", "greeter"),
                     ("Seat", ("seat1", "/other")), ("User", (os.getuid() + 1, "/other"))):
        old = login.values[key]
        login.values[key] = off
        until(lambda: not peer.claimants, key + " blocked")
        unchanged()
        login.values[key] = old
        until(lambda: peer.claimants, key + " recovered")
    print("PANEL off/blank/zero, locked/inactive/closing/foreign seats and users verified")

    peer.deny_release = True
    saver.change(True)
    until(lambda: not peer.claimants, "denied release still drops unique sender")
    unchanged()
    saver.withdraw()
    unchanged()
    saver = fixture.Locker(False)
    saver.publish()
    until(lambda: peer.claimants, "new locker")
    peer.deny_release = False
    for key, invalid in (("HasAmbientLight", False), ("LightLevelUnit", "vendor")):
        old = peer.values[key]
        peer.values[key] = invalid
        until(lambda: not peer.claimants, key + " release")
        unchanged()
        peer.values[key] = old
        until(lambda: peer.claimants, key + " recovered")
    peer.emit_lux(float("nan"))
    unchanged()
    peer.emit_lux(-1.0)
    unchanged()
    original_sender, = peer.claimants
    peer.claimants.clear()  # Rapid SSC reset preserved name and HasAmbientLight.
    until(lambda: original_sender in peer.claimants, "quiet same-owner re-claim")
    assert peer.values["HasAmbientLight"]
    unchanged()
    peer.withdraw()
    unchanged()
    old_peer, peer = peer, sensor()
    until(lambda: peer.claimants and not old_peer.claimants, "service replacement")
    print("SENSOR missing, invalid lux/unit, same-owner reset, replacement and locker owner loss verified")

    assert settings.set_boolean(ambient.KEY, False)
    until(lambda: not peer.claimants, "manual/disable release")
    checks = (len(login.calls), len(login.reads), len(peer.reads), len(saver.calls))
    unchanged()
    assert checks == (len(login.calls), len(login.reads), len(peer.reads), len(saver.calls))
    peer.paused_claim = True
    settings.set_boolean(ambient.KEY, True)
    until(lambda: peer.pending_claim, "claim waiting for first sample")
    settings.set_boolean(ambient.KEY, False)
    until(lambda: not peer.claimants, "release pending claim")
    peer.finish_claim()
    unchanged()
    peer.paused_claim = False
    settings.set_boolean(ambient.KEY, True)
    until(lambda: peer.claimants, "last claim")
    stop()
    assert not peer.claimants and not (work / "activated").exists()
    print("LIFECYCLE default off, no disabled polling, pending cancellation, shutdown release, no activation verified")
finally:
    if client.poll() is None:
        stop()
