"""Exercise the guard without a system bus, HCI socket, or physical devices."""

from contextlib import nullcontext, redirect_stdout
from copy import deepcopy
import importlib.util
import io
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

from gi.repository import Gio, GLib


spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('guarded-pair.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
ADAPTER, AI, DI, HID = '/org/bluez/hci0', 'org.bluez.Adapter1', 'org.bluez.Device1', 'fake-hid'
TOKEN = b'fixture!'
HOST, RANDOM, OTHER = '01:02:03:04:05:06', 'D0:02:03:04:05:06', '04:04:04:04:04:04'


def device(address):
    return ADAPTER + '/dev_' + address.replace(':', '_')


def record(address, **properties):
    return {DI: dict(Adapter=ADAPTER, Address=address, ServiceData={HID: TOKEN}, **properties)}


class Reply:
    def __init__(self):
        self.accepted = None

    def return_value(self, _):
        self.accepted = True

    def return_dbus_error(self, *unused):
        self.accepted = False


class OfflineBlueZ:
    def __init__(self, runtime, scenario):
        self.runtime, self.scenario = runtime, scenario
        self.objects = {ADAPTER: {AI: {'Powered': True, 'Discovering': False}},
                        device(OTHER): record(OTHER, Paired=True, Bonded=True, Trusted=True)}
        self.attempts, self.removed, self.when = 0, [], 0
        self.reply = self.callback = self.finish = None

    def sleep(self, delay):
        self.when += delay

    def register_object(self, path, interface, callback, *unused):
        self.callback = callback
        return 1

    def unregister_object(self, unused):
        self.callback = None

    def invoke(self, path, iface, method, params=None, **unused):
        if method in ('StartDiscovery', 'StopDiscovery'):
            self.objects[ADAPTER][AI]['Discovering'] = method == 'StartDiscovery'
        elif method == 'RemoveDevice':
            self.removed.append(params.unpack()[0])
            del self.objects[self.removed[-1]]
        elif method == 'Disconnect':
            self.objects[path][DI]['Connected'] = False
        elif method not in ('RegisterAgent', 'UnregisterAgent', 'SetDiscoveryFilter', 'CancelPairing'):
            raise AssertionError(method)

    def find(self, *unused):
        self.objects[device(RANDOM)] = record(RANDOM)
        return device(RANDOM)

    def call(self, owner, target, iface, method, *args):
        assert (owner, target, iface, method) == (':1.8', device(RANDOM), DI, 'Pair')
        self.attempts += 1
        self.finish = args[-1]
        if self.scenario == 'silent':
            self.complete()

    def complete(self):
        del self.objects[device(RANDOM)]
        self.objects[device(HOST)] = record(HOST, Connected=True, Bonded=True, Paired=True)
        self.finish(self, None)
        self.finish = None

    def call_finish(self, result):
        return ()

    def pump(self):
        if not self.finish:
            return
        if self.reply is None:
            self.reply = Reply()
            if self.scenario == 'unsupported':
                method, values = 'RequestAuthorization', GLib.Variant('(o)', (device(RANDOM),))
            else:
                method, values = 'RequestConfirmation', GLib.Variant('(ou)', (device(RANDOM), 42))
            self.callback(None, ':1.8', '', '', method, values, self.reply)
            if self.scenario in ('match', 'no-consumer', 'mismatch'):
                guard.put_private(self.runtime/'windows-code', b'123456' if self.scenario == 'mismatch' else b'000042\n')
            elif self.scenario == 'abort':
                (self.runtime/'abort').touch()
        elif self.reply.accepted and self.finish:
            self.complete()
            if self.scenario == 'match':
                (self.runtime/'input-done').touch()

    def run(self):
        probe = dict(bus=self, invoke=self.invoke, state=lambda: deepcopy(self.objects),
                     ADAPTER=ADAPTER, ADAPTER_IFACE=AI, DEVICE_IFACE=DI, HID=HID,
                     radio_events=lambda: nullcontext(None), find_connectable=self.find)
        with mock.patch.object(guard, 'bluez_owner', return_value=':1.8'), \
                mock.patch.object(guard, 'desktop', return_value={b'c1'}), \
                mock.patch.object(guard, 'pump', side_effect=self.pump), \
                mock.patch.object(guard, 'time', monotonic=lambda: self.when, sleep=self.sleep):
            guard.attempt(probe, TOKEN, HOST, self.runtime, [])


class GuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.runtime = Path(tmp.name)
        self.output = io.StringIO()
        capture = redirect_stdout(self.output)
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def exercise(self, scenario, failure=None):
        fake = OfflineBlueZ(self.runtime, scenario)
        original = deepcopy(fake.objects)
        with self.assertRaisesRegex(guard.Failure, failure) if failure else nullcontext():
            fake.run()
        self.assertEqual(fake.attempts, 1)
        self.assertEqual(fake.objects, original)
        self.assertNotIn(device(OTHER), fake.removed)
        self.assertNotIn('000042', self.output.getvalue())
        self.assertNotIn(RANDOM, self.output.getvalue())
        return fake

    def test_match_and_rotated_identity_cleanup(self):
        fake = self.exercise('match')
        self.assertEqual(fake.removed, [device(HOST)])
        self.assertEqual((self.runtime/'peer-address').read_text().strip(), HOST)
        self.assertEqual((self.runtime/'linux-code').read_text(), '000042\n')
        self.assertEqual((self.runtime/'linux-code').stat().st_mode & 0o777, 0o600)
        self.assertIn('TABLET_INPUT_CONSUMER_DONE', self.output.getvalue())

    def test_silent_pair_is_refused_and_removed(self):
        self.exercise('silent', 'UNCONFIRMED')
        self.assertNotIn('TABLET_PAIR_VERIFIED', self.output.getvalue())

    def test_reject_unexpected_prompt(self):
        self.assertFalse(self.exercise('unsupported', 'UNSUPPORTED').reply.accepted)

    def test_reject_mismatch(self):
        self.assertFalse(self.exercise('mismatch', 'NUMERIC_MISMATCH').reply.accepted)

    def test_abort(self):
        self.assertFalse(self.exercise('abort', 'ABORTED').reply.accepted)

    def test_timeout(self):
        self.assertLess(self.exercise('timeout', 'UNCONFIRMED').when, 52)

    def test_consumer_deadline(self):
        self.assertLess(self.exercise('no-consumer').when, 17)
        self.assertIn('TABLET_INPUT_WINDOW_ELAPSED', self.output.getvalue())

    def test_prior_host_relationship_never_touched(self):
        for flag in ('Trusted', 'Paired', 'Bonded', 'Connected'):
            with self.subTest(flag=flag):
                fake = OfflineBlueZ(self.runtime, 'match')
                fake.objects[device(HOST)] = record(HOST, **{flag: True})
                old = deepcopy(fake.objects)
                with self.assertRaisesRegex(guard.Failure, 'EXISTING_PEER_PROTECTED'):
                    fake.run()
                self.assertEqual(fake.objects, old)
                self.assertEqual((fake.attempts, fake.removed), (0, []))

    def test_foreign_agent_sender_rejected(self):
        agent = guard.Comparison(':1.8', self.runtime, lambda path: True)
        reply = Reply()
        agent.request(None, ':1.9', '', '', 'RequestConfirmation', GLib.Variant('(ou)', (device(RANDOM), 42)), reply)
        self.assertFalse(reply.accepted)
        self.assertIsNone(agent.pending)
        self.assertFalse((self.runtime/'linux-code').exists())

    def test_code_rejects_insecure_files(self):
        path = self.runtime/'windows-code'
        path.write_text('000123\n')
        path.chmod(0o644)
        with self.assertRaisesRegex(guard.Failure, 'UNSAFE'):
            guard.read_code(path)
        path.unlink()
        path.symlink_to(self.runtime/'missing')
        with self.assertRaises(OSError):
            guard.read_code(path)

    def test_real_dbus_confirmation_is_held_until_independent_reply(self):
        daemon = Gio.TestDBus.new(Gio.TestDBusFlags.NONE)
        daemon.up()
        self.addCleanup(daemon.down)
        def connection():
            flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
            bus = Gio.DBusConnection.new_for_address_sync(daemon.get_bus_address(), flags, None, None)
            self.addCleanup(bus.close_sync, None)
            return bus
        client, server = connection(), connection()
        dest = device(RANDOM)
        agent = guard.Comparison(client.get_unique_name(), self.runtime, lambda path: path == dest)
        xml = Gio.DBusNodeInfo.new_for_xml(guard.AGENT_XML)
        ident = server.register_object(guard.AGENT, xml.interfaces[0], agent.request, None, None)
        self.addCleanup(server.unregister_object, ident)
        results = []
        def finished(conn, reply):
            results.append(conn.call_finish(reply).unpack())
        client.call(server.get_unique_name(), guard.AGENT, 'org.bluez.Agent1', 'RequestConfirmation',
                    GLib.Variant('(ou)', (dest, 7)), None, Gio.DBusCallFlags.NO_AUTO_START, 3000, None, finished)
        def until(condition):
            until_time = time.monotonic() + 2
            while not condition() and time.monotonic() < until_time:
                guard.pump()
                time.sleep(.005)
            self.assertTrue(condition())
        until(lambda: agent.pending is not None)
        agent.poll()
        self.assertFalse(results)
        self.assertEqual((self.runtime/'linux-code').read_bytes(), b'000007\n')
        guard.put_private(self.runtime/'windows-code', b'000007\n')
        agent.poll()
        until(lambda: bool(results))
        self.assertEqual(results, [()])
