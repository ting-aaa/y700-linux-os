"""Apply sensor-proxy orientations only in the active, unlocked Xfce session."""
import math
import os
import signal
import subprocess
import sys
import time

from gi.repository import Gio, GLib

SENSOR = 'net.hadess.SensorProxy'
LOGIN = 'org.freedesktop.login1'
SAVER = 'org.xfce.ScreenSaver'
SAVER_PATH = '/org/xfce/ScreenSaver'
PASSIVE = Gio.DBusProxyFlags.DO_NOT_AUTO_START
CALL = Gio.DBusCallFlags.NO_AUTO_START


def cached(proxy, key):
    value = proxy.get_cached_property(key) if proxy else None
    return value.unpack() if value is not None else None


class Session:
    def __init__(self, policy, loop):
        self.policy = policy
        self.loop = loop
        self.settings = Gio.Settings.new('org.y700.tablet')
        self.settings.connect('changed::auto-rotate', self.refresh)
        self.login = None
        self.manager = None
        self.saver_bus = None
        self.saver_owner = None
        self.saver_subscription = 0
        self.saver_retry = 0
        self.saver_clear = False
        self.sensor_owner = None
        self.connection = None
        self.sensor = None
        self.claimed = False
        self.pending = None
        self.timer = 0
        self.retry = 0
        self.poll = 0
        self.session_id = os.environ.get('XDG_SESSION_ID', '')

    def login_appeared(self, bus, name, owner):
        try:
            self.manager = Gio.DBusProxy.new_sync(
                bus, PASSIVE, None, owner, '/org/freedesktop/login1', LOGIN + '.Manager', None)
            self.manager.connect('g-signal', self.login_signal)
            if self.session_id:
                method, arg = 'GetSession', GLib.Variant('(s)', (self.session_id,))
            else:
                method, arg = 'GetSessionByPID', GLib.Variant('(u)', (os.getpid(),))
            path, = self.manager.call_sync(method, arg, CALL, 3000, None).unpack()
            self.login = Gio.DBusProxy.new_sync(bus, PASSIVE, None, owner, path, LOGIN + '.Session', None)
            self.login.connect('g-properties-changed', self.refresh)
        except GLib.Error as exc:
            print(f'Cannot identify this graphical login: {exc.message}', file=sys.stderr)
            self.loop.quit()
            return
        self.refresh()

    def login_signal(self, manager, sender, name, parameters):
        if name == 'SessionRemoved' and self.login:
            _, path = parameters.unpack()
            if path == self.login.get_object_path():
                self.loop.quit()

    def login_gone(self, *_):
        self.login = self.manager = None
        self.refresh()

    def saver_appeared(self, bus, name, owner):
        self.saver_bus = bus
        self.saver_owner = owner
        self.saver_subscription = bus.signal_subscribe(
            owner, SAVER, 'ActiveChanged', SAVER_PATH, None, Gio.DBusSignalFlags.NONE,
            self.saver_changed)
        self.read_saver()
        self.refresh()

    def saver_gone(self, *_):
        if self.saver_subscription:
            self.saver_bus.signal_unsubscribe(self.saver_subscription)
            self.saver_subscription = 0
        if self.saver_retry:
            GLib.source_remove(self.saver_retry)
            self.saver_retry = 0
        self.saver_bus = self.saver_owner = None
        self.saver_clear = False
        self.refresh()

    def read_saver(self):
        # Address the current owner of the well-known name. A former daemon
        # can survive a handover and still answer calls to its unique name.
        try:
            reply = self.saver_bus.call_sync(
                SAVER, SAVER_PATH, SAVER, 'GetActive', None, GLib.VariantType.new('(b)'),
                CALL, 2000, None)
            self.saver_clear = not reply.unpack()[0]
        except GLib.Error:
            self.saver_clear = False
            if not self.saver_retry:
                self.saver_retry = GLib.timeout_add_seconds(2, self.retry_saver)

    def retry_saver(self):
        self.saver_retry = 0
        self.read_saver()
        self.refresh()
        return GLib.SOURCE_REMOVE

    def saver_changed(self, bus, sender, path, interface, name, parameters):
        if sender != self.saver_owner:
            return
        if parameters.get_type_string() == '(b)' and parameters.unpack()[0]:
            self.saver_clear = False
        else:
            # An unlock signal may already be queued when the saver relocks.
            self.read_saver()
        self.refresh()

    def sensor_appeared(self, bus, name, owner):
        self.sensor_owner = owner
        self.refresh()

    def sensor_gone(self, *_):
        self.sensor_owner = None
        self.disconnect()

    def connect_sensor(self):
        # v3.9 unicasts changes to the claiming sender. A private connection
        # also drops the lease on seat loss even if polkit now denies Release.
        address = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SYSTEM, None)
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        self.connection = Gio.DBusConnection.new_for_address_sync(address, flags, None, None)
        self.sensor = Gio.DBusProxy.new_sync(self.connection, PASSIVE, None, self.sensor_owner,
                                             '/net/hadess/SensorProxy', SENSOR, None)
        self.sensor.connect('g-properties-changed', self.refresh)
        self.poll = GLib.timeout_add_seconds(20, self.probe)

    def read_properties(self):
        # A driver can disappear before the proxy emits to its former clients.
        # Query the same unique owner before moving the screen.
        try:
            reply = self.sensor.call_sync('org.freedesktop.DBus.Properties.GetAll',
                                          GLib.Variant('(s)', (SENSOR,)), CALL, 2000, None)
            properties = reply.get_child_value(0)
        except GLib.Error:
            properties = None
        for name in ('HasAccelerometer', 'AccelerometerOrientation', 'AccelerometerTilt'):
            value = properties.lookup_value(name, None) if properties is not None else None
            self.sensor.set_cached_property(name, value)

    def probe(self):
        self.read_properties()
        if self.claimed and cached(self.sensor, 'HasAccelerometer') is True:
            # A driver reset between two probes can forget our claim while the
            # bus owner and HasAccelerometer stay the same. Duplicate claims
            # are idempotent. A renewed claim waits for a fresh first reading.
            self.claimed = False
            self.policy.observe(None, time.monotonic())
            if self.timer:
                GLib.source_remove(self.timer)
                self.timer = 0
        self.refresh()
        return GLib.SOURCE_CONTINUE

    def reset(self):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        if self.retry:
            GLib.source_remove(self.retry)
            self.retry = 0
        self.policy.due(time.monotonic(), locked=True)

    def release(self):
        self.reset()
        if self.claimed or self.pending is not None:
            try:
                self.sensor.call_sync('ReleaseAccelerometer', None, CALL, 3000, None)
            except GLib.Error as exc:
                print(f'Cannot release accelerometer: {exc.message}', file=sys.stderr)
        self.claimed = False
        self.pending = None

    def disconnect(self):
        self.release()
        if self.poll:
            GLib.source_remove(self.poll)
            self.poll = 0
        self.sensor = None
        if self.connection:
            try:
                self.connection.close_sync(None)
            except GLib.Error:
                pass
            self.connection = None

    def active(self):
        return (self.settings.get_boolean('auto-rotate')
                and self.saver_clear
                and cached(self.login, 'Active') is True
                and cached(self.login, 'LockedHint') is False)

    def orientation(self):
        if cached(self.sensor, 'AccelerometerTilt') in ('face-up', 'face-down'):
            return None
        return cached(self.sensor, 'AccelerometerOrientation')

    def retry_claim(self):
        self.retry = 0
        self.refresh()
        return GLib.SOURCE_REMOVE

    def refresh(self, *_):
        if not self.sensor_owner or not self.active():
            self.disconnect()
            return
        if not self.sensor:
            if self.retry:
                return
            try:
                self.connect_sensor()
            except GLib.Error as exc:
                print(f'Cannot connect to sensor proxy: {exc.message}', file=sys.stderr)
                self.disconnect()
                self.retry = GLib.timeout_add_seconds(5, self.retry_claim)
                return
        if cached(self.sensor, 'HasAccelerometer') is not True:
            self.release()
            return
        if not self.claimed:
            if not self.retry and self.pending is None:
                self.pending = object()
                self.sensor.call('ClaimAccelerometer', None, CALL, 10000, None, self.claim_finished, self.pending)
            return
        previous = self.policy.candidate
        self.policy.observe(self.orientation(), time.monotonic())
        candidate = self.policy.candidate
        if self.timer and candidate != previous:
            GLib.source_remove(self.timer)
            self.timer = 0
        if candidate and candidate != self.policy.applied and not self.timer:
            self.schedule(self.policy.settle)

    def claim_finished(self, proxy, result, token):
        try:
            proxy.call_finish(result)
        except GLib.Error as exc:
            if token is self.pending:
                print(f'Cannot claim accelerometer: {exc.message}', file=sys.stderr)
                self.disconnect()
                self.retry = GLib.timeout_add_seconds(5, self.retry_claim)
            return
        if token is self.pending:
            self.pending = None
            self.claimed = True
            self.read_properties()
            self.refresh()

    def schedule(self, seconds):
        self.timer = GLib.timeout_add(max(1, math.ceil(seconds * 1000)), self.rotate)

    def rotate(self):
        self.timer = 0
        self.read_properties()
        previous = self.policy.candidate
        self.policy.observe(self.orientation(), time.monotonic())
        if (not self.active() or cached(self.sensor, 'HasAccelerometer') is not True
                or self.policy.candidate != previous):
            self.refresh()
            return GLib.SOURCE_REMOVE
        now = time.monotonic()
        direction = self.policy.due(now)
        if not direction:
            if self.policy.candidate and self.policy.candidate != self.policy.applied:
                self.schedule(self.policy.settle - (now - self.policy.since))
            return GLib.SOURCE_REMOVE
        # Lock activation can precede delivery of ActiveChanged to this main
        # loop, including while the synchronous sensor query above was running.
        self.read_saver()
        if not self.saver_clear:
            self.disconnect()
            return GLib.SOURCE_REMOVE
        try:
            success = subprocess.run(['y700-display', '--rotate', direction], check=False).returncode == 0
        except OSError as exc:
            print(f'Cannot call display helper: {exc}', file=sys.stderr)
            success = False
        self.policy.complete(direction, success, time.monotonic())
        if not success:
            self.schedule(max(2, self.policy.settle))
        return GLib.SOURCE_REMOVE


def run_session(policy):
    loop = GLib.MainLoop()
    session = Session(policy, loop)
    flags = Gio.BusNameWatcherFlags.NONE
    watches = [
        Gio.bus_watch_name(Gio.BusType.SESSION, SAVER, flags, session.saver_appeared, session.saver_gone),
        Gio.bus_watch_name(Gio.BusType.SYSTEM, LOGIN, flags, session.login_appeared, session.login_gone),
        Gio.bus_watch_name(Gio.BusType.SYSTEM, SENSOR, flags, session.sensor_appeared, session.sensor_gone),
    ]
    for signum in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, loop.quit)
    try:
        loop.run()
    finally:
        session.disconnect()
        for watch in watches:
            Gio.bus_unwatch_name(watch)
    return 0
