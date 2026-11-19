"""One authorized BlueZ numeric-comparison attempt against a fresh fixture marker."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import runpy
import signal
import stat
import subprocess
import tempfile
import time

from gi.repository import Gio, GLib


AGENT = '/org/y700/GuardedPair'
OWNER = 'org.freedesktop.DBus'
FLAGS = ('Paired', 'Bonded', 'Trusted')
ADDRESS = re.compile(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}')
AGENT_XML = """<node><interface name="org.bluez.Agent1">
  <method name="Release"/><method name="Cancel"/>
  <method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
  <method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
  <method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
  <method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
  <method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
  <method name="RequestAuthorization"><arg type="o" direction="in"/></method>
  <method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
</interface></node>"""


class Failure(Exception):
    """Only fixed, public status codes are permitted in this exception."""


def status(message):
    print(message, flush=True)


def put_private(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            out.write(data)
            out.flush()
            os.fchmod(out.fileno(), 0o600)
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)


def read_code(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise Failure('WINDOWS_CODE_UNSAFE')
        value = stream.read(8)
    if not re.fullmatch(rb'[0-9]{6}\n?', value):
        raise Failure('WINDOWS_CODE_INVALID')
    return value.rstrip(b'\n')


def reserve(runtime):
    if (runtime.parent != Path('/run') or not re.fullmatch(r'y700-[A-Za-z0-9_.-]+', runtime.name)
            or os.geteuid() != 0):
        raise Failure('PRIVATE_RUNTIME_REQUIRED')
    runtime.mkdir(mode=0o700, exist_ok=True)
    info = runtime.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise Failure('PRIVATE_RUNTIME_REQUIRED')
    for name in ('windows-code', 'linux-code', 'peer-address', 'abort', 'input-done'):
        if os.path.lexists(runtime/name):
            raise Failure('STALE_RUNTIME')
    try:
        fd = os.open(runtime/'guard-started', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise Failure('ATTEMPT_ALREADY_RESERVED') from None
    os.close(fd)


def inventory(objects, iface):
    return {flag: {(path, obj[iface].get('Address')) for path, obj in objects.items()
                   if obj.get(iface, {}).get(flag)} for flag in FLAGS}


def protected(peer):
    return any(peer.get(flag) for flag in (*FLAGS, 'Connected'))


def peers(objects, probe, target, addresses):
    iface, adapter = probe['DEVICE_IFACE'], probe['ADAPTER']
    result = {}
    for path, obj in objects.items():
        peer = obj.get(iface, {})
        address = peer.get('Address')
        if peer.get('Adapter') != adapter or address not in addresses:
            continue
        # A rotated identity must have the controller-supplied public address.
        if path == target or path == adapter + '/dev_' + address.replace(':', '_'):
            result[path] = peer
    return result


def desktop():
    # Only the display manager and existing graphical login sessions are observed.
    active = subprocess.check_output(['systemctl', 'is-active', 'lightdm.service'], timeout=3)
    sessions = subprocess.check_output(['loginctl', 'list-sessions', '--no-legend', '--no-pager'], timeout=3)
    seat = {line.split()[0] for line in sessions.splitlines() if b'seat0' in line.split()}
    if active.strip() != b'active' or not seat:
        raise Failure('DESKTOP_UNAVAILABLE')
    return seat


def bluez_owner(bus):
    return bus.call_sync(OWNER, '/org/freedesktop/DBus', OWNER, 'GetNameOwner',
                         GLib.Variant('(s)', ('org.bluez',)), GLib.VariantType.new('(s)'),
                         Gio.DBusCallFlags.NO_AUTO_START, 3000, None).unpack()[0]


def pump():
    context = GLib.MainContext.default()
    for _ in range(32):
        if not context.iteration(False):
            break


class Comparison:
    def __init__(self, owner, runtime, is_target):
        self.owner, self.runtime, self.is_target = owner, runtime, is_target
        self.pending = self.expected = None
        self.accepted = False
        self.failure = None

    @staticmethod
    def reject(reply):
        reply.return_dbus_error('org.bluez.Error.Rejected', 'Comparison unavailable')

    def discard(self):
        if self.pending is not None:
            self.reject(self.pending)
            self.pending = self.expected = None

    def request(self, _bus, sender, _path, _iface, method, args, reply):
        if sender != self.owner:
            self.reject(reply)
            return
        if method in ('Cancel', 'Release'):
            self.discard()
            if not self.accepted:
                self.failure = 'AGENT_CANCELLED'
            reply.return_value(None)
            return
        try:
            values = args.unpack()
            if (method != 'RequestConfirmation' or self.pending is not None or self.accepted
                    or self.failure or not self.is_target(values[0]) or not 0 <= values[1] <= 999999):
                raise Failure('UNSUPPORTED_OR_UNEXPECTED_PROMPT')
            self.expected = f'{values[1]:06d}'.encode('ascii')
            put_private(self.runtime/'linux-code', self.expected + b'\n')
            self.pending = reply
            status('TABLET_NUMERIC_COMPARISON_PENDING')
        except Exception:
            self.failure = 'UNSUPPORTED_OR_UNEXPECTED_PROMPT'
            self.reject(reply)
            self.discard()

    def poll(self):
        if self.failure:
            raise Failure(self.failure)
        if self.pending is None:
            return
        value = read_code(self.runtime/'windows-code')
        if value is not None:
            if value != self.expected:
                self.discard()
                raise Failure('NUMERIC_MISMATCH')
            self.pending.return_value(None)
            self.pending = self.expected = None
            self.accepted = True
            status('TABLET_NUMERIC_COMPARISON_MATCHED')


def attempt(probe, token, host, runtime, interrupted):
    bus, invoke, state = (probe[key] for key in ('bus', 'invoke', 'state'))
    adapter, ai, di = (probe[key] for key in ('ADAPTER', 'ADAPTER_IFACE', 'DEVICE_IFACE'))
    owner = bluez_owner(bus)
    initial, seat = state(), desktop()
    initial_inventory = inventory(initial, di)
    if not initial[adapter][ai]['Powered'] or initial[adapter][ai]['Discovering']:
        raise Failure('ADAPTER_BUSY')
    if any(protected(peer) for peer in peers(initial, probe, None, {host}).values()):
        raise Failure('EXISTING_PEER_PROTECTED')
    target = None
    addresses = {host}
    scanning = registered = issued = False
    registration = comparison = None
    result = []

    def stop_requested():
        if interrupted or (runtime/'abort').exists():
            raise Failure('ABORTED')

    def pair_done(connection, reply):
        try:
            connection.call_finish(reply)
            result.append(True)
        except GLib.Error:
            result.append(False)

    try:
        invoke(adapter, ai, 'SetDiscoveryFilter', GLib.Variant('(a{sv})', ({
            'Transport': GLib.Variant('s', 'le'), 'DuplicateData': GLib.Variant('b', True)},)))
        with probe['radio_events']() as events:
            invoke(adapter, ai, 'StartDiscovery')
            scanning = True
            target = probe['find_connectable'](events, token, host.replace(':', ''))
        invoke(adapter, ai, 'StopDiscovery')
        scanning = False
        current = state()
        peer = current[target][di]
        observed = peer['Address']
        if (peer['Adapter'] != adapter or not ADDRESS.fullmatch(observed)
                or bytes(peer.get('ServiceData', {}).get(probe['HID'], ())) != token):
            raise Failure('FRESH_MARKER_LOST')
        addresses.add(observed)
        if any(protected(p) for snapshot in (initial, current)
               for p in peers(snapshot, probe, target, addresses).values()):
            raise Failure('EXISTING_PEER_PROTECTED')
        put_private(runtime/'peer-address', observed.encode() + b'\n')
        status('TABLET_HID_ADVERTISEMENT_MATCHED')
        comparison = Comparison(owner, runtime, lambda path: path in peers(state(), probe, target, addresses))
        interface = Gio.DBusNodeInfo.new_for_xml(AGENT_XML).interfaces[0]
        registration = bus.register_object(AGENT, interface, comparison.request, None, None)
        invoke('/org/bluez', 'org.bluez.AgentManager1', 'RegisterAgent', GLib.Variant('(os)', (AGENT, 'DisplayYesNo')))
        registered = True
        stop_requested()
        if bluez_owner(bus) != owner:
            raise Failure('BLUEZ_OWNER_CHANGED')
        deadline = time.monotonic() + 50
        issued = True
        status('TABLET_SINGLE_PAIR_REQUEST')
        bus.call(owner, target, di, 'Pair', None, None, Gio.DBusCallFlags.NO_AUTO_START, 50000, None, pair_done)
        while time.monotonic() < deadline:
            stop_requested()
            pump()
            comparison.poll()
            if result:
                break
            time.sleep(.04)
        if result != [True] or not comparison.accepted:
            raise Failure('PAIR_FAILED_OR_UNCONFIRMED')
        candidates = peers(state(), probe, target, addresses)
        bonded = [p for p in candidates.values() if p.get('Bonded') and p.get('Paired')]
        if len(bonded) != 1 or any(p.get('Trusted') for p in candidates.values()):
            raise Failure('PAIR_STATE_UNVERIFIED')
        put_private(runtime/'peer-address', bonded[0]['Address'].encode() + b'\n')
        status('TABLET_PAIR_VERIFIED')
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            stop_requested()
            pump()
            comparison.poll()
            if (runtime/'input-done').exists():
                status('TABLET_INPUT_CONSUMER_DONE')
                break
            time.sleep(.06)
        else:
            status('TABLET_INPUT_WINDOW_ELAPSED')
    finally:
        if comparison:
            comparison.discard()
        failed = False
        if bluez_owner(bus) != owner:
            raise Failure('CLEANUP_BLUEZ_OWNER_CHANGED')
        if scanning:
            try:
                invoke(adapter, ai, 'StopDiscovery')
            except GLib.Error:
                failed = True
        if registered:
            try:
                invoke('/org/bluez', 'org.bluez.AgentManager1', 'UnregisterAgent', GLib.Variant('(o)', (AGENT,)))
            except GLib.Error:
                failed = True
        if registration:
            bus.unregister_object(registration)
        if issued:
            if result != [True]:
                try:
                    invoke(target, di, 'CancelPairing')
                except GLib.Error:
                    pass  # No in-progress Pair is also normal here.
            deadline = time.monotonic() + 5
            quiet_since = None
            while time.monotonic() < deadline:
                pump()
                candidates = peers(state(), probe, target, addresses)
                dirty = False
                for path, peer in candidates.items():
                    old = initial.get(path, {}).get(di, {})
                    if protected(old):
                        raise Failure('CLEANUP_EXISTING_PEER_PROTECTED')
                    if peer.get('Connected'):
                        dirty = True
                        try:
                            invoke(path, di, 'Disconnect', timeout=1000)
                        except GLib.Error:
                            pass  # An identity transition can retire this path.
                    if not old or any(peer.get(key) for key in FLAGS):
                        dirty = True
                        try:
                            invoke(adapter, ai, 'RemoveDevice', GLib.Variant('(o)', (path,)), timeout=1000)
                        except GLib.Error:
                            pass
                if not dirty:
                    if quiet_since is None:
                        quiet_since = time.monotonic()
                    if time.monotonic() - quiet_since >= .8:
                        break
                else:
                    quiet_since = None
                time.sleep(.12)
            else:
                failed = True
        after = state()
        if (failed or initial_inventory != inventory(after, di) or after[adapter][ai]['Discovering']
                or not after[adapter][ai]['Powered'] or bluez_owner(bus) != owner or desktop() != seat):
            raise Failure('CLEANUP_OR_CONTINUITY_FAILED')
        status('TABLET_DISCOVERY_AND_BONDS_RESTORED')
        status('TABLET_PAIRED_BONDED_TRUSTED_AND_DESKTOP_UNCHANGED')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('marker')
    parser.add_argument('--host-address', required=True)
    parser.add_argument('--runtime', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'(?:[0-9]{1,3}-){7}[0-9]{1,3}', args.marker):
        raise Failure('INVALID_MARKER')
    numbers = [int(v) for v in args.marker.split('-')]
    if max(numbers) > 255 or not re.fullmatch(r'[A-Fa-f0-9]{12}', args.host_address):
        raise Failure('INVALID_INPUT')
    if b'lenovo,asphalt' not in Path('/proc/device-tree/compatible').read_bytes().split(b'\0'):
        raise Failure('EXPECTED_ASPHALT_TABLET')
    reserve(args.runtime)
    interrupted = []
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda *_: interrupted.append(True))
    try:
        probe = runpy.run_path(str(Path(__file__).with_name('tablet-probe.py')))
        attempt(probe, bytes(numbers), ':'.join(re.findall('..', args.host_address.upper())),
                args.runtime, interrupted)
    finally:
        # The Windows relay holds the same directory lock when publishing a
        # comparison. Once linux-code is unlinked a late relay must stop.
        fd = os.open(args.runtime, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            for name in ('linux-code', 'windows-code'):
                (args.runtime/name).unlink(missing_ok=True)
        finally:
            os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except Failure as error:
        status('TABLET_GUARD_' + str(error))
        raise SystemExit(1)
    except Exception:
        status('TABLET_GUARD_FAILED')
        raise SystemExit(1)
